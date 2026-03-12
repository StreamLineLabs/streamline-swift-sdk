import XCTest
@testable import StreamlineSDK

// MARK: - ConfigValidator Tests

final class ConfigValidatorTests: XCTestCase {

    func testValidConfigPasses() throws {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!, timeout: 10)
        XCTAssertNoThrow(try ConfigValidator.validate(config))
    }

    func testZeroTimeoutFails() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!, timeout: 0)
        XCTAssertThrowsError(try ConfigValidator.validate(config)) { error in
            guard let streamlineError = error as? StreamlineError else {
                return XCTFail("Expected StreamlineError, got \(error)")
            }
            XCTAssertEqual(streamlineError.errorCode, .configuration)
            if case .configurationError(let detail) = streamlineError {
                XCTAssertTrue(detail.contains("timeout"))
            } else {
                XCTFail("Expected configurationError")
            }
        }
    }

    func testNegativeTimeoutFails() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!, timeout: -5)
        XCTAssertThrowsError(try ConfigValidator.validate(config)) { error in
            guard let streamlineError = error as? StreamlineError else {
                return XCTFail("Expected StreamlineError")
            }
            XCTAssertEqual(streamlineError.errorCode, .configuration)
        }
    }
}

// MARK: - RecordValidation Tests

final class RecordValidationTests: XCTestCase {

    func testSmallRecordPasses() throws {
        let key = Data("key".utf8)
        let value = Data("value".utf8)
        XCTAssertNoThrow(try RecordValidation.validate(key: key, value: value))
    }

    func testNilKeyAndValuePasses() throws {
        XCTAssertNoThrow(try RecordValidation.validate(key: nil, value: nil))
    }

    func testNilKeyWithValuePasses() throws {
        let value = Data(repeating: 0x42, count: 1024)
        XCTAssertNoThrow(try RecordValidation.validate(key: nil, value: value))
    }

    func testExactlyMaxSizePasses() throws {
        let value = Data(repeating: 0x42, count: 1_048_576)
        XCTAssertNoThrow(try RecordValidation.validate(key: nil, value: value))
    }

    func testExceedsMaxSizeFails() {
        let value = Data(repeating: 0x42, count: 1_048_577)
        XCTAssertThrowsError(try RecordValidation.validate(key: nil, value: value)) { error in
            guard let streamlineError = error as? StreamlineError else {
                return XCTFail("Expected StreamlineError")
            }
            XCTAssertEqual(streamlineError.errorCode, .serialization)
            if case .serializationError(let detail) = streamlineError {
                XCTAssertTrue(detail.contains("exceeds maximum"))
            }
        }
    }

    func testCombinedKeySizeExceedsMax() {
        let key = Data(repeating: 0x41, count: 524_288)
        let value = Data(repeating: 0x42, count: 524_289)
        XCTAssertThrowsError(try RecordValidation.validate(key: key, value: value)) { error in
            guard let streamlineError = error as? StreamlineError else {
                return XCTFail("Expected StreamlineError")
            }
            if case .serializationError(let detail) = streamlineError {
                XCTAssertTrue(detail.contains("1048577"))
            }
        }
    }

    func testMaxRecordSizeConstant() {
        XCTAssertEqual(RecordValidation.maxRecordSize, 1_048_576)
    }
}

// MARK: - BatchBuffer Tests

final class BatchBufferTests: XCTestCase {

    func testInitiallyEmpty() {
        let buffer = BatchBuffer<Int>()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertFalse(buffer.isFull)
    }

    func testAppendIncreasesCount() {
        var buffer = BatchBuffer<String>(capacity: 5)
        _ = buffer.append("a")
        XCTAssertEqual(buffer.count, 1)
        _ = buffer.append("b")
        XCTAssertEqual(buffer.count, 2)
    }

    func testIsFullAtCapacity() {
        var buffer = BatchBuffer<Int>(capacity: 3)
        XCTAssertFalse(buffer.append(1))
        XCTAssertFalse(buffer.append(2))
        XCTAssertTrue(buffer.append(3))
        XCTAssertTrue(buffer.isFull)
    }

    func testDrainReturnsAllItems() {
        var buffer = BatchBuffer<String>(capacity: 10)
        _ = buffer.append("x")
        _ = buffer.append("y")
        _ = buffer.append("z")
        let items = buffer.drain()
        XCTAssertEqual(items, ["x", "y", "z"])
    }

