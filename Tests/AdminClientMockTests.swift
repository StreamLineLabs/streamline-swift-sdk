import XCTest
@testable import StreamlineSDK
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Mock URLProtocol for HTTP Testing

/// A URLProtocol subclass that intercepts HTTP requests and returns mock responses.
/// This allows testing AdminClient and SchemaRegistryClient without a real server.
final class MockURLProtocol: URLProtocol {

    /// Handler type: receives a request and returns (response, data) or throws.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Captured requests for assertion.
    static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)

        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }
}

// MARK: - Helper

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func jsonResponse(_ statusCode: Int, json: Any, url: URL? = nil) -> (HTTPURLResponse, Data) {
    let responseURL = url ?? URL(string: "http://localhost:9094")!
    let response = HTTPURLResponse(
        url: responseURL,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    let data = try! JSONSerialization.data(withJSONObject: json)
    return (response, data)
}

// MARK: - AdminClient List Topics Tests

final class AdminClientListTopicsTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testListTopicsReturnsTopics() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/topics"))
            XCTAssertEqual(request.httpMethod, "GET")
            return jsonResponse(200, json: [
                ["name": "events", "partitions": 3, "replication_factor": 1, "message_count": 100],
                ["name": "orders", "partitions": 6, "replication_factor": 3, "message_count": 500],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let topics = try await admin.listTopics()

        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].name, "events")
        XCTAssertEqual(topics[0].partitions, 3)
        XCTAssertEqual(topics[0].replicationFactor, 1)
        XCTAssertEqual(topics[0].messageCount, 100)
        XCTAssertEqual(topics[1].name, "orders")
        XCTAssertEqual(topics[1].partitions, 6)
    }

    func testListTopicsReturnsEmpty() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [Any]())
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let topics = try await admin.listTopics()
        XCTAssertTrue(topics.isEmpty)
    }

    func testListTopicsHandlesServerError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(500, json: ["error": "internal server error"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.listTopics()
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            if case .adminOperationFailed(let msg) = error {
                XCTAssertTrue(msg.contains("500"))
            } else {
                XCTFail("Expected adminOperationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - AdminClient Describe Topic Tests

final class AdminClientDescribeTopicTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testDescribeTopicReturnsDescription() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/topics/events"))
            return jsonResponse(200, json: [
                "name": "events",
                "partitions": 6,
                "replication_factor": 3,
                "message_count": 5000,
                "config": ["retention.ms": "86400000", "cleanup.policy": "delete"],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let desc = try await admin.describeTopic(name: "events")

        XCTAssertEqual(desc.name, "events")
        XCTAssertEqual(desc.partitions, 6)
        XCTAssertEqual(desc.replicationFactor, 3)
        XCTAssertEqual(desc.messageCount, 5000)
        XCTAssertEqual(desc.config["retention.ms"], "86400000")
        XCTAssertEqual(desc.config["cleanup.policy"], "delete")
    }

    func testDescribeTopicHandles404() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(404, json: ["error": "not found"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.describeTopic(name: "nonexistent")
            XCTFail("Expected topicNotFound error")
        } catch let error as StreamlineError {
            if case .topicNotFound = error {
                // Expected
            } else {
                XCTFail("Expected topicNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - URL Path Segment Encoding Tests
//
// AdminClient interpolates caller-supplied identifiers (consumer group IDs in
// particular accept any non-empty string — TopicNameValidator only restricts
// topic names) directly into HTTP request paths. Without percent-encoding,
// a value such as "../v1/admin" or one containing "/" could make the actual
// request target a different path than the one the caller specified. These
// tests pin the behavior of ``URLPathSegmentEncoder`` and confirm AdminClient
// applies it consistently before constructing a request URL.

final class URLPathSegmentEncoderTests: XCTestCase {

    func testUnreservedCharactersPassThroughUnchanged() {
        let input = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        XCTAssertEqual(URLPathSegmentEncoder.encode(input), input)
    }

    func testPathSeparatorIsPercentEncoded() {
        XCTAssertEqual(URLPathSegmentEncoder.encode("foo/bar"), "foo%2Fbar")
    }

    func testDotDotSegmentDoesNotSurviveAsLiteralTraversal() {
        // "." and "_"/"-" are unreserved and pass through unencoded, but the
        // "/" that would be needed to actually traverse a path is always
        // encoded, so "../" can never become a real path separator.
        XCTAssertEqual(URLPathSegmentEncoder.encode("../admin"), "..%2Fadmin")
    }

    func testSpaceAndReservedURLCharactersAreEncoded() {
        XCTAssertEqual(URLPathSegmentEncoder.encode("a b"), "a%20b")
        XCTAssertEqual(URLPathSegmentEncoder.encode("a?b"), "a%3Fb")
        XCTAssertEqual(URLPathSegmentEncoder.encode("a#b"), "a%23b")
        XCTAssertEqual(URLPathSegmentEncoder.encode("a&b=c"), "a%26b%3Dc")
    }

    func testEmptyStringEncodesToEmptyString() {
        XCTAssertEqual(URLPathSegmentEncoder.encode(""), "")
    }

    func testNonASCIICharactersAreEncodedAsUTF8Bytes() {
        // "é" is 2 UTF-8 bytes (0xC3 0xA9).
        XCTAssertEqual(URLPathSegmentEncoder.encode("é"), "%C3%A9")
    }
}

final class AdminClientPathEncodingTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A malicious consumer group ID attempting a path traversal must not
    /// change the request's actual path prefix — it must be confined to a
    /// single, percent-encoded path segment.
    func testConsumerGroupPathTraversalIsConfinedToOneSegment() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return jsonResponse(200, json: [
                "id": "whatever", "state": "stable", "members": [Any](), "protocol": "consumer",
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        _ = try await admin.describeConsumerGroup(groupId: "../v1/admin")

        let url = try XCTUnwrap(capturedURL)
        // Assert against the *encoded* wire path (`percentEncodedPath`), not
        // the decoded `URL.path`. `.path` silently turns the escaped "%2F"
        // back into a literal "/", which would make a safely-confined single
        // segment indistinguishable from an actual, unescaped path-traversal
        // segment — exactly the distinction this test exists to verify. Both
        // forms decode to the same string, so checking `.path` alone cannot
        // tell a safe encoded segment apart from a real traversal.
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encodedPath = components.percentEncodedPath
        XCTAssertTrue(
            encodedPath.hasPrefix("/v1/consumer-groups/"),
            "Path traversal must not escape the consumer-groups prefix, got: \(encodedPath)"
        )
        let segment = encodedPath.dropFirst("/v1/consumer-groups/".count)
        XCTAssertFalse(
            segment.contains("/"),
            "Traversal must be confined to a single opaque segment, got: \(encodedPath)"
        )
        XCTAssertEqual(encodedPath, "/v1/consumer-groups/..%2Fv1%2Fadmin")
    }

    func testConsumerGroupIdWithSlashIsPercentEncodedInRequestPath() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return jsonResponse(200, json: [
                "id": "a/b", "state": "stable", "members": [Any](), "protocol": "consumer",
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        _ = try await admin.describeConsumerGroup(groupId: "a/b")

        let request = try XCTUnwrap(capturedRequest)
        let url = try XCTUnwrap(request.url)
        // The raw request URL must carry the encoded form, not a literal "/".
        XCTAssertTrue(url.absoluteString.contains("a%2Fb"))
        // Assert against the encoded path, not the decoded `URL.path`: `.path`
        // would turn "%2F" back into "/", making the assertion below
        // trivially (and incorrectly) pass even if encoding were broken.
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertFalse(components.percentEncodedPath.hasSuffix("/a/b"))
        XCTAssertTrue(components.percentEncodedPath.hasSuffix("a%2Fb"))
    }

    func testDeleteConsumerGroupEncodesSpecialCharacters() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return jsonResponse(200, json: [String: Any]())
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.deleteConsumerGroup(groupId: "group with spaces")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertTrue(request.url!.absoluteString.contains("group%20with%20spaces"))
    }
}

// MARK: - AdminClient Create/Delete Topic Tests

final class AdminClientTopicMutationTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testCreateTopicSendsCorrectPayload() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/topics"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["name"] as? String, "new-topic")
            XCTAssertEqual(body["partitions"] as? Int, 3)
            XCTAssertEqual(body["replication_factor"] as? Int, 2)

            return jsonResponse(201, json: ["created": true])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.createTopic(name: "new-topic", partitions: 3, replicationFactor: 2)
    }

    func testCreateTopicWithConfig() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertNotNil(body["config"])
            let config = body["config"] as! [String: String]
            XCTAssertEqual(config["retention.ms"], "3600000")
            return jsonResponse(201, json: ["created": true])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.createTopic(
            name: "configured-topic",
            config: ["retention.ms": "3600000"]
        )
    }

    func testDeleteTopicSendsDeleteRequest() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/topics/old-topic"))
            return jsonResponse(200, json: ["deleted": true])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.deleteTopic(name: "old-topic")
    }
}

// MARK: - AdminClient Consumer Group Tests

final class AdminClientConsumerGroupTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testListConsumerGroups() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                ["id": "group-1", "members": ["m1", "m2"], "state": "Stable"],
                ["id": "group-2", "members": ["m3"], "state": "Empty"],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let groups = try await admin.listConsumerGroups()

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "group-1")
        XCTAssertEqual(groups[0].members, ["m1", "m2"])
        XCTAssertEqual(groups[0].state, "Stable")
        XCTAssertEqual(groups[1].id, "group-2")
        XCTAssertEqual(groups[1].state, "Empty")
    }

    func testDescribeConsumerGroup() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "id": "group-1",
                "state": "Stable",
                "protocol": "range",
                "members": [
                    [
                        "id": "member-1",
                        "client_id": "client-app-1",
                        "host": "10.0.0.1",
                        "assignments": ["events-0", "events-1"],
                    ],
                ],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let desc = try await admin.describeConsumerGroup(groupId: "group-1")

        XCTAssertEqual(desc.id, "group-1")
        XCTAssertEqual(desc.state, "Stable")
        XCTAssertEqual(desc.protocolType, "range")
        XCTAssertEqual(desc.members.count, 1)
        XCTAssertEqual(desc.members[0].id, "member-1")
        XCTAssertEqual(desc.members[0].clientId, "client-app-1")
        XCTAssertEqual(desc.members[0].host, "10.0.0.1")
        XCTAssertEqual(desc.members[0].assignments, ["events-0", "events-1"])
    }

    func testDeleteConsumerGroup() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/consumer-groups/group-1"))
            return jsonResponse(200, json: ["deleted": true])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.deleteConsumerGroup(groupId: "group-1")
    }
}

