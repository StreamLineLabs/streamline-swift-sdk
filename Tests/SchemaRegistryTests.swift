import Foundation
@testable import StreamlineSDK
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Mock URLProtocol

/// A custom URLProtocol that intercepts requests for testing.
final class SchemaRegistryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
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
}

// MARK: - Helpers

private let baseURL = requiredTestValue(URL(string: "http://localhost:9094"))

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SchemaRegistryURLProtocol.self]
    return URLSession(configuration: config)
}

private func jsonData(_ object: Any) -> Data {
    testJSONData(object)
}

private func httpResponse(statusCode: Int = 200) -> HTTPURLResponse {
    requiredTestValue(
        HTTPURLResponse(url: baseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    )
}

// MARK: - SchemaRegistryClient Tests

final class SchemaRegistryClientTests: XCTestCase {
    // MARK: - Registration

    func testRegisterSchemaReturnsId() async throws {
        let recorder = URLRequestRecorder()
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/subjects/orders-value/versions"))
            XCTAssertEqual(request.httpMethod, "POST")
            return (httpResponse(), jsonData(["id": 42]))
        }

        let client = SchemaRegistryClient(
            baseURL: baseURL,
            session: makeSession(),
            requestObserver: { recorder.record($0) }
        )
        let id = try await client.registerSchema(
            subject: "orders-value",
            schema: #"{"type":"object"}"#,
            format: .json
        )

        let request = try XCTUnwrap(recorder.lastRequest)
        let body = try request.decodedJSONBody(as: [String: Any].self)
        XCTAssertEqual(body["schemaType"] as? String, "JSON")
        XCTAssertEqual(body["schema"] as? String, #"{"type":"object"}"#)
        XCTAssertEqual(id, 42)
    }

    func testSubjectIsEncodedAsSinglePathSegment() async throws {
        SchemaRegistryURLProtocol.requestHandler = { request in
            let absoluteURL = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertTrue(absoluteURL.contains("/subjects/team%2Forders/versions"))
            XCTAssertFalse(absoluteURL.contains("%252F"))
            return (httpResponse(), jsonData(["id": 7]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let id = try await client.registerSchema(
            subject: "team/orders",
            schema: #"{"type":"object"}"#,
            format: .json
        )

        XCTAssertEqual(id, 7)
    }

    func testRegisterSchemaInvalidResponse() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(), jsonData(["unexpected": "data"]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.registerSchema(subject: "s", schema: "{}", format: .json)
            XCTFail("Expected error")
        } catch {
            guard case StreamlineError.schemaRegistryError = error else {
                XCTFail("Expected schemaRegistryError, got \(error)")
                return
            }
        }
    }

    // MARK: - Schema Retrieval

    func testGetSchemaByVersion() async throws {
        let responseBody: [String: Any] = [
            "id": 1, "subject": "events-value", "version": 2,
            "schemaType": "AVRO", "schema": #"{"type":"string"}"#,
        ]
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/subjects/events-value/versions/2"))
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let info = try await client.getSchema(subject: "events-value", version: 2)
        XCTAssertEqual(info.id, 1)
        XCTAssertEqual(info.subject, "events-value")
        XCTAssertEqual(info.version, 2)
        XCTAssertEqual(info.format, .avro)
        XCTAssertEqual(info.schema, #"{"type":"string"}"#)
    }

    func testGetLatestSchema() async throws {
        let responseBody: [String: Any] = [
            "id": 5, "subject": "users-value", "version": 3,
            "schema_type": "JSON", "schema": "{}",
        ]
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/versions/latest"))
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let info = try await client.getLatestSchema(subject: "users-value")
        XCTAssertEqual(info.id, 5)
        XCTAssertEqual(info.version, 3)
        XCTAssertEqual(info.format, .json)
    }

    func testGetSchemaById() async throws {
        let responseBody: [String: Any] = [
            "id": 10, "subject": "test", "version": 1,
            "schemaType": "PROTOBUF", "schema": "syntax = \"proto3\";",
        ]
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/schemas/ids/10"))
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let info = try await client.getSchemaById(10)
        XCTAssertEqual(info.id, 10)
        XCTAssertEqual(info.format, .protobuf)
    }

    // MARK: - Subject Listing

    func testListSubjects() async throws {
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/subjects"))
            XCTAssertEqual(request.httpMethod, "GET")
            return (httpResponse(), jsonData(["orders-value", "users-value", "events-key"]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let subjects = try await client.listSubjects()
        XCTAssertEqual(subjects, ["orders-value", "users-value", "events-key"])
    }

    func testListSubjectsEmpty() async throws {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(), jsonData([String]()))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let subjects = try await client.listSubjects()
        XCTAssertTrue(subjects.isEmpty)
    }

    // MARK: - Subject Deletion

    func testDeleteSubject() async throws {
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/subjects/orders-value"))
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (httpResponse(), jsonData([1, 2, 3]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        try await client.deleteSubject(subject: "orders-value")
    }

    // MARK: - Compatibility Checking

    func testCheckCompatibilityReturnsTrue() async throws {
        let recorder = URLRequestRecorder()
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(
                try XCTUnwrap(request.url).path.contains("/compatibility/subjects/orders-value/versions/latest")
            )
            XCTAssertEqual(request.httpMethod, "POST")
            return (httpResponse(), jsonData(["is_compatible": true]))
        }

        let client = SchemaRegistryClient(
            baseURL: baseURL,
            session: makeSession(),
            requestObserver: { recorder.record($0) }
        )
        let compatible = try await client.checkCompatibility(
            subject: "orders-value",
            schema: #"{"type":"object"}"#,
            format: .json
        )

        let request = try XCTUnwrap(recorder.lastRequest)
        let body = try request.decodedJSONBody(as: [String: Any].self)
        XCTAssertEqual(body["schemaType"] as? String, "JSON")
        XCTAssertEqual(body["schema"] as? String, #"{"type":"object"}"#)
        XCTAssertTrue(compatible)
    }

    func testCheckCompatibilityReturnsFalse() async throws {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(), jsonData(["is_compatible": false]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let compatible = try await client.checkCompatibility(
            subject: "orders-value",
            schema: #"{"type":"int"}"#,
            format: .avro
        )
        XCTAssertFalse(compatible)
    }

    // MARK: - Compatibility Level

    func testGetCompatibilityLevel() async throws {
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/config/orders-value"))
            XCTAssertEqual(request.httpMethod, "GET")
            return (httpResponse(), jsonData(["compatibilityLevel": "BACKWARD"]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let level = try await client.getCompatibilityLevel(subject: "orders-value")
        XCTAssertEqual(level, .backward)
    }

    func testGetCompatibilityLevelAlternateKey() async throws {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(), jsonData(["compatibility": "FULL_TRANSITIVE"]))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        let level = try await client.getCompatibilityLevel(subject: "events")
        XCTAssertEqual(level, .fullTransitive)
    }

    func testSetCompatibilityLevel() async throws {
        let recorder = URLRequestRecorder()
        SchemaRegistryURLProtocol.requestHandler = { request in
            XCTAssertTrue(try XCTUnwrap(request.url).path.contains("/config/orders-value"))
            XCTAssertEqual(request.httpMethod, "PUT")
            return (httpResponse(), jsonData(["compatibility": "FORWARD"]))
        }

        let client = SchemaRegistryClient(
            baseURL: baseURL,
            session: makeSession(),
            requestObserver: { recorder.record($0) }
        )
        try await client.setCompatibilityLevel(subject: "orders-value", level: .forward)

        let request = try XCTUnwrap(recorder.lastRequest)
        let body = try request.decodedJSONBody(as: [String: String].self)
        XCTAssertEqual(body["compatibility"], "FORWARD")
    }

    // MARK: - Cache Behavior

    func testGetSchemaCachesResult() async throws {
        var requestCount = 0
        let responseBody: [String: Any] = [
            "id": 1, "subject": "cached-topic", "version": 1,
            "schemaType": "JSON", "schema": "{}",
        ]
        SchemaRegistryURLProtocol.requestHandler = { _ in
            requestCount += 1
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())

        // First call hits the network
        let first = try await client.getSchema(subject: "cached-topic", version: 1)
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(requestCount, 1)

        // Second call returns cached value
        let second = try await client.getSchema(subject: "cached-topic", version: 1)
        XCTAssertEqual(second.id, 1)
        XCTAssertEqual(requestCount, 1) // No additional network call
    }

    func testGetLatestSchemaCachesResult() async throws {
        var requestCount = 0
        let responseBody: [String: Any] = [
            "id": 7, "subject": "latest-topic", "version": 5,
            "schemaType": "AVRO", "schema": "{}",
        ]
        SchemaRegistryURLProtocol.requestHandler = { _ in
            requestCount += 1
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())

        // getLatestSchema caches by version
        _ = try await client.getLatestSchema(subject: "latest-topic")
        XCTAssertEqual(requestCount, 1)

        // getSchema for the same version should hit cache
        let cached = try await client.getSchema(subject: "latest-topic", version: 5)
        XCTAssertEqual(cached.id, 7)
        XCTAssertEqual(requestCount, 1)
    }

    func testClearCacheRemovesEntries() async throws {
        let responseBody: [String: Any] = [
            "id": 1, "subject": "s", "version": 1,
            "schemaType": "JSON", "schema": "{}",
        ]
        var requestCount = 0
        SchemaRegistryURLProtocol.requestHandler = { _ in
            requestCount += 1
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())

        _ = try await client.getSchema(subject: "s", version: 1)
        XCTAssertEqual(requestCount, 1)
        let count = await client.cacheCount
        XCTAssertEqual(count, 1)

        await client.clearCache()
        let countAfterClear = await client.cacheCount
        XCTAssertEqual(countAfterClear, 0)

        // After clearing, next call hits network again
        _ = try await client.getSchema(subject: "s", version: 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testDeleteSubjectEvictsCache() async throws {
        let responseBody: [String: Any] = [
            "id": 1, "subject": "del-me", "version": 1,
            "schemaType": "JSON", "schema": "{}",
        ]
        var requestCount = 0
        SchemaRegistryURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.httpMethod == "DELETE" {
                return (httpResponse(), jsonData([1]))
            }
            return (httpResponse(), jsonData(responseBody))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())

        _ = try await client.getSchema(subject: "del-me", version: 1)
        let cachedBefore = await client.cachedSchema(subject: "del-me", version: 1)
        XCTAssertNotNil(cachedBefore)

        try await client.deleteSubject(subject: "del-me")
        let cachedAfter = await client.cachedSchema(subject: "del-me", version: 1)
        XCTAssertNil(cachedAfter)
    }

    // MARK: - Error Handling

    func testNotFoundError() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 404), Data())
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.getLatestSchema(subject: "nonexistent")
            XCTFail("Expected error")
        } catch {
            guard case let StreamlineError.schemaRegistryError(msg) = error else {
                XCTFail("Expected schemaRegistryError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("not found"))
        }
    }

    func testUnauthorizedError() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 401), Data("Forbidden".utf8))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.listSubjects()
            XCTFail("Expected error")
        } catch {
            guard case StreamlineError.authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got \(error)")
                return
            }
        }
    }

    func testNetworkFailureError() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.listSubjects()
            XCTFail("Expected error")
        } catch {
            guard case let StreamlineError.schemaRegistryError(msg) = error else {
                XCTFail("Expected schemaRegistryError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Request failed"))
        }
    }

    func testServerError() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 500), Data("Internal Server Error".utf8))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.registerSchema(subject: "s", schema: "{}", format: .json)
            XCTFail("Expected error")
        } catch {
            guard case let StreamlineError.schemaRegistryError(msg) = error else {
                XCTFail("Expected schemaRegistryError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("500"))
        }
    }

    func testConflictError() async {
        SchemaRegistryURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: 409), Data("Conflict".utf8))
        }

        let client = SchemaRegistryClient(baseURL: baseURL, session: makeSession())
        do {
            _ = try await client.registerSchema(subject: "s", schema: "{}", format: .json)
            XCTFail("Expected error")
        } catch {
            guard case let StreamlineError.schemaRegistryError(msg) = error else {
                XCTFail("Expected schemaRegistryError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Incompatible"))
        }
    }

    // MARK: - Auth Token

    func testAuthTokenSentInHeader() async throws {
        SchemaRegistryURLProtocol.requestHandler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(auth, "Bearer my-secret-token")
            return (httpResponse(), jsonData(["orders-value"]))
        }

        let client = SchemaRegistryClient(
            baseURL: baseURL,
            authToken: "my-secret-token",
            session: makeSession()
        )
        _ = try await client.listSubjects()
    }

    // MARK: - Client Initialization

    func testClientCreation() {
        let client = SchemaRegistryClient(baseURL: baseURL)
        XCTAssertNotNil(client)
    }

    func testClientWithAuth() {
        let client = SchemaRegistryClient(baseURL: baseURL, authToken: "token")
        XCTAssertNotNil(client)
    }
}

