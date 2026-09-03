import Foundation

// MARK: - Messages

/// A message produced to or consumed from a Streamline topic.
public struct StreamlineMessage: Sendable, Equatable {
    /// Topic the message belongs to.
    public let topic: String

    /// Optional partitioning key.
    public let key: String?

    /// Message payload as raw bytes.
    public let value: Data

    /// Server-assigned offset (nil for outbound messages).
    public let offset: Int64?

    /// Server-assigned timestamp (nil for outbound messages).
    public let timestamp: Date?

    /// Server-assigned partition (nil for outbound messages).
    public let partition: Int?

    /// Message headers returned by the server.
    public let headers: [String: String]

    public init(
        topic: String,
        key: String? = nil,
        value: Data,
        offset: Int64? = nil,
        timestamp: Date? = nil,
        partition: Int? = nil,
        headers: [String: String] = [:]
    ) {
        self.topic = topic
        self.key = key
        self.value = value
        self.offset = offset
        self.timestamp = timestamp
        self.partition = partition
        self.headers = headers
    }

    /// Convenience initializer that encodes a UTF-8 string as the value.
    public init(
        topic: String,
        key: String? = nil,
        stringValue: String,
        offset: Int64? = nil,
        timestamp: Date? = nil,
        partition: Int? = nil,
        headers: [String: String] = [:]
    ) {
        self.init(
            topic: topic,
            key: key,
            value: Data(stringValue.utf8),
            offset: offset,
            timestamp: timestamp,
            partition: partition,
            headers: headers
        )
    }
}

// MARK: - Topic Info

/// Metadata about a Streamline topic.
public struct TopicInfo: Sendable, Equatable {
    public let name: String
    public let partitions: Int
    public let replicationFactor: Int
    public let messageCount: Int64

    public init(name: String, partitions: Int, replicationFactor: Int, messageCount: Int64) {
        self.name = name
        self.partitions = partitions
        self.replicationFactor = replicationFactor
        self.messageCount = messageCount
    }
}

// MARK: - Search Result

/// A single search result from a topic.
public struct SearchResult: Sendable, Equatable {
    /// Partition of the matching record.
    public let partition: Int
    /// Offset of the matching record.
    public let offset: Int64
    /// Similarity score (higher = more relevant).
    public let score: Double
    /// Record value, if returned by the server.
    public let value: String?

    public init(partition: Int, offset: Int64, score: Double, value: String? = nil) {
        self.partition = partition
        self.offset = offset
        self.score = score
        self.value = value
    }
}

// MARK: - Consumer Group

/// Represents a consumer group on the server.
public struct ConsumerGroup: Sendable, Equatable {
    public let id: String
    public let members: [String]
    public let state: String

    public init(id: String, members: [String], state: String) {
        self.id = id
        self.members = members
        self.state = state
    }
}

// MARK: - Topic Description

/// Detailed topic description including configuration.
public struct TopicDescription: Sendable, Equatable {
    public let name: String
    public let partitions: Int
    public let replicationFactor: Int
    public let messageCount: Int64
    public let config: [String: String]

    public init(name: String, partitions: Int, replicationFactor: Int, messageCount: Int64 = 0, config: [String: String] = [:]) {
        self.name = name
        self.partitions = partitions
        self.replicationFactor = replicationFactor
        self.messageCount = messageCount
        self.config = config
    }
}

// MARK: - Consumer Group Description

/// A member of a consumer group.
public struct ConsumerGroupMember: Sendable, Equatable {
    public let id: String
    public let clientId: String
    public let host: String
    public let assignments: [String]

    public init(id: String, clientId: String = "", host: String = "", assignments: [String] = []) {
        self.id = id
        self.clientId = clientId
        self.host = host
        self.assignments = assignments
    }
}

/// Detailed description of a consumer group.
public struct ConsumerGroupDescription: Sendable, Equatable {
    public let id: String
    public let state: String
    public let members: [ConsumerGroupMember]
    public let protocolType: String

