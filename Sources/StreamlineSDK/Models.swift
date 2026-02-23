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

// MARK: - Errors

/// Errors that can occur when interacting with the Streamline SDK.
public enum StreamlineError: Error, Sendable, Equatable {
    /// The client is not currently connected.
    case notConnected

    /// A connection attempt failed.
    case connectionFailed(String)

    /// The server rejected the authentication credentials.
    case authenticationFailed(String)

    /// A produce or subscribe call timed out.
    case timeout

    /// The requested topic does not exist.
    case topicNotFound(String)

    /// Message serialization or deserialization failed.
    case serializationError(String)

    /// The offline queue is full and cannot accept more messages.
    case offlineQueueFull
}
