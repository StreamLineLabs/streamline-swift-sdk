@testable import StreamlineSDK
import XCTest

// MARK: - ErrorCode Tests

final class ErrorCodeTests: XCTestCase {
    func testAllErrorCodesExist() {
        let codes: [ErrorCode] = [
            .connection, .timeout, .authentication, .authorization,
            .topicNotFound, .partitionNotFound, .protocol, .serialization,
            .schema, .configuration, .internal, .circuitOpen,
            .contractViolation, .attestationFailed, .memoryAccessDenied,
            .branchQuotaExceeded, .semanticSearchUnavailable, .unsupported,
        ]
        XCTAssertEqual(codes.count, 18)
        XCTAssertEqual(ErrorCode.allCases.count, 18)
    }

    func testErrorCodeRawValues() {
        XCTAssertEqual(ErrorCode.connection.rawValue, "connection")
        XCTAssertEqual(ErrorCode.timeout.rawValue, "timeout")
        XCTAssertEqual(ErrorCode.circuitOpen.rawValue, "circuitOpen")
    }

    func testErrorCodeEquality() {
        XCTAssertEqual(ErrorCode.connection, ErrorCode.connection)
        XCTAssertNotEqual(ErrorCode.connection, ErrorCode.timeout)
    }
}

// MARK: - StreamlineError ErrorCode Mapping

final class ErrorCodeMappingTests: XCTestCase {
    func testNotConnectedMapsToConnection() {
        XCTAssertEqual(StreamlineError.notConnected.errorCode, .connection)
    }

    func testConnectionFailedMapsToConnection() {
        XCTAssertEqual(StreamlineError.connectionFailed("refused").errorCode, .connection)
    }

    func testTimeoutMapsToTimeout() {
        XCTAssertEqual(StreamlineError.timeout.errorCode, .timeout)
    }

    func testAuthenticationFailedMapsToAuthentication() {
        XCTAssertEqual(StreamlineError.authenticationFailed("bad token").errorCode, .authentication)
    }

    func testAuthorizationFailedMapsToAuthorization() {
        XCTAssertEqual(StreamlineError.authorizationFailed("forbidden").errorCode, .authorization)
    }

    func testTopicNotFoundMapsToTopicNotFound() {
        XCTAssertEqual(StreamlineError.topicNotFound("events").errorCode, .topicNotFound)
    }

    func testPartitionNotFoundMapsToPartitionNotFound() {
        XCTAssertEqual(StreamlineError.partitionNotFound("events:99").errorCode, .partitionNotFound)
    }

    func testProtocolErrorMapsToProtocol() {
        XCTAssertEqual(StreamlineError.protocolError("bad frame").errorCode, .protocol)
    }

    func testSerializationErrorMapsToSerialization() {
        XCTAssertEqual(StreamlineError.serializationError("bad json").errorCode, .serialization)
    }

    func testSchemaRegistryErrorMapsToSchema() {
        XCTAssertEqual(StreamlineError.schemaRegistryError("not found").errorCode, .schema)
    }

    func testConfigurationErrorMapsToConfiguration() {
        XCTAssertEqual(StreamlineError.configurationError("bad url").errorCode, .configuration)
    }

    func testUnsupportedMapsToUnsupportedAndIsNotRetryable() {
        let error = StreamlineError.unsupported("no acknowledgement contract")
        XCTAssertEqual(error.errorCode, .unsupported)
        XCTAssertFalse(error.isRetryable)
    }

    func testOfflineQueueFullMapsToInternal() {
        XCTAssertEqual(StreamlineError.offlineQueueFull.errorCode, .internal)
    }

    func testAdminOperationFailedMapsToInternal() {
        XCTAssertEqual(StreamlineError.adminOperationFailed("500").errorCode, .internal)
    }

    func testQueryFailedMapsToInternal() {
        XCTAssertEqual(StreamlineError.queryFailed("syntax").errorCode, .internal)
    }

    func testInternalErrorMapsToInternal() {
        XCTAssertEqual(StreamlineError.internalError("bug").errorCode, .internal)
    }

    func testCircuitOpenMapsToCircuitOpen() {
        XCTAssertEqual(StreamlineError.circuitOpen.errorCode, .circuitOpen)
    }
}

// MARK: - isRetryable Tests

