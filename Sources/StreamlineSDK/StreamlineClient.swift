import Foundation

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

    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            delegate?.client(self, didChangeState: state)
        }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession

    /// Active topic subscriptions: topic → handler.
    private var subscriptions: [String: MessageHandler] = [:]

    /// Messages queued while the client was disconnected.
    private var offlineQueue: [StreamlineMessage] = []
    private let maxOfflineQueueSize = 1000

    /// Producer batch accumulator: topic → pending messages.
    private var batchQueue: [StreamlineMessage] = []
    private var batchFlushTimer: DispatchWorkItem?

    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?

    private let lock = NSLock()

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

    // Transaction state
    private var inTransaction = false
    private var transactionBuffer: [(topic: String, key: String?, value: Data)] = []

    // MARK: - Init

    public init(configuration: StreamlineConfiguration, producerConfig: ProducerConfig = ProducerConfig(), circuitBreaker: CircuitBreaker? = nil, session: URLSession = .shared) {
        self.configuration = configuration
        self.producerConfig = producerConfig
        self.circuitBreaker = circuitBreaker
        self.session = session
    }

    deinit {
        reconnectTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connection

    /// Open a WebSocket connection to the configured server URL.
    public func connect() {
        lock.lock()
        guard state == .disconnected || state == .reconnecting else {
            lock.unlock()
            return
        }
        let isReconnecting = state == .reconnecting
        if !isReconnecting { state = .connecting }
        lock.unlock()

        var request = URLRequest(url: configuration.url, timeoutInterval: configuration.timeout)
        if let token = configuration.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        lock.lock()
        webSocketTask = task
        lock.unlock()

        task.resume()
        state = .connected
        retryCount = 0
        listenForMessages()
        drainOfflineQueue()
    }

    /// Gracefully close the connection.
    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil

        lock.lock()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        state = .disconnected
        lock.unlock()
    }

    // MARK: - Produce

    /// Send a message to the given topic. Messages are accumulated into batches
    /// and flushed when the batch reaches `producerConfig.batchSize` bytes or
    /// after `producerConfig.lingerMs` milliseconds, whichever comes first.
    /// If the client is disconnected the message is placed in the offline queue.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
        // Check circuit breaker before accepting the message
        if let cb = circuitBreaker {
            try cb.check()
        }

        let message = StreamlineMessage(topic: topic, key: key, value: value)

        lock.lock()
        let currentState = state
        lock.unlock()

        guard currentState == .connected, webSocketTask != nil else {
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

    /// Begin a new transaction. Messages sent via `sendTransactional` are
    /// buffered until `commitTransaction` or `abortTransaction`.
    public func beginTransaction() throws {
        guard !inTransaction else {
            throw StreamlineError.transaction("Transaction already in progress")
        }
        inTransaction = true
        transactionBuffer = []
    }

    /// Buffer a message within the current transaction.
    public func sendTransactional(topic: String, key: String? = nil, value: Data) throws {
        guard inTransaction else {
            throw StreamlineError.transaction("No transaction in progress")
        }
        transactionBuffer.append((topic: topic, key: key, value: value))
    }

    /// Commit the transaction, sending all buffered records.
    public func commitTransaction() throws {
        guard inTransaction else {
            throw StreamlineError.transaction("No transaction in progress")
        }
        defer {
            inTransaction = false
            transactionBuffer = []
        }
        for msg in transactionBuffer {
            try produce(topic: msg.topic, key: msg.key, value: msg.value)
        }
    }

    /// Abort the transaction, discarding all buffered records.
    public func abortTransaction() throws {
        guard inTransaction else {
            throw StreamlineError.transaction("No transaction in progress")
        }
        inTransaction = false
        transactionBuffer = []
    }

    /// Flush all pending batched messages immediately.
    public func flushBatch() {
        lock.lock()
        batchFlushTimer?.cancel()
        batchFlushTimer = nil
        let messages = batchQueue
        batchQueue.removeAll()
        lock.unlock()

        guard !messages.isEmpty, let ws = webSocketTask else { return }

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
        let payload = encodeMessage(message, compression: producerConfig.compression)
        let maxRetries = producerConfig.retries
        let backoffMs = producerConfig.retryBackoffMs
        var attempt = 0
        let startTime = Date()

        func trySend() {
            ws.send(.data(payload)) { [weak self] error in
                if let error {
                    self?.circuitBreaker?.recordFailure()
                    self?.lock.lock()
                    self?._metrics.produceErrors += 1
                    self?.lock.unlock()
                    attempt += 1
                    if attempt <= maxRetries {
                        let delayMs = backoffMs * Int(pow(2.0, Double(attempt - 1)))
                        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                            trySend()
                        }
                    } else {
                        self?.delegate?.client(self!, didEncounterError: .connectionFailed(error.localizedDescription))
                    }
                } else {
                    self?.circuitBreaker?.recordSuccess()
                    let latencyMs = Date().timeIntervalSince(startTime) * 1000
                    self?.lock.lock()
                    let count = (self?._metrics.produceCount ?? 0)
                    let prevAvg = self?._metrics.produceAvgLatencyMs ?? 0
                    self?._metrics.produceCount += 1
                    self?._metrics.produceBytes += Int64(message.value.count)
                    self?._metrics.produceAvgLatencyMs = (prevAvg * Double(count) + latencyMs) / Double(count + 1)
                    self?.lock.unlock()
                }
            }
        }

        trySend()
    }

    // MARK: - Subscribe / Unsubscribe

    /// Register a handler for messages on the given topic.
    public func subscribe(topic: String, handler: @escaping MessageHandler) {
        lock.lock()
        subscriptions[topic] = handler
        lock.unlock()

        guard let ws = webSocketTask else { return }
        let command = #"{"action":"subscribe","topic":"\#(topic)"}"#
        ws.send(.string(command)) { _ in }
    }

    /// Remove the subscription for the given topic.
    public func unsubscribe(topic: String) {
        lock.lock()
        subscriptions.removeValue(forKey: topic)
        lock.unlock()

        guard let ws = webSocketTask else { return }
        let command = #"{"action":"unsubscribe","topic":"\#(topic)"}"#
        ws.send(.string(command)) { _ in }
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
        // First drain anything already buffered
        lock.lock()
        if !pollBuffer.isEmpty {
            let count = min(maxRecords, pollBuffer.count)
            let batch = Array(pollBuffer.prefix(count))
            pollBuffer.removeFirst(count)
            lock.unlock()
            return batch
        }
        lock.unlock()

        // Wait up to timeout for messages to arrive
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            lock.lock()
            if !pollBuffer.isEmpty {
                let count = min(maxRecords, pollBuffer.count)
                let batch = Array(pollBuffer.prefix(count))
                pollBuffer.removeFirst(count)
                lock.unlock()
                return batch
            }
            lock.unlock()
        }
        return []
    }

    // MARK: - Internals

    /// Committed offsets tracked locally (topic:partition → offset).
    private var committedOffsets: [String: Int64] = [:]

    /// Current consumer positions tracked locally (topic:partition → offset).
    private var currentPositions: [String: Int64] = [:]

    /// Pending offset query continuations awaiting server response.
    private var pendingOffsetQueries: [String: CheckedContinuation<Int64?, Never>] = [:]
    private var pendingOffsetQueryOrder: [String] = []

    // MARK: - Offset Management

    /// Commit consumer offsets to the server.
    ///
    /// - Parameter offsets: A dictionary of `"topic:partition"` keys to offset values.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func commitOffsets(_ offsets: [String: Int64]) async throws {
        lock.lock()
        let ws = webSocketTask
        lock.unlock()

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "commit_offsets",
            "offsets": offsets.mapValues { NSNumber(value: $0) },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        lock.lock()
        for (key, offset) in offsets {
            committedOffsets[key] = offset
        }
        lock.unlock()
    }

    /// Seek to a specific offset for a topic partition.
    ///
    /// - Parameters:
    ///   - topic: The topic name.
    ///   - partition: The partition index.
    ///   - offset: The offset to seek to.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToOffset(topic: String, partition: Int, offset: Int64) async throws {
        lock.lock()
        let ws = webSocketTask
        lock.unlock()

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
        lock.lock()
        currentPositions[key] = offset
        lock.unlock()
    }

    /// Seek to the beginning of all partitions for the given topic.
    ///
    /// - Parameter topic: The topic name.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToBeginning(topic: String) async throws {
        lock.lock()
        let ws = webSocketTask
        lock.unlock()

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "seek_to_beginning",
            "topic": topic,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        lock.lock()
        let keysToReset = currentPositions.keys.filter { $0.hasPrefix("\(topic):") }
        for key in keysToReset {
            currentPositions[key] = 0
        }
        lock.unlock()
    }

    /// Seek to the end (latest) of all partitions for the given topic.
    ///
    /// - Parameter topic: The topic name.
    /// - Throws: ``StreamlineError/notConnected`` if the client is disconnected.
    public func seekToEnd(topic: String) async throws {
        lock.lock()
        let ws = webSocketTask
        lock.unlock()

        guard let ws else {
            throw StreamlineError.notConnected
        }

        let payload: [String: Any] = [
            "action": "seek_to_end",
            "topic": topic,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await ws.send(.data(data))

        lock.lock()
        let keysToReset = currentPositions.keys.filter { $0.hasPrefix("\(topic):") }
        for key in keysToReset {
            currentPositions.removeValue(forKey: key)
        }
        lock.unlock()
    }

    /// Get the current consumer position for a specific topic partition.
    ///
    /// Sends a query to the server over WebSocket and awaits the response.
    /// Falls back to locally tracked position if the server does not respond.
    public func position(topic: String, partition: Int) async -> Int64? {
        let key = "\(topic):\(partition)"

        lock.lock()
        let ws = webSocketTask
        lock.unlock()

        guard let ws else {
            lock.lock()
            let local = currentPositions[key]
            lock.unlock()
            return local
        }

        let payload: [String: Any] = [
            "action": "position",
            "topic": topic,
            "partition": partition,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            lock.lock()
            let local = currentPositions[key]
            lock.unlock()
            return local
        }

        do {
            try await ws.send(.data(data))
        } catch {
            lock.lock()
            let local = currentPositions[key]
            lock.unlock()
            return local
        }

        return await withCheckedContinuation { continuation in
            let queryId = UUID().uuidString
            lock.lock()
            pendingOffsetQueries[queryId] = continuation
            pendingOffsetQueryOrder.append(queryId)
            lock.unlock()

            // Timeout after 5 seconds to avoid hanging forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let cont = self.pendingOffsetQueries.removeValue(forKey: queryId) {
                    self.pendingOffsetQueryOrder.removeAll { $0 == queryId }
                    let local = self.currentPositions[key]
                    self.lock.unlock()
                    cont.resume(returning: local)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    /// Get the last committed offset for a specific topic partition.
    ///
    /// Sends a query to the server over WebSocket and awaits the response.
    /// Falls back to locally tracked committed offset if the server does not respond.
    public func committed(topic: String, partition: Int) async -> Int64? {
        let key = "\(topic):\(partition)"

        lock.lock()
        let ws = webSocketTask
        lock.unlock()

        guard let ws else {
            lock.lock()
            let local = committedOffsets[key]
            lock.unlock()
            return local
        }

        let payload: [String: Any] = [
            "action": "committed",
            "topic": topic,
            "partition": partition,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            lock.lock()
            let local = committedOffsets[key]
            lock.unlock()
            return local
        }

        do {
            try await ws.send(.data(data))
        } catch {
            lock.lock()
            let local = committedOffsets[key]
            lock.unlock()
            return local
        }

        return await withCheckedContinuation { continuation in
            let queryId = UUID().uuidString
            lock.lock()
            pendingOffsetQueries[queryId] = continuation
            pendingOffsetQueryOrder.append(queryId)
            lock.unlock()

            // Timeout after 5 seconds to avoid hanging forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let cont = self.pendingOffsetQueries.removeValue(forKey: queryId) {
                    self.pendingOffsetQueryOrder.removeAll { $0 == queryId }
                    let local = self.committedOffsets[key]
                    self.lock.unlock()
                    cont.resume(returning: local)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    // MARK: - Receive Loop

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let wsMessage):
                self.handleIncoming(wsMessage)
                self.listenForMessages()
            case .failure:
                self.handleDisconnection()
            }
        }
    }

    private func handleIncoming(_ wsMessage: URLSessionWebSocketTask.Message) {
        let data: Data
        switch wsMessage {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            return
        }

        // Try to resolve a pending offset query if this is an offset response.
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           dict["offset"] != nil || dict["action"] as? String == "offset_response" {
            let offset = dict["offset"] as? Int64
            lock.lock()
            if let firstKey = pendingOffsetQueryOrder.first,
               let continuation = pendingOffsetQueries.removeValue(forKey: firstKey) {
                pendingOffsetQueryOrder.removeFirst()
                lock.unlock()
                continuation.resume(returning: offset)
                return
            }
            lock.unlock()
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

    private func handleDisconnection() {
        lock.lock()
        webSocketTask = nil
        guard configuration.autoReconnect, retryCount < configuration.maxRetries else {
            state = .disconnected
            lock.unlock()
            return
        }
        state = .reconnecting
        retryCount += 1
        let attempt = retryCount
        lock.unlock()

        let backoff = min(
            configuration.initialBackoff * pow(2.0, Double(attempt - 1)),
            configuration.maxBackoff
        )

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
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
        lock.unlock()

        for message in queued {
            try? produce(topic: message.topic, key: message.key, value: message.value)
        }
    }

    // MARK: - Serialization (minimal JSON wire format)

    private func encodeMessage(_ message: StreamlineMessage, compression: CompressionType = .none) -> Data {
        var dict: [String: Any] = ["topic": message.topic, "value": message.value.base64EncodedString()]
        if let key = message.key { dict["key"] = key }
        if compression != .none { dict["compression"] = compression.rawValue }
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func decodeMessage(_ data: Data) -> StreamlineMessage? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = dict["topic"] as? String,
              let b64 = dict["value"] as? String,
              let value = Data(base64Encoded: b64)
        else { return nil }

        let key = dict["key"] as? String
        let offset = dict["offset"] as? Int64
        var timestamp: Date?
        if let ts = dict["timestamp"] as? TimeInterval {
            timestamp = Date(timeIntervalSince1970: ts)
        }
        return StreamlineMessage(topic: topic, key: key, value: value, offset: offset, timestamp: timestamp)
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
