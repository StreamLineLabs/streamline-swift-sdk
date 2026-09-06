import Foundation

// MARK: - Producer Configuration

/// Compression type for produced messages.
public enum CompressionType: String, Sendable, Equatable {
    case none
    case gzip
    case snappy
    case lz4
    case zstd
}

/// Acknowledgment level for produced messages.
public enum Acks: Int, Sendable, Equatable {
    /// No broker acknowledgment. A successful send only means URLSession
    /// accepted the WebSocket frame.
    case none = 0
    /// Retained for source compatibility; unsupported by this transport.
    case one = 1
    /// Retained for source compatibility; unsupported by this transport.
    case all = -1
}

/// Configuration for message production.
public struct ProducerConfig: Sendable, Equatable {
    /// Maximum buffered payload bytes before flushing individual WebSocket
    /// sends. This is not an atomic broker-side batch.
    public let batchSize: Int

    /// Time to wait before flushing buffered individual sends (ms).
    public let lingerMs: Int

    /// Compression mode. Only ``CompressionType/none`` is currently supported.
    public let compression: CompressionType

    /// Number of retries for failed WebSocket sends. Retries can produce
    /// duplicates because idempotence is unsupported.
    public let retries: Int

    /// Backoff between retries (ms).
    public let retryBackoffMs: Int

    /// Retained for source compatibility. Idempotent production is unsupported.
    public let idempotent: Bool

    /// Acknowledgment level. Only ``Acks/none`` is currently supported.
    public let acks: Acks

    public init(
        batchSize: Int = 16384,
        lingerMs: Int = 0,
        compression: CompressionType = .none,
        retries: Int = 3,
        retryBackoffMs: Int = 100,
        idempotent: Bool = false,
        acks: Acks = .none
    ) {
        self.batchSize = batchSize
        self.lingerMs = lingerMs
        self.compression = compression
        self.retries = retries
        self.retryBackoffMs = retryBackoffMs
        self.idempotent = idempotent
        self.acks = acks
    }

    /// Validate that this configuration can be honored by the current
    /// WebSocket transport.
    public func validate() throws {
        guard batchSize > 0 else {
            throw StreamlineError.configurationError("producer batchSize must be positive")
        }
        guard lingerMs >= 0 else {
            throw StreamlineError.configurationError("producer lingerMs must not be negative")
        }
        guard retries >= 0 else {
            throw StreamlineError.configurationError("producer retries must not be negative")
        }
        guard retryBackoffMs >= 0 else {
            throw StreamlineError.configurationError("producer retryBackoffMs must not be negative")
        }
        guard compression == .none else {
            throw StreamlineError.configurationError(
                "producer compression \(compression.rawValue) is unsupported by the WebSocket transport"
            )
        }
        guard !idempotent else {
            throw StreamlineError.configurationError(
                "idempotent production is unsupported by the WebSocket transport"
            )
        }
        guard acks == .none else {
            throw StreamlineError.configurationError(
                "broker acknowledgment mode \(acks.rawValue) is unsupported by the WebSocket transport"
            )
        }
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
///
/// The current WebSocket transport has no verified consumer-group
/// coordination, commit-acknowledgement, or offset-reset protocol — see
/// `StreamlineClient.commitOffsets`, `position`, and `committed`, which fail
/// closed with `StreamlineError.unsupported` for the same reason. Consumption
/// is plain topic subscription plus local `poll(maxRecords:timeout:)`; there
/// is no broker-side group membership, so ``validate()`` only accepts the
/// neutral "standalone consumer" shape represented by the defaults below.
/// Anything implying group coordination (a ``groupId``, ``autoCommit``, a
/// non-default session/heartbeat interval, a non-default ``maxPollRecords``,
/// or an ``autoOffsetReset`` other than ``OffsetReset/latest``) is rejected
/// up front instead of being silently accepted and then ignored.
public struct ConsumerConfig: Sendable, Equatable {
    /// The only session timeout accepted by ``validate()``: there is no
    /// consumer-group session to bound without a ``groupId``.
    public static let standaloneSessionTimeoutMs = 30000

    /// The only heartbeat interval accepted by ``validate()``: there is no
    /// consumer-group heartbeat without a ``groupId``.
    public static let standaloneHeartbeatIntervalMs = 3000

    /// Retained neutral value for the otherwise unsupported auto-commit
    /// interval field. Any other configured value is rejected.
    public static let standaloneAutoCommitIntervalMs = 5000

    /// The only `maxPollRecords` accepted by ``validate()``. Pass the
    /// desired batch size directly to `poll(maxRecords:timeout:)` instead —
    /// this field is not wired to any server-side bounded-poll contract.
    public static let standaloneMaxPollRecords = 500

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
        autoCommit: Bool = false,
        autoCommitIntervalMs: Int = ConsumerConfig.standaloneAutoCommitIntervalMs,
        sessionTimeoutMs: Int = ConsumerConfig.standaloneSessionTimeoutMs,
        heartbeatIntervalMs: Int = ConsumerConfig.standaloneHeartbeatIntervalMs,
        maxPollRecords: Int = ConsumerConfig.standaloneMaxPollRecords,
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

    /// Validate that this configuration can be honored by the current
    /// WebSocket transport. Only the neutral standalone-consumer defaults
    /// validate; any option implying unsupported consumer-group, commit,
    /// offset-reset, session, heartbeat, or max-poll semantics is rejected.
    public func validate() throws {
        guard groupId == nil else {
            throw StreamlineError.configurationError(
                "consumer groupId is unsupported: the WebSocket transport has no verified consumer-group coordination protocol"
            )
        }
        guard !autoCommit else {
            throw StreamlineError.configurationError(
                "autoCommit is unsupported: the WebSocket transport has no verified commit-acknowledgement contract"
            )
        }
        guard autoCommitIntervalMs == ConsumerConfig.standaloneAutoCommitIntervalMs else {
            throw StreamlineError.configurationError(
                "autoCommitIntervalMs is unsupported because autoCommit itself is unavailable"
            )
        }
        guard sessionTimeoutMs == ConsumerConfig.standaloneSessionTimeoutMs else {
            throw StreamlineError.configurationError(
                "sessionTimeoutMs is unsupported: there is no consumer-group session to bound without groupId"
            )
        }
        guard heartbeatIntervalMs == ConsumerConfig.standaloneHeartbeatIntervalMs else {
            throw StreamlineError.configurationError(
                "heartbeatIntervalMs is unsupported: there is no consumer-group heartbeat without groupId"
            )
        }
        guard maxPollRecords == ConsumerConfig.standaloneMaxPollRecords else {
            throw StreamlineError.configurationError(
                "maxPollRecords is unsupported as a config knob: pass the desired batch size directly to poll(maxRecords:) instead"
            )
        }
        guard autoOffsetReset == .latest else {
            throw StreamlineError.configurationError(
                "autoOffsetReset \(autoOffsetReset.rawValue) is unsupported: there is no committed offset to reset from without a consumer group"
            )
        }
    }
}