final class ErrorRetryableTests: XCTestCase {
    func testConnectionErrorsAreRetryable() {
        XCTAssertTrue(StreamlineError.notConnected.isRetryable)
        XCTAssertTrue(StreamlineError.connectionFailed("refused").isRetryable)
    }

    func testTimeoutIsRetryable() {
        XCTAssertTrue(StreamlineError.timeout.isRetryable)
    }

    func testCircuitOpenIsRetryable() {
        XCTAssertTrue(StreamlineError.circuitOpen.isRetryable)
    }

    func testAuthenticationIsNotRetryable() {
        XCTAssertFalse(StreamlineError.authenticationFailed("bad").isRetryable)
    }

    func testAuthorizationIsNotRetryable() {
        XCTAssertFalse(StreamlineError.authorizationFailed("forbidden").isRetryable)
    }

    func testTopicNotFoundIsNotRetryable() {
        XCTAssertFalse(StreamlineError.topicNotFound("events").isRetryable)
    }

    func testPartitionNotFoundIsNotRetryable() {
        XCTAssertFalse(StreamlineError.partitionNotFound("events:0").isRetryable)
    }

    func testSerializationIsNotRetryable() {
        XCTAssertFalse(StreamlineError.serializationError("bad").isRetryable)
    }

    func testProtocolIsNotRetryable() {
        XCTAssertFalse(StreamlineError.protocolError("frame").isRetryable)
    }

    func testConfigurationIsNotRetryable() {
        XCTAssertFalse(StreamlineError.configurationError("bad").isRetryable)
    }

    func testInternalIsNotRetryable() {
        XCTAssertFalse(StreamlineError.internalError("bug").isRetryable)
    }

    func testOfflineQueueFullIsNotRetryable() {
        XCTAssertFalse(StreamlineError.offlineQueueFull.isRetryable)
    }

    func testAdminOperationIsNotRetryable() {
        XCTAssertFalse(StreamlineError.adminOperationFailed("fail").isRetryable)
    }

    func testSchemaRegistryIsNotRetryable() {
        XCTAssertFalse(StreamlineError.schemaRegistryError("not found").isRetryable)
    }
}

// MARK: - Error Hint Tests

final class ErrorHintTests: XCTestCase {
    func testNotConnectedHint() {
        let hint = StreamlineError.notConnected.hint
        XCTAssertTrue(hint.contains("connect()"))
    }

    func testConnectionFailedHint() {
        let hint = StreamlineError.connectionFailed("refused").hint
        XCTAssertTrue(hint.contains("refused"))
        XCTAssertTrue(hint.contains("server URL"))
    }

    func testAuthenticationFailedHint() {
        let hint = StreamlineError.authenticationFailed("bad token").hint
        XCTAssertTrue(hint.contains("authToken"))
    }

    func testAuthorizationFailedHint() {
        let hint = StreamlineError.authorizationFailed("no access").hint
        XCTAssertTrue(hint.contains("ACLs"))
    }

    func testTimeoutHint() {
        let hint = StreamlineError.timeout.hint
        XCTAssertTrue(hint.contains("timed out"))
    }

    func testTopicNotFoundHint() {
        let hint = StreamlineError.topicNotFound("orders").hint
        XCTAssertTrue(hint.contains("orders"))
        XCTAssertTrue(hint.contains("Create"))
    }

    func testPartitionNotFoundHint() {
        let hint = StreamlineError.partitionNotFound("events:99").hint
        XCTAssertTrue(hint.contains("events:99"))
    }

    func testSerializationHint() {
        let hint = StreamlineError.serializationError("bad json").hint
        XCTAssertTrue(hint.contains("serialized"))
    }

    func testProtocolErrorHint() {
        let hint = StreamlineError.protocolError("bad frame").hint
        XCTAssertTrue(hint.contains("protocol"))
    }

    func testConfigurationErrorHint() {
        let hint = StreamlineError.configurationError("bad url").hint
        XCTAssertTrue(hint.contains("bad url"))
    }

    func testCircuitOpenHint() {
        let hint = StreamlineError.circuitOpen.hint
        XCTAssertTrue(hint.contains("Circuit breaker"))
    }