    public init(id: String, state: String, members: [ConsumerGroupMember] = [], protocolType: String = "") {
        self.id = id
        self.state = state
        self.members = members
        self.protocolType = protocolType
    }
}

// MARK: - Query Result

/// Result from a SQL query against streaming data.
public struct QueryResult: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[String]]
    public let rowCount: Int

    public init(columns: [String] = [], rows: [[String]] = [], rowCount: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
    }
}

// MARK: - Server Info

/// Information about the Streamline server.
public struct ServerInfo: Sendable, Equatable {
    public let version: String
    public let uptime: Int64
    public let topicCount: Int
    public let messageCount: Int64

    public init(version: String = "", uptime: Int64 = 0, topicCount: Int = 0, messageCount: Int64 = 0) {
        self.version = version
        self.uptime = uptime
        self.topicCount = topicCount
        self.messageCount = messageCount
    }
}

// MARK: - Schema Info

/// Schema formats supported by the registry.
public enum SchemaFormat: String, Codable, Sendable, Equatable {
    case avro = "AVRO"
    case json = "JSON"
    case protobuf = "PROTOBUF"
}

/// Compatibility levels for schema evolution.
public enum CompatibilityLevel: String, Codable, Sendable, Equatable {
    case backward = "BACKWARD"
    case forward = "FORWARD"
    case full = "FULL"
    case none = "NONE"
    case backwardTransitive = "BACKWARD_TRANSITIVE"
    case forwardTransitive = "FORWARD_TRANSITIVE"
    case fullTransitive = "FULL_TRANSITIVE"
}

/// Schema information returned by the registry.
public struct SchemaInfo: Codable, Sendable, Equatable {
    public let id: Int
    public let subject: String
    public let version: Int
    public let format: SchemaFormat
    public let schema: String

    public init(id: Int, subject: String, version: Int, format: SchemaFormat, schema: String) {
        self.id = id
        self.subject = subject
        self.version = version
        self.format = format
        self.schema = schema
    }
}

// MARK: - Cluster Info

/// Information about the Streamline cluster.
public struct ClusterInfo: Sendable, Equatable {
    public let clusterId: String
    public let brokerId: Int
    public let brokers: [BrokerInfo]
    public let controller: Int

    public init(clusterId: String = "", brokerId: Int = 0, brokers: [BrokerInfo] = [], controller: Int = -1) {
        self.clusterId = clusterId
        self.brokerId = brokerId
        self.brokers = brokers
        self.controller = controller
    }
}

/// Information about a single broker in the cluster.
public struct BrokerInfo: Sendable, Equatable {
    public let id: Int
    public let host: String
    public let port: Int
    public let rack: String?

    public init(id: Int = 0, host: String = "", port: Int = 9092, rack: String? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.rack = rack
    }
}

// MARK: - Consumer Lag

/// Consumer group lag information for a topic partition.
public struct ConsumerLag: Sendable, Equatable {
    public let topic: String
    public let partition: Int
    public let currentOffset: Int64
    public let endOffset: Int64
    public let lag: Int64

    public init(topic: String, partition: Int = 0, currentOffset: Int64 = 0, endOffset: Int64 = 0, lag: Int64 = 0) {
        self.topic = topic
        self.partition = partition
        self.currentOffset = currentOffset
        self.endOffset = endOffset
        self.lag = lag
    }
}

/// Aggregated consumer group lag across all subscribed partitions.
public struct ConsumerGroupLag: Sendable, Equatable {
    public let groupId: String
    public let partitions: [ConsumerLag]
    public let totalLag: Int64

    public init(groupId: String, partitions: [ConsumerLag] = [], totalLag: Int64 = 0) {
        self.groupId = groupId
        self.partitions = partitions
        self.totalLag = totalLag
    }
}

// MARK: - Message Inspection