// MARK: - AdminClient Query Tests

final class AdminClientQueryTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testQueryReturnsResults() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/query"))

            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["query"] as? String, "SELECT * FROM events LIMIT 5")

            return jsonResponse(200, json: [
                "columns": ["key", "value", "offset"],
                "rows": [["k1", "v1", "0"], ["k2", "v2", "1"]],
                "row_count": 2,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let result = try await admin.query("SELECT * FROM events LIMIT 5")

        XCTAssertEqual(result.columns, ["key", "value", "offset"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], ["k1", "v1", "0"])
        XCTAssertEqual(result.rowCount, 2)
    }

    func testQueryWithEmptyResults() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "columns": ["key", "value"],
                "rows": [Any](),
                "row_count": 0,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let result = try await admin.query("SELECT * FROM events WHERE key = 'nonexistent'")

        XCTAssertEqual(result.columns, ["key", "value"])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.rowCount, 0)
    }
}

// MARK: - AdminClient Server Info Tests

final class AdminClientServerInfoTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testServerInfoReturnsData() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("/v1/info"))
            return jsonResponse(200, json: [
                "version": "0.2.0",
                "uptime": 7200,
                "topic_count": 5,
                "message_count": 100000,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let info = try await admin.serverInfo()

        XCTAssertEqual(info.version, "0.2.0")
        XCTAssertEqual(info.uptime, 7200)
        XCTAssertEqual(info.topicCount, 5)
        XCTAssertEqual(info.messageCount, 100000)
    }

    func testIsHealthyReturnsTrue() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["status": "ok"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let healthy = await admin.isHealthy()
        XCTAssertTrue(healthy)
    }

    func testIsHealthyReturnsFalseOnError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(503, json: ["status": "unavailable"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let healthy = await admin.isHealthy()
        XCTAssertFalse(healthy)
    }

    func testIsHealthyReturnsFalseOnNetworkError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let healthy = await admin.isHealthy()
        XCTAssertFalse(healthy)
    }
}