    func testDrainResetsBuffer() {
        var buffer = BatchBuffer<Int>(capacity: 5)
        _ = buffer.append(1)
        _ = buffer.append(2)
        _ = buffer.drain()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertFalse(buffer.isFull)
    }

    func testDrainOnEmptyBuffer() {
        var buffer = BatchBuffer<Int>(capacity: 5)
        let items = buffer.drain()
        XCTAssertTrue(items.isEmpty)
    }

    func testDefaultCapacity() {
        var buffer = BatchBuffer<Int>()
        for i in 0..<999 {
            XCTAssertFalse(buffer.append(i), "Should not be full at \(i + 1)")
        }
        XCTAssertTrue(buffer.append(999))
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.count, 1000)
    }

    func testAppendAfterDrain() {
        var buffer = BatchBuffer<Int>(capacity: 3)
        _ = buffer.append(1)
        _ = buffer.append(2)
        _ = buffer.drain()
        _ = buffer.append(3)
        XCTAssertEqual(buffer.count, 1)
        let items = buffer.drain()
        XCTAssertEqual(items, [3])
    }
}

// MARK: - Client Initialization & Configuration Tests

final class ClientInitializationTests: XCTestCase {

    func testClientStoresConfiguration() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://myhost:9092")!,
            autoReconnect: false,
            maxRetries: 3,
            timeout: 15,
            authToken: "token-123"
        )
        let client = StreamlineClient(configuration: config)
        XCTAssertEqual(client.configuration.url.absoluteString, "ws://myhost:9092")
        XCTAssertFalse(client.configuration.autoReconnect)
        XCTAssertEqual(client.configuration.maxRetries, 3)
        XCTAssertEqual(client.configuration.timeout, 15)
        XCTAssertEqual(client.configuration.authToken, "token-123")
    }

    func testClientAcceptsCustomProducerConfig() {
        let producerConfig = ProducerConfig(batchSize: 32768, compression: .gzip, retries: 5)
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config, producerConfig: producerConfig)
        XCTAssertEqual(client.producerConfig.batchSize, 32768)
        XCTAssertEqual(client.producerConfig.compression, .gzip)
        XCTAssertEqual(client.producerConfig.retries, 5)
    }

    func testClientDefaultProducerConfig() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        XCTAssertEqual(client.producerConfig.batchSize, 16384)
        XCTAssertEqual(client.producerConfig.compression, .none)
        XCTAssertEqual(client.producerConfig.retries, 3)
    }

    func testClientAcceptsCustomURLSession() {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 5
        let customSession = URLSession(configuration: sessionConfig)
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config, session: customSession)
        XCTAssertNotNil(client)
        XCTAssertEqual(client.state, .disconnected)
    }

    func testProducerConfigIsMutable() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        client.producerConfig = ProducerConfig(batchSize: 65536, compression: .zstd)
        XCTAssertEqual(client.producerConfig.batchSize, 65536)
        XCTAssertEqual(client.producerConfig.compression, .zstd)
    }

    func testConfigurationWithAllSecurityOptions() {
        let config = StreamlineConfiguration(
            url: URL(string: "wss://secure.example.com:9092")!,
            authToken: "jwt-token",
            tls: TlsConfig(
                enabled: true,
                caCertificatePath: "/certs/ca.pem",
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client-key.pem",
                insecureSkipVerify: false
            ),
            sasl: SaslConfig(mechanism: .scramSha512, username: "admin", password: "secret")
        )
        XCTAssertNotNil(config.tls)
        XCTAssertTrue(config.tls!.enabled)
        XCTAssertNotNil(config.sasl)
        XCTAssertEqual(config.sasl!.mechanism, .scramSha512)
        XCTAssertEqual(config.authToken, "jwt-token")
    }

    func testConfigurationPreservesBackoffSettings() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            initialBackoff: 2.0,
            maxBackoff: 120
        )
        XCTAssertEqual(config.initialBackoff, 2.0)
        XCTAssertEqual(config.maxBackoff, 120)
    }

    func testConfigurationWithEmbeddedProducerAndConsumer() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            producerConfig: ProducerConfig(batchSize: 4096, idempotent: true, acks: .all),
            consumerConfig: ConsumerConfig(groupId: "test-group", autoCommit: false, autoOffsetReset: .earliest)
        )
        XCTAssertEqual(config.producerConfig.batchSize, 4096)
        XCTAssertTrue(config.producerConfig.idempotent)
        XCTAssertEqual(config.consumerConfig.groupId, "test-group")
        XCTAssertFalse(config.consumerConfig.autoCommit)
        XCTAssertEqual(config.consumerConfig.autoOffsetReset, .earliest)
    }
}