// MARK: - Model Tests

final class SchemaRegistryModelTests: XCTestCase {
    // MARK: - CompatibilityLevel

    func testCompatibilityLevelRawValues() {
        XCTAssertEqual(CompatibilityLevel.backward.rawValue, "BACKWARD")
        XCTAssertEqual(CompatibilityLevel.forward.rawValue, "FORWARD")
        XCTAssertEqual(CompatibilityLevel.full.rawValue, "FULL")
        XCTAssertEqual(CompatibilityLevel.none.rawValue, "NONE")
        XCTAssertEqual(CompatibilityLevel.backwardTransitive.rawValue, "BACKWARD_TRANSITIVE")
        XCTAssertEqual(CompatibilityLevel.forwardTransitive.rawValue, "FORWARD_TRANSITIVE")
        XCTAssertEqual(CompatibilityLevel.fullTransitive.rawValue, "FULL_TRANSITIVE")
    }

    func testCompatibilityLevelFromRawValue() {
        XCTAssertEqual(CompatibilityLevel(rawValue: "BACKWARD"), .backward)
        XCTAssertEqual(CompatibilityLevel(rawValue: "FULL_TRANSITIVE"), .fullTransitive)
        XCTAssertNil(CompatibilityLevel(rawValue: "INVALID"))
    }

