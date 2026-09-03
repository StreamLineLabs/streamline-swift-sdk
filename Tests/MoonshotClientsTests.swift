import XCTest
@testable import StreamlineSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - URL protocol stub (local copy to avoid coupling to other test files)

final class MoonshotURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var capturedRequests: [URLRequest] = []
    static var capturedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 1024)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.capturedBodies.append(data)
        } else if let body = request.httpBody {
            Self.capturedBodies.append(body)
        }
        guard let handler = Self.requestHandler else {
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
        capturedBodies = []
    }
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MoonshotURLProtocol.self]
    return URLSession(configuration: config)
}

private func jsonResponse(_ status: Int, json: Any) -> (HTTPURLResponse, Data) {
    let url = URL(string: "http://localhost:9094")!
    let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                               headerFields: ["Content-Type": "application/json"])!
    let data = try! JSONSerialization.data(withJSONObject: json)
    return (resp, data)
}

private func opts(token: String? = nil) -> MoonshotOptions {
    MoonshotOptions(httpURL: URL(string: "http://localhost:9094")!,
                    authToken: token, session: mockSession())
}

// MARK: - Tests

final class MoonshotBranchAdminTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testListAndCreate() async throws {
        var nthRequest = 0
        MoonshotURLProtocol.requestHandler = { req in
            nthRequest += 1
            if nthRequest == 1 {
                XCTAssertEqual(req.httpMethod, "GET")
                XCTAssertTrue(req.url!.path.hasSuffix("/api/v1/branches"))
                return jsonResponse(200, json: [
                    "branches": [
                        ["name": "main", "parent": NSNull(), "created_at_ms": 1],
                        ["name": "f", "parent": "main", "created_at_ms": 2],
                    ]
                ])
            }

            XCTAssertEqual(req.httpMethod, "POST")
            return jsonResponse(201, json: ["name": "newb", "parent": "main", "created_at_ms": 99])
        }
        let admin = BranchAdminClient(opts())
        let list = try await admin.listBranches()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "main")
        XCTAssertEqual(list[1].parent, "main")
        let created = try await admin.createBranch(name: "newb", parent: "main")
        XCTAssertEqual(created.name, "newb")
        XCTAssertEqual(created.createdAtMs, 99)
    }

    func testDeleteEncodesSlashes() async throws {
        MoonshotURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            // "feature/a" should encode "/" as %2F
            XCTAssertTrue(req.url!.absoluteString.contains("feature%2Fa"))
            XCTAssertFalse(req.url!.absoluteString.contains("%252F"))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }
        let admin = BranchAdminClient(opts())
        try await admin.deleteBranch(name: "feature/a")
    }

    func testMerge() async throws {
        MoonshotURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            return jsonResponse(200, json: ["merged": 7, "conflicts": ["t"]])
        }
        let admin = BranchAdminClient(opts())
        let r = try await admin.mergeBranch(source: "f", target: "main")
        XCTAssertEqual(r.merged, 7)
        XCTAssertEqual(r.conflicts, ["t"])
    }

    func testInvalidArguments() async {
        let admin = BranchAdminClient(opts())
        do { _ = try await admin.createBranch(name: ""); XCTFail("should throw") }
        catch { /* expected */ }
        do { try await admin.deleteBranch(name: ""); XCTFail("should throw") }
        catch { /* expected */ }
    }
}

final class MoonshotContractsTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testValidValidation() async throws {
        MoonshotURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: ["valid": true, "warnings": ["w"]])
        }
        let c = ContractsClient(opts())
        let r = try await c.validate(name: "orders", payload: ["k": 1])
        XCTAssertTrue(r.valid)
        XCTAssertEqual(r.warnings, ["w"])
    }

    func testInvalidValidationStatus400() async throws {
        MoonshotURLProtocol.requestHandler = { _ in
            jsonResponse(400, json: ["valid": false, "errors": ["bad"]])
        }
        let c = ContractsClient(opts())
        let r = try await c.validate(name: "orders", payload: "x")
        XCTAssertFalse(r.valid)
        XCTAssertEqual(r.errors, ["bad"])
    }

    func testServerErrorThrows() async {
        MoonshotURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
            return (resp, Data("nope".utf8))
        }
        let c = ContractsClient(opts())
        do {
            _ = try await c.validate(name: "x", payload: 1)
            XCTFail("should throw")
        } catch let MoonshotError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRegisterAndGet() async throws {
        var n = 0
        MoonshotURLProtocol.requestHandler = { req in
            n += 1
            if n == 1 {
                return jsonResponse(200, json: ["name": "orders", "version": 1])
            }
            return jsonResponse(200, json: ["name": "orders", "version": 2])
        }
        let c = ContractsClient(opts())
        let reg = try await c.registerContract(["name": "orders"])
        XCTAssertEqual(reg["version"] as? Int, 1)
        let got = try await c.getContract(name: "orders")
        XCTAssertEqual(got["version"] as? Int, 2)
    }
}

