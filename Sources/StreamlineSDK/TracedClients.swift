import Foundation

// MARK: - OTel Semantic Convention Helpers

/// Standard attribute keys following OpenTelemetry messaging semantic conventions.
public enum TelemetryAttributes {
    public static let messagingSystem = "messaging.system"
    public static let messagingDestinationName = "messaging.destination.name"
    public static let messagingOperation = "messaging.operation"
    public static let messagingMessageKey = "messaging.message.key"
    public static let messagingMessageOffset = "messaging.message.offset"
    public static let messagingConsumerGroupName = "messaging.consumer.group.name"
    public static let messagingDestinationPartitionId = "messaging.destination.partition.id"
    public static let messagingBatchMessageCount = "messaging.batch_message_count"
    public static let dbStatement = "db.statement"

    /// Build standard produce attributes for a topic.
    public static func produceAttributes(topic: String, key: String? = nil) -> [String: String] {
        var attrs: [String: String] = [
            messagingSystem: "streamline",
            messagingDestinationName: topic,
            messagingOperation: "produce",
        ]
        if let key = key { attrs[messagingMessageKey] = key }
        return attrs
    }

    /// Build standard consume attributes for a topic.
    public static func consumeAttributes(topic: String, groupId: String? = nil) -> [String: String] {
        var attrs: [String: String] = [
            messagingSystem: "streamline",
            messagingDestinationName: topic,
            messagingOperation: "consume",
        ]
        if let groupId = groupId { attrs[messagingConsumerGroupName] = groupId }
        return attrs
    }

    /// Build standard process attributes for a received message.
    public static func processAttributes(topic: String, offset: Int64? = nil, partition: Int? = nil) -> [String: String] {
        var attrs: [String: String] = [
            messagingSystem: "streamline",
            messagingDestinationName: topic,
            messagingOperation: "process",
        ]
        if let offset = offset { attrs[messagingMessageOffset] = String(offset) }
        if let partition = partition { attrs[messagingDestinationPartitionId] = String(partition) }
        return attrs
    }
}

// MARK: - TracedClient

/// Wraps a ``StreamlineClient`` with automatic telemetry instrumentation.
///
/// Every produce, subscribe, poll, and transaction operation creates a span
/// following OpenTelemetry messaging semantic conventions.
///
/// ```swift
/// let telemetry = ConsoleTelemetry()
/// let client = StreamlineClient(configuration: config)
/// let traced = TracedClient(client: client, telemetry: telemetry)
/// try traced.produce(topic: "events", stringValue: "hello")
/// ```
public final class TracedClient: @unchecked Sendable {

    private let client: StreamlineClient
    private let telemetry: Telemetry

    /// The underlying client's connection state.
    public var state: ConnectionState { client.state }

    /// The underlying client's metrics snapshot.
    public var clientMetrics: ClientMetrics { client.clientMetrics }

    public init(client: StreamlineClient, telemetry: Telemetry) {
        self.client = client
        self.telemetry = telemetry
    }

    /// Connect to the server with tracing.
    public func connect() {
        let span = telemetry.startSpan(topic: "", operation: "connect")
        client.connect()
        span.setAttribute("status", value: "connected")
        telemetry.endSpan(span)
    }

    /// Disconnect from the server with tracing.
    public func disconnect() {
        let span = telemetry.startSpan(topic: "", operation: "disconnect")
        client.disconnect()
        telemetry.endSpan(span)
    }

