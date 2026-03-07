import Foundation

// MARK: - Circuit Breaker State

/// State of the circuit breaker.
///
/// - ``closed``: Normal operation — requests pass through and failures are tracked.
/// - ``open``: Circuit is tripped — requests are rejected immediately.
/// - ``halfOpen``: A single probe request is allowed to determine recovery.
public enum CircuitBreakerState: Sendable, Equatable {
    case closed
    case open
    case halfOpen
}

// MARK: - Configuration

/// Configuration for a ``CircuitBreaker``.
public struct CircuitBreakerConfig: Sendable {
    /// Number of consecutive failures before the circuit opens.
    public let failureThreshold: Int

    /// Time in seconds to wait in the open state before probing.
    public let resetTimeout: TimeInterval

    /// Number of successful probes required to close the circuit.
    public let halfOpenMaxAttempts: Int

    public init(failureThreshold: Int = 5, resetTimeout: TimeInterval = 30, halfOpenMaxAttempts: Int = 1) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.halfOpenMaxAttempts = halfOpenMaxAttempts
    }
}

// MARK: - Circuit Breaker

/// Implements the Circuit Breaker resilience pattern.
///
/// When a configurable number of consecutive failures is reached the breaker
/// transitions from ``CircuitBreakerState/closed`` to ``CircuitBreakerState/open``,
/// rejecting all calls immediately. After the reset timeout the breaker moves
/// to ``CircuitBreakerState/halfOpen`` and allows a probe request. If the probe
/// succeeds the circuit closes; if it fails the circuit re-opens.
///
/// Thread-safe — uses an `actor`-like serial dispatch queue for state mutations.
///
/// ```swift
/// let cb = CircuitBreaker(config: .init(failureThreshold: 3))
/// let result = try await cb.execute { try await riskyRemoteCall() }
/// ```
public final class CircuitBreaker: @unchecked Sendable {

    private let config: CircuitBreakerConfig
    private let lock = NSLock()

    private var _state: CircuitBreakerState = .closed {
        didSet {
            guard _state != oldValue else { return }
            let newState = _state
            onStateChange?(newState)
        }
    }
    private var failureCount: Int = 0
    private var halfOpenSuccesses: Int = 0
    private var lastFailureTime: Date?

    // -- Metrics --
    private var _totalFailures: Int = 0
    private var _totalSuccesses: Int = 0
    private var _totalRejections: Int = 0

    /// Called whenever the circuit breaker transitions to a new state.
    public var onStateChange: ((CircuitBreakerState) -> Void)?

    /// Total number of failures recorded since creation.
    public var totalFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalFailures
    }

    /// Total number of successes recorded since creation.
    public var totalSuccesses: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalSuccesses
    }

    /// Total number of calls rejected while the circuit was open.
    public var totalRejections: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalRejections
    }

    /// Current state of the circuit breaker (snapshot — may change immediately).
    public var state: CircuitBreakerState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public init(config: CircuitBreakerConfig = CircuitBreakerConfig()) {
        self.config = config
    }

    /// Execute `action` through the circuit breaker.
    ///
    /// - Throws: ``StreamlineError/circuitBreakerOpen(_:)`` when the circuit is
    ///   open and the reset timeout has not elapsed. Rethrows any error from `action`.
    public func execute<T>(_ action: () throws -> T) throws -> T {
        let calledInState = try acquirePermission()

        do {
            let result = try action()
            onSuccess(calledInState: calledInState)
            return result
        } catch {
            onFailure(calledInState: calledInState)
            throw error
        }
    }

    /// Async overload for structured-concurrency contexts.
    public func execute<T>(_ action: () async throws -> T) async throws -> T {
        let calledInState = try acquirePermission()

        do {
            let result = try await action()
            onSuccess(calledInState: calledInState)
            return result
        } catch {
            onFailure(calledInState: calledInState)
            throw error
        }
    }

    /// Manually reset the circuit breaker to ``CircuitBreakerState/closed``.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _state = .closed
        failureCount = 0
        halfOpenSuccesses = 0
        lastFailureTime = nil
    }

    // MARK: - Private Helpers

    private func acquirePermission() throws -> CircuitBreakerState {
        lock.lock()
        defer { lock.unlock() }

        switch _state {
        case .closed:
            return .closed
        case .open:
            let elapsed: TimeInterval
            if let last = lastFailureTime {
                elapsed = Date().timeIntervalSince(last)
            } else {
                elapsed = .infinity
            }

            if elapsed >= config.resetTimeout {
                _state = .halfOpen
                halfOpenSuccesses = 0
                return .halfOpen
            } else {
                let remainingMs = Int((config.resetTimeout - elapsed) * 1000)
                _totalRejections += 1
                throw StreamlineError.circuitBreakerOpen(remainingMs)
            }
        case .halfOpen:
            return .halfOpen
        }
    }

    private func onSuccess(calledInState: CircuitBreakerState) {
        lock.lock()
        defer { lock.unlock() }

        _totalSuccesses += 1

        switch calledInState {
        case .halfOpen:
            halfOpenSuccesses += 1
            if halfOpenSuccesses >= config.halfOpenMaxAttempts {
                _state = .closed
                failureCount = 0
                halfOpenSuccesses = 0
                lastFailureTime = nil
            }
        case .closed:
            failureCount = 0
        case .open:
            break
        }
    }

    private func onFailure(calledInState: CircuitBreakerState) {
        lock.lock()
        defer { lock.unlock() }

        _totalFailures += 1
        lastFailureTime = Date()

        switch calledInState {
        case .closed:
            failureCount += 1
            if failureCount >= config.failureThreshold {
                _state = .open
            }
        case .halfOpen:
            _state = .open
            halfOpenSuccesses = 0
        case .open:
            break
        }
    }
}
