import Foundation
import StreamlineSDK

/// Demonstrates the CircuitBreaker and RetryPolicy resilience features.
///
/// The circuit breaker protects against cascading failures by opening the
/// circuit after consecutive failures, rejecting calls during the cooldown
/// period, and then probing with a single request to check recovery.
///
/// The retry policy adds exponential backoff with jitter for transient
/// errors, integrating with the `isRetryable` flag on all errors.

// MARK: - 1. Configure resilience via StreamlineConfiguration

let config = StreamlineConfiguration(
    url: URL(string: "ws://localhost:9092")!,
    circuitBreakerConfig: CircuitBreakerConfig(
        failureThreshold: 3,     // Open after 3 consecutive failures
        resetTimeout: 10,        // Probe after 10 seconds
        halfOpenMaxAttempts: 1   // 1 successful probe closes the circuit
    ),
    retryPolicyConfig: RetryPolicyConfig(
        maxRetries: 5,
        baseDelay: 0.2,
        maxDelay: 10,
        jitter: true             // Random jitter prevents thundering herd
    )
)

let client = StreamlineClient(configuration: config)

// MARK: - 2. Produce with automatic resilience

// Sends are automatically protected by CircuitBreaker + RetryPolicy.
// If the server is temporarily down, the retry policy will retry with
// exponential backoff. If failures persist, the circuit breaker opens
// and throws StreamlineError.circuitBreakerOpen immediately.

client.connect()

do {
    try client.produce(topic: "events", key: "user-1", stringValue: #"{"action":"click"}"#)
    print("Message sent successfully")
} catch let error as StreamlineError {
    print("Error (\(error.code)): \(error)")
    print("Retryable: \(error.isRetryable)")
    print("Hint: \(error.hint)")

    if case .circuitBreakerOpen(let remainingMs) = error {
        print("Circuit breaker OPEN — cooldown: \(remainingMs)ms")
    }
}

// MARK: - 3. Monitor circuit breaker state

print("Circuit state: \(client.circuitBreaker.state)")
// Possible values: .closed, .open, .halfOpen

// Manually reset the circuit breaker if needed
client.circuitBreaker.reset()
print("Circuit reset to: \(client.circuitBreaker.state)") // .closed

// MARK: - 4. Use RetryPolicy standalone

let retryPolicy = RetryPolicy(config: RetryPolicyConfig(
    maxRetries: 3,
    baseDelay: 0.1,
    jitter: true,
    retryIf: { $0 is StreamlineError }
))

do {
    var attempts = 0
    let result: String = try retryPolicy.execute {
        attempts += 1
        print("  Attempt \(attempts)...")
        if attempts < 3 { throw StreamlineError.connectionFailed("Server busy") }
        return "Success on attempt \(attempts)"
    }
    print("Result: \(result)")
} catch {
    print("All retries exhausted: \(error)")
}

// MARK: - 5. Use CircuitBreaker standalone

let breaker = CircuitBreaker(config: CircuitBreakerConfig(
    failureThreshold: 2,
    resetTimeout: 5
))

// Trip the breaker with failures
for _ in 0..<2 {
    do { _ = try breaker.execute { throw StreamlineError.connectionFailed("down") } } catch {}
}
print("After 2 failures: \(breaker.state)") // .open

// Wait for reset timeout, then probe
Thread.sleep(forTimeInterval: 5.1)
do {
    try breaker.execute { print("Probe succeeded!") }
    print("Circuit recovered: \(breaker.state)") // .closed
} catch {
    print("Still open: \(error)")
}

client.disconnect()