    func testInternalErrorHint() {
        let hint = StreamlineError.internalError("unexpected").hint
        XCTAssertTrue(hint.contains("unexpected"))
    }

    func testOfflineQueueFullHint() {
        let hint = StreamlineError.offlineQueueFull.hint
        XCTAssertTrue(hint.contains("1000"))
    }

    func testEveryErrorHasNonEmptyHint() {
        let errors: [StreamlineError] = [
            .notConnected,
            .connectionFailed("x"),
            .authenticationFailed("x"),
            .authorizationFailed("x"),
            .timeout,
            .topicNotFound("x"),
            .partitionNotFound("x"),
            .serializationError("x"),
            .protocolError("x"),
            .configurationError("x"),
            .offlineQueueFull,
            .adminOperationFailed("x"),
            .queryFailed("x"),
            .schemaRegistryError("x"),
            .circuitOpen,
            .internalError("x"),
            .unsupported("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.hint.isEmpty, "\(error) has empty hint")
        }
    }
}

// MARK: - New Error Cases

final class NewErrorCaseTests: XCTestCase {
    func testPartitionNotFoundEquality() {
        XCTAssertEqual(StreamlineError.partitionNotFound("x"), StreamlineError.partitionNotFound("x"))
        XCTAssertNotEqual(StreamlineError.partitionNotFound("x"), StreamlineError.partitionNotFound("y"))
    }

    func testAuthorizationFailedEquality() {
        XCTAssertEqual(StreamlineError.authorizationFailed("a"), StreamlineError.authorizationFailed("a"))
        XCTAssertNotEqual(StreamlineError.authorizationFailed("a"), StreamlineError.authorizationFailed("b"))
    }

    func testProtocolErrorEquality() {
        XCTAssertEqual(StreamlineError.protocolError("p"), StreamlineError.protocolError("p"))
    }

    func testConfigurationErrorEquality() {
        XCTAssertEqual(StreamlineError.configurationError("c"), StreamlineError.configurationError("c"))
    }

    func testCircuitOpenEquality() {
        XCTAssertEqual(StreamlineError.circuitOpen, StreamlineError.circuitOpen)
    }

    func testInternalErrorEquality() {
        XCTAssertEqual(StreamlineError.internalError("e"), StreamlineError.internalError("e"))
    }

    func testNewErrorsConformToErrorProtocol() {
        let errors: [Error] = [
            StreamlineError.authorizationFailed("x"),
            StreamlineError.partitionNotFound("x"),
            StreamlineError.protocolError("x"),
            StreamlineError.configurationError("x"),
            StreamlineError.circuitOpen,
            StreamlineError.internalError("x"),
        ]
        XCTAssertEqual(errors.count, 6)
    }
}

// MARK: - Consumer Offset Management Tests

final class OffsetManagementTests: XCTestCase {
    private func makeClient() -> StreamlineClient {
        let config = StreamlineConfiguration(
            url: requiredTestValue(URL(string: "ws://localhost:9092"))
        )
        return StreamlineClient(configuration: config)
    }

