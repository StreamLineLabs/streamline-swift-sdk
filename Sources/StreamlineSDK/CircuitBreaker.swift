import Foundation

// MARK: - Circuit Breaker State

/// Represents the current state of a circuit breaker.
public enum CircuitBreakerState: String, Sendable, Equatable {
    /// Circuit is closed — requests flow through normally.
    case closed
    /// Circuit is open — requests are rejected immediately.
    case open
    /// Circuit is half-open — a limited number of probe requests are allowed.
    case halfOpen
}

// MARK: - Circuit Breaker Configuration

/// Configuration for a ``CircuitBreaker``.
public struct CircuitBreakerConfig: Sendable, Equatable {
    /// Number of consecutive failures before the circuit opens.
    public let failureThreshold: Int

    /// Number of consecutive successes in half-open state before closing the circuit.
    public let successThreshold: Int

    /// Duration in seconds the circuit stays open before transitioning to half-open.
    public let openTimeout: TimeInterval

    /// Maximum number of probe requests allowed while half-open.
    public let halfOpenMaxRequests: Int

    public init(
        failureThreshold: Int = 5,
        successThreshold: Int = 2,
        openTimeout: TimeInterval = 30,
        halfOpenMaxRequests: Int = 3
    ) {
        self.failureThreshold = failureThreshold
        self.successThreshold = successThreshold
        self.openTimeout = openTimeout
        self.halfOpenMaxRequests = halfOpenMaxRequests
    }
}

// MARK: - Circuit Breaker Counts

/// Snapshot of circuit breaker counters.
public struct CircuitBreakerCounts: Sendable, Equatable {
    /// Total requests since the circuit entered its current state.
    public let requests: Int

    /// Consecutive successes in the current state.
    public let consecutiveSuccesses: Int

    /// Consecutive failures in the current state.
    public let consecutiveFailures: Int

    /// Total successes in the current state.
    public let totalSuccesses: Int

    /// Total failures in the current state.
    public let totalFailures: Int
}

// MARK: - Circuit Breaker

/// A thread-safe circuit breaker that prevents cascading failures.
///
/// The circuit breaker starts in the **closed** state where all requests pass
/// through. After `failureThreshold` consecutive failures the circuit **opens**
/// and immediately rejects requests with ``StreamlineError/circuitOpen``. After
/// `openTimeout` seconds the circuit transitions to **half-open**, allowing up
/// to `halfOpenMaxRequests` probe requests. If `successThreshold` consecutive
/// probes succeed the circuit closes again; any failure immediately re-opens it.
///
/// ```swift
/// let cb = CircuitBreaker()
/// try cb.check()          // throws if open
/// do {
///     try await riskyOperation()
///     cb.recordSuccess()
/// } catch {
///     cb.recordFailure()
///     throw error
/// }
/// ```
public final class CircuitBreaker: @unchecked Sendable {
    // MARK: - Properties

    public let config: CircuitBreakerConfig

    private let lock = NSLock()
    private var currentState: CircuitBreakerState = .closed
    private var consecutiveSuccessCount: Int = 0
    private var consecutiveFailureCount: Int = 0
    private var totalSuccessCount: Int = 0
    private var totalFailureCount: Int = 0
    private var requestCount: Int = 0
    private var lastStateChangeDate: Date = .init()

    // MARK: - Init

    public init(config: CircuitBreakerConfig = CircuitBreakerConfig()) {
        self.config = config
    }

    // MARK: - Public API

    /// Check whether a request is allowed. Throws ``StreamlineError/circuitOpen``
    /// if the circuit is open (or half-open with max probes reached).
    ///
    /// Call this **before** executing the protected operation.
    public func check() throws {
        lock.lock()
        defer { lock.unlock() }

        switch currentState {
        case .closed:
            requestCount += 1
            return

        case .open:
            if Date().timeIntervalSince(lastStateChangeDate) >= config.openTimeout {
                transitionTo(.halfOpen)
                requestCount += 1
                return
            }
            throw StreamlineError.circuitOpen

        case .halfOpen:
            if requestCount >= config.halfOpenMaxRequests {
                throw StreamlineError.circuitOpen
            }
            requestCount += 1
            return
        }
    }

    /// Record a successful operation. In the half-open state, reaching
    /// `successThreshold` consecutive successes closes the circuit.
    public func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }

        consecutiveSuccessCount += 1
        consecutiveFailureCount = 0
        totalSuccessCount += 1

        if currentState == .halfOpen, consecutiveSuccessCount >= config.successThreshold {
            transitionTo(.closed)
        }
    }

    /// Record a failed operation. In the closed state, reaching
    /// `failureThreshold` consecutive failures opens the circuit.
    /// In the half-open state any failure immediately re-opens the circuit.
    public func recordFailure() {
        lock.lock()
        defer { lock.unlock() }

        consecutiveFailureCount += 1
        consecutiveSuccessCount = 0
        totalFailureCount += 1

        switch currentState {
        case .closed:
            if consecutiveFailureCount >= config.failureThreshold {
                transitionTo(.open)
            }
        case .halfOpen:
            transitionTo(.open)
        case .open:
            break
        }
    }

    /// The current circuit breaker state.
    public func state() -> CircuitBreakerState {
        lock.lock()
        defer { lock.unlock() }

        // Check for automatic open → halfOpen transition.
        if currentState == .open,
           Date().timeIntervalSince(lastStateChangeDate) >= config.openTimeout
        {
            transitionTo(.halfOpen)
        }
        return currentState
    }

    /// Reset the circuit breaker to the closed state with zeroed counters.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        transitionTo(.closed)
    }

    /// A snapshot of the current counters.
    public func counts() -> CircuitBreakerCounts {
        lock.lock()
        defer { lock.unlock() }
        return CircuitBreakerCounts(
            requests: requestCount,
            consecutiveSuccesses: consecutiveSuccessCount,
            consecutiveFailures: consecutiveFailureCount,
            totalSuccesses: totalSuccessCount,
            totalFailures: totalFailureCount
        )
    }

    // MARK: - Internal

    /// Transition to a new state, resetting counters. Must be called under lock.
    private func transitionTo(_ newState: CircuitBreakerState) {
        currentState = newState
        consecutiveSuccessCount = 0
        consecutiveFailureCount = 0
        totalSuccessCount = 0
        totalFailureCount = 0
        requestCount = 0
        lastStateChangeDate = Date()
    }
}
