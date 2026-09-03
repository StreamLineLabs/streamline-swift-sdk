import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Connection State

/// Represents the current state of the client's connection to the server.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

// MARK: - Delegate

/// Delegate protocol for receiving connection lifecycle events.
public protocol StreamlineClientDelegate: AnyObject {
    func client(_ client: StreamlineClient, didChangeState state: ConnectionState)
    func client(_ client: StreamlineClient, didReceiveMessage message: StreamlineMessage)
    func client(_ client: StreamlineClient, didEncounterError error: StreamlineError)
}

// Optional default implementations so delegates can be selective.
public extension StreamlineClientDelegate {
    func client(_ client: StreamlineClient, didChangeState state: ConnectionState) {}
    func client(_ client: StreamlineClient, didReceiveMessage message: StreamlineMessage) {}
    func client(_ client: StreamlineClient, didEncounterError error: StreamlineError) {}
}

// MARK: - Message Handler

/// Closure invoked when a message arrives on a subscribed topic.
public typealias MessageHandler = @Sendable (StreamlineMessage) -> Void

// MARK: - StreamlineClient

/// Primary entry-point for interacting with a Streamline server over WebSocket.
///
/// The client supports automatic reconnection with exponential backoff and an
/// offline message queue that buffers produce calls while disconnected.
public final class StreamlineClient: @unchecked Sendable {

    // MARK: - Properties

    public let configuration: StreamlineConfiguration
    public weak var delegate: StreamlineClientDelegate?
    public var producerConfig: ProducerConfig
    public var circuitBreaker: CircuitBreaker?

    public private(set) var state: ConnectionState = .disconnected

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession

    /// Active topic subscriptions: topic → handler.
    private var subscriptions: [String: MessageHandler] = [:]

    /// Messages queued while the client was disconnected.
    private var offlineQueue: [StreamlineMessage] = []
    private let maxOfflineQueueSize = 1000

    /// Number of messages at the front of `offlineQueue` that are prior
    /// produce failures already waiting for redelivery (as opposed to newly
    /// buffered messages appended by `enqueueOffline` while disconnected).
    /// Tracked so repeated individual `requeueForReconnect` calls — one per
    /// exhausted in-flight send, each arriving on its own async completion —
    /// insert after previously-requeued entries instead of always at index 0,
    /// which would otherwise reverse their original relative order. Reset to
    /// zero whenever `drainOfflineQueue` consumes the whole queue.
    private var offlineRequeuePriorityCount = 0

    /// Producer batch accumulator: topic → pending messages.
    private var batchQueue: [StreamlineMessage] = []
    private var batchFlushTimer: DispatchWorkItem?

    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?

    /// Monotonically increasing token identifying the current connection
    /// lifecycle attempt. Bumped on every `connect()` and `disconnect()` so a
    /// reconnect `Task` scheduled by an earlier attempt can detect it has
    /// been superseded and must not resurrect a connection.
    private var reconnectGeneration = 0

    /// `true` once the caller has explicitly requested `disconnect()` (or the
    /// client has never been connected). While `true`, no reconnect attempt
    /// may run, no matter how a stale `Task` races with `disconnect()`.
    private var isClosed = true

    private let lock = NSLock()

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Snapshot of reconnect lifecycle bookkeeping for white-box testing.
    /// Not part of the public API surface (no access modifier keeps it
    /// module-internal); production code should observe ``state`` instead.
    func reconnectLifecycleSnapshotForTesting() -> (isClosed: Bool, generation: Int, hasReconnectTask: Bool) {
        synchronized { (isClosed, reconnectGeneration, reconnectTask != nil) }
    }

    /// Snapshot of the offline (disconnected-produce) buffer for white-box
    /// testing. Not part of the public API surface (no access modifier keeps
    /// it module-internal); production code should rely on automatic
    /// draining on reconnect instead.
    func offlineQueueSnapshotForTesting() -> [StreamlineMessage] {
        synchronized { offlineQueue }
    }

