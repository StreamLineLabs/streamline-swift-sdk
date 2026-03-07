import XCTest
@testable import StreamlineSDK

final class CircuitBreakerTests: XCTestCase {

    func testStartsInClosedState() {
        let cb = CircuitBreaker()
        XCTAssertEqual(cb.state, .closed)
    }

    func testSuccessfulCallsKeepCircuitClosed() throws {
        let cb = CircuitBreaker(config: .init(failureThreshold: 3))
        for _ in 0..<10 {
            let result = try cb.execute { "ok" }
            XCTAssertEqual(result, "ok")
        }
        XCTAssertEqual(cb.state, .closed)
    }

    func testOpensAfterReachingFailureThreshold() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 3))
        for _ in 0..<3 {
            do {
                _ = try cb.execute { throw StreamlineError.connectionFailed("fail") }
            } catch {}
        }
        XCTAssertEqual(cb.state, .open)
    }

    func testRejectsCallsWhenOpen() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 1, resetTimeout: 60))
        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        XCTAssertEqual(cb.state, .open)

        XCTAssertThrowsError(try cb.execute { "should not run" }) { error in
            guard case StreamlineError.circuitBreakerOpen = error else {
                XCTFail("Expected circuitBreakerOpen, got \(error)")
                return
            }
        }
    }

    func testTransitionsToHalfOpenAfterResetTimeout() throws {
        let cb = CircuitBreaker(config: .init(failureThreshold: 1, resetTimeout: 0.01))
        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        XCTAssertEqual(cb.state, .open)

        Thread.sleep(forTimeInterval: 0.02)

        let result = try cb.execute { "probe" }
        XCTAssertEqual(result, "probe")
        XCTAssertEqual(cb.state, .closed)
    }

    func testHalfOpenFailureReOpensCircuit() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 1, resetTimeout: 0.01))
        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}

        Thread.sleep(forTimeInterval: 0.02)

        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail again") } } catch {}
        XCTAssertEqual(cb.state, .open)
    }

    func testResetReturnsToClosed() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 1))
        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        XCTAssertEqual(cb.state, .open)

        cb.reset()
        XCTAssertEqual(cb.state, .closed)
    }

    func testFailuresBelowThresholdKeepCircuitClosed() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 5))
        for _ in 0..<4 {
            do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        }
        XCTAssertEqual(cb.state, .closed)
    }

    func testSuccessResetsFailureCount() throws {
        let cb = CircuitBreaker(config: .init(failureThreshold: 3))
        for _ in 0..<2 {
            do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        }
        _ = try cb.execute { "ok" }
        for _ in 0..<2 {
            do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}
        }
        XCTAssertEqual(cb.state, .closed)
    }

    func testCircuitBreakerOpenErrorProperties() {
        let cb = CircuitBreaker(config: .init(failureThreshold: 1, resetTimeout: 60))
        do { _ = try cb.execute { throw StreamlineError.connectionFailed("fail") } } catch {}

        do {
            _ = try cb.execute { "no" }
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error.code, .circuitBreakerOpen)
            XCTAssertTrue(error.isRetryable)
            XCTAssertFalse(error.hint.isEmpty)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

final class RetryPolicyTests: XCTestCase {

    func testSucceedsOnFirstTry() throws {
        let policy = RetryPolicy(config: .init(maxRetries: 3))
        let result = try policy.execute { 42 }
        XCTAssertEqual(result, 42)
    }

    func testRetriesOnRetryableError() throws {
        var attempts = 0
        let policy = RetryPolicy(config: .init(maxRetries: 3, baseDelay: 0.001))

        let result: String = try policy.execute {
            attempts += 1
            if attempts < 3 { throw StreamlineError.connectionFailed("transient") }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 3)
    }

    func testDoesNotRetryNonRetryableError() {
        var attempts = 0
        let policy = RetryPolicy(config: .init(maxRetries: 3, baseDelay: 0.001))

        XCTAssertThrowsError(try policy.execute {
            attempts += 1
            throw StreamlineError.authenticationFailed("bad creds")
        } as String)

        XCTAssertEqual(attempts, 1)
    }

    func testExhaustsRetriesAndThrowsLastError() {
        var attempts = 0
        let policy = RetryPolicy(config: .init(maxRetries: 2, baseDelay: 0.001))

        XCTAssertThrowsError(try policy.execute {
            attempts += 1
            throw StreamlineError.connectionFailed("always fails")
        } as String)

        XCTAssertEqual(attempts, 3) // initial + 2 retries
    }

    func testDelayIsExponential() {
        let policy = RetryPolicy(config: .init(baseDelay: 0.1, maxDelay: 10, jitter: false))
        XCTAssertEqual(policy.computeDelay(attempt: 0), 0.1, accuracy: 0.001)
        XCTAssertEqual(policy.computeDelay(attempt: 1), 0.2, accuracy: 0.001)
        XCTAssertEqual(policy.computeDelay(attempt: 2), 0.4, accuracy: 0.001)
        XCTAssertEqual(policy.computeDelay(attempt: 3), 0.8, accuracy: 0.001)
    }

    func testDelayIsCappedAtMaxDelay() {
        let policy = RetryPolicy(config: .init(baseDelay: 0.1, maxDelay: 0.5, jitter: false))
        XCTAssertEqual(policy.computeDelay(attempt: 5), 0.5, accuracy: 0.001)
        XCTAssertEqual(policy.computeDelay(attempt: 10), 0.5, accuracy: 0.001)
    }

    func testJitterProducesDelayWithinExpectedRange() {
        let policy = RetryPolicy(config: .init(baseDelay: 1.0, maxDelay: 30, jitter: true))
        for _ in 0..<50 {
            let d = policy.computeDelay(attempt: 0)
            XCTAssertGreaterThanOrEqual(d, 0.5)
            XCTAssertLessThanOrEqual(d, 1.0)
        }
    }

    func testZeroRetriesThrowsImmediately() {
        var attempts = 0
        let policy = RetryPolicy(config: .init(maxRetries: 0, baseDelay: 0.001))

        XCTAssertThrowsError(try policy.execute {
            attempts += 1
            throw StreamlineError.connectionFailed("fail")
        } as String)

        XCTAssertEqual(attempts, 1)
    }
}
