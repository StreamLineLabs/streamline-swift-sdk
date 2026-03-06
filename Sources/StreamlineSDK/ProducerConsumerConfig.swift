import Foundation

// MARK: - Producer Configuration

/// Compression type for produced messages.
public enum CompressionType: String, Sendable, Equatable {
    case none = "none"
    case gzip = "gzip"
    case snappy = "snappy"
    case lz4 = "lz4"
    case zstd = "zstd"
}

/// Acknowledgment level for produced messages.
public enum Acks: Int, Sendable, Equatable {
    /// No acknowledgment required (fire and forget).
    case none = 0
    /// Wait for leader acknowledgment.
    case one = 1
    /// Wait for all replicas to acknowledge.
    case all = -1
}

/// Configuration for message production.
public struct ProducerConfig: Sendable, Equatable {
    /// Maximum batch size in bytes before flushing.
    public let batchSize: Int

    /// Time to wait for additional messages before sending a batch (ms).
    public let lingerMs: Int

    /// Compression type for the message batch.
    public let compression: CompressionType

    /// Number of retries for failed sends.
    public let retries: Int

    /// Backoff between retries (ms).
    public let retryBackoffMs: Int

    /// Enable idempotent producer (exactly-once semantics).
    public let idempotent: Bool

    /// Acknowledgment level.
    public let acks: Acks

    public init(
        batchSize: Int = 16384,
        lingerMs: Int = 0,
        compression: CompressionType = .none,
        retries: Int = 3,
        retryBackoffMs: Int = 100,
        idempotent: Bool = false,
        acks: Acks = .one
    ) {
        self.batchSize = batchSize
        self.lingerMs = lingerMs
        self.compression = compression
        self.retries = retries
        self.retryBackoffMs = retryBackoffMs
        self.idempotent = idempotent
        self.acks = acks
    }
}

// MARK: - Consumer Configuration

/// Auto-offset reset policy when no committed offset exists.
public enum OffsetReset: String, Sendable, Equatable {
    /// Start consuming from the earliest available offset.
    case earliest
    /// Start consuming from the latest offset.
    case latest
    /// Throw an error if no committed offset exists.
    case none
}

/// Configuration for message consumption.
public struct ConsumerConfig: Sendable, Equatable {
    /// Consumer group identifier (nil for standalone consumers).
    public let groupId: String?

    /// Whether to automatically commit offsets.
    public let autoCommit: Bool

    /// Interval between auto-commits (ms).
    public let autoCommitIntervalMs: Int

    /// Session timeout for consumer group membership (ms).
    public let sessionTimeoutMs: Int

    /// Heartbeat interval for consumer group coordination (ms).
    public let heartbeatIntervalMs: Int

    /// Maximum number of records returned per poll.
    public let maxPollRecords: Int

    /// Offset reset policy when no committed offset exists.
    public let autoOffsetReset: OffsetReset

    public init(
        groupId: String? = nil,
        autoCommit: Bool = true,
        autoCommitIntervalMs: Int = 5000,
        sessionTimeoutMs: Int = 30000,
        heartbeatIntervalMs: Int = 3000,
        maxPollRecords: Int = 500,
        autoOffsetReset: OffsetReset = .latest
    ) {
        self.groupId = groupId
        self.autoCommit = autoCommit
        self.autoCommitIntervalMs = autoCommitIntervalMs
        self.sessionTimeoutMs = sessionTimeoutMs
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.maxPollRecords = maxPollRecords
        self.autoOffsetReset = autoOffsetReset
    }
}