/// A message returned by the message inspection API.
public struct InspectedMessage: Sendable, Equatable {
    public let offset: Int64
    public let key: String?
    public let value: String
    public let timestamp: Int64
    public let partition: Int
    public let headers: [String: String]

    public init(offset: Int64, key: String? = nil, value: String = "", timestamp: Int64 = 0, partition: Int = 0, headers: [String: String] = [:]) {
        self.offset = offset
        self.key = key
        self.value = value
        self.timestamp = timestamp
        self.partition = partition
        self.headers = headers
    }
}

// MARK: - Metrics

/// A single metric data point from the server.
public struct MetricPoint: Sendable, Equatable {
    public let name: String
    public let value: Double
    public let labels: [String: String]
    public let timestamp: Int64

    public init(name: String = "", value: Double = 0, labels: [String: String] = [:], timestamp: Int64 = 0) {
        self.name = name
        self.value = value
        self.labels = labels
        self.timestamp = timestamp
    }
}

// MARK: - Error Code

/// Programmatic classification of errors for handling and retry logic.
public enum ErrorCode: String, Sendable, Equatable, CaseIterable {
    case connection
    case timeout
    case authentication
    case authorization
    case topicNotFound
    case partitionNotFound
    case `protocol`
    case serialization
    case schema
    case configuration
    case `internal`
    case circuitOpen
    case contractViolation
    case attestationFailed
    case memoryAccessDenied
    case branchQuotaExceeded
    case semanticSearchUnavailable
    case unsupported
}

// MARK: - Errors

/// Errors that can occur when interacting with the Streamline SDK.
public enum StreamlineError: Error, Sendable, Equatable {
    /// The client is not currently connected.
    case notConnected

    /// A connection attempt failed.
    case connectionFailed(String)

    /// The server rejected the authentication credentials.
    case authenticationFailed(String)

    /// The client is not authorized to perform the operation.
    case authorizationFailed(String)

    /// A produce or subscribe call timed out.
    case timeout

    /// The requested topic does not exist.
    case topicNotFound(String)

    /// The requested partition does not exist.
    case partitionNotFound(String)

    /// Message serialization or deserialization failed.
    case serializationError(String)

    /// A wire-protocol framing or decoding error.
    case protocolError(String)

    /// A configuration value is invalid.
    case configurationError(String)

    /// The offline queue is full and cannot accept more messages.
    case offlineQueueFull

    /// An admin operation failed.
    case adminOperationFailed(String)

    /// A SQL query failed.
    case queryFailed(String)

    /// A schema registry operation failed.
    case schemaRegistryError(String)

    /// The circuit breaker is open; calls are being rejected.
    case circuitOpen

    /// An unexpected internal error occurred.
    case internalError(String)

    /// A transaction operation failed.
    case transaction(String)

    /// A record violated the topic's data contract.
    case contractViolation(topic: String, details: String)

    /// Attestation signature verification failed.
    case attestationFailed(String)

    /// An agent lacks permission to access memory.
    case memoryAccessDenied(agent: String)

    /// A branch exceeded its storage or lifetime quota.
    case branchQuotaExceeded(branch: String, details: String)

    /// Semantic search is unavailable (embedding provider down).
    case semanticSearchUnavailable(String)

    /// The requested operation has no verified protocol contract in this SDK.
    case unsupported(String)

    // MARK: - Computed Properties

    /// Programmatic error classification.
    public var errorCode: ErrorCode {
        switch self {
        case .notConnected, .connectionFailed:
            return .connection
        case .timeout:
            return .timeout
        case .authenticationFailed:
            return .authentication
        case .authorizationFailed:
            return .authorization
        case .topicNotFound:
            return .topicNotFound
        case .partitionNotFound:
            return .partitionNotFound
        case .protocolError:
            return .protocol
        case .serializationError:
            return .serialization
        case .schemaRegistryError:
            return .schema
        case .configurationError:
            return .configuration
        case .offlineQueueFull, .adminOperationFailed, .queryFailed, .internalError, .transaction:
            return .internal
        case .circuitOpen:
            return .circuitOpen
        case .contractViolation:
            return .contractViolation
        case .attestationFailed:
            return .attestationFailed
        case .memoryAccessDenied:
            return .memoryAccessDenied
        case .branchQuotaExceeded:
            return .branchQuotaExceeded
        case .semanticSearchUnavailable:
            return .semanticSearchUnavailable
        case .unsupported:
            return .unsupported
        }
    }

