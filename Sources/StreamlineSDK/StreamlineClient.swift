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

    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?

    private let lock = NSLock()

    // MARK: - Init

    public init(configuration: StreamlineConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
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

    /// Send a message to the given topic. If the client is disconnected the
    /// message is placed in the offline queue for later delivery.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
        let message = StreamlineMessage(topic: topic, key: key, value: value)

        lock.lock()
        let currentState = state
        lock.unlock()

        guard currentState == .connected, let ws = webSocketTask else {
            try enqueueOffline(message)
            return
        }

        let payload = encodeMessage(message)
        ws.send(.data(payload)) { [weak self] error in
            if let error {
                self?.delegate?.client(self!, didEncounterError: .connectionFailed(error.localizedDescription))
            }
        }
    }

    /// Convenience overload accepting a UTF-8 string value.
    public func produce(topic: String, key: String? = nil, stringValue: String) throws {
        try produce(topic: topic, key: key, value: Data(stringValue.utf8))
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

    private func encodeMessage(_ message: StreamlineMessage) -> Data {
        var dict: [String: Any] = ["topic": message.topic, "value": message.value.base64EncodedString()]
        if let key = message.key { dict["key"] = key }
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

