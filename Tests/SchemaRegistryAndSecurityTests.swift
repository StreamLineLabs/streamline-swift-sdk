import XCTest
@testable import StreamlineSDK

final class SchemaRegistryTests: XCTestCase {

    // MARK: - SchemaInfo Model

    func testSchemaInfoCreation() {
        let info = SchemaInfo(
            subject: "orders-value",
            id: 1,
            version: 1,
            schemaType: "JSON",
            schema: #"{"type":"object"}"#
        )
        XCTAssertEqual(info.subject, "orders-value")
        XCTAssertEqual(info.id, 1)
        XCTAssertEqual(info.version, 1)
        XCTAssertEqual(info.schemaType, "JSON")
    }

    func testSchemaInfoEquality() {
        let a = SchemaInfo(subject: "s", id: 1, version: 1, schemaType: "JSON", schema: "{}")
        let b = SchemaInfo(subject: "s", id: 1, version: 1, schemaType: "JSON", schema: "{}")
        XCTAssertEqual(a, b)
    }

    func testSchemaInfoInequality() {
        let a = SchemaInfo(subject: "s1", id: 1, version: 1, schemaType: "JSON", schema: "{}")
        let b = SchemaInfo(subject: "s2", id: 2, version: 1, schemaType: "JSON", schema: "{}")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - SchemaFormat

    func testSchemaFormatRawValues() {
        XCTAssertEqual(SchemaFormat.avro.rawValue, "AVRO")
        XCTAssertEqual(SchemaFormat.protobuf.rawValue, "PROTOBUF")
        XCTAssertEqual(SchemaFormat.json.rawValue, "JSON")
    }

    func testSchemaFormatEquality() {
        XCTAssertEqual(SchemaFormat.avro, SchemaFormat.avro)
        XCTAssertNotEqual(SchemaFormat.avro, SchemaFormat.json)
    }

    // MARK: - SchemaRegistryClient Init

    func testClientCreation() {
        let client = SchemaRegistryClient(baseURL: URL(string: "http://localhost:9094")!)
        XCTAssertNotNil(client)
    }

    func testClientWithAuth() {
        let client = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            authToken: "my-token"
        )
        XCTAssertNotNil(client)
    }

    // MARK: - Error Cases

    func testSchemaRegistryError() {
        let error = StreamlineError.schemaRegistryError("Subject not found")
        if case .schemaRegistryError(let message) = error {
            XCTAssertTrue(message.contains("Subject"))
        } else {
            XCTFail("Expected schemaRegistryError")
        }
    }

    func testSchemaRegistryErrorEquality() {
        XCTAssertEqual(
            StreamlineError.schemaRegistryError("test"),
            StreamlineError.schemaRegistryError("test")
        )
        XCTAssertNotEqual(
            StreamlineError.schemaRegistryError("a"),
            StreamlineError.schemaRegistryError("b")
        )
    }
}

// MARK: - Security Tests

final class SecurityTests: XCTestCase {

    func testTlsConfigDefaults() {
        let config = TlsConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertNil(config.caCertificatePath)
        XCTAssertNil(config.clientCertificatePath)
        XCTAssertNil(config.clientKeyPath)
        XCTAssertFalse(config.insecureSkipVerify)
    }

    func testTlsConfigCustom() {
        let config = TlsConfig(
            enabled: true,
            caCertificatePath: "/etc/ssl/ca.pem",
            clientCertificatePath: "/etc/ssl/client.pem",
            clientKeyPath: "/etc/ssl/client-key.pem",
            insecureSkipVerify: false
        )
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.caCertificatePath, "/etc/ssl/ca.pem")
    }

    func testTlsConfigEquality() {
        let a = TlsConfig(enabled: true)
        let b = TlsConfig(enabled: true)
        XCTAssertEqual(a, b)
    }

    func testSaslMechanismRawValues() {
        XCTAssertEqual(SaslMechanism.plain.rawValue, "PLAIN")
        XCTAssertEqual(SaslMechanism.scramSha256.rawValue, "SCRAM-SHA-256")
        XCTAssertEqual(SaslMechanism.scramSha512.rawValue, "SCRAM-SHA-512")
    }

    func testSaslConfigCreation() {
        let config = SaslConfig(mechanism: .scramSha256, username: "admin", password: "secret")
        XCTAssertEqual(config.mechanism, .scramSha256)
        XCTAssertEqual(config.username, "admin")
        XCTAssertEqual(config.password, "secret")
    }

    func testSaslConfigDefaultMechanism() {
        let config = SaslConfig(username: "user", password: "pass")
        XCTAssertEqual(config.mechanism, .plain)
    }

    func testSaslConfigEquality() {
        let a = SaslConfig(username: "u", password: "p")
        let b = SaslConfig(username: "u", password: "p")
        XCTAssertEqual(a, b)
    }
}

// MARK: - Telemetry Tests

final class TelemetryTests: XCTestCase {

    func testNoOpTelemetryCreatesSpan() {
        let telemetry = NoOpTelemetry()
        let span = telemetry.startSpan(topic: "orders", operation: "produce")
        XCTAssertEqual(span.name, "orders produce")
        XCTAssertEqual(span.topic, "orders")
        XCTAssertEqual(span.operation, "produce")
    }

    func testConsoleTelemetryCreatesSpan() {
        let telemetry = ConsoleTelemetry()
        let span = telemetry.startSpan(topic: "events", operation: "consume")
        XCTAssertEqual(span.name, "events consume")
        telemetry.endSpan(span)
    }

    func testSpanElapsed() throws {
        let span = TelemetrySpan(name: "test", topic: "t", operation: "op")
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertGreaterThan(span.elapsed, 0)
    }