// MARK: - AdminClient Authentication Tests

final class AdminClientAuthTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testAuthTokenIncludedInRequest() async throws {
        MockURLProtocol.requestHandler = { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(authHeader, "Bearer my-secret-token")
            return jsonResponse(200, json: [Any]())
        }

        let admin = AdminClient(
            baseURL: URL(string: "http://localhost:9094")!,
            authToken: "my-secret-token",
            session: makeMockSession()
        )
        _ = try await admin.listTopics()
    }

    func testNoAuthTokenOmitsHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertNil(authHeader)
            return jsonResponse(200, json: [Any]())
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        _ = try await admin.listTopics()
    }

    func testUnauthorizedResponseThrowsAuthError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(401, json: ["error": "Unauthorized"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.listTopics()
            XCTFail("Expected authentication error")
        } catch let error as StreamlineError {
            if case .authenticationFailed(let msg) = error {
                XCTAssertTrue(msg.contains("Unauthorized"))
            } else {
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - AdminClient Error Response Tests

final class AdminClientErrorResponseTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testNotFoundResponseThrowsTopicNotFound() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(404, json: ["error": "not found"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.describeTopic(name: "missing")
            XCTFail("Expected topicNotFound error")
        } catch let error as StreamlineError {
            if case .topicNotFound = error {
                // Expected
            } else {
                XCTFail("Expected topicNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServerErrorThrowsAdminOperationFailed() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(500, json: ["error": "internal"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.serverInfo()
            XCTFail("Expected adminOperationFailed error")
        } catch let error as StreamlineError {
            if case .adminOperationFailed(let msg) = error {
                XCTAssertTrue(msg.contains("500"))
            } else {
                XCTFail("Expected adminOperationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkErrorThrowsAdminOperationFailed() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.listTopics()
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            if case .adminOperationFailed(let msg) = error {
                XCTAssertTrue(msg.contains("Request failed"))
            } else {
                XCTFail("Expected adminOperationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBadGatewayResponseThrowsAdminError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(502, json: ["error": "bad gateway"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.listConsumerGroups()
            XCTFail("Expected adminOperationFailed error")
        } catch let error as StreamlineError {
            if case .adminOperationFailed(let msg) = error {
                XCTAssertTrue(msg.contains("502"))
            } else {
                XCTFail("Expected adminOperationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - SchemaRegistryClient Mock Tests

final class SchemaRegistryClientMockTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testRegisterSchemaReturnsId() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("/subjects/orders-value/versions"))
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["schemaType"] as? String, "JSON")
            XCTAssertNotNil(body["schema"])
            return jsonResponse(200, json: ["id": 42])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let id = try await registry.registerSchema(
            subject: "orders-value",
            schema: #"{"type":"object"}"#,
            format: .json
        )
        XCTAssertEqual(id, 42)
    }

    func testGetSchemaByVersion() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "id": 1,
                "subject": "orders-value",
                "version": 1,
                "schemaType": "JSON",
                "schema": #"{"type":"object"}"#,
            ])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let info = try await registry.getSchema(subject: "orders-value", version: 1)
        XCTAssertEqual(info.id, 1)
        XCTAssertEqual(info.subject, "orders-value")
        XCTAssertEqual(info.version, 1)
        XCTAssertEqual(info.format, .json)
    }

    func testGetSchemaByVersionCaches() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return jsonResponse(200, json: [
                "id": 1,
                "subject": "orders-value",
                "version": 1,
                "schemaType": "JSON",
                "schema": "{}",
            ])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        _ = try await registry.getSchema(subject: "orders-value", version: 1)
        _ = try await registry.getSchema(subject: "orders-value", version: 1)
        // Second call should use cache
        XCTAssertEqual(requestCount, 1)
    }

    func testGetLatestSchema() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "id": 5,
                "subject": "events-value",
                "version": 3,
                "schema_type": "AVRO",
                "schema": #"{"type":"string"}"#,
            ])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let info = try await registry.getLatestSchema(subject: "events-value")
        XCTAssertEqual(info.id, 5)
        XCTAssertEqual(info.version, 3)
        XCTAssertEqual(info.format, .avro)
    }

    func testListSubjects() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["events-value", "orders-value", "users-key"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let subjects = try await registry.listSubjects()
        XCTAssertEqual(subjects, ["events-value", "orders-value", "users-key"])
    }

    func testListVersions() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [1, 2, 3])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let versions = try await registry.listVersions(subject: "events-value")
        XCTAssertEqual(versions, [1, 2, 3])
    }

    func testCheckCompatibility() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["is_compatible": true])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let compatible = try await registry.checkCompatibility(
            subject: "events-value",
            schema: #"{"type":"string"}"#,
            format: .json
        )
        XCTAssertTrue(compatible)
    }

    func testCheckCompatibilityReturnsFalse() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["is_compatible": false])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let compatible = try await registry.checkCompatibility(
            subject: "events-value",
            schema: #"{"type":"int"}"#
        )
        XCTAssertFalse(compatible)
    }

    func testGetCompatibilityLevel() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["compatibilityLevel": "BACKWARD"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        let level = try await registry.getCompatibilityLevel(subject: "events-value")
        XCTAssertEqual(level, .backward)
    }

    func testSetCompatibilityLevel() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["compatibility"] as? String, "FULL")
            return jsonResponse(200, json: ["compatibility": "FULL"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        try await registry.setCompatibilityLevel(subject: "events-value", level: .full)
    }

    func testDeleteSubject() async throws {
        // First populate cache
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "id": 1,
                "subject": "events-value",
                "version": 1,
                "schemaType": "JSON",
                "schema": "{}",
            ])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        _ = try await registry.getSchema(subject: "events-value", version: 1)
        let countBefore = await registry.cacheCount
        XCTAssertEqual(countBefore, 1)

        // Now delete
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return jsonResponse(200, json: [1])
        }
        try await registry.deleteSubject(subject: "events-value")

        let countAfter = await registry.cacheCount
        XCTAssertEqual(countAfter, 0)
    }

    func testClearCache() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "id": 1,
                "subject": "s",
                "version": 1,
                "schemaType": "JSON",
                "schema": "{}",
            ])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        _ = try await registry.getSchema(subject: "s", version: 1)
        let countAfterFetch = await registry.cacheCount
        XCTAssertEqual(countAfterFetch, 1)

        await registry.clearCache()
        let countAfterClear = await registry.cacheCount
        XCTAssertEqual(countAfterClear, 0)
    }

    func testSchemaRegistryAuthHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer registry-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return jsonResponse(200, json: ["events-value"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            authToken: "registry-token",
            session: makeMockSession()
        )
        _ = try await registry.listSubjects()
    }

    func testSchemaRegistry401ThrowsAuthError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(401, json: ["error": "Unauthorized"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        do {
            _ = try await registry.listSubjects()
            XCTFail("Expected auth error")
        } catch let error as StreamlineError {
            if case .authenticationFailed = error {
                // Expected
            } else {
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSchemaRegistry404ThrowsSchemaError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(404, json: ["error": "not found"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        do {
            _ = try await registry.getSchema(subject: "missing", version: 1)
            XCTFail("Expected schema error")
        } catch let error as StreamlineError {
            if case .schemaRegistryError(let msg) = error {
                XCTAssertTrue(msg.contains("not found"))
            } else {
                XCTFail("Expected schemaRegistryError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSchemaRegistry409ThrowsIncompatibleError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(409, json: ["error": "schema incompatible"])
        }

        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!,
            session: makeMockSession()
        )
        do {
            _ = try await registry.registerSchema(subject: "events-value", schema: "{}", format: .json)
            XCTFail("Expected schema error")
        } catch let error as StreamlineError {
            if case .schemaRegistryError(let msg) = error {
                XCTAssertTrue(msg.contains("Incompatible"))
            } else {
                XCTFail("Expected schemaRegistryError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Cluster Info Tests

    func testClusterInfoReturnsClusterDetails() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/cluster"))
            return jsonResponse(200, json: [
                "cluster_id": "cluster-abc",
                "broker_id": 1,
                "brokers": [
                    ["id": 1, "host": "broker-1", "port": 9092, "rack": "us-east-1a"],
                    ["id": 2, "host": "broker-2", "port": 9092],
                ],
                "controller": 1,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let info = try await admin.clusterInfo()

        XCTAssertEqual(info.clusterId, "cluster-abc")
        XCTAssertEqual(info.brokerId, 1)
        XCTAssertEqual(info.brokers.count, 2)
        XCTAssertEqual(info.brokers[0].host, "broker-1")
        XCTAssertEqual(info.brokers[0].rack, "us-east-1a")
        XCTAssertNil(info.brokers[1].rack)
        XCTAssertEqual(info.controller, 1)
    }

    func testListBrokersDelegatesToClusterInfo() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "cluster_id": "c1", "broker_id": 0,
                "brokers": [["id": 1, "host": "h1", "port": 9092]],
                "controller": 1,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let brokers = try await admin.listBrokers()
        XCTAssertEqual(brokers.count, 1)
        XCTAssertEqual(brokers[0].host, "h1")
    }

    func testClusterInfoUnauthorized() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(401, json: ["error": "unauthorized"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.clusterInfo()
            XCTFail("Expected auth error")
        } catch let error as StreamlineError {
            if case .authenticationFailed = error {
                // expected
            } else {
                XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Consumer Group Lag Tests

    func testConsumerGroupLagReturnsLagDetails() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/consumer-groups/my-group/lag"))
            return jsonResponse(200, json: [
                "group_id": "my-group",
                "partitions": [
                    ["topic": "events", "partition": 0, "current_offset": 50, "end_offset": 100, "lag": 50],
                    ["topic": "events", "partition": 1, "current_offset": 80, "end_offset": 100, "lag": 20],
                ],
                "total_lag": 70,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let lag = try await admin.consumerGroupLag(groupId: "my-group")

        XCTAssertEqual(lag.groupId, "my-group")
        XCTAssertEqual(lag.partitions.count, 2)
        XCTAssertEqual(lag.partitions[0].lag, 50)
        XCTAssertEqual(lag.partitions[1].lag, 20)
        XCTAssertEqual(lag.totalLag, 70)
    }

    func testConsumerGroupTopicLagReturnsScopedLag() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/lag/events"))
            return jsonResponse(200, json: [
                "group_id": "my-group",
                "partitions": [
                    ["topic": "events", "partition": 0, "current_offset": 90, "end_offset": 100, "lag": 10],
                ],
                "total_lag": 10,
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let lag = try await admin.consumerGroupTopicLag(groupId: "my-group", topic: "events")

        XCTAssertEqual(lag.partitions.count, 1)
        XCTAssertEqual(lag.partitions[0].topic, "events")
        XCTAssertEqual(lag.totalLag, 10)
    }

    func testConsumerGroupLagNotFound() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(404, json: ["error": "not found"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.consumerGroupLag(groupId: "nonexistent")
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            if case .topicNotFound = error {
                // expected (404 maps to topicNotFound)
            } else {
                XCTFail("Expected topicNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Reset Offsets Tests

    func testResetOffsetsDryRunReturnsProjectedChanges() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("reset-offsets/dry-run"))
            XCTAssertEqual(request.httpMethod, "POST")
            return jsonResponse(200, json: [
                ["topic": "events", "partition": 0, "current_offset": 100, "end_offset": 100, "lag": 0],
                ["topic": "events", "partition": 1, "current_offset": 50, "end_offset": 100, "lag": 50],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let result = try await admin.resetOffsetsDryRun(groupId: "my-group", topic: "events", strategy: "earliest")

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].lag, 0)
        XCTAssertEqual(result[1].lag, 50)
    }

    func testResetOffsetsSendsPostRequest() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("reset-offsets"))
            XCTAssertFalse(request.url!.path.contains("dry-run"))
            XCTAssertEqual(request.httpMethod, "POST")
            return jsonResponse(200, json: [:] as [String: Any])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        try await admin.resetOffsets(groupId: "my-group", topic: "events", strategy: "latest")
    }

    // MARK: - Message Inspection Tests

    func testInspectMessagesReturnsMessagesWithHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/v1/inspect/events"))
            let query = request.url!.query ?? ""
            XCTAssertTrue(query.contains("partition=0"))
            XCTAssertTrue(query.contains("limit=5"))
            return jsonResponse(200, json: [
                ["offset": 0, "key": "k1", "value": "v1", "timestamp": 1000, "partition": 0, "headers": ["source": "test"]],
                ["offset": 1, "value": "v2", "timestamp": 1001, "partition": 0, "headers": [:] as [String: String]],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let messages = try await admin.inspectMessages(topic: "events", partition: 0, limit: 5)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].key, "k1")
        XCTAssertEqual(messages[0].value, "v1")
        XCTAssertEqual(messages[0].headers, ["source": "test"])
        XCTAssertNil(messages[1].key)
    }

    func testInspectMessagesWithOffset() async throws {
        MockURLProtocol.requestHandler = { request in
            let query = request.url!.query ?? ""
            XCTAssertTrue(query.contains("offset=100"))
            return jsonResponse(200, json: [] as [Any])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let messages = try await admin.inspectMessages(topic: "events", offset: 100)
        XCTAssertEqual(messages.count, 0)
    }

    func testLatestMessagesReturnsRecentMessages() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/latest"))
            let query = request.url!.query ?? ""
            XCTAssertTrue(query.contains("count=3"))
            return jsonResponse(200, json: [
                ["offset": 97, "value": "msg1", "timestamp": 3000, "partition": 0, "headers": [:] as [String: String]],
                ["offset": 98, "value": "msg2", "timestamp": 3001, "partition": 0, "headers": [:] as [String: String]],
                ["offset": 99, "value": "msg3", "timestamp": 3002, "partition": 0, "headers": [:] as [String: String]],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let messages = try await admin.latestMessages(topic: "events", count: 3)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].offset, 97)
        XCTAssertEqual(messages[2].value, "msg3")
    }

    func testInspectMessagesServerError() async {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(500, json: ["error": "internal"])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        do {
            _ = try await admin.inspectMessages(topic: "events")
            XCTFail("Expected error")
        } catch let error as StreamlineError {
            if case .adminOperationFailed = error {
                // expected
            } else {
                XCTFail("Expected adminOperationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Metrics Tests

    func testMetricsHistoryReturnsMetricPoints() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/v1/metrics/history"))
            return jsonResponse(200, json: [
                ["name": "bytes_in", "value": 1024.5, "labels": ["topic": "events"], "timestamp": 1000],
                ["name": "bytes_out", "value": 512.0, "labels": [:] as [String: String], "timestamp": 1001],
            ])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let metrics = try await admin.metricsHistory()

        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics[0].name, "bytes_in")
        XCTAssertEqual(metrics[0].value, 1024.5)
        XCTAssertEqual(metrics[0].labels, ["topic": "events"])
        XCTAssertEqual(metrics[1].value, 512.0)
    }

    func testMetricsHistoryEmptyResponse() async throws {
        MockURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [] as [Any])
        }

        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, session: makeMockSession())
        let metrics = try await admin.metricsHistory()
        XCTAssertEqual(metrics.count, 0)
    }
}
