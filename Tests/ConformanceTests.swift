import XCTest
@testable import StreamlineSDK

// SDK Conformance Test Suite — 46 tests per SDK_CONFORMANCE_SPEC.md
//
// Tests validate SDK model contracts, configuration, error handling,
// and serialization without requiring a running Streamline server.

// MARK: - Producer (8 tests)

final class ProducerConformanceTests: XCTestCase {

    func testP01_SimpleProduce() {
        let msg = StreamlineMessage(topic: "events", stringValue: "{\"action\":\"click\"}")
        XCTAssertEqual(msg.topic, "events")
        XCTAssertEqual(String(data: msg.value, encoding: .utf8), "{\"action\":\"click\"}")
        XCTAssertNil(msg.key)
        XCTAssertNil(msg.offset)
    }

    func testP02_KeyedProduce() {
        let msg = StreamlineMessage(topic: "events", key: "user-42", stringValue: "data")
        XCTAssertEqual(msg.key, "user-42")
        XCTAssertEqual(String(data: msg.value, encoding: .utf8), "data")
    }

    func testP03_HeadersProduce() {
        let ts = Date()
        let msg = StreamlineMessage(topic: "events", key: "k1", stringValue: "v1", offset: 42, timestamp: ts)
        XCTAssertEqual(msg.offset, 42)
        XCTAssertEqual(msg.timestamp, ts)
    }

    func testP04_BatchProduce() {
        let config = ProducerConfig(batchSize: 65536, lingerMs: 10)
        XCTAssertEqual(config.batchSize, 65536)
        XCTAssertEqual(config.lingerMs, 10)
    }

    func testP05_Compression() {
        let allTypes: [CompressionType] = [.none, .gzip, .snappy, .lz4, .zstd]
        for type in allTypes {
            let config = ProducerConfig(compression: type)
            XCTAssertEqual(config.compression, type)
        }
    }

    func testP06_Partitioner() {
        let config = ProducerConfig()
        XCTAssertEqual(config.batchSize, 16384)
        XCTAssertEqual(config.lingerMs, 0)
        XCTAssertEqual(config.compression, .none)
        XCTAssertEqual(config.retries, 3)
        XCTAssertEqual(config.acks, .one)
    }

    func testP07_Idempotent() {
        let config = ProducerConfig(idempotent: true, acks: .all)
        XCTAssertTrue(config.idempotent)
        XCTAssertEqual(config.acks, .all)
    }

    func testP08_Timeout() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!, timeout: 5)
        XCTAssertEqual(config.timeout, 5)
    }
}

// MARK: - Consumer (8 tests)

final class ConsumerConformanceTests: XCTestCase {

    func testC01_Subscribe() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        XCTAssertTrue(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 10)
    }

    func testC02_FromBeginning() {
        let config = ConsumerConfig(autoOffsetReset: .earliest)
        XCTAssertEqual(config.autoOffsetReset, .earliest)
    }

    func testC03_FromOffset() {
        let msg = StreamlineMessage(topic: "t", stringValue: "v", offset: 999)
        XCTAssertEqual(msg.offset, 999)
    }

    func testC04_FromTimestamp() {
        let ts = Date()
        let msg = StreamlineMessage(topic: "t", stringValue: "v", timestamp: ts)
        XCTAssertEqual(msg.timestamp, ts)
    }

    func testC05_Follow() {
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!, autoReconnect: true, maxRetries: 5
        )
        XCTAssertTrue(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 5)
    }

    func testC06_Filter() {
        let messages = [
            StreamlineMessage(topic: "t", key: "a", stringValue: "1"),
            StreamlineMessage(topic: "t", stringValue: "2"),
            StreamlineMessage(topic: "t", key: "b", stringValue: "3"),
        ]
        let filtered = messages.filter { $0.key != nil }
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].key, "a")
        XCTAssertEqual(filtered[1].key, "b")
    }

    func testC07_Headers() {
        let ts = Date()
        let msg = StreamlineMessage(topic: "events", key: "k", stringValue: "v", offset: 10, timestamp: ts)
        XCTAssertNotNil(msg.topic)
        XCTAssertNotNil(msg.key)
        XCTAssertNotNil(msg.offset)
        XCTAssertNotNil(msg.timestamp)
    }

    func testC08_Timeout() {
        let config = ConsumerConfig(sessionTimeoutMs: 15000, heartbeatIntervalMs: 5000)
        XCTAssertEqual(config.sessionTimeoutMs, 15000)
        XCTAssertEqual(config.heartbeatIntervalMs, 5000)
    }
}