final class MoonshotAttestationTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testSignAndVerify() async throws {
        var n = 0
        MoonshotURLProtocol.requestHandler = { req in
            n += 1
            if n == 1 {
                XCTAssertTrue(req.url!.path.hasSuffix("/api/v1/attest/sign"))
                return jsonResponse(200, json: [
                    "key_id": "k", "algorithm": "ed25519", "signature": "sig", "payload_hash": "h"
                ])
            }
            XCTAssertTrue(req.url!.path.hasSuffix("/api/v1/attest/verify"))
            return jsonResponse(200, json: ["valid": true])
        }
        let a = AttestationClient(opts(), defaultKeyId: "k")
        let payload = Data("hello".utf8)
        let att = try await a.sign(payload: payload)
        XCTAssertEqual(att.signature, "sig")
        XCTAssertEqual(att.keyId, "k")
        let valid = try await a.verify(payload: payload, attestation: att)
        XCTAssertTrue(valid)
    }
}

final class MoonshotSearchTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testSearchOK() async throws {
        MoonshotURLProtocol.requestHandler = { _ in
            jsonResponse(200, json: [
                "hits": [["topic": "t", "partition": 1, "offset": 42, "score": 0.91, "snippet": "s"]]
            ])
        }
        let s = SemanticSearchClient(opts())
        let hits = try await s.search(topic: "t", query: "q", k: 3)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].partition, 1)
        XCTAssertEqual(hits[0].offset, 42)
        XCTAssertEqual(hits[0].snippet, "s")
    }

    func testSearchInvalid() async {
        let s = SemanticSearchClient(opts())
        do { _ = try await s.search(topic: "", query: "q"); XCTFail() } catch {}
        do { _ = try await s.search(topic: "t", query: ""); XCTFail() } catch {}
        do { _ = try await s.search(topic: "t", query: "q", k: 0); XCTFail() } catch {}
    }
}

final class MoonshotMemoryTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testRememberAndRecall() async throws {
        var n = 0
        MoonshotURLProtocol.requestHandler = { req in
            n += 1
            if n == 1 {
                XCTAssertTrue(req.url!.path.hasSuffix("/api/v1/memory"))
                return jsonResponse(200, json: ["ok": true])
            }
            return jsonResponse(200, json: [
                "memories": [[
                    "agent": "a", "kind": "fact", "text": "x",
                    "tags": ["t1"], "timestamp_ms": 1
                ]]
            ])
        }
        let m = MemoryClient(opts())
        try await m.remember(agent: "a", kind: .observation, text: "saw x")
        let recs = try await m.recall(agent: "a", query: "x")
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].kind, .fact)
        XCTAssertEqual(recs[0].tags, ["t1"])
    }

    func testInvalidArgs() async {
        let m = MemoryClient(opts())
        do { try await m.remember(agent: "", kind: .fact, text: "x"); XCTFail() } catch {}
        do { try await m.remember(agent: "a", kind: .fact, text: ""); XCTFail() } catch {}
        do { _ = try await m.recall(agent: "", query: "q"); XCTFail() } catch {}
        do { _ = try await m.recall(agent: "a", query: ""); XCTFail() } catch {}
        do { _ = try await m.recall(agent: "a", query: "q", k: 0); XCTFail() } catch {}
    }
}

final class MoonshotAuthHeaderTests: XCTestCase {
    override func tearDown() { MoonshotURLProtocol.reset(); super.tearDown() }

    func testAuthorizationHeaderForwarded() async throws {
        MoonshotURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T0K3N")
            return jsonResponse(200, json: ["branches": []])
        }
        let admin = BranchAdminClient(opts(token: "T0K3N"))
        _ = try await admin.listBranches()
    }
}
