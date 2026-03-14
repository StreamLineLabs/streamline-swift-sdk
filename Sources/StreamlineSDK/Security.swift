import Foundation

// MARK: - TLS Configuration

/// TLS configuration for secure connections.
public struct TlsConfig: Sendable, Equatable {
    /// Whether TLS is enabled.
    public let enabled: Bool

    /// Path to the CA certificate bundle for server verification.
    public let caCertificatePath: String?

    /// Path to the client certificate for mutual TLS.
    public let clientCertificatePath: String?

    /// Path to the client private key for mutual TLS.
    public let clientKeyPath: String?

    /// Skip server certificate verification (for development only).
    public let insecureSkipVerify: Bool

    public init(
        enabled: Bool = false,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil,
        insecureSkipVerify: Bool = false
    ) {
        self.enabled = enabled
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.insecureSkipVerify = insecureSkipVerify
    }
}

// MARK: - SASL Configuration

/// SASL authentication mechanism.
public enum SaslMechanism: String, Sendable, Equatable {
    case plain = "PLAIN"
    case scramSha256 = "SCRAM-SHA-256"
    case scramSha512 = "SCRAM-SHA-512"
}

/// SASL authentication configuration.
public struct SaslConfig: Sendable, Equatable {
    /// Authentication mechanism.
    public let mechanism: SaslMechanism

    /// Username for authentication.
    public let username: String

    /// Password for authentication.
    public let password: String

    public init(mechanism: SaslMechanism = .plain, username: String, password: String) {
        self.mechanism = mechanism
        self.username = username
        self.password = password
    }
}

// MARK: - Telemetry

/// Telemetry span for tracking operation durations.
public final class TelemetrySpan: @unchecked Sendable {
    /// The operation name (e.g., "orders produce").
    public let name: String

    /// The topic associated with this span.
    public let topic: String

    /// The operation type.
    public let operation: String

    let startTime: Date

    private let lock = NSLock()
    private var _attributes: [String: String] = [:]
    private var _error: Error?

    init(name: String, topic: String, operation: String) {
        self.name = name
        self.topic = topic
        self.operation = operation
        self.startTime = Date()
    }

    /// Duration since span start, in seconds.
    public var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    /// Attach a key-value attribute to the span.
    public func setAttribute(_ key: String, value: String) {
        lock.lock()
        _attributes[key] = value
        lock.unlock()
    }

    /// Record an error on the span.
    public func setError(_ error: Error) {
        lock.lock()
        _error = error
        lock.unlock()
    }

    /// Current span attributes.
    public var attributes: [String: String] {
        lock.lock()
        let copy = _attributes
        lock.unlock()
        return copy
    }

    /// Whether an error has been recorded on this span.
    public var hasError: Bool {
        lock.lock()
        let err = _error != nil
        lock.unlock()
        return err
    }
}

/// Protocol for telemetry implementations.
public protocol Telemetry: Sendable {
    func startSpan(topic: String, operation: String) -> TelemetrySpan
    func endSpan(_ span: TelemetrySpan)
    func endSpan(_ span: TelemetrySpan, error: String)
}

public extension Telemetry {
    /// Start a span with a custom name and attributes dictionary.
    func startSpan(_ name: String, attributes: [String: String]) -> TelemetrySpan {
        let topic = attributes[TelemetryAttributes.messagingDestinationName] ?? ""
        let operation = attributes[TelemetryAttributes.messagingOperation] ?? ""
        let span = startSpan(topic: topic, operation: operation)
        for (key, value) in attributes {
            span.setAttribute(key, value: value)
        }
        return span
    }

    /// Generate a W3C traceparent header value for context propagation.
    func traceparent() -> String? {
        TraceContext.generateTraceparent()
    }
}

/// No-op telemetry implementation (zero overhead when telemetry is disabled).
public final class NoOpTelemetry: Telemetry, @unchecked Sendable {
    public init() {}

    public func startSpan(topic: String, operation: String) -> TelemetrySpan {
        TelemetrySpan(name: "\(topic) \(operation)", topic: topic, operation: operation)
    }

    public func endSpan(_ span: TelemetrySpan) {}
    public func endSpan(_ span: TelemetrySpan, error: String) {}
}

/// Console-based telemetry that prints timing information to stdout.
public final class ConsoleTelemetry: Telemetry, @unchecked Sendable {
    public init() {}

    public func startSpan(topic: String, operation: String) -> TelemetrySpan {
        let span = TelemetrySpan(name: "\(topic) \(operation)", topic: topic, operation: operation)
        print("[telemetry] START \(span.name)")
        return span
    }

    public func endSpan(_ span: TelemetrySpan) {
        let durationMs = span.elapsed * 1000
        print("[telemetry] END   \(span.name) (\(String(format: "%.1f", durationMs))ms)")
    }

    public func endSpan(_ span: TelemetrySpan, error: String) {
        let durationMs = span.elapsed * 1000
        print("[telemetry] ERROR \(span.name) (\(String(format: "%.1f", durationMs))ms): \(error)")
    }
}

/// W3C Trace Context helper for distributed tracing.
public enum TraceContext {
    /// Generate a W3C traceparent header value.
    public static func generateTraceparent() -> String {
        let traceId = generateHexId(length: 32)
        let spanId = generateHexId(length: 16)
        return "00-\(traceId)-\(spanId)-01"
    }

    /// Parse a traceparent header into components.
    public static func parseTraceparent(_ traceparent: String) -> (version: String, traceId: String, spanId: String, traceFlags: String)? {
        let parts = traceparent.split(separator: "-")
        guard parts.count == 4, parts[0] == "00" else { return nil }
        return (
            version: String(parts[0]),
            traceId: String(parts[1]),
            spanId: String(parts[2]),
            traceFlags: String(parts[3])
        )
    }

    private static func generateHexId(length: Int) -> String {
        (0..<length).map { _ in
            String(format: "%x", Int.random(in: 0..<16))
        }.joined()
    }
}