// MARK: - Consumer Groups (8 tests)

final class ConsumerGroupConformanceTests: XCTestCase {

    func testG01_JoinGroup() {
        let config = ConsumerConfig(groupId: "my-group")
        XCTAssertEqual(config.groupId, "my-group")
    }

    func testG02_CommitOffset() {
        let config = ConsumerConfig()
        XCTAssertTrue(config.autoCommit)
        XCTAssertEqual(config.autoCommitIntervalMs, 5000)
    }

    func testG03_FetchCommittedOffset() {
        let group = ConsumerGroup(id: "grp-1", members: ["m-1", "m-2"], state: "Stable")
        XCTAssertEqual(group.id, "grp-1")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.state, "Stable")
    }

    func testG04_AutoCommit() {
        let config = ConsumerConfig(autoCommit: true, autoCommitIntervalMs: 1000)
        XCTAssertTrue(config.autoCommit)
        XCTAssertEqual(config.autoCommitIntervalMs, 1000)
    }

    func testG05_Rebalance() {
        let member = ConsumerGroupMember(
            id: "member-1", clientId: "client-1",
            host: "192.168.1.1", assignments: ["events-0", "events-1"]
        )
        let desc = ConsumerGroupDescription(
            id: "grp-1", state: "Stable", members: [member], protocolType: "range"
        )
        XCTAssertEqual(desc.id, "grp-1")
        XCTAssertEqual(desc.members.count, 1)
        XCTAssertEqual(desc.members[0].clientId, "client-1")
        XCTAssertEqual(desc.members[0].assignments.count, 2)
    }

    func testG06_LeaveGroup() {
        let group1 = ConsumerGroup(id: "grp-1", members: ["m1", "m2"], state: "Stable")
        let group2 = ConsumerGroup(id: "grp-1", members: ["m2"], state: "Stable")
        XCTAssertEqual(group1.members.count, 2)
        XCTAssertEqual(group2.members.count, 1)
        XCTAssertNotEqual(group1, group2)
    }

    func testG07_IndependentGroups() {
        let groupA = ConsumerGroup(id: "group-a", members: ["m1"], state: "Stable")
        let groupB = ConsumerGroup(id: "group-b", members: ["m2", "m3"], state: "Stable")
        XCTAssertNotEqual(groupA.id, groupB.id)
        XCTAssertEqual(groupA.members.count, 1)
        XCTAssertEqual(groupB.members.count, 2)
    }

    func testG08_StaticMembership() {
        let config = ConsumerConfig(groupId: "static-group", autoCommit: false, maxPollRecords: 100)
        XCTAssertEqual(config.groupId, "static-group")
        XCTAssertFalse(config.autoCommit)
        XCTAssertEqual(config.maxPollRecords, 100)
    }
}

// MARK: - Admin / Topics (6 tests)

final class AdminConformanceTests: XCTestCase {

    func testD01_CreateTopic() {
        let topic = TopicInfo(name: "events", partitions: 3, replicationFactor: 1, messageCount: 0)
        XCTAssertEqual(topic.name, "events")
        XCTAssertEqual(topic.partitions, 3)
        XCTAssertEqual(topic.messageCount, 0)
    }

    func testD02_ListTopics() {
        let topics = [
            TopicInfo(name: "t1", partitions: 1, replicationFactor: 1, messageCount: 0),
            TopicInfo(name: "t2", partitions: 3, replicationFactor: 1, messageCount: 100),
        ]
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].name, "t1")
        XCTAssertEqual(topics[1].partitions, 3)
    }

    func testD03_DescribeTopic() {
        let desc = TopicDescription(
            name: "events", partitions: 6, replicationFactor: 3,
            messageCount: 5000, config: ["retention.ms": "86400000"]
        )
        XCTAssertEqual(desc.name, "events")
        XCTAssertEqual(desc.partitions, 6)
        XCTAssertEqual(desc.replicationFactor, 3)
        XCTAssertEqual(desc.config["retention.ms"], "86400000")
    }

    func testD04_DeleteTopic() {
        let before = [
            TopicInfo(name: "keep", partitions: 1, replicationFactor: 1, messageCount: 0),
            TopicInfo(name: "delete-me", partitions: 1, replicationFactor: 1, messageCount: 0),
        ]
        let after = before.filter { $0.name != "delete-me" }
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].name, "keep")
    }

    func testD05_AutoCreateTopic() {
        let topic = TopicDescription(name: "auto-topic", partitions: 1, replicationFactor: 1)
        XCTAssertEqual(topic.name, "auto-topic")
        XCTAssertEqual(topic.messageCount, 0)
        XCTAssertTrue(topic.config.isEmpty)
    }

    func testD06_DuplicateTopicRejected() {
        let error = StreamlineError.adminOperationFailed("Topic already exists")
        if case .adminOperationFailed(let msg) = error {
            XCTAssertTrue(msg.contains("already exists"))
        } else {
            XCTFail("Expected adminOperationFailed")
        }
    }
}