    /// Testing-only entry point for the offline-drain retry path exercised
    /// automatically by ``handleConnectionReady(_:)`` on every reconnect.
    func drainOfflineQueueForTesting() {
        drainOfflineQueue()
    }

    // Client metrics
    private var _metrics = ClientMetrics()

    /// Read-only snapshot of client-side metrics.
    public var clientMetrics: ClientMetrics {
        lock.lock()
        let m = _metrics
        lock.unlock()
        return m
    }

    // Poll buffer for poll-based consumption
    private var pollBuffer: [StreamlineMessage] = []
    private let pollBufferCapacity = 10_000

    // MARK: - Init

    public init(
        configuration: StreamlineConfiguration,
        circuitBreaker: CircuitBreaker? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.producerConfig = configuration.producerConfig
        self.circuitBreaker = circuitBreaker
        self.session = session
    }

    /// Retained for source compatibility. Put producer settings on
    /// ``StreamlineConfiguration/producerConfig`` instead.
    @available(
        *,
        deprecated,
        message: "Pass producerConfig through StreamlineConfiguration instead."
    )
    public init(
        configuration: StreamlineConfiguration,
        producerConfig: ProducerConfig,
        circuitBreaker: CircuitBreaker? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.producerConfig = producerConfig
        self.circuitBreaker = circuitBreaker
        self.session = session
    }

