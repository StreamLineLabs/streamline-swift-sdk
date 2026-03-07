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

    public init(topic: String, key: String? = nil, value: Data, offset: Int64? = nil, timestamp: Date? = nil) {
        self.topic = topic
        self.key = key
        self.value = value
        self.offset = offset
        self.timestamp = timestamp
    }

    /// Convenience initializer that encodes a UTF-8 string as the value.
    public init(topic: String, key: String? = nil, stringValue: String, offset: Int64? = nil, timestamp: Date? = nil) {
        self.init(topic: topic, key: key, value: Data(stringValue.utf8), offset: offset, timestamp: timestamp)
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

/// Schema metadata from the Schema Registry.
public struct SchemaInfo: Sendable, Equatable {
    public let subject: String
    public let id: Int
    public let version: Int
    public let schemaType: String
    public let schema: String

    public init(subject: String, id: Int, version: Int, schemaType: String, schema: String) {
        self.subject = subject
        self.id = id
        self.version = version
        self.schemaType = schemaType
        self.schema = schema
    }
}

/// Schema format types supported by the Schema Registry.
public enum SchemaFormat: String, Sendable, Equatable {
    case avro = "AVRO"
    case protobuf = "PROTOBUF"
    case json = "JSON"
}

// MARK: - Error Code

/// Categorizes SDK errors for programmatic handling.
public enum StreamlineErrorCode: String, Sendable, Equatable {
    case connection = "CONNECTION"
    case authentication = "AUTHENTICATION"
    case authorization = "AUTHORIZATION"
    case topicNotFound = "TOPIC_NOT_FOUND"
    case timeout = "TIMEOUT"
    case serialization = "SERIALIZATION"
    case offlineQueueFull = "OFFLINE_QUEUE_FULL"
    case circuitBreakerOpen = "CIRCUIT_BREAKER_OPEN"
    case adminOperation = "ADMIN"
    case query = "QUERY"
    case schemaRegistry = "SCHEMA_REGISTRY"
    case producer = "PRODUCER"
    case consumer = "CONSUMER"
    case `internal` = "INTERNAL"
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

    /// The authenticated principal lacks the required permissions.
    case authorizationFailed(String)

    /// A produce or subscribe call timed out.
    case timeout

    /// The requested topic does not exist.
    case topicNotFound(String)

    /// Message serialization or deserialization failed.
    case serializationError(String)

    /// The offline queue is full and cannot accept more messages.
    case offlineQueueFull

    /// The circuit breaker is open. Associated value is remaining cooldown in milliseconds.
    case circuitBreakerOpen(Int)

    /// A produce operation failed.
    case producerError(String)

    /// A consume operation failed.
    case consumerError(String)

    /// An admin operation failed.
    case adminOperationFailed(String)

    /// A SQL query failed.
    case queryFailed(String)

    /// A schema registry operation failed.
    case schemaRegistryError(String)

    /// Machine-readable error category.
    public var code: StreamlineErrorCode {
        switch self {
        case .notConnected, .connectionFailed: return .connection
        case .authenticationFailed: return .authentication
        case .authorizationFailed: return .authorization
        case .timeout: return .timeout
        case .topicNotFound: return .topicNotFound
        case .serializationError: return .serialization
        case .offlineQueueFull: return .offlineQueueFull
        case .circuitBreakerOpen: return .circuitBreakerOpen
        case .producerError: return .producer
        case .consumerError: return .consumer
        case .adminOperationFailed: return .adminOperation
        case .queryFailed: return .query
        case .schemaRegistryError: return .schemaRegistry
        }
    }

    /// Whether the operation may succeed if retried.
    public var isRetryable: Bool {
        switch self {
        case .notConnected, .connectionFailed, .timeout, .circuitBreakerOpen,
             .producerError, .consumerError, .schemaRegistryError, .adminOperationFailed:
            return true
        case .authenticationFailed, .authorizationFailed, .topicNotFound,
             .serializationError, .offlineQueueFull, .queryFailed:
            return false
        }
    }

    /// A human-friendly suggestion for resolving the error.
    public var hint: String {
        switch self {
        case .notConnected:
            return "Call connect() before performing operations."
        case .connectionFailed:
            return "Check that the Streamline server is running and the URL is correct."
        case .authenticationFailed:
            return "Verify your auth token or SASL credentials."
        case .authorizationFailed:
            return "Check that the authenticated principal has the required ACL permissions."
        case .timeout:
            return "Increase the timeout or check server health."
        case .topicNotFound:
            return "Create the topic first or check for typos in the topic name."
        case .serializationError:
            return "Verify message format matches the expected schema."
        case .offlineQueueFull:
            return "Reconnect to the server or increase the offline queue capacity."
        case .circuitBreakerOpen:
            return "The remote endpoint is unhealthy. Retry after the reset timeout."
        case .producerError:
            return "Check message size limits and server connectivity."
        case .consumerError:
            return "Check consumer group configuration and server connectivity."
        case .adminOperationFailed:
            return "Check server connectivity and required permissions."
        case .queryFailed:
            return "Verify SQL syntax and that the analytics feature is enabled on the server."
        case .schemaRegistryError:
            return "Check schema registry connectivity and schema compatibility."
        }
    }
}