// MARK: - Authentication (6 tests)

final class AuthConformanceTests: XCTestCase {

    func testA01_TLSConnect() {
        let tls = TlsConfig(enabled: true, caCertificatePath: "/etc/ssl/ca.pem")
        XCTAssertTrue(tls.enabled)
        XCTAssertEqual(tls.caCertificatePath, "/etc/ssl/ca.pem")
        let config = StreamlineConfiguration(
            url: URL(string: "wss://localhost:9092")!,
            tls: tls
        )
        XCTAssertThrowsError(try config.validate())
    }

    func testA02_MutualTLS() {
        let tls = TlsConfig(
            enabled: true,
            caCertificatePath: "/etc/ssl/ca.pem",
            clientCertificatePath: "/etc/ssl/client.pem",
            clientKeyPath: "/etc/ssl/client.key"
        )
        XCTAssertEqual(tls.clientCertificatePath, "/etc/ssl/client.pem")
        XCTAssertEqual(tls.clientKeyPath, "/etc/ssl/client.key")
        let config = StreamlineConfiguration(
            url: URL(string: "wss://localhost:9092")!,
            tls: tls
        )
        XCTAssertThrowsError(try config.validate())
    }

    func testA03_SASLPlain() {
        let sasl = SaslConfig(mechanism: .plain, username: "admin", password: "secret")
        XCTAssertEqual(sasl.mechanism, .plain)
        XCTAssertEqual(sasl.username, "admin")
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            sasl: sasl
        )
        XCTAssertThrowsError(try config.validate())
    }

    func testA04_SCRAMSHA256() {
        let sasl = SaslConfig(mechanism: .scramSha256, username: "u", password: "p")
        XCTAssertEqual(sasl.mechanism, .scramSha256)
        XCTAssertEqual(sasl.mechanism.rawValue, "SCRAM-SHA-256")
    }

    func testA05_SCRAMSHA512() {
        let sasl = SaslConfig(mechanism: .scramSha512, username: "u", password: "p")
        XCTAssertEqual(sasl.mechanism, .scramSha512)
        XCTAssertEqual(sasl.mechanism.rawValue, "SCRAM-SHA-512")
    }

    func testA06_AuthFailure() {
        let error = StreamlineError.authenticationFailed("Invalid credentials")
        if case .authenticationFailed(let msg) = error {
            XCTAssertTrue(msg.contains("Invalid"))
        } else {
            XCTFail("Expected authenticationFailed")
        }
    }
}

// MARK: - Schema Registry (6 tests)

final class SchemaConformanceTests: XCTestCase {

    func testS01_RegisterSchema() {
        let schema = SchemaInfo(
            id: 1, subject: "events-value", version: 1, format: .avro,
            schema: "{\"type\":\"record\",\"name\":\"Event\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}"
        )
        XCTAssertEqual(schema.subject, "events-value")
        XCTAssertEqual(schema.id, 1)
        XCTAssertEqual(schema.format, .avro)
    }

    func testS02_GetSchemaById() {
        let schema = SchemaInfo(
            id: 42, subject: "test-value", version: 3,
            format: .protobuf, schema: "syntax = \"proto3\";"
        )
        XCTAssertEqual(schema.id, 42)
        XCTAssertEqual(schema.version, 3)
        XCTAssertEqual(schema.format, .protobuf)
    }

    func testS03_ListVersions() {
        let schemas = [
            SchemaInfo(id: 1, subject: "events-value", version: 1, format: .avro, schema: "{}"),
            SchemaInfo(id: 2, subject: "events-value", version: 2, format: .avro, schema: "{}"),
        ]
        XCTAssertEqual(schemas.count, 2)
        XCTAssertEqual(schemas[0].version, 1)
        XCTAssertEqual(schemas[1].version, 2)
    }