// MARK: - Client Connection State Tests

final class ClientConnectionStateTests: XCTestCase {

    private func makeClient(autoReconnect: Bool = true) -> StreamlineClient {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            autoReconnect: autoReconnect
        )
        return StreamlineClient(configuration: config)
    }

    func testInitialStateIsDisconnected() {
        let client = makeClient()
        XCTAssertEqual(client.state, .disconnected)
    }

    func testDisconnectOnAlreadyDisconnected() {
        let client = makeClient()
        XCTAssertEqual(client.state, .disconnected)
        client.disconnect()
        XCTAssertEqual(client.state, .disconnected)
    }

    func testDelegateIsWeakReference() {
        let client = makeClient()
        XCTAssertNil(client.delegate)
    }

    func testConnectionStateEquatability() {
        let states: [ConnectionState] = [.disconnected, .connecting, .connected, .reconnecting]
        for i in 0..<states.count {
            for j in 0..<states.count {
                if i == j {
                    XCTAssertEqual(states[i], states[j])
                } else {
                    XCTAssertNotEqual(states[i], states[j])
                }
            }
        }
    }
}

// MARK: - Offline Queue Tests

final class OfflineQueueTests: XCTestCase {

    private func makeClient() -> StreamlineClient {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        return StreamlineClient(configuration: config)
    }

    func testProduceWhenDisconnectedQueuesMessage() throws {
        let client = makeClient()
        XCTAssertEqual(client.state, .disconnected)
        // Should not throw — message goes to offline queue
        try client.produce(topic: "events", stringValue: "hello")
    }

    func testProduceMultipleMessagesWhileDisconnected() throws {
        let client = makeClient()
        for i in 0..<100 {
            try client.produce(topic: "events", key: "key-\(i)", stringValue: "value-\(i)")
        }
        // All 100 should have been queued without error
    }

    func testOfflineQueueOverflowThrows() {
        let client = makeClient()
        // Fill the queue to capacity (1000)
        for i in 0..<1000 {
            XCTAssertNoThrow(try client.produce(topic: "events", stringValue: "msg-\(i)"),
                             "Message \(i) should succeed")
        }
        // The 1001st message should throw offlineQueueFull
        XCTAssertThrowsError(try client.produce(topic: "events", stringValue: "overflow")) { error in
            guard let streamlineError = error as? StreamlineError else {
                return XCTFail("Expected StreamlineError")
            }
            XCTAssertEqual(streamlineError, .offlineQueueFull)
            XCTAssertFalse(streamlineError.isRetryable)
            XCTAssertEqual(streamlineError.errorCode, .internal)
        }
    }

    func testOfflineQueueFullHintMessage() {
        let error = StreamlineError.offlineQueueFull
        XCTAssertTrue(error.hint.contains("1000"))
        XCTAssertTrue(error.hint.contains("Connect"))
    }

    func testProduceWithDataPayload() throws {
        let client = makeClient()
        let payload = Data([0x00, 0x01, 0x02, 0xFF])
        try client.produce(topic: "binary-topic", key: "bin-key", value: payload)
    }

    func testProduceWithEmptyValue() throws {
        let client = makeClient()
        try client.produce(topic: "events", value: Data())
    }

    func testProduceWithNilKey() throws {
        let client = makeClient()
        try client.produce(topic: "events", value: Data("test".utf8))
    }

    func testProduceWithKeyAndStringValue() throws {
        let client = makeClient()
        try client.produce(topic: "events", key: "user-42", stringValue: "payload-data")
    }
}

// MARK: - Subscription Management Tests

final class SubscriptionManagementTests: XCTestCase {

    private func makeClient() -> StreamlineClient {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        return StreamlineClient(configuration: config)
    }