    func testCommitOffsetsFailsClosedAsUnsupported() async {
        let client = makeClient()
        do {
            try await client.commitOffsets(["events:0": 42])
            XCTFail("Expected unsupported error")
        } catch let error as StreamlineError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeekToOffsetThrowsWhenDisconnected() async {
        let client = makeClient()
        do {
            try await client.seekToOffset(topic: "events", partition: 0, offset: 100)
            XCTFail("Expected notConnected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeekToBeginningThrowsWhenDisconnected() async {
        let client = makeClient()
        do {
            try await client.seekToBeginning(topic: "events")
            XCTFail("Expected notConnected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeekToEndThrowsWhenDisconnected() async {
        let client = makeClient()
        do {
            try await client.seekToEnd(topic: "events")
            XCTFail("Expected notConnected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPositionFailsClosedAsUnsupported() async {
        let client = makeClient()
        do {
            _ = try await client.queryPosition(topic: "events", partition: 0)
            XCTFail("Expected unsupported error")
        } catch let error as StreamlineError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommittedFailsClosedAsUnsupported() async {
        let client = makeClient()
        do {
            _ = try await client.queryCommitted(topic: "events", partition: 0)
            XCTFail("Expected unsupported error")
        } catch let error as StreamlineError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - CircuitBreaker Tests

final class CircuitBreakerTests: XCTestCase {
    // MARK: - Configuration

    func testDefaultConfig() {
        let config = CircuitBreakerConfig()
        XCTAssertEqual(config.failureThreshold, 5)
        XCTAssertEqual(config.successThreshold, 2)
        XCTAssertEqual(config.openTimeout, 30)
        XCTAssertEqual(config.halfOpenMaxRequests, 3)
    }

    func testCustomConfig() {
        let config = CircuitBreakerConfig(
            failureThreshold: 3,
            successThreshold: 1,
            openTimeout: 10,
            halfOpenMaxRequests: 5
        )
        XCTAssertEqual(config.failureThreshold, 3)
        XCTAssertEqual(config.successThreshold, 1)
        XCTAssertEqual(config.openTimeout, 10)
        XCTAssertEqual(config.halfOpenMaxRequests, 5)
    }

    func testConfigEquality() {
        XCTAssertEqual(CircuitBreakerConfig(), CircuitBreakerConfig())
        XCTAssertNotEqual(
            CircuitBreakerConfig(failureThreshold: 3),
            CircuitBreakerConfig(failureThreshold: 5)
        )
    }

    // MARK: - Initial State

    func testInitialStateIsClosed() {
        let cb = CircuitBreaker()
        XCTAssertEqual(cb.state(), .closed)
    }

    func testInitialCountsAreZero() {
        let cb = CircuitBreaker()
        let c = cb.counts()
        XCTAssertEqual(c.requests, 0)
        XCTAssertEqual(c.consecutiveSuccesses, 0)
        XCTAssertEqual(c.consecutiveFailures, 0)
        XCTAssertEqual(c.totalSuccesses, 0)
        XCTAssertEqual(c.totalFailures, 0)
    }

    // MARK: - Closed State

    func testCheckSucceedsWhenClosed() {
        let cb = CircuitBreaker()
        XCTAssertNoThrow(try cb.check())
    }

    func testCheckIncrementsRequestCount() throws {
        let cb = CircuitBreaker()
        try cb.check()
        try cb.check()
        XCTAssertEqual(cb.counts().requests, 2)
    }

    func testRecordSuccessIncrementsCounts() throws {
        let cb = CircuitBreaker()
        try cb.check()
        cb.recordSuccess()
        let c = cb.counts()
        XCTAssertEqual(c.consecutiveSuccesses, 1)
        XCTAssertEqual(c.totalSuccesses, 1)
        XCTAssertEqual(c.consecutiveFailures, 0)
    }

    func testRecordFailureIncrementsCounts() throws {
        let cb = CircuitBreaker()
        try cb.check()
        cb.recordFailure()
        let c = cb.counts()
        XCTAssertEqual(c.consecutiveFailures, 1)
        XCTAssertEqual(c.totalFailures, 1)
        XCTAssertEqual(c.consecutiveSuccesses, 0)
    }

    func testSuccessResetsConsecutiveFailures() {
        let cb = CircuitBreaker()
        cb.recordFailure()
        cb.recordFailure()
        cb.recordSuccess()
        XCTAssertEqual(cb.counts().consecutiveFailures, 0)
        XCTAssertEqual(cb.counts().consecutiveSuccesses, 1)
    }

    func testFailureResetsConsecutiveSuccesses() {
        let cb = CircuitBreaker()
        cb.recordSuccess()
        cb.recordSuccess()
        cb.recordFailure()
        XCTAssertEqual(cb.counts().consecutiveSuccesses, 0)
        XCTAssertEqual(cb.counts().consecutiveFailures, 1)
    }

    // MARK: - Transition to Open

    func testOpensAfterFailureThreshold() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(failureThreshold: 3))
        cb.recordFailure()
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .closed)
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)
    }

    func testCheckThrowsWhenOpen() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(failureThreshold: 2))
        cb.recordFailure()
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)

        do {
            try cb.check()
            XCTFail("Expected circuitOpen error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .circuitOpen)
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(error.errorCode, .circuitOpen)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Transition to Half-Open

    func testTransitionsToHalfOpenAfterTimeout() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            openTimeout: 0.01
        ))
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)

        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(cb.state(), .halfOpen)
    }

    func testHalfOpenAllowsLimitedRequests() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            openTimeout: 0.01,
            halfOpenMaxRequests: 2
        ))
        cb.recordFailure()
        Thread.sleep(forTimeInterval: 0.02)