    deinit {
        // reconnectTask/isClosed/reconnectGeneration are only ever mutated
        // under `lock` elsewhere; we keep that discipline here too even
        // though deinit has no concurrent observers of `self`.
        let pendingReconnect: Task<Void, Never>? = synchronized {
            isClosed = true
            reconnectGeneration &+= 1
            let task = reconnectTask
            reconnectTask = nil
            return task
        }
        pendingReconnect?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connection

    /// Open a WebSocket connection to the configured server URL.
    public func connect() {
        do {
            try configuration.validate()
            try producerConfig.validate()
        } catch let error as StreamlineError {
            reportConnectionConfigurationError(error)
            return
        } catch {
            reportConnectionConfigurationError(
                .configurationError(error.localizedDescription)
            )
            return
        }

        lock.lock()
        guard state == .disconnected || state == .reconnecting else {
            lock.unlock()
            return
        }
        let previousState = state
        let isReconnecting = state == .reconnecting
        if !isReconnecting { state = .connecting }
        let currentState = state
        // An explicit connect() reopens the lifecycle and invalidates any
        // reconnect Task scheduled by a previous attempt: that Task's
        // captured generation will no longer match, so it cannot race this
        // call into a duplicate/resurrected connection.
        isClosed = false
        reconnectGeneration &+= 1
        lock.unlock()
        notifyStateChange(from: previousState, to: currentState)

        var request = URLRequest(url: configuration.url, timeoutInterval: configuration.timeout)
        if let token = configuration.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        lock.lock()
        webSocketTask = task
        lock.unlock()

        task.resume()
        listenForMessages(on: task)
        task.sendPing { [weak self, weak task] error in
            guard let self, let task else { return }
            if let error {
                self.delegate?.client(
                    self,
                    didEncounterError: .connectionFailed(error.localizedDescription)
                )
                self.handleDisconnection(of: task)
                return
            }
            self.handleConnectionReady(task)
        }
    }

    /// Gracefully close the connection.
    ///
    /// Marking the client closed, bumping the generation token, and clearing
    /// any in-flight reconnect `Task` all happen atomically under `lock`, so
    /// a reconnect `Task` created concurrently by `handleDisconnection`
    /// cannot race this call into resurrecting a connection: before it ever
    /// calls `connect()`, it re-checks `isClosed` and its captured
    /// generation against the current value under the same lock.
    public func disconnect() {
        lock.lock()
        isClosed = true
        reconnectGeneration &+= 1
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        let task = webSocketTask
        webSocketTask = nil
        let previousState = state
        state = .disconnected
        lock.unlock()

        pendingReconnect?.cancel()
        notifyStateChange(from: previousState, to: .disconnected)
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Produce

    /// Send a message to the given topic. Messages are accumulated into batches
    /// and flushed when the batch reaches `producerConfig.batchSize` bytes or
    /// after `producerConfig.lingerMs` milliseconds, whichever comes first.
    /// If the client is disconnected the message is placed in the offline queue.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
        try TopicNameValidator.validate(topic)
        try producerConfig.validate()

        // Check circuit breaker before accepting the message
        if let cb = circuitBreaker {
            try cb.check()
        }

        let message = StreamlineMessage(topic: topic, key: key, value: value)

        lock.lock()
        let currentState = state
        let currentTask = webSocketTask
        lock.unlock()

        guard currentState == .connected, currentTask != nil else {
            try enqueueOffline(message)
            return
        }

        lock.lock()
        batchQueue.append(message)
        let totalBytes = batchQueue.reduce(0) { $0 + $1.value.count }
        let shouldFlush = totalBytes >= producerConfig.batchSize
        lock.unlock()

        if shouldFlush {
            flushBatch()
        } else {
            scheduleLingerFlush()
        }
    }

    /// Convenience overload accepting a UTF-8 string value.
    public func produce(topic: String, key: String? = nil, stringValue: String) throws {
        try produce(topic: topic, key: key, value: Data(stringValue.utf8))
    }

    // MARK: - Transactions

    /// Transactions are unsupported by the current WebSocket wire protocol.
    @available(*, deprecated, message: "Transactions are unsupported and always throw.")
    public func beginTransaction() throws {
        throw Self.unsupportedTransactionError()
    }

    /// Transactions are unsupported by the current WebSocket wire protocol.
    @available(*, deprecated, message: "Transactions are unsupported and always throw.")
    public func sendTransactional(topic: String, key: String? = nil, value: Data) throws {
        throw Self.unsupportedTransactionError()
    }

    /// Transactions are unsupported by the current WebSocket wire protocol.
    @available(*, deprecated, message: "Transactions are unsupported and always throw.")
    public func commitTransaction() throws {
        throw Self.unsupportedTransactionError()
    }

    /// Transactions are unsupported by the current WebSocket wire protocol.
    @available(*, deprecated, message: "Transactions are unsupported and always throw.")
    public func abortTransaction() throws {
        throw Self.unsupportedTransactionError()
    }

    static func unsupportedTransactionError() -> StreamlineError {
        StreamlineError.transaction(
            "transactions are unsupported by the current WebSocket wire protocol"
        )
    }

    /// Flush all pending batched messages immediately.
    public func flushBatch() {
        lock.lock()
        batchFlushTimer?.cancel()
        batchFlushTimer = nil
        let messages = batchQueue
        batchQueue.removeAll()
        let ws = state == .connected ? webSocketTask : nil
        lock.unlock()

        guard !messages.isEmpty else { return }
        guard let ws else {
            requeueForReconnect(messages)
            return
        }

        for message in messages {
            sendWithRetry(message: message, ws: ws)
        }
    }

    private func scheduleLingerFlush() {
        lock.lock()
        guard batchFlushTimer == nil else {
            lock.unlock()
            return
        }
        let lingerMs = producerConfig.lingerMs
        let item = DispatchWorkItem { [weak self] in
            self?.flushBatch()
        }
        batchFlushTimer = item
        lock.unlock()

        let delayMs = max(lingerMs, 1)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(delayMs),
            execute: item
        )
    }

    private func sendWithRetry(message: StreamlineMessage, ws: URLSessionWebSocketTask) {
        let payload = encodeMessage(message)
        sendAttempt(
            message: message,
            payload: payload,
            ws: ws,
            attempt: 0,
            startTime: Date()
        )
    }