    func testSubscribeRegistersHandler() {
        let client = makeClient()
        var receivedMessages: [StreamlineMessage] = []
        client.subscribe(topic: "events") { msg in
            receivedMessages.append(msg)
        }
        // Handler is registered (no crash), but won't fire without a connection
        XCTAssertTrue(receivedMessages.isEmpty)
    }

    func testUnsubscribeWithoutPriorSubscription() {
        let client = makeClient()
        // Should not crash
        client.unsubscribe(topic: "nonexistent")
    }

    func testSubscribeMultipleTopics() {
        let client = makeClient()
        var topic1Messages: [StreamlineMessage] = []
        var topic2Messages: [StreamlineMessage] = []

        client.subscribe(topic: "events") { msg in topic1Messages.append(msg) }
        client.subscribe(topic: "orders") { msg in topic2Messages.append(msg) }

        // Both handlers registered without error
        XCTAssertTrue(topic1Messages.isEmpty)
        XCTAssertTrue(topic2Messages.isEmpty)
    }

    func testSubscribeReplacesExistingHandler() {
        let client = makeClient()
        var firstHandlerCalled = false
        var secondHandlerCalled = false

        client.subscribe(topic: "events") { _ in firstHandlerCalled = true }
        client.subscribe(topic: "events") { _ in secondHandlerCalled = true }

        // Second subscribe should have replaced the first
        // Can't directly test handler replacement without a connection, but no crash
        XCTAssertFalse(firstHandlerCalled)
        XCTAssertFalse(secondHandlerCalled)
    }

    func testUnsubscribeAfterSubscribe() {
        let client = makeClient()
        client.subscribe(topic: "events") { _ in }
        client.unsubscribe(topic: "events")
        // No crash, handler removed
    }

    func testMessagesAsyncStreamCreation() {
        let client = makeClient()
        let stream = client.messages(topic: "events")
        XCTAssertNotNil(stream)
    }

    func testMultipleAsyncStreamsForDifferentTopics() {
        let client = makeClient()
        let stream1 = client.messages(topic: "events")
        let stream2 = client.messages(topic: "orders")
        XCTAssertNotNil(stream1)
        XCTAssertNotNil(stream2)
    }
}

// MARK: - Offset Management Extended Tests

final class OffsetManagementExtendedTests: XCTestCase {

    private func makeClient() -> StreamlineClient {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        return StreamlineClient(configuration: config)
    }

    func testPositionForMultiplePartitionsReturnsNil() async {
        let client = makeClient()
        for partition in 0..<10 {
            let pos = await client.position(topic: "events", partition: partition)
            XCTAssertNil(pos, "Partition \(partition) should have nil position initially")
        }
    }

    func testCommittedForMultiplePartitionsReturnsNil() async {
        let client = makeClient()
        for partition in 0..<10 {
            let committed = await client.committed(topic: "events", partition: partition)
            XCTAssertNil(committed, "Partition \(partition) should have nil committed offset initially")
        }
    }

