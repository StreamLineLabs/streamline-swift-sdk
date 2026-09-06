import Foundation

/// SDK version constant, kept in sync with the organization release.
public let streamlineSDKVersion = "0.4.0"

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

    /// TLS requirement. Only platform-default trust with a `wss://` URL is
    /// supported; custom CA, mTLS, and insecure options are rejected.
    public let tls: TlsConfig?

    /// Retained for source compatibility. SASL is currently unsupported and
    /// non-nil values are rejected by ``validate()`` and ``StreamlineClient/connect()``.
    public let sasl: SaslConfig?

    /// Producer configuration.
    public let producerConfig: ProducerConfig

    /// Consumer configuration.
    public let consumerConfig: ConsumerConfig

    /// Initial backoff interval for reconnection (doubles on each retry).
    public let initialBackoff: TimeInterval

    /// Maximum backoff interval cap.
    public let maxBackoff: TimeInterval

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
        maxBackoff: TimeInterval = 30
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
    }

    /// Validate that all values are well formed and supported by the current
    /// URLSession WebSocket transport.
    public func validate() throws {
        try ConfigValidator.validate(self)
    }
}

/// Validates configuration before client initialization.
enum ConfigValidator {
    static func validate(_ config: StreamlineConfiguration) throws {
        guard let scheme = config.url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else {
            throw StreamlineError.configurationError("server URL must use ws:// or wss://")
        }
        guard config.timeout > 0 else {
            throw StreamlineError.configurationError("timeout must be positive")
        }
        guard config.maxRetries >= 0 else {
            throw StreamlineError.configurationError("maxRetries must not be negative")
        }
        guard config.initialBackoff > 0 else {
            throw StreamlineError.configurationError("initialBackoff must be positive")
        }
        guard config.maxBackoff > 0 else {
            throw StreamlineError.configurationError("maxBackoff must be positive")
        }
        guard config.initialBackoff <= config.maxBackoff else {
            throw StreamlineError.configurationError("initialBackoff must not exceed maxBackoff")
        }
        if let token = config.authToken, token.isEmpty {
            throw StreamlineError.configurationError("authToken must not be empty")
        }

        if let tls = config.tls {
            guard tls.caCertificatePath == nil,
                  tls.clientCertificatePath == nil,
                  tls.clientKeyPath == nil,
                  !tls.insecureSkipVerify
            else {
                throw StreamlineError.configurationError(
                    "custom CA, mutual TLS, and insecure TLS options are unsupported"
                )
            }
            if tls.enabled, scheme != "wss" {
                throw StreamlineError.configurationError(
                    "TLS requires a wss:// server URL"
                )
            }
        }

        if config.sasl != nil {
            throw StreamlineError.configurationError(
                "SASL is unsupported by the WebSocket transport; use authToken"
            )
        }

        try config.producerConfig.validate()
        try config.consumerConfig.validate()
    }
}