    /// Produce a message with tracing.
    public func produce(topic: String, key: String? = nil, value: Data) throws {
        let span = telemetry.startSpan(topic: topic, operation: "produce")
        if let key = key { span.setAttribute(TelemetryAttributes.messagingMessageKey, value: key) }
        do {
            try client.produce(topic: topic, key: key, value: value)
            telemetry.endSpan(span)
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    /// Produce a string message with tracing.
    public func produce(topic: String, key: String? = nil, stringValue: String) throws {
        try produce(topic: topic, key: key, value: Data(stringValue.utf8))
    }

    /// Subscribe to a topic with per-message tracing.
    public func subscribe(topic: String, handler: @escaping MessageHandler) {
        let span = telemetry.startSpan(topic: topic, operation: "subscribe")
        client.subscribe(topic: topic) { [telemetry] message in
            let receiveSpan = telemetry.startSpan(topic: message.topic, operation: "process")
            if let key = message.key {
                receiveSpan.setAttribute(TelemetryAttributes.messagingMessageKey, value: key)
            }
            if let offset = message.offset {
                receiveSpan.setAttribute(TelemetryAttributes.messagingMessageOffset, value: String(offset))
            }
            handler(message)
            telemetry.endSpan(receiveSpan)
        }
        telemetry.endSpan(span)
    }

    /// Unsubscribe from a topic.
    public func unsubscribe(topic: String) {
        client.unsubscribe(topic: topic)
    }

    /// Poll for messages with tracing.
    public func poll(maxRecords: Int = 100, timeout: TimeInterval = 1.0) async -> [StreamlineMessage] {
        let span = telemetry.startSpan(topic: "", operation: "poll")
        let messages = await client.poll(maxRecords: maxRecords, timeout: timeout)
        span.setAttribute(TelemetryAttributes.messagingBatchMessageCount, value: String(messages.count))
        telemetry.endSpan(span)
        return messages
    }

    /// Returns an `AsyncStream` of messages with per-message tracing.
    public func messages(topic: String) -> AsyncStream<StreamlineMessage> {
        let telemetryRef = telemetry
        let upstream = client.messages(topic: topic)
        return AsyncStream { continuation in
            Task {
                for await message in upstream {
                    let span = telemetryRef.startSpan(topic: message.topic, operation: "process")
                    if let key = message.key {
                        span.setAttribute(TelemetryAttributes.messagingMessageKey, value: key)
                    }
                    if let offset = message.offset {
                        span.setAttribute(TelemetryAttributes.messagingMessageOffset, value: String(offset))
                    }
                    telemetryRef.endSpan(span)
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }

    /// Begin a transaction with tracing.
    public func beginTransaction() throws {
        let span = telemetry.startSpan(topic: "", operation: "transaction.begin")
        do {
            try client.beginTransaction()
            telemetry.endSpan(span)
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    /// Commit a transaction with tracing.
    public func commitTransaction() throws {
        let span = telemetry.startSpan(topic: "", operation: "transaction.commit")
        do {
            try client.commitTransaction()
            telemetry.endSpan(span)
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    /// Abort a transaction with tracing.
    public func abortTransaction() throws {
        let span = telemetry.startSpan(topic: "", operation: "transaction.abort")
        do {
            try client.abortTransaction()
            telemetry.endSpan(span)
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    /// Flush pending batches with tracing.
    public func flushBatch() {
        let span = telemetry.startSpan(topic: "", operation: "flush")
        client.flushBatch()
        telemetry.endSpan(span)
    }
}

// MARK: - TracedAdminClient

/// Wraps an ``AdminClient`` with automatic telemetry instrumentation.
///
/// ```swift
/// let traced = TracedAdminClient(admin: adminClient, telemetry: ConsoleTelemetry())
/// let topics = try await traced.listTopics()
/// ```
public final class TracedAdminClient: @unchecked Sendable {

    private let admin: AdminClient
    private let telemetry: Telemetry

    public init(admin: AdminClient, telemetry: Telemetry) {
        self.admin = admin
        self.telemetry = telemetry
    }

    public func listTopics() async throws -> [TopicInfo] {
        try await traced(topic: "", operation: "admin.list_topics") {
            try await admin.listTopics()
        }
    }

    public func describeTopic(name: String) async throws -> TopicDescription {
        try await traced(topic: name, operation: "admin.describe_topic") {
            try await admin.describeTopic(name: name)
        }
    }

    public func createTopic(name: String, partitions: Int = 1, replicationFactor: Int = 1, config: [String: String] = [:]) async throws {
        try await traced(topic: name, operation: "admin.create_topic") {
            try await admin.createTopic(name: name, partitions: partitions, replicationFactor: replicationFactor, config: config)
        }
    }

    public func deleteTopic(name: String) async throws {
        try await traced(topic: name, operation: "admin.delete_topic") {
            try await admin.deleteTopic(name: name)
        }
    }

    public func listConsumerGroups() async throws -> [ConsumerGroup] {
        try await traced(topic: "", operation: "admin.list_groups") {
            try await admin.listConsumerGroups()
        }
    }

    public func describeConsumerGroup(groupId: String) async throws -> ConsumerGroupDescription {
        let span = telemetry.startSpan(topic: "", operation: "admin.describe_group")
        span.setAttribute(TelemetryAttributes.messagingConsumerGroupName, value: groupId)
        do {
            let result = try await admin.describeConsumerGroup(groupId: groupId)
            telemetry.endSpan(span)
            return result
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    public func query(_ sql: String) async throws -> QueryResult {
        let span = telemetry.startSpan(topic: "", operation: "admin.query")
        span.setAttribute(TelemetryAttributes.dbStatement, value: sql)
        do {
            let result = try await admin.query(sql)
            telemetry.endSpan(span)
            return result
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }

    public func serverInfo() async throws -> ServerInfo {
        try await traced(topic: "", operation: "admin.server_info") {
            try await admin.serverInfo()
        }
    }

    private func traced<T>(
        topic: String,
        operation: String,
        _ block: () async throws -> T
    ) async rethrows -> T {
        let span = telemetry.startSpan(topic: topic, operation: operation)
        do {
            let result = try await block()
            telemetry.endSpan(span)
            return result
        } catch {
            span.setError(error)
            telemetry.endSpan(span, error: error.localizedDescription)
            throw error
        }
    }
}
