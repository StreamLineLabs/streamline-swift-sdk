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

    /// Circuit breaker protecting send operations.
    public let circuitBreaker: CircuitBreaker

    /// Retry policy for transient failures.
    public let retryPolicy: RetryPolicy

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

    // MARK: - Init

    public init(configuration: StreamlineConfiguration, producerConfig: ProducerConfig = ProducerConfig(), session: URLSession = .shared) {
        self.configuration = configuration
        self.producerConfig = producerConfig
        self.session = session
        self.circuitBreaker = CircuitBreaker(config: configuration.circuitBreakerConfig)
        self.retryPolicy = RetryPolicy(config: configuration.retryPolicyConfig)
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

        // Apply authentication: bearer token or SASL credentials
        if let token = configuration.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let sasl = configuration.sasl {
            let credentials = Data("\(sasl.username):\(sasl.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            request.setValue(sasl.mechanism.rawValue, forHTTPHeaderField: "X-Streamline-SASL-Mechanism")
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

    // MARK: - Admin

    /// Creates an ``AdminClient`` that inherits auth configuration from this client.
    ///
    /// The admin client uses HTTP (default port 9094) while the streaming client
    /// uses WebSocket (default port 9092). Pass the HTTP base URL.
    ///
    /// ```swift
    /// let client = StreamlineClient(configuration: config)
    /// let admin = client.admin(baseURL: URL(string: "http://localhost:9094")!)
    /// let topics = try await admin.listTopics()
    /// ```
    public func admin(baseURL: URL) -> AdminClient {
        AdminClient(
            baseURL: baseURL,
            authToken: configuration.authToken,
            saslConfig: configuration.sasl
        )
    }

    // MARK: - Produce

    /// Send a message to the given topic. Messages are accumulated into batches
    /// and flushed when the batch reaches `producerConfig.batchSize` bytes or
    /// after `producerConfig.lingerMs` milliseconds, whichever comes first.
    /// If the client is disconnected the message is placed in the offline queue.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
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

    /// Flush all pending batched messages immediately.
    public func flushBatch() {
        lock.lock()
        batchFlushTimer?.cancel()
        batchFlushTimer = nil
        let messages = batchQueue
        batchQueue.removeAll()
        lock.unlock()

        guard !messages.isEmpty, let ws = webSocketTask else { return }

        if messages.count == 1 {
            sendWithRetry(message: messages[0], ws: ws)
        } else {
            // Send as a batch array for efficiency
            let batchPayloads = messages.map { encodeMessage($0, compression: producerConfig.compression) }
            let batchArray = batchPayloads.compactMap { String(data: $0, encoding: .utf8) }
            let wrapper = #"{"action":"produce_batch","messages":[\#(batchArray.joined(separator: ","))]}"#

            do {
                try retryPolicy.execute {
                    try self.circuitBreaker.execute {
                        let semaphore = DispatchSemaphore(value: 0)
                        var sendError: Error?
                        ws.send(.string(wrapper)) { error in
                            sendError = error
                            semaphore.signal()
                        }
                        semaphore.wait()
                        if let error = sendError {
                            throw StreamlineError.connectionFailed(error.localizedDescription)
                        }
                    }
                }
            } catch {
                delegate?.client(self, didEncounterError:
                    (error as? StreamlineError) ?? .connectionFailed(error.localizedDescription))
            }
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

        do {
            try retryPolicy.execute {
                try self.circuitBreaker.execute {
                    let semaphore = DispatchSemaphore(value: 0)
                    var sendError: Error?
                    ws.send(.data(payload)) { error in
                        sendError = error
                        semaphore.signal()
                    }
                    semaphore.wait()
                    if let error = sendError {
                        throw StreamlineError.connectionFailed(error.localizedDescription)
                    }
                }
            }
        } catch {
            delegate?.client(self, didEncounterError:
                (error as? StreamlineError) ?? .connectionFailed(error.localizedDescription))
        }
    }

    // MARK: - Subscribe / Unsubscribe

    /// Register a handler for messages on the given topic.
    public func subscribe(topic: String, handler: @escaping MessageHandler) {
        lock.lock()
        subscriptions[topic] = handler
        lock.unlock()

        guard let ws = webSocketTask else { return }
        let command = #"{"action":"subscribe","topic":"\#(topic)"}"#
        do {
            try circuitBreaker.execute {
                ws.send(.string(command)) { _ in }
            }
        } catch {
            delegate?.client(self, didEncounterError:
                (error as? StreamlineError) ?? .connectionFailed(error.localizedDescription))
        }
    }

    /// Remove the subscription for the given topic.
    public func unsubscribe(topic: String) {
        lock.lock()
        subscriptions.removeValue(forKey: topic)
        lock.unlock()

        guard let ws = webSocketTask else { return }
        let command = #"{"action":"unsubscribe","topic":"\#(topic)"}"#
        do {
            try circuitBreaker.execute {
                ws.send(.string(command)) { _ in }
            }
        } catch {
            delegate?.client(self, didEncounterError:
                (error as? StreamlineError) ?? .connectionFailed(error.localizedDescription))
        }
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

    // MARK: - Internals

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

        guard let message = decodeMessage(data) else { return }

        lock.lock()
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

