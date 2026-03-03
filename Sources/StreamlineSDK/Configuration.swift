import Foundation

/// Configuration for connecting to a Streamline server.
public struct StreamlineConfiguration {
    /// WebSocket URL of the Streamline server (e.g. "ws://localhost:9092").
    public let url: URL

    /// Whether the client should automatically reconnect on disconnection.
    public var autoReconnect: Bool

    /// Maximum number of reconnection attempts before giving up.
    public var maxRetries: Int

    /// Connection timeout interval in seconds.
    public var timeout: TimeInterval

    /// Optional authentication token.
    public var authToken: String?

    /// Initial backoff interval for reconnection (doubles on each retry).
    public var initialBackoff: TimeInterval

    /// Maximum backoff interval cap.
    public var maxBackoff: TimeInterval

    public init(
        url: URL,
        autoReconnect: Bool = true,
        maxRetries: Int = 10,
        timeout: TimeInterval = 30,
        authToken: String? = nil,
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 30
    ) {
        self.url = url
        self.autoReconnect = autoReconnect
        self.maxRetries = maxRetries
        self.timeout = timeout
        self.authToken = authToken
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
    }
}