    func testCompatibilityLevelEquality() {
        XCTAssertEqual(CompatibilityLevel.backward, CompatibilityLevel.backward)
        XCTAssertNotEqual(CompatibilityLevel.backward, CompatibilityLevel.forward)
    }

    // MARK: - SchemaFormat Codable

    func testSchemaFormatCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = SchemaFormat.avro
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SchemaFormat.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSchemaFormatAllCases() {
        let formats: [SchemaFormat] = [.avro, .json, .protobuf]
        XCTAssertEqual(formats.count, 3)
        XCTAssertEqual(SchemaFormat.avro.rawValue, "AVRO")
        XCTAssertEqual(SchemaFormat.json.rawValue, "JSON")
        XCTAssertEqual(SchemaFormat.protobuf.rawValue, "PROTOBUF")
    }

    // MARK: - SchemaInfo Codable

    func testSchemaInfoCodable() throws {
        let original = SchemaInfo(
            id: 42, subject: "orders-value", version: 3,
            format: .json, schema: #"{"type":"object"}"#
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SchemaInfo.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSchemaInfoFields() {
        let info = SchemaInfo(
            id: 10, subject: "events-key", version: 2,
            format: .protobuf, schema: "syntax = \"proto3\";"
        )
        XCTAssertEqual(info.id, 10)
        XCTAssertEqual(info.subject, "events-key")
        XCTAssertEqual(info.version, 2)
        XCTAssertEqual(info.format, .protobuf)
        XCTAssertEqual(info.schema, "syntax = \"proto3\";")
    }

    // MARK: - SchemaRegistryError Integration

    func testSchemaRegistryErrorCode() {
        let error = StreamlineError.schemaRegistryError("test")
        XCTAssertEqual(error.errorCode, .schema)
        XCTAssertFalse(error.isRetryable)
    }

    func testSchemaRegistryErrorHint() {
        let error = StreamlineError.schemaRegistryError("Subject not found")
        XCTAssertTrue(error.hint.contains("Schema registry"))
    }
}
