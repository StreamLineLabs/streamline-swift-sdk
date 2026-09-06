@testable import StreamlineSDK
import XCTest

final class StreamlineClientTests: XCTestCase {
    // MARK: - Configuration

    func testDefaultConfiguration() throws {
        let config = try StreamlineConfiguration(url: XCTUnwrap(URL(string: "ws://localhost:9092")))
        XCTAssertTrue(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 10)
        XCTAssertEqual(config.timeout, 30)
        XCTAssertNil(config.authToken)
        XCTAssertEqual(config.initialBackoff, 0.5)
        XCTAssertEqual(config.maxBackoff, 30)
    }

    func testCustomConfiguration() throws {
        let config = try StreamlineConfiguration(
            url: XCTUnwrap(URL(string: "ws://myhost:9092")),
            autoReconnect: false,
            maxRetries: 5,
            timeout: 10,
            authToken: "secret",
            initialBackoff: 1.0,
            maxBackoff: 60
        )
        XCTAssertEqual(config.url.absoluteString, "ws://myhost:9092")
        XCTAssertFalse(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 5)
        XCTAssertEqual(config.timeout, 10)
        XCTAssertEqual(config.authToken, "secret")
        XCTAssertEqual(config.initialBackoff, 1.0)
        XCTAssertEqual(config.maxBackoff, 60)
    }

    // MARK: - Connection State

    func testInitialStateIsDisconnected() throws {
        let config = try StreamlineConfiguration(url: XCTUnwrap(URL(string: "ws://localhost:9092")))
        let client = StreamlineClient(configuration: config)
        XCTAssertEqual(client.state, .disconnected)
    }

    func testAllConnectionStatesExist() {
        let states: [ConnectionState] = [.disconnected, .connecting, .connected, .reconnecting]
        XCTAssertEqual(states.count, 4)
        XCTAssertNotEqual(ConnectionState.connected, ConnectionState.disconnected)
        XCTAssertNotEqual(ConnectionState.connecting, ConnectionState.reconnecting)
    }

    // MARK: - Offline Queue

    func testOfflineQueueBuffersMessages() throws {
        let config = try StreamlineConfiguration(url: XCTUnwrap(URL(string: "ws://localhost:9092")))
        let client = StreamlineClient(configuration: config)
        try client.produce(topic: "test-topic", stringValue: "hello")
    }

    // MARK: - Message Model

    func testMessageEquality() {
        let data = Data("hello".utf8)
        let a = StreamlineMessage(topic: "t", key: "k", value: data, offset: 1, timestamp: nil)
        let b = StreamlineMessage(topic: "t", key: "k", value: data, offset: 1, timestamp: nil)
        XCTAssertEqual(a, b)
    }

    func testMessageWithNilOptionals() {
        let msg = StreamlineMessage(topic: "test", value: Data("v".utf8))
        XCTAssertEqual(msg.topic, "test")
        XCTAssertNil(msg.key)
        XCTAssertNil(msg.offset)
        XCTAssertNil(msg.timestamp)
    }

    func testMessageStringValueConvenience() {
        let msg = StreamlineMessage(topic: "t", stringValue: "hello world")
        XCTAssertEqual(String(data: msg.value, encoding: .utf8), "hello world")
    }