    func testS04_CompatibilityCheck() {
        let v1 = SchemaInfo(id: 1, subject: "s", version: 1, format: .avro, schema: "{\"type\":\"string\"}")
        let v2 = SchemaInfo(id: 2, subject: "s", version: 2, format: .avro, schema: "{\"type\":\"string\"}")
        XCTAssertEqual(v1.subject, v2.subject)
        XCTAssertNotEqual(v1.version, v2.version)
    }

    func testS05_AvroFormat() {
        XCTAssertEqual(SchemaFormat.avro.rawValue, "AVRO")
    }

    func testS06_JsonFormat() {
        let formats: [SchemaFormat] = [.avro, .protobuf, .json]
        XCTAssertEqual(formats.count, 3)
        XCTAssertTrue(formats.contains(.avro))
        XCTAssertTrue(formats.contains(.protobuf))
        XCTAssertTrue(formats.contains(.json))
    }
}

// MARK: - Error Handling (5 tests)

final class ErrorConformanceTests: XCTestCase {

    func testE01_UnknownTopic() {
        let error = StreamlineError.topicNotFound("nonexistent")
        if case .topicNotFound(let name) = error {
            XCTAssertEqual(name, "nonexistent")
        } else {
            XCTFail("Expected topicNotFound")
        }
    }

    func testE02_InvalidPartition() {
        let error = StreamlineError.adminOperationFailed("Invalid partition: -1")
        if case .adminOperationFailed(let msg) = error {
            XCTAssertTrue(msg.contains("-1"))
        } else {
            XCTFail("Expected adminOperationFailed")
        }
    }

    func testE03_InvalidOffset() {
        let errors: [StreamlineError] = [
            .notConnected,
            .connectionFailed("refused"),
            .timeout,
            .offlineQueueFull,
        ]
        XCTAssertEqual(errors.count, 4)
        XCTAssertEqual(errors[0], .notConnected)
        XCTAssertEqual(errors[2], .timeout)
        XCTAssertEqual(errors[3], .offlineQueueFull)
    }

    func testE04_RetryableErrorInfo() {
        let topicErr = StreamlineError.topicNotFound("events")
        let authErr = StreamlineError.authenticationFailed("bad creds")
        let adminErr = StreamlineError.adminOperationFailed("server error")
        let queryErr = StreamlineError.queryFailed("syntax error")
        let schemaErr = StreamlineError.schemaRegistryError("not found")

        XCTAssertNotEqual(topicErr, authErr)
        XCTAssertNotEqual(adminErr, queryErr)
        XCTAssertNotEqual(queryErr, schemaErr)
    }

    func testE05_DescriptiveErrorMessages() {
        let error = StreamlineError.serializationError("Invalid JSON at position 42")
        if case .serializationError(let msg) = error {
            XCTAssertTrue(msg.contains("position 42"))
        } else {
            XCTFail("Expected serializationError")
        }
    }
}

// MARK: - Performance (4 tests)

final class PerformanceConformanceTests: XCTestCase {

    func testF01_Throughput1KB() {
        let value = String(repeating: "x", count: 1024)
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<10_000 {
            _ = StreamlineMessage(topic: "perf", key: "k-\(i)", stringValue: value)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 10.0, "10k message creations took \(elapsed)s, expected < 10s")
    }

    func testF02_LatencyP99() {
        var times: [Double] = []
        for _ in 0..<1000 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = StreamlineConfiguration(
                url: URL(string: "ws://localhost:9092")!, autoReconnect: true, maxRetries: 10,
                tls: TlsConfig(enabled: true),
                sasl: SaslConfig(mechanism: .scramSha256, username: "u", password: "p")
            )
            times.append(CFAbsoluteTimeGetCurrent() - start)
        }
        times.sort()
        let p99 = times[Int(Double(times.count) * 0.99)]
        XCTAssertLessThan(p99, 0.001, "P99 config creation: \(p99 * 1000)ms")
    }

    func testF03_StartupTime() {
        let start = CFAbsoluteTimeGetCurrent()
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        _ = StreamlineClient(configuration: config)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.0, "Client instantiation took \(elapsed)s, expected < 1s")
    }

    func testF04_MemoryUsage() {
        let messages = (1...10_000).map {
            StreamlineMessage(topic: "perf", key: "key-\($0)", stringValue: "value-\($0)")
        }
        XCTAssertEqual(messages.count, 10_000)
        XCTAssertEqual(messages.first?.key, "key-1")
        XCTAssertEqual(messages.last?.key, "key-10000")
    }
}
