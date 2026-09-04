import Foundation
@testable import StreamlineSDK
import XCTest

final class IntegrationTests: XCTestCase {
    func testAdminTopicLifecycleAgainstFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["STREAMLINE_HTTP_URL"],
              let baseURL = URL(string: rawURL)
        else {
            throw XCTSkip("STREAMLINE_HTTP_URL is required for integration tests")
        }

        let admin = AdminClient(baseURL: baseURL)
        let topic = "swift-integration-\(UUID().uuidString.lowercased())"

        do {
            try await admin.createTopic(name: topic, partitions: 1)
            let topics = try await admin.listTopics()
            XCTAssertTrue(topics.contains { $0.name == topic })

            let description = try await admin.describeTopic(name: topic)
            XCTAssertEqual(description.name, topic)

            try await admin.deleteTopic(name: topic)
        } catch {
            try? await admin.deleteTopic(name: topic)
            throw error
        }
    }

    func testWebSocketConnectionReachesOpenState() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["STREAMLINE_WEBSOCKET_URL"],
              let webSocketURL = URL(string: rawURL)
        else {
            throw XCTSkip("STREAMLINE_WEBSOCKET_URL is required for integration tests")
        }

        let connected = expectation(description: "WebSocket connection opened")
        let delegate = ConnectionDelegate(connected: connected)
        let client = StreamlineClient(
            configuration: StreamlineConfiguration(
                url: webSocketURL,
                autoReconnect: false,
                timeout: 10
            )
        )
        client.delegate = delegate

        client.connect()
        await fulfillment(of: [connected], timeout: 10)

        XCTAssertEqual(client.state, .connected)
        XCTAssertNil(delegate.error)
        client.disconnect()
    }
}

private final class ConnectionDelegate: StreamlineClientDelegate {
    private let connected: XCTestExpectation
    private let lock = NSLock()
    private var storedError: StreamlineError?

    init(connected: XCTestExpectation) {
        self.connected = connected
    }

    var error: StreamlineError? {
        lock.lock()
        let error = storedError
        lock.unlock()
        return error
    }

    func client(_: StreamlineClient, didChangeState state: ConnectionState) {
        if state == .connected {
            connected.fulfill()
        }
    }

    func client(_: StreamlineClient, didEncounterError error: StreamlineError) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