    func testTraceContextGenerate() {
        let traceparent = TraceContext.generateTraceparent()
        XCTAssertTrue(traceparent.hasPrefix("00-"))
        let parts = traceparent.split(separator: "-")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(String(parts[0]), "00")
        XCTAssertEqual(parts[1].count, 32)
        XCTAssertEqual(parts[2].count, 16)
        XCTAssertEqual(String(parts[3]), "01")
    }

    func testTraceContextParse() {
        let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        let result = TraceContext.parseTraceparent(traceparent)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.version, "00")
        XCTAssertEqual(result?.traceId, "0af7651916cd43dd8448eb211c80319c")
        XCTAssertEqual(result?.spanId, "b7ad6b7169203331")
        XCTAssertEqual(result?.traceFlags, "01")
    }

    func testTraceContextParseInvalid() {
        XCTAssertNil(TraceContext.parseTraceparent("invalid"))
        XCTAssertNil(TraceContext.parseTraceparent("01-abc-def-01"))
    }
}

// MARK: - ProducerConsumerConfig Tests

final class ProducerConsumerConfigTests: XCTestCase {

    func testProducerConfigDefaults() {
        let config = ProducerConfig()
        XCTAssertEqual(config.batchSize, 16384)
        XCTAssertEqual(config.lingerMs, 0)
        XCTAssertEqual(config.compression, .none)
        XCTAssertEqual(config.retries, 3)
        XCTAssertEqual(config.retryBackoffMs, 100)
        XCTAssertFalse(config.idempotent)
        XCTAssertEqual(config.acks, .one)
    }

    func testProducerConfigCustom() {
        let config = ProducerConfig(
            batchSize: 65536,
            lingerMs: 5,
            compression: .zstd,
            retries: 5,
            retryBackoffMs: 200,
            idempotent: true,
            acks: .all
        )
        XCTAssertEqual(config.batchSize, 65536)
        XCTAssertEqual(config.lingerMs, 5)
        XCTAssertEqual(config.compression, .zstd)
        XCTAssertEqual(config.retries, 5)
        XCTAssertTrue(config.idempotent)
        XCTAssertEqual(config.acks, .all)
    }

    func testProducerConfigEquality() {
        XCTAssertEqual(ProducerConfig(), ProducerConfig())
    }

    func testConsumerConfigDefaults() {
        let config = ConsumerConfig()
        XCTAssertNil(config.groupId)
        XCTAssertTrue(config.autoCommit)
        XCTAssertEqual(config.autoCommitIntervalMs, 5000)
        XCTAssertEqual(config.sessionTimeoutMs, 30000)
        XCTAssertEqual(config.heartbeatIntervalMs, 3000)
        XCTAssertEqual(config.maxPollRecords, 500)
        XCTAssertEqual(config.autoOffsetReset, .latest)
    }

    func testConsumerConfigCustom() {
        let config = ConsumerConfig(
            groupId: "my-group",
            autoCommit: false,
            autoCommitIntervalMs: 10000,
            sessionTimeoutMs: 60000,
            heartbeatIntervalMs: 5000,
            maxPollRecords: 1000,
            autoOffsetReset: .earliest
        )
        XCTAssertEqual(config.groupId, "my-group")
        XCTAssertFalse(config.autoCommit)
        XCTAssertEqual(config.maxPollRecords, 1000)
        XCTAssertEqual(config.autoOffsetReset, .earliest)
    }

    func testConsumerConfigEquality() {
        XCTAssertEqual(ConsumerConfig(), ConsumerConfig())
    }

    func testCompressionTypes() {
        let types: [CompressionType] = [.none, .gzip, .snappy, .lz4, .zstd]
        XCTAssertEqual(types.count, 5)
        XCTAssertEqual(CompressionType.zstd.rawValue, "zstd")
    }

    func testAcksValues() {
        XCTAssertEqual(Acks.none.rawValue, 0)
        XCTAssertEqual(Acks.one.rawValue, 1)
        XCTAssertEqual(Acks.all.rawValue, -1)
    }

    func testOffsetResetValues() {
        XCTAssertEqual(OffsetReset.earliest.rawValue, "earliest")
        XCTAssertEqual(OffsetReset.latest.rawValue, "latest")
        XCTAssertEqual(OffsetReset.none.rawValue, "none")
    }
}

// MARK: - Configuration with New Fields

final class ConfigurationExtendedTests: XCTestCase {

    func testConfigurationWithTls() {
        let config = StreamlineConfiguration(
            url: URL(string: "wss://localhost:9092")!,
            tls: TlsConfig(enabled: true)
        )
        XCTAssertNotNil(config.tls)
        XCTAssertTrue(config.tls!.enabled)
    }

    func testConfigurationWithSasl() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            sasl: SaslConfig(username: "admin", password: "secret")
        )
        XCTAssertNotNil(config.sasl)
        XCTAssertEqual(config.sasl!.username, "admin")
    }

    func testConfigurationDefaultsPreserved() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        XCTAssertNil(config.tls)
        XCTAssertNil(config.sasl)
        XCTAssertTrue(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 10)
    }

    func testConfigurationWithProducerConfig() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            producerConfig: ProducerConfig(batchSize: 32768, compression: .lz4)
        )
        XCTAssertEqual(config.producerConfig.batchSize, 32768)
        XCTAssertEqual(config.producerConfig.compression, .lz4)
    }

    func testConfigurationWithConsumerConfig() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            consumerConfig: ConsumerConfig(groupId: "my-app", autoCommit: false)
        )
        XCTAssertEqual(config.consumerConfig.groupId, "my-app")
        XCTAssertFalse(config.consumerConfig.autoCommit)
    }
}