    func testMessageInequality() {
        let a = StreamlineMessage(topic: "t1", value: Data("v".utf8))
        let b = StreamlineMessage(topic: "t2", value: Data("v".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testMessageWithAllFields() {
        let now = Date()
        let msg = StreamlineMessage(
            topic: "events",
            key: "user-1",
            value: Data("payload".utf8),
            offset: 42,
            timestamp: now
        )
        XCTAssertEqual(msg.topic, "events")
        XCTAssertEqual(msg.key, "user-1")
        XCTAssertEqual(msg.offset, 42)
        XCTAssertEqual(msg.timestamp, now)
    }

    // MARK: - Topic Info

    func testTopicInfoEquality() {
        let a = TopicInfo(name: "t", partitions: 3, replicationFactor: 1, messageCount: 100)
        let b = TopicInfo(name: "t", partitions: 3, replicationFactor: 1, messageCount: 100)
        XCTAssertEqual(a, b)
    }

    func testTopicInfoProperties() {
        let info = TopicInfo(name: "events", partitions: 12, replicationFactor: 3, messageCount: 50000)
        XCTAssertEqual(info.name, "events")
        XCTAssertEqual(info.partitions, 12)
        XCTAssertEqual(info.replicationFactor, 3)
        XCTAssertEqual(info.messageCount, 50000)
    }

    // MARK: - Topic Description

    func testTopicDescriptionWithConfig() {
        let desc = TopicDescription(
            name: "events",
            partitions: 6,
            replicationFactor: 3,
            messageCount: 1000,
            config: ["retention.ms": "86400000", "cleanup.policy": "delete"]
        )
        XCTAssertEqual(desc.name, "events")
        XCTAssertEqual(desc.config.count, 2)
        XCTAssertEqual(desc.config["retention.ms"], "86400000")
    }

    func testTopicDescriptionDefaults() {
        let desc = TopicDescription(name: "t", partitions: 1, replicationFactor: 1)
        XCTAssertTrue(desc.config.isEmpty)
        XCTAssertEqual(desc.messageCount, 0)
    }

    // MARK: - Consumer Group

    func testConsumerGroupEquality() {
        let a = ConsumerGroup(id: "g1", members: ["m1"], state: "Stable")
        let b = ConsumerGroup(id: "g1", members: ["m1"], state: "Stable")
        XCTAssertEqual(a, b)
    }

    func testConsumerGroupDescription() {
        let member = ConsumerGroupMember(
            id: "m1",
            clientId: "client-1",
            host: "10.0.0.1",
            assignments: ["events-0", "events-1"]
        )
        let desc = ConsumerGroupDescription(
            id: "cg-1",
            state: "Stable",
            members: [member],
            protocolType: "range"
        )
        XCTAssertEqual(desc.id, "cg-1")
        XCTAssertEqual(desc.members.count, 1)
        XCTAssertEqual(desc.members[0].clientId, "client-1")
        XCTAssertEqual(desc.members[0].assignments.count, 2)
        XCTAssertEqual(desc.protocolType, "range")
    }

    func testConsumerGroupMemberDefaults() {
        let member = ConsumerGroupMember(id: "m1")
        XCTAssertEqual(member.clientId, "")
        XCTAssertEqual(member.host, "")
        XCTAssertTrue(member.assignments.isEmpty)
    }

    // MARK: - Query Result

    func testQueryResultWithData() {
        let result = QueryResult(
            columns: ["key", "value", "offset"],
            rows: [["k1", "v1", "0"], ["k2", "v2", "1"]],
            rowCount: 2
        )
        XCTAssertEqual(result.columns.count, 3)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0][0], "k1")
        XCTAssertEqual(result.rowCount, 2)
    }

    func testQueryResultDefaults() {
        let result = QueryResult()
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.rowCount, 0)
    }

    // MARK: - Server Info

    func testServerInfoProperties() {
        let info = ServerInfo(version: "0.2.0", uptime: 3600, topicCount: 10, messageCount: 50000)
        XCTAssertEqual(info.version, "0.2.0")
        XCTAssertEqual(info.uptime, 3600)
        XCTAssertEqual(info.topicCount, 10)
        XCTAssertEqual(info.messageCount, 50000)
    }

    func testServerInfoDefaults() {
        let info = ServerInfo()
        XCTAssertEqual(info.version, "")
        XCTAssertEqual(info.uptime, 0)
        XCTAssertEqual(info.topicCount, 0)
        XCTAssertEqual(info.messageCount, 0)
    }

    // MARK: - Error Types

    func testErrorCases() {
        let errors: [StreamlineError] = [
            .notConnected,
            .connectionFailed("fail"),
            .authenticationFailed("bad token"),
            .timeout,
            .topicNotFound("missing"),
            .serializationError("bad json"),
            .offlineQueueFull,
            .adminOperationFailed("http 500"),
            .queryFailed("bad sql"),
        ]
        XCTAssertEqual(errors.count, 9)
    }

    func testErrorEquality() {
        XCTAssertEqual(StreamlineError.notConnected, StreamlineError.notConnected)
        XCTAssertEqual(StreamlineError.timeout, StreamlineError.timeout)
        XCTAssertEqual(StreamlineError.offlineQueueFull, StreamlineError.offlineQueueFull)
        XCTAssertEqual(StreamlineError.topicNotFound("x"), StreamlineError.topicNotFound("x"))
        XCTAssertNotEqual(StreamlineError.topicNotFound("x"), StreamlineError.topicNotFound("y"))
    }

    func testErrorIsErrorProtocol() {
        let error: Error = StreamlineError.notConnected
        XCTAssertNotNil(error)
    }

    func testAdminOperationError() {
        let error = StreamlineError.adminOperationFailed("HTTP 500: internal error")
        if case let .adminOperationFailed(message) = error {
            XCTAssertTrue(message.contains("500"))
        } else {
            XCTFail("Expected adminOperationFailed")
        }
    }

    func testQueryError() {
        let error = StreamlineError.queryFailed("invalid SQL syntax")
        if case let .queryFailed(message) = error {
            XCTAssertTrue(message.contains("SQL"))
        } else {
            XCTFail("Expected queryFailed")
        }
    }

    // MARK: - AdminClient Init

    func testAdminClientInit() throws {
        let admin = try AdminClient(baseURL: XCTUnwrap(URL(string: "http://localhost:9094")))
        XCTAssertNotNil(admin)
    }

    func testAdminClientWithAuth() throws {
        let admin = try AdminClient(baseURL: XCTUnwrap(URL(string: "http://localhost:9094")), authToken: "my-token")
        XCTAssertNotNil(admin)
    }

    // MARK: - AsyncStream

    func testMessagesReturnsAsyncStream() throws {
        let config = try StreamlineConfiguration(url: XCTUnwrap(URL(string: "ws://localhost:9092")))
        let client = StreamlineClient(configuration: config)
        let stream = client.messages(topic: "test")
        XCTAssertNotNil(stream)
    }
}
