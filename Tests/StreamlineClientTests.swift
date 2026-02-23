import XCTest
@testable import StreamlineSDK

final class StreamlineClientTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        XCTAssertTrue(config.autoReconnect)
        XCTAssertEqual(config.maxRetries, 10)
        XCTAssertEqual(config.timeout, 30)
        XCTAssertNil(config.authToken)
    }

    func testInitialStateIsDisconnected() {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)
        XCTAssertEqual(client.state, .disconnected)
    }

    func testOfflineQueueBuffersMessages() throws {
        let config = StreamlineConfiguration(url: URL(string: "ws://localhost:9092")!)
        let client = StreamlineClient(configuration: config)

        // Producing while disconnected should not throw (queued offline).
        try client.produce(topic: "test-topic", stringValue: "hello")
    }

    func testMessageEquality() {
        let data = Data("hello".utf8)
        let a = StreamlineMessage(topic: "t", key: "k", value: data, offset: 1, timestamp: nil)
        let b = StreamlineMessage(topic: "t", key: "k", value: data, offset: 1, timestamp: nil)
        XCTAssertEqual(a, b)
    }
}
