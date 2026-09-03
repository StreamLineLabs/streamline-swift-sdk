/**
 Circuit breaker example for Streamline Swift SDK.

 Prerequisites:
   1. Start a Streamline server:  streamline --playground
   2. Run with:  swift run CircuitBreakerUsage (if integrated into a package)

 The circuit breaker prevents your application from repeatedly attempting
 operations against a failing server. After consecutive failures it "opens"
 and rejects requests immediately, giving the server time to recover.
 */
import Foundation
import StreamlineSDK

@main
struct CircuitBreakerUsage {
    static func main() async throws {
        print("Circuit Breaker Example")
        print(String(repeating: "=", count: 40))

        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            autoReconnect: true
        )

        // Configure the circuit breaker
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 5,
            successThreshold: 2,
            openTimeout: 10.0,
            halfOpenMaxRequests: 3
        ))

        let client = StreamlineClient(
            configuration: config,
            circuitBreaker: cb
        )
        client.connect()
        print("Connection initiated. Circuit state: \(cb.state())")

        // Send messages through the circuit breaker
        for i in 0..<20 {
            do {
                try cb.check()
                try client.produce(topic: "cb-example", stringValue: "message-\(i)")
                cb.recordSuccess()
                print("  Message \(i): sent (circuit: \(cb.state()))")
            } catch is StreamlineError where (try? cb.check()) == nil {
                print("  Message \(i): circuit breaker is OPEN")
            } catch {
                cb.recordFailure()
                print("  Message \(i): FAILED (\(error)) (circuit: \(cb.state()))")
            }
        }

        // Show final state
        let counts = cb.counts()
        print("\nFinal circuit state: \(cb.state())")
        print("Successes: \(counts.totalSuccesses), Failures: \(counts.totalFailures)")

        // Manual reset
        if cb.state() == .open {
            cb.reset()
            print("Circuit manually reset to: \(cb.state())")
        }

        client.disconnect()
        print("Done!")
    }
}