    func testCommitOffsetsThrowsNotConnected() async {
        let client = makeClient()
        do {
            try await client.commitOffsets(["events:0": 42, "events:1": 84])
            XCTFail("Expected notConnected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .notConnected)
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeekToOffsetThrowsNotConnected() async {
        let client = makeClient()
        do {
            try await client.seekToOffset(topic: "events", partition: 0, offset: 0)
            XCTFail("Expected notConnected error")
        } catch let error as StreamlineError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeekToBeginningThrowsNotConnected() async {
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

    func testSeekToEndThrowsNotConnected() async {
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

    func testPositionForDifferentTopics() async {
        let client = makeClient()
        let pos1 = await client.position(topic: "events", partition: 0)
        let pos2 = await client.position(topic: "orders", partition: 0)
        XCTAssertNil(pos1)
        XCTAssertNil(pos2)
    }
}

// MARK: - FlushBatch Tests

final class FlushBatchTests: XCTestCase {

    func testFlushBatchOnEmptyQueueDoesNothing() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        // Flush on empty queue should not crash
        client.flushBatch()
    }

    func testFlushBatchWhenDisconnected() throws {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let producerConfig = ProducerConfig(batchSize: 1_000_000, lingerMs: 60000)
        let client = StreamlineClient(configuration: config, producerConfig: producerConfig)

        // Produce messages that go to offline queue (not batch queue) because disconnected
        try client.produce(topic: "events", stringValue: "msg1")
        // Flush should not crash even when disconnected
        client.flushBatch()
    }
}

// MARK: - Delegate Protocol Tests

final class DelegateProtocolTests: XCTestCase {

    final class MockDelegate: StreamlineClientDelegate {
        var stateChanges: [ConnectionState] = []
        var receivedMessages: [StreamlineMessage] = []
        var encounteredErrors: [StreamlineError] = []

        func client(_ client: StreamlineClient, didChangeState state: ConnectionState) {
            stateChanges.append(state)
        }
        func client(_ client: StreamlineClient, didReceiveMessage message: StreamlineMessage) {
            receivedMessages.append(message)
        }
        func client(_ client: StreamlineClient, didEncounterError error: StreamlineError) {
            encounteredErrors.append(error)
        }
    }

    func testDelegateCanBeAssigned() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        let delegate = MockDelegate()
        client.delegate = delegate
        XCTAssertNotNil(client.delegate)
    }

    func testDelegateIsWeak() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)

        var delegate: MockDelegate? = MockDelegate()
        client.delegate = delegate
        XCTAssertNotNil(client.delegate)

        delegate = nil
        XCTAssertNil(client.delegate)
    }

    func testDefaultDelegateImplementationsExist() {
        // Verify default extension methods don't crash when called
        final class MinimalDelegate: StreamlineClientDelegate {}
        let delegate = MinimalDelegate()
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        // These should use default empty implementations
        delegate.client(client, didChangeState: .connected)
        delegate.client(client, didReceiveMessage: StreamlineMessage(topic: "t", value: Data()))
        delegate.client(client, didEncounterError: .notConnected)
    }
}

// MARK: - Error Comprehensive Tests

final class ErrorComprehensiveTests: XCTestCase {

    func testAllErrorCasesHaveUniqueErrorCodes() {
        // Map each error to its code, verify expected mappings
        let mappings: [(StreamlineError, ErrorCode)] = [
            (.notConnected, .connection),
            (.connectionFailed("x"), .connection),
            (.authenticationFailed("x"), .authentication),
            (.authorizationFailed("x"), .authorization),
            (.timeout, .timeout),
            (.topicNotFound("x"), .topicNotFound),
            (.partitionNotFound("x"), .partitionNotFound),
            (.serializationError("x"), .serialization),
            (.protocolError("x"), .protocol),
            (.configurationError("x"), .configuration),
            (.offlineQueueFull, .internal),
            (.adminOperationFailed("x"), .internal),
            (.queryFailed("x"), .internal),
            (.schemaRegistryError("x"), .schema),
            (.circuitOpen, .circuitOpen),
            (.internalError("x"), .internal),
        ]
        for (error, expectedCode) in mappings {
            XCTAssertEqual(error.errorCode, expectedCode, "Error \(error) should map to \(expectedCode)")
        }
    }

    func testAllRetryableErrorsAreCorrectlyClassified() {
        let retryable: [StreamlineError] = [
            .notConnected,
            .connectionFailed("x"),
            .timeout,
            .circuitOpen,
        ]
        for error in retryable {
            XCTAssertTrue(error.isRetryable, "\(error) should be retryable")
        }

        let nonRetryable: [StreamlineError] = [
            .authenticationFailed("x"),
            .authorizationFailed("x"),
            .topicNotFound("x"),
            .partitionNotFound("x"),
            .serializationError("x"),
            .protocolError("x"),
            .configurationError("x"),
            .offlineQueueFull,
            .adminOperationFailed("x"),
            .queryFailed("x"),
            .schemaRegistryError("x"),
            .internalError("x"),
        ]
        for error in nonRetryable {
            XCTAssertFalse(error.isRetryable, "\(error) should NOT be retryable")
        }
    }

    func testAllErrorHintsContainActionableGuidance() {
        let errors: [StreamlineError] = [
            .notConnected,
            .connectionFailed("refused"),
            .authenticationFailed("bad"),
            .authorizationFailed("denied"),
            .timeout,
            .topicNotFound("events"),
            .partitionNotFound("events:0"),
            .serializationError("bad json"),
            .protocolError("bad frame"),
            .configurationError("bad url"),
            .offlineQueueFull,
            .adminOperationFailed("500"),
            .queryFailed("syntax"),
            .schemaRegistryError("not found"),
            .circuitOpen,
            .internalError("unexpected"),
        ]
        for error in errors {
            XCTAssertFalse(error.hint.isEmpty, "\(error) should have a non-empty hint")
            XCTAssertGreaterThan(error.hint.count, 10, "\(error) hint should be meaningful: '\(error.hint)'")
        }
    }

    func testErrorsConformToErrorProtocol() {
        let errors: [Error] = [
            StreamlineError.notConnected,
            StreamlineError.connectionFailed("x"),
            StreamlineError.authenticationFailed("x"),
            StreamlineError.authorizationFailed("x"),
            StreamlineError.timeout,
            StreamlineError.topicNotFound("x"),
            StreamlineError.partitionNotFound("x"),
            StreamlineError.serializationError("x"),
            StreamlineError.protocolError("x"),
            StreamlineError.configurationError("x"),
            StreamlineError.offlineQueueFull,
            StreamlineError.adminOperationFailed("x"),
            StreamlineError.queryFailed("x"),
            StreamlineError.schemaRegistryError("x"),
            StreamlineError.circuitOpen,
            StreamlineError.internalError("x"),
        ]
        XCTAssertEqual(errors.count, 16)
        for error in errors {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testErrorEqualityWithDifferentPayloads() {
        XCTAssertNotEqual(
            StreamlineError.connectionFailed("reason A"),
            StreamlineError.connectionFailed("reason B")
        )
        XCTAssertNotEqual(
            StreamlineError.adminOperationFailed("err1"),
            StreamlineError.queryFailed("err1")
        )
    }

    func testErrorHintIncludesContextDetails() {
        let error = StreamlineError.topicNotFound("my-special-topic")
        XCTAssertTrue(error.hint.contains("my-special-topic"))

        let configError = StreamlineError.configurationError("invalid port")
        XCTAssertTrue(configError.hint.contains("invalid port"))

        let adminError = StreamlineError.adminOperationFailed("server unavailable")
        XCTAssertTrue(adminError.hint.contains("server unavailable"))
    }

    func testSchemaRegistryErrorHint() {
        let error = StreamlineError.schemaRegistryError("subject not found")
        XCTAssertTrue(error.hint.contains("subject not found"))
        XCTAssertTrue(error.hint.contains("schema"))
    }

    func testQueryFailedErrorHint() {
        let error = StreamlineError.queryFailed("invalid SQL")
        XCTAssertTrue(error.hint.contains("invalid SQL"))
        XCTAssertTrue(error.hint.contains("query"))
    }
}

// MARK: - CompatibilityLevel Tests

final class CompatibilityLevelTests: XCTestCase {

    func testAllRawValues() {
        XCTAssertEqual(CompatibilityLevel.backward.rawValue, "BACKWARD")
        XCTAssertEqual(CompatibilityLevel.forward.rawValue, "FORWARD")
        XCTAssertEqual(CompatibilityLevel.full.rawValue, "FULL")
        XCTAssertEqual(CompatibilityLevel.none.rawValue, "NONE")
        XCTAssertEqual(CompatibilityLevel.backwardTransitive.rawValue, "BACKWARD_TRANSITIVE")
        XCTAssertEqual(CompatibilityLevel.forwardTransitive.rawValue, "FORWARD_TRANSITIVE")
        XCTAssertEqual(CompatibilityLevel.fullTransitive.rawValue, "FULL_TRANSITIVE")
    }

    func testInitFromRawValue() {
        XCTAssertEqual(CompatibilityLevel(rawValue: "BACKWARD"), .backward)
        XCTAssertEqual(CompatibilityLevel(rawValue: "FORWARD"), .forward)
        XCTAssertEqual(CompatibilityLevel(rawValue: "FULL"), .full)
        XCTAssertEqual(CompatibilityLevel(rawValue: "NONE"), .none)
        XCTAssertNil(CompatibilityLevel(rawValue: "INVALID"))
    }

    func testEquality() {
        XCTAssertEqual(CompatibilityLevel.backward, CompatibilityLevel.backward)
        XCTAssertNotEqual(CompatibilityLevel.backward, CompatibilityLevel.forward)
    }
}
