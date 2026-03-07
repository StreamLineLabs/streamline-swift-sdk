import Foundation

/// Configuration for connecting to a Streamline server.
///
/// All properties are immutable after initialization. Use the initializer
/// to set all values. This ensures thread safety for concurrent use.
public struct StreamlineConfiguration: Sendable {
    /// WebSocket URL of the Streamline server (e.g. "ws://localhost:9092").
    public let url: URL

    /// Whether the client should automatically reconnect on disconnection.
    public let autoReconnect: Bool

    /// Maximum number of reconnection attempts before giving up.
    public let maxRetries: Int

    /// Connection timeout interval in seconds.
    public let timeout: TimeInterval

    /// Optional authentication token.
    public let authToken: String?

    /// TLS configuration for secure connections.
    public let tls: TlsConfig?

    /// SASL authentication configuration.
    public let sasl: SaslConfig?

    /// Producer configuration.
    public let producerConfig: ProducerConfig

    /// Consumer configuration.
    public let consumerConfig: ConsumerConfig

    /// Initial backoff interval for reconnection (doubles on each retry).
    public let initialBackoff: TimeInterval

    /// Maximum backoff interval cap.
    public let maxBackoff: TimeInterval

    /// Configuration for the circuit breaker protecting send operations.
    public let circuitBreakerConfig: CircuitBreakerConfig

    /// Configuration for the retry policy on transient failures.
    public let retryPolicyConfig: RetryPolicyConfig

    public init(
        url: URL,
        autoReconnect: Bool = true,
        maxRetries: Int = 10,
        timeout: TimeInterval = 30,
        authToken: String? = nil,
        tls: TlsConfig? = nil,
        sasl: SaslConfig? = nil,
        producerConfig: ProducerConfig = ProducerConfig(),
        consumerConfig: ConsumerConfig = ConsumerConfig(),
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30,
        circuitBreakerConfig: CircuitBreakerConfig = CircuitBreakerConfig(),
        retryPolicyConfig: RetryPolicyConfig = RetryPolicyConfig()
    ) {
        self.url = url
        self.autoReconnect = autoReconnect
        self.maxRetries = maxRetries
        self.timeout = timeout
        self.authToken = authToken
        self.tls = tls
        self.sasl = sasl
        self.producerConfig = producerConfig
        self.consumerConfig = consumerConfig
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.circuitBreakerConfig = circuitBreakerConfig
        self.retryPolicyConfig = retryPolicyConfig
    }
}