        XCTAssertNoThrow(try cb.check())
        XCTAssertNoThrow(try cb.check())

        do {
            try cb.check()
            XCTFail("Expected circuitOpen error for exceeding halfOpenMaxRequests")
        } catch {
            XCTAssertEqual(error as? StreamlineError, .circuitOpen)
        }
    }

    // MARK: - Half-Open → Closed

    func testHalfOpenClosesAfterSuccessThreshold() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            successThreshold: 2,
            openTimeout: 0.01
        ))
        cb.recordFailure()
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(cb.state(), .halfOpen)

        cb.recordSuccess()
        XCTAssertEqual(cb.state(), .halfOpen)
        cb.recordSuccess()
        XCTAssertEqual(cb.state(), .closed)
    }

    // MARK: - Half-Open → Open

    func testHalfOpenReopensOnFailure() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            openTimeout: 0.01
        ))
        cb.recordFailure()
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(cb.state(), .halfOpen)

        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)
    }

    // MARK: - Reset

    func testResetReturnsToClosed() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(failureThreshold: 1))
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)

        cb.reset()
        XCTAssertEqual(cb.state(), .closed)
        XCTAssertNoThrow(try cb.check())
    }

    func testResetZeroesCounters() {
        let cb = CircuitBreaker()
        cb.recordFailure()
        cb.recordFailure()
        cb.recordSuccess()
        cb.reset()

        let c = cb.counts()
        XCTAssertEqual(c.requests, 0)
        XCTAssertEqual(c.consecutiveSuccesses, 0)
        XCTAssertEqual(c.consecutiveFailures, 0)
        XCTAssertEqual(c.totalSuccesses, 0)
        XCTAssertEqual(c.totalFailures, 0)
    }

    // MARK: - CircuitBreakerState

    func testStateRawValues() {
        XCTAssertEqual(CircuitBreakerState.closed.rawValue, "closed")
        XCTAssertEqual(CircuitBreakerState.open.rawValue, "open")
        XCTAssertEqual(CircuitBreakerState.halfOpen.rawValue, "halfOpen")
    }

    func testStateEquality() {
        XCTAssertEqual(CircuitBreakerState.closed, CircuitBreakerState.closed)
        XCTAssertNotEqual(CircuitBreakerState.closed, CircuitBreakerState.open)
    }

    // MARK: - CircuitBreakerCounts

    func testCountsEquality() {
        let a = CircuitBreakerCounts(requests: 1, consecutiveSuccesses: 0, consecutiveFailures: 1, totalSuccesses: 0, totalFailures: 1)
        let b = CircuitBreakerCounts(requests: 1, consecutiveSuccesses: 0, consecutiveFailures: 1, totalSuccesses: 0, totalFailures: 1)
        XCTAssertEqual(a, b)
    }

    // MARK: - Thread Safety

    func testConcurrentAccess() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(failureThreshold: 100))
        let group = DispatchGroup()

        for _ in 0 ..< 100 {
            group.enter()
            DispatchQueue.global().async {
                try? cb.check()
                if Bool.random() {
                    cb.recordSuccess()
                } else {
                    cb.recordFailure()
                }
                _ = cb.state()
                _ = cb.counts()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success)
        // Just verifying no crashes — thread safety via NSLock.
    }

    // MARK: - Full Lifecycle

    func testFullLifecycle() {
        let cb = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 2,
            successThreshold: 1,
            openTimeout: 0.01,
            halfOpenMaxRequests: 1
        ))

        // Closed: requests pass
        XCTAssertEqual(cb.state(), .closed)
        XCTAssertNoThrow(try cb.check())
        cb.recordSuccess()

        // Trip the breaker
        cb.recordFailure()
        cb.recordFailure()
        XCTAssertEqual(cb.state(), .open)

        // Open: requests rejected
        XCTAssertThrowsError(try cb.check())

        // Wait for half-open
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(cb.state(), .halfOpen)

        // Half-open: probe succeeds → closes
        XCTAssertNoThrow(try cb.check())
        cb.recordSuccess()
        XCTAssertEqual(cb.state(), .closed)
    }
}
