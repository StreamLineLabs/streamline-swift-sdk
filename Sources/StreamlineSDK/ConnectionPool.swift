import Foundation

// MARK: - Connection Pool

/// Manages a pool of `StreamlineClient` connections for concurrent topic access.
///
/// Each connection in the pool is an independent WebSocket session. The pool
/// distributes subscriptions across connections to avoid single-connection bottlenecks.
///
/// ```swift
/// let pool = ConnectionPool(
///     configuration: config,
///     size: 3
/// )
/// pool.connectAll()
/// pool.subscribe(topic: "events") { msg in print(msg) }
/// pool.subscribe(topic: "orders") { msg in print(msg) }
/// pool.disconnectAll()
/// ```
public final class ConnectionPool: @unchecked Sendable {
    // MARK: - Properties

    /// Pool size (number of connections).
    public let size: Int

    /// All connections in the pool.
    public private(set) var connections: [StreamlineClient]

    private let lock = NSLock()
    private var topicAssignments: [String: Int] = [:]
    private var nextIndex = 0

    // MARK: - Init

    /// Create a pool of `size` independent client connections.
    public init(configuration: StreamlineConfiguration, size: Int = 3) {
        precondition(size > 0, "Pool size must be at least 1")
        self.size = size
        connections = (0 ..< size).map { _ in
            StreamlineClient(configuration: configuration)
        }
    }

    // MARK: - Lifecycle

    /// Connect all clients in the pool.
    public func connectAll() {
        for conn in connections {
            conn.connect()
        }
    }

    /// Disconnect all clients in the pool.
    public func disconnectAll() {
        for conn in connections {
            conn.disconnect()
        }
    }

    // MARK: - Produce

    /// Produce a message using a round-robin selected connection.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
        try TopicNameValidator.validate(topic)
        let conn = nextConnection()
        try conn.produce(topic: topic, key: key, value: value)
    }

    /// Produce a string message using a round-robin selected connection.
    public func produce(topic: String, key: String? = nil, stringValue: String) throws {
        try produce(topic: topic, key: key, value: Data(stringValue.utf8))
    }

    // MARK: - Subscribe

    /// Subscribe to a topic using a deterministic connection assignment.
    /// The same topic always uses the same connection for ordered delivery.
    public func subscribe(topic: String, handler: @escaping MessageHandler) {
        guard (try? TopicNameValidator.validate(topic)) != nil else { return }
        let index = assignedIndex(for: topic)
        connections[index].subscribe(topic: topic, handler: handler)
    }

    /// Unsubscribe from a topic.
    public func unsubscribe(topic: String) {
        lock.lock()
        let index = topicAssignments.removeValue(forKey: topic)
        lock.unlock()

        if let idx = index {
            connections[idx].unsubscribe(topic: topic)
        }
    }

    // MARK: - Status

    /// Returns the number of connected clients.
    public var connectedCount: Int {
        connections.filter { $0.state == .connected }.count
    }

    /// Returns aggregate metrics across all pool connections.
    public var metrics: ClientMetrics {
        var total = ClientMetrics()
        for conn in connections {
            let m = conn.clientMetrics
            total.produceCount += m.produceCount
            total.produceBytes += m.produceBytes
            total.produceErrors += m.produceErrors
            total.consumeCount += m.consumeCount
            total.consumeBytes += m.consumeBytes
        }
        if total.produceCount > 0 {
            // Average latency across connections
            var totalLatency: Double = 0
            for conn in connections {
                totalLatency += conn.clientMetrics.produceAvgLatencyMs * Double(conn.clientMetrics.produceCount)
            }
            total.produceAvgLatencyMs = totalLatency / Double(total.produceCount)
        }
        return total
    }

    // MARK: - Private

    private func nextConnection() -> StreamlineClient {
        lock.lock()
        let idx = nextIndex % size
        nextIndex += 1
        lock.unlock()
        return connections[idx]
    }

    private func assignedIndex(for topic: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        if let existing = topicAssignments[topic] {
            return existing
        }
        // Assign to the connection with fewest subscriptions
        var minCount = Int.max
        var minIndex = 0
        for (i, _) in connections.enumerated() {
            let count = topicAssignments.values.filter { $0 == i }.count
            if count < minCount {
                minCount = count
                minIndex = i
            }
        }
        topicAssignments[topic] = minIndex
        return minIndex
    }
}

// MARK: - Client Metrics

/// Snapshot of client-side operational metrics.
public struct ClientMetrics: Sendable, Equatable {
    public var produceCount: Int64 = 0
    public var produceBytes: Int64 = 0
    public var produceErrors: Int64 = 0
    public var produceAvgLatencyMs: Double = 0
    public var consumeCount: Int64 = 0
    public var consumeBytes: Int64 = 0
}
