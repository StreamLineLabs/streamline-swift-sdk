import Foundation

// MARK: - Configuration

/// Configuration for a ``RetryPolicy``.
public struct RetryPolicyConfig: Sendable {
    /// Maximum number of retry attempts (0 = no retries).
    public let maxRetries: Int

    /// Initial delay between retries in seconds.
    public let baseDelay: TimeInterval

    /// Upper bound for the computed delay in seconds.
    public let maxDelay: TimeInterval

    /// When true, adds random jitter to avoid thundering-herd effects.
    public let jitter: Bool

    /// Optional predicate — only retry when the error matches.
    /// When nil, defaults to retrying ``StreamlineError`` cases that are retryable.
    public let retryIf: (@Sendable (Error) -> Bool)?

    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.2,
        maxDelay: TimeInterval = 30,
        jitter: Bool = true,
        retryIf: (@Sendable (Error) -> Bool)? = nil
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.retryIf = retryIf
    }
}

// MARK: - Retry Policy

/// Retry policy with exponential backoff and optional jitter.
///
/// Wraps an async action and retries it up to ``RetryPolicyConfig/maxRetries``
/// times using exponential backoff.
///
/// ```swift
/// let policy = RetryPolicy(config: .init(maxRetries: 5))
/// let result = try await policy.execute { try await riskyCall() }
/// ```
public struct RetryPolicy: Sendable {

    public let config: RetryPolicyConfig

    public init(config: RetryPolicyConfig = RetryPolicyConfig()) {
        self.config = config
    }

    /// Execute `action` with retries according to the configured policy.
    ///
    /// - Returns: The result of a successful invocation.
    /// - Throws: The last error if all retries are exhausted or the error is not retryable.
    public func execute<T>(_ action: () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0 ... config.maxRetries {
            do {
                return try await action()
            } catch {
                lastError = error

                if attempt >= config.maxRetries || !shouldRetry(error) {
                    throw error
                }

                let delay = computeDelay(attempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? StreamlineError.timeout
    }

    /// Synchronous overload for non-async contexts.
    public func execute<T>(_ action: () throws -> T) throws -> T {
        var lastError: Error?

        for attempt in 0 ... config.maxRetries {
            do {
                return try action()
            } catch {
                lastError = error

                if attempt >= config.maxRetries || !shouldRetry(error) {
                    throw error
                }

                let delay = computeDelay(attempt: attempt)
                Thread.sleep(forTimeInterval: delay)
            }
        }

        throw lastError ?? StreamlineError.timeout
    }

    // MARK: - Internal

    func computeDelay(attempt: Int) -> TimeInterval {
        let exponential = config.baseDelay * pow(2.0, Double(min(attempt, 30)))
        let capped = min(exponential, config.maxDelay)
        guard config.jitter else { return capped }
        return (capped / 2) + Double.random(in: 0 ..< (capped / 2))
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let predicate = config.retryIf {
            return predicate(error)
        }
        guard let slError = error as? StreamlineError else { return false }
        return slError.isRetryable
    }
}