    private func sendAttempt(
        message: StreamlineMessage,
        payload: Data,
        ws: URLSessionWebSocketTask,
        attempt: Int,
        startTime: Date
    ) {
        ws.send(.data(payload)) { [weak self, weak ws] error in
            guard let self else { return }

            if let error {
                self.circuitBreaker?.recordFailure()
                self.lock.lock()
                self._metrics.produceErrors += 1
                self.lock.unlock()

                if attempt < self.producerConfig.retries {
                    let delayMs =
                        self.producerConfig.retryBackoffMs
                        * Int(pow(2.0, Double(attempt)))
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + .milliseconds(delayMs)
                    ) { [weak self, weak ws] in
                        guard let self else { return }
                        guard let ws else {
                            // The socket that owned this retry is gone (the
                            // client disconnected while backing off). Treat
                            // this exactly like exhausted retries: requeue
                            // instead of silently dropping the message.
                            self.handleExhaustedProduceRetries(
                                message: message,
                                sendError: error
                            )
                            return
                        }
                        self.sendAttempt(
                            message: message,
                            payload: payload,
                            ws: ws,
                            attempt: attempt + 1,
                            startTime: startTime
                        )
                    }
                } else {
                    self.handleExhaustedProduceRetries(message: message, sendError: error)
                }
                return
            }

            self.circuitBreaker?.recordSuccess()
            let latencyMs = Date().timeIntervalSince(startTime) * 1000
            self.lock.lock()
            let count = self._metrics.produceCount
            let previousAverage = self._metrics.produceAvgLatencyMs
            self._metrics.produceCount += 1
            self._metrics.produceBytes += Int64(message.value.count)
            self._metrics.produceAvgLatencyMs =
                (previousAverage * Double(count) + latencyMs) / Double(count + 1)
            self.lock.unlock()
        }
    }

    /// Called once a produce attempt has exhausted its retry budget (or its
    /// socket disappeared mid-backoff). The message is requeued — front of
    /// line — into the offline buffer so the next successful reconnect
    /// drain retries it, and the terminal failure is surfaced to the
    /// delegate instead of being dropped on the floor.
    func handleExhaustedProduceRetries(message: StreamlineMessage, sendError: Error) {
        requeueForReconnect([message])
        delegate?.client(
            self,
            didEncounterError: .connectionFailed(sendError.localizedDescription)
        )
    }

    // MARK: - Subscribe / Unsubscribe

    /// Register a handler for messages on the given topic.
    public func subscribe(topic: String, handler: @escaping MessageHandler) {
        guard (try? TopicNameValidator.validate(topic)) != nil else { return }
        lock.lock()
        subscriptions[topic] = handler
        let ws = state == .connected ? webSocketTask : nil
        lock.unlock()

        guard let ws else { return }
        sendSubscription(action: "subscribe", topic: topic, over: ws)
    }

    /// Remove the subscription for the given topic.
    public func unsubscribe(topic: String) {
        lock.lock()
        subscriptions.removeValue(forKey: topic)
        let ws = state == .connected ? webSocketTask : nil
        lock.unlock()

        guard let ws else { return }
        sendSubscription(action: "unsubscribe", topic: topic, over: ws)
    }

    // MARK: - AsyncStream Consumption

    /// Returns an `AsyncStream` of messages for the given topic.
    ///
    /// The stream subscribes when iteration begins and unsubscribes when
    /// the task is cancelled. Use with Swift's `for await` syntax:
    ///
    /// ```swift
    /// for await message in client.messages(topic: "events") {
    ///     print("Got: \(String(data: message.value, encoding: .utf8)!)")
    /// }
    /// ```
    public func messages(topic: String) -> AsyncStream<StreamlineMessage> {
        AsyncStream { continuation in
            self.subscribe(topic: topic) { message in
                continuation.yield(message)
            }
            continuation.onTermination = { @Sendable _ in
                self.unsubscribe(topic: topic)
            }
        }
    }

    // MARK: - Poll-based Consumption

    /// Poll for messages from all subscribed topics.
    ///
    /// Returns up to `maxRecords` messages that have been buffered from
    /// active subscriptions. This provides a Kafka-style pull model
    /// complementing the callback-based ``subscribe(topic:handler:)``
    /// and async ``messages(topic:)`` APIs.
    ///
    /// - Parameters:
    ///   - maxRecords: Maximum messages to return (default: 500).
    ///   - timeout: Maximum time to wait for messages if buffer is empty.
    /// - Returns: Array of buffered messages.
    public func poll(maxRecords: Int = 500, timeout: TimeInterval = 1.0) async -> [StreamlineMessage] {
        if let batch: [StreamlineMessage] = synchronized({
            guard !pollBuffer.isEmpty else { return nil }
            let count = min(maxRecords, pollBuffer.count)
            let batch = Array(pollBuffer.prefix(count))
            pollBuffer.removeFirst(count)
            return batch
        }) {
            return batch
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if let batch: [StreamlineMessage] = synchronized({
                guard !pollBuffer.isEmpty else { return nil }
                let count = min(maxRecords, pollBuffer.count)
                let batch = Array(pollBuffer.prefix(count))
                pollBuffer.removeFirst(count)
                return batch
            }) {
                return batch
            }
        }
        return []
    }

    // MARK: - Internals

    /// Current consumer positions tracked locally (topic:partition → offset)
    /// from `seekToOffset`/`seekToBeginning`/`seekToEnd`. This is a
    /// best-effort, non-authoritative hint returned by the source-compatible
    /// `position(topic:partition:)` overload — never treat it as a
    /// broker-confirmed position. `queryPosition(topic:partition:)` never
    /// reads from this cache and always fails closed instead.
    private var currentPositions: [String: Int64] = [:]

    // MARK: - Offset Management

    /// Commit consumer offsets.
    ///
    /// The current WebSocket protocol has no verified offset-commit
    /// acknowledgement contract, so this method always fails closed instead
    /// of treating a local WebSocket send or cache update as a durable broker
    /// commit.
    ///
    /// - Parameter offsets: A dictionary of `"topic:partition"` keys to offset values.
    /// - Throws: ``StreamlineError/unsupported(_:)``.
    public func commitOffsets(_ offsets: [String: Int64]) async throws {
        _ = offsets
        throw StreamlineError.unsupported(
            "offset commits are unavailable because the WebSocket protocol does not define a broker acknowledgement"
        )
    }

    /// Seek to a specific offset for a topic partition.
    ///
    /// - Parameters:
    ///   - topic: The topic name.
    ///   - partition: The partition index.
    ///   - offset: The offset to seek to.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToOffset(topic: String, partition: Int, offset: Int64) async throws {
        let ws = synchronized { state == .connected ? webSocketTask : nil }

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "seek",
            "topic": topic,
            "partition": partition,
            "offset": NSNumber(value: offset),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        let key = "\(topic):\(partition)"
        synchronized {
            currentPositions[key] = offset
        }
    }

    /// Seek to the beginning of all partitions for the given topic.
    ///
    /// - Parameter topic: The topic name.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToBeginning(topic: String) async throws {
        let ws = synchronized { state == .connected ? webSocketTask : nil }

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "seek_to_beginning",
            "topic": topic,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        synchronized {
            let keysToReset = currentPositions.keys.filter { $0.hasPrefix("\(topic):") }
            for key in keysToReset {
                currentPositions[key] = 0
            }
        }
    }

    /// Seek to the end (latest) of all partitions for the given topic.
    ///
    /// - Parameter topic: The topic name.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToEnd(topic: String) async throws {
        let ws = synchronized { state == .connected ? webSocketTask : nil }

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "seek_to_end",
            "topic": topic,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        synchronized {
            let keysToReset = currentPositions.keys.filter { $0.hasPrefix("\(topic):") }
            for key in keysToReset {
                currentPositions.removeValue(forKey: key)
            }
        }
    }

    /// Best-effort, non-authoritative local hint for the consumer position of
    /// a specific topic partition.
    ///
    /// Retained for source compatibility with versions of this SDK prior to
    /// the fail-closed offset-protocol fix, which had this method perform a
    /// live query over a WebSocket action with no verified response
    /// contract. This overload no longer sends that invented request at
    /// all — it never talks to the broker — so it stays `async` and
    /// non-throwing rather than becoming `async throws`, and existing
    /// callers do not need to add `try`.
    ///
    /// The only value it can honestly report is this client's own local
    /// bookkeeping from `seekToOffset`/`seekToBeginning`/`seekToEnd`. That
    /// value is a **non-authoritative hint**: it can be stale, wrong after
    /// reconnecting to a different broker, or simply unknown (`nil`) if this
    /// client never sought that partition. Do not treat a non-nil result as
    /// a broker-confirmed position. Use ``queryPosition(topic:partition:)``
    /// if a possibly-misleading local guess is unacceptable and you need
    /// failures to be explicit instead.
    ///
    /// - Returns: The locally-tracked position, or `nil` if unknown.
    public func position(topic: String, partition: Int) async -> Int64? {
        let key = "\(topic):\(partition)"
        return synchronized { currentPositions[key] }
    }

    /// Broker-verified consumer position query.
    ///
    /// Always fails with ``StreamlineError/unsupported(_:)``: the current
    /// WebSocket protocol has no verified position-query response contract,
    /// so this method never fabricates a request/response round trip or
    /// dresses up a local cache as broker-authoritative. This is a new,
    /// separately named API — it does not replace or change the source
    /// shape of ``position(topic:partition:)``.
    ///
    /// - Throws: ``StreamlineError/unsupported(_:)``, always.
    public func queryPosition(topic: String, partition: Int) async throws -> Int64 {
        _ = topic
        _ = partition
        throw StreamlineError.unsupported(
            "consumer position queries are unavailable because the WebSocket response contract is not defined"
        )
    }

    /// Best-effort, non-authoritative local hint for the last committed
    /// offset of a specific topic partition.
    ///
    /// Retained for source compatibility with versions of this SDK prior to
    /// the fail-closed offset-protocol fix. This SDK never durably commits
    /// offsets to the broker (see ``commitOffsets(_:)``), so there is no
    /// local or broker-verified committed offset to honestly report here —
    /// this always returns `nil`. It is kept `async` and non-throwing,
    /// rather than removed, purely so callers written against older
    /// versions of this SDK keep compiling without adding `try`. Use
    /// ``queryCommitted(topic:partition:)`` for a call that fails loudly
    /// instead of silently returning `nil`.
    ///
    /// - Returns: Always `nil`.
    public func committed(topic: String, partition: Int) async -> Int64? {
        _ = topic
        _ = partition
        return nil
    }

    /// Broker-verified committed-offset query.
    ///
    /// Always fails with ``StreamlineError/unsupported(_:)``: the current
    /// WebSocket protocol has no verified committed-offset response
    /// contract. This is a new, separately named API — it does not replace
    /// or change the source shape of ``committed(topic:partition:)``.
    ///
    /// - Throws: ``StreamlineError/unsupported(_:)``, always.
    public func queryCommitted(topic: String, partition: Int) async throws -> Int64 {
        _ = topic
        _ = partition
        throw StreamlineError.unsupported(
            "committed-offset queries are unavailable because the WebSocket response contract is not defined"
        )
    }

    // MARK: - Receive Loop

    private func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, self.isCurrentWebSocketTask(task) else { return }
            switch result {
            case .success(let wsMessage):
                self.handleIncoming(wsMessage)
                self.listenForMessages(on: task)
            case .failure(let error):
                self.delegate?.client(
                    self,
                    didEncounterError: .connectionFailed(error.localizedDescription)
                )
                self.handleDisconnection(of: task)
            }
        }
    }

    func handleIncoming(_ wsMessage: URLSessionWebSocketTask.Message) {
        let data: Data
        switch wsMessage {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            return
        }

        guard let message = decodeMessage(data) else { return }

        // Track consume metrics and buffer for poll
        lock.lock()
        _metrics.consumeCount += 1
        _metrics.consumeBytes += Int64(message.value.count)
        if pollBuffer.count < pollBufferCapacity {
            pollBuffer.append(message)
        }
        let handler = subscriptions[message.topic]
        lock.unlock()

        if let handler {
            handler(message)
        }
        delegate?.client(self, didReceiveMessage: message)
    }

    // MARK: - Reconnection

    private func handleDisconnection(of task: URLSessionWebSocketTask) {
        lock.lock()
        guard webSocketTask === task else {
            lock.unlock()
            return
        }
        webSocketTask = nil
        guard !isClosed, configuration.autoReconnect, retryCount < configuration.maxRetries else {
            let previousState = state
            state = .disconnected
            lock.unlock()
            notifyStateChange(from: previousState, to: .disconnected)
            return
        }
        let previousState = state
        state = .reconnecting
        retryCount += 1
        let attempt = retryCount
        reconnectGeneration &+= 1
        let myGeneration = reconnectGeneration
        lock.unlock()
        notifyStateChange(from: previousState, to: .reconnecting)

        let backoff = min(
            configuration.initialBackoff * pow(2.0, Double(attempt - 1)),
            configuration.maxBackoff
        )

        let newReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let self else { return }
            // Re-check, under the lock, that nothing (an explicit
            // disconnect(), a fresh connect(), or a newer reconnect attempt)
            // has superseded this one while we were asleep. This is the
            // authoritative gate — Task cancellation alone is a best-effort
            // signal and races with disconnect()'s own bookkeeping, so it is
            // not sufficient on its own to prevent resurrecting a connection
            // the caller explicitly closed.
            let shouldConnect: Bool = self.synchronized {
                !self.isClosed && self.reconnectGeneration == myGeneration
            }
            guard shouldConnect, !Task.isCancelled else { return }
            self.connect()
        }

        let installed: Bool = synchronized {
            // Only install this Task as the current reconnectTask if it is
            // still the current generation and the client hasn't been closed
            // in the interim; otherwise cancel it immediately so it never
            // fires (defense in depth alongside the generation re-check
            // above, which is the real race-closing guarantee).
            guard !isClosed, reconnectGeneration == myGeneration else { return false }
            reconnectTask = newReconnectTask
            return true
        }
        if !installed {
            newReconnectTask.cancel()
        }

    }

    // MARK: - Offline Queue

    private func enqueueOffline(_ message: StreamlineMessage) throws {
        lock.lock()
        defer { lock.unlock() }
        guard offlineQueue.count < maxOfflineQueueSize else {
            throw StreamlineError.offlineQueueFull
        }
        offlineQueue.append(message)
    }

    private func drainOfflineQueue() {
        lock.lock()
        let queued = offlineQueue
        offlineQueue.removeAll()
        // The whole queue is being redriven from scratch, so any earlier
        // requeue-priority bookkeeping no longer applies.
        offlineRequeuePriorityCount = 0
        lock.unlock()

        // Re-drive every buffered message through `produce(topic:key:value:)`
        // in original order. A message that fails here (validation, producer
        // config, or an open circuit breaker) must never simply vanish —
        // collect it and requeue it (front of line, preserving order) rather
        // than swallowing the throw with `try?` as before.
        var failedMessages: [StreamlineMessage] = []
        var firstFailure: StreamlineError?

        for message in queued {
            do {
                try produce(topic: message.topic, key: message.key, value: message.value)
            } catch let error as StreamlineError {
                failedMessages.append(message)
                if firstFailure == nil { firstFailure = error }
            } catch {
                failedMessages.append(message)
                if firstFailure == nil {
                    firstFailure = .internalError(error.localizedDescription)
                }
            }
        }

        guard !failedMessages.isEmpty else { return }

        requeueForReconnect(failedMessages)
        if let firstFailure {
            delegate?.client(self, didEncounterError: firstFailure)
        }
    }

    private func requeueForReconnect(_ messages: [StreamlineMessage]) {
        lock.lock()
        let availableCapacity = maxOfflineQueueSize - offlineQueue.count
        let acceptedCount = min(messages.count, max(availableCapacity, 0))
        if acceptedCount > 0 {
            // Insert after any previously-requeued entries (not always at
            // index 0) so repeated calls — e.g. one per individually
            // exhausted in-flight send — preserve their relative order
            // instead of reversing it, while still landing ahead of
            // freshly-buffered messages appended at the tail.
            let insertionIndex = min(offlineRequeuePriorityCount, offlineQueue.count)
            offlineQueue.insert(contentsOf: messages.prefix(acceptedCount), at: insertionIndex)
            offlineRequeuePriorityCount = insertionIndex + acceptedCount
        }
        let droppedCount = messages.count - acceptedCount
        lock.unlock()

        if droppedCount > 0 {
            delegate?.client(self, didEncounterError: .offlineQueueFull)
        }
    }

    private func handleConnectionReady(_ task: URLSessionWebSocketTask) {
        lock.lock()
        guard webSocketTask === task,
              state == .connecting || state == .reconnecting
        else {
            lock.unlock()
            return
        }
        let previousState = state
        state = .connected
        retryCount = 0
        let topics = Array(subscriptions.keys)
        lock.unlock()

        notifyStateChange(from: previousState, to: .connected)
        for topic in topics {
            sendSubscription(action: "subscribe", topic: topic, over: task)
        }
        drainOfflineQueue()
    }

    private func sendSubscription(
        action: String,
        topic: String,
        over task: URLSessionWebSocketTask
    ) {
        let payload: [String: Any] = ["action": action, "topic": topic]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        task.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.delegate?.client(
                self,
                didEncounterError: .connectionFailed(error.localizedDescription)
            )
        }
    }

    private func isCurrentWebSocketTask(_ task: URLSessionWebSocketTask) -> Bool {
        lock.lock()
        let isCurrent = webSocketTask === task
        lock.unlock()
        return isCurrent
    }

    private func reportConnectionConfigurationError(_ error: StreamlineError) {
        lock.lock()
        webSocketTask = nil
        let previousState = state
        state = .disconnected
        lock.unlock()
        notifyStateChange(from: previousState, to: .disconnected)
        delegate?.client(self, didEncounterError: error)
    }

    private func notifyStateChange(
        from previousState: ConnectionState,
        to currentState: ConnectionState
    ) {
        guard previousState != currentState else { return }
        delegate?.client(self, didChangeState: currentState)
    }

    // MARK: - Serialization (minimal JSON wire format)

    private func encodeMessage(_ message: StreamlineMessage) -> Data {
        var dict: [String: Any] = ["topic": message.topic, "value": message.value.base64EncodedString()]
        if let key = message.key { dict["key"] = key }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    private func decodeMessage(_ data: Data) -> StreamlineMessage? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = dict["topic"] as? String,
              let b64 = dict["value"] as? String,
              let value = Data(base64Encoded: b64)
        else { return nil }

        let key = dict["key"] as? String
        let offset = (dict["offset"] as? NSNumber)?.int64Value
        let partition = (dict["partition"] as? NSNumber)?.intValue
        let headers = dict["headers"] as? [String: String] ?? [:]
        var timestamp: Date?
        if let timestampValue = dict["timestamp"] as? NSNumber {
            timestamp = Date(timeIntervalSince1970: timestampValue.doubleValue)
        }
        return StreamlineMessage(
            topic: topic,
            key: key,
            value: value,
            offset: offset,
            timestamp: timestamp,
            partition: partition,
            headers: headers
        )
    }
}



/// Internal buffer for accumulating records before batch send.
internal struct BatchBuffer<T> {
    private var items: [T] = []
    private let capacity: Int

    init(capacity: Int = 1000) {
        self.capacity = capacity
        self.items.reserveCapacity(capacity)
    }

    var isFull: Bool { items.count >= capacity }
    var count: Int { items.count }

    mutating func append(_ item: T) -> Bool {
        items.append(item)
        return isFull
    }

    mutating func drain() -> [T] {
        let batch = items
        items = []
        items.reserveCapacity(capacity)
        return batch
    }
}