    /// Whether this error is transient and the operation may succeed if retried.
    public var isRetryable: Bool {
        switch errorCode {
        case .connection, .timeout, .circuitOpen, .semanticSearchUnavailable:
            return true
        default:
            return false
        }
    }

    /// Human-readable guidance for resolving this error.
    public var hint: String {
        switch self {
        case .notConnected:
            return "Call connect() before producing or subscribing."
        case .connectionFailed(let reason):
            return "Connection failed (\(reason)). Verify the server URL and network connectivity."
        case .authenticationFailed:
            return "Check your authToken and confirm the server accepts bearer authentication."
        case .authorizationFailed:
            return "The authenticated identity lacks permission for this operation. Check ACLs."
        case .timeout:
            return "The operation timed out. Consider increasing the timeout or checking server load."
        case .topicNotFound(let name):
            return "Topic '\(name)' does not exist. Create it first or enable auto-create on the server."
        case .partitionNotFound(let detail):
            return "Partition not found (\(detail)). Verify the partition index is within the topic's range."
        case .serializationError:
            return "Message payload could not be serialized/deserialized. Check the data format."
        case .protocolError:
            return "Wire-protocol error. Ensure the client and server versions are compatible."
        case .configurationError(let detail):
            return "Invalid configuration (\(detail)). Review StreamlineConfiguration values."
        case .offlineQueueFull:
            return "The offline queue is full (1000 messages). Connect to the server or reduce produce rate."
        case .adminOperationFailed(let reason):
            return "Admin operation failed (\(reason)). Check server logs for details."
        case .queryFailed(let reason):
            return "SQL query failed (\(reason)). Verify your query syntax."
        case .schemaRegistryError(let reason):
            return "Schema registry error (\(reason)). Check subject names and schema compatibility."
        case .circuitOpen:
            return "Circuit breaker is open due to repeated failures. Wait for the open timeout to elapse."
        case .internalError(let reason):
            return "Internal error (\(reason)). This may indicate a bug — please report it."
        case .transaction(let reason):
            return "Transaction error (\(reason)). Transactions are unsupported by the current WebSocket transport."
        case .contractViolation(let topic, _):
            return "Record violated the data contract for topic '\(topic)'. Validate the record against the registered schema."
        case .attestationFailed:
            return "Attestation signature verification failed. Check the signing key and attestation configuration."
        case .memoryAccessDenied(let agent):
            return "Agent '\(agent)' lacks permission. Verify agent permissions for memory operations."
        case .branchQuotaExceeded(let branch, _):
            return "Branch '\(branch)' exceeded its quota. Increase branch quotas or clean up unused branches."
        case .semanticSearchUnavailable:
            return "Semantic search is unavailable. Check embedding provider connectivity and configuration."
        case .unsupported(let reason):
            return "Unsupported operation (\(reason)). This SDK refused to claim success without a verified protocol contract."
        }
    }
}

/// Utilities for validating records before serialization.
enum RecordValidation {
    /// Maximum allowed record size in bytes.
    static let maxRecordSize = 1_048_576  // 1 MB

    /// Validates that a record does not exceed the maximum size.
    static func validate(key: Data?, value: Data?) throws {
        let totalSize = (key?.count ?? 0) + (value?.count ?? 0)
        if totalSize > maxRecordSize {
            throw StreamlineError.serializationError(
                "Record size \(totalSize) exceeds maximum \(maxRecordSize) bytes"
            )
        }
    }
}
