import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors & Options

/// Error thrown by Streamline moonshot HTTP clients.
public enum MoonshotError: Error, CustomStringConvertible {
    /// HTTP request returned a non-success status.
    case httpStatus(code: Int, body: String)
    /// Underlying transport failure (DNS, connect, TLS, etc.).
    case transport(Error)
    /// Response body could not be decoded.
    case decode(String)
    /// Caller-provided argument failed validation.
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .httpStatus(let code, let body): return "moonshot HTTP \(code): \(body)"
        case .transport(let err): return "transport error: \(err.localizedDescription)"
        case .decode(let msg): return "decode error: \(msg)"
        case .invalidArgument(let msg): return "invalid argument: \(msg)"
        }
    }
}

/// Configuration for moonshot HTTP clients.
public struct MoonshotOptions: Sendable {
    public let httpURL: URL
    public let authToken: String?
    public let session: URLSession

    public init(httpURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.httpURL = httpURL
        self.authToken = authToken
        self.session = session
    }
}

// MARK: - HTTP base

/// Internal HTTP base; not part of the public API but must be `public` so
/// subclasses (BranchAdminClient, …) can be declared public.
public class MoonshotHTTPBase: @unchecked Sendable {
    let opts: MoonshotOptions

    public init(_ opts: MoonshotOptions) {
        self.opts = opts
    }

    /// Performs an HTTP request; throws `.httpStatus` on non-2xx unless the
    /// caller passes `acceptableStatuses` (used by ContractsClient.validate).
    func request(
        method: String,
        path: String,
        body: Any? = nil,
        acceptableStatuses: Set<Int> = []
    ) async throws -> (Int, Data) {
        guard let url = URL(string: path, relativeTo: opts.httpURL) else {
            throw MoonshotError.invalidArgument("invalid request path")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = opts.authToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            do {
                let data = try JSONSerialization.data(withJSONObject: body, options: [])
                req.httpBody = data
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                throw MoonshotError.decode("encode body: \(error.localizedDescription)")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await opts.session.data(for: req)
        } catch {
            throw MoonshotError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoonshotError.transport(URLError(.badServerResponse))
        }
        let code = http.statusCode
        if !(200..<300).contains(code) && !acceptableStatuses.contains(code) {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw MoonshotError.httpStatus(code: code, body: bodyString)
        }
        return (code, data)
    }

    /// Path-segment style URL encoding (encodes "/" as %2F).
    func encode(_ s: String) -> String {
        URLPathSegmentEncoder.encode(s)
    }

    func parseObject(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoonshotError.decode("expected JSON object")
        }
        return dict
    }
}

// MARK: - M5 Branches

public struct Branch: Sendable, Equatable {
    public let name: String
    public let parent: String?
    public let createdAtMs: Int64
}

public struct MergeReport: Sendable, Equatable {
    public let merged: Int
    public let conflicts: [String]
}

public final class BranchAdminClient: MoonshotHTTPBase, @unchecked Sendable {
    public override init(_ opts: MoonshotOptions) { super.init(opts) }

    public func listBranches() async throws -> [Branch] {
        let (_, data) = try await request(method: "GET", path: "/api/v1/branches")
        let obj = try parseObject(data)
        let arr = (obj["branches"] as? [[String: Any]]) ?? []
        return arr.map(Self.toBranch)
    }

    @discardableResult
    public func createBranch(name: String, parent: String? = nil) async throws -> Branch {
        guard !name.isEmpty else { throw MoonshotError.invalidArgument("branch name required") }
        var body: [String: Any] = ["name": name]
        if let parent = parent { body["parent"] = parent }
        let (_, data) = try await request(method: "POST", path: "/api/v1/branches", body: body)
        return Self.toBranch(try parseObject(data))
    }

    public func deleteBranch(name: String) async throws {
        guard !name.isEmpty else { throw MoonshotError.invalidArgument("branch name required") }
        _ = try await request(method: "DELETE", path: "/api/v1/branches/\(encode(name))")
    }

    public func mergeBranch(source: String, target: String) async throws -> MergeReport {
        guard !source.isEmpty, !target.isEmpty else {
            throw MoonshotError.invalidArgument("source/target required")
        }
        let (_, data) = try await request(
            method: "POST",
            path: "/api/v1/branches/merge",
            body: ["source": source, "target": target]
        )
        let obj = try parseObject(data)
        let merged = (obj["merged"] as? Int) ?? Int((obj["merged"] as? NSNumber)?.intValue ?? 0)
        let conflicts = (obj["conflicts"] as? [String]) ?? []
        return MergeReport(merged: merged, conflicts: conflicts)
    }

    private static func toBranch(_ d: [String: Any]) -> Branch {
        Branch(
            name: d["name"] as? String ?? "",
            parent: d["parent"] as? String,
            createdAtMs: (d["created_at_ms"] as? NSNumber)?.int64Value
                ?? Int64((d["created_at_ms"] as? Int) ?? 0)
        )
    }
}

// MARK: - M4 Contracts

public struct ContractValidationResult: Sendable, Equatable {
    public let valid: Bool
    public let errors: [String]
    public let warnings: [String]
}

public final class ContractsClient: MoonshotHTTPBase, @unchecked Sendable {
    public override init(_ opts: MoonshotOptions) { super.init(opts) }

    @discardableResult
    public func registerContract(_ contract: [String: Any]) async throws -> [String: Any] {
        let (_, data) = try await request(method: "POST", path: "/api/v1/contracts", body: contract)
        return try parseObject(data)
    }

    public func getContract(name: String) async throws -> [String: Any] {
        guard !name.isEmpty else { throw MoonshotError.invalidArgument("contract name required") }
        let (_, data) = try await request(method: "GET", path: "/api/v1/contracts/\(encode(name))")
        return try parseObject(data)
    }

    /// Validate a payload against a contract. Status 200 (valid) and 400
    /// (invalid) both return a result; other non-2xx throws.
    public func validate(name: String, payload: Any) async throws -> ContractValidationResult {
        guard !name.isEmpty else { throw MoonshotError.invalidArgument("contract name required") }
        let body: [String: Any] = ["contract": name, "payload": payload]
        let (status, data) = try await request(
            method: "POST",
            path: "/api/v1/contracts/validate",
            body: body,
            acceptableStatuses: [400]
        )
        let obj = (try? parseObject(data)) ?? [:]
        return ContractValidationResult(
            valid: (obj["valid"] as? Bool) ?? (status == 200),
            errors: (obj["errors"] as? [String]) ?? [],
            warnings: (obj["warnings"] as? [String]) ?? []
        )
    }
}

// MARK: - M4 Attestation

public struct Attestation: Sendable, Equatable {
    public let keyId: String
    public let algorithm: String
    public let signature: String
    public let payloadHash: String
}

public final class AttestationClient: MoonshotHTTPBase, @unchecked Sendable {
    public let defaultKeyId: String
    public let defaultAlgorithm: String

    public init(_ opts: MoonshotOptions, defaultKeyId: String = "broker-0", defaultAlgorithm: String = "ed25519") {
        self.defaultKeyId = defaultKeyId
        self.defaultAlgorithm = defaultAlgorithm
        super.init(opts)
    }

    public func sign(payload: Data, keyId: String? = nil, algorithm: String? = nil) async throws -> Attestation {
        let body: [String: Any] = [
            "key_id": keyId ?? defaultKeyId,
            "algorithm": algorithm ?? defaultAlgorithm,
            "payload_b64": payload.base64EncodedString()
        ]
        let (_, data) = try await request(method: "POST", path: "/api/v1/attest/sign", body: body)
        let o = try parseObject(data)
        return Attestation(
            keyId: o["key_id"] as? String ?? keyId ?? defaultKeyId,
            algorithm: o["algorithm"] as? String ?? algorithm ?? defaultAlgorithm,
            signature: o["signature"] as? String ?? "",
            payloadHash: o["payload_hash"] as? String ?? ""
        )
    }

    public func verify(payload: Data, attestation: Attestation) async throws -> Bool {
        let body: [String: Any] = [
            "key_id": attestation.keyId,
            "algorithm": attestation.algorithm,
            "signature": attestation.signature,
            "payload_b64": payload.base64EncodedString()
        ]
        let (_, data) = try await request(method: "POST", path: "/api/v1/attest/verify", body: body)
        let o = try parseObject(data)
        return (o["valid"] as? Bool) ?? false
    }
}

// MARK: - M2 Semantic Search

public struct SearchHit: Sendable, Equatable {
    public let topic: String
    public let partition: Int
    public let offset: Int64
    public let score: Double
    public let snippet: String?
}

public final class SemanticSearchClient: MoonshotHTTPBase, @unchecked Sendable {
    public override init(_ opts: MoonshotOptions) { super.init(opts) }

    public func search(topic: String, query: String, k: Int = 10) async throws -> [SearchHit] {
        guard !topic.isEmpty else { throw MoonshotError.invalidArgument("topic required") }
        guard !query.isEmpty else { throw MoonshotError.invalidArgument("query required") }
        guard k > 0 else { throw MoonshotError.invalidArgument("k must be > 0") }
        let body: [String: Any] = ["topic": topic, "query": query, "k": k]
        let (_, data) = try await request(method: "POST", path: "/api/v1/search", body: body)
        let obj = try parseObject(data)
        let arr = (obj["hits"] as? [[String: Any]]) ?? []
        return arr.map { h in
            SearchHit(
                topic: h["topic"] as? String ?? topic,
                partition: (h["partition"] as? NSNumber)?.intValue ?? 0,
                offset: (h["offset"] as? NSNumber)?.int64Value ?? 0,
                score: (h["score"] as? NSNumber)?.doubleValue ?? 0.0,
                snippet: h["snippet"] as? String
            )
        }
    }
}

// MARK: - M1 Memory

public enum MemoryKind: String, Sendable {
    case observation
    case fact
    case procedure
}

public struct MemoryRecord: Sendable, Equatable {
    public let agent: String
    public let kind: MemoryKind
    public let text: String
    public let tags: [String]
    public let timestampMs: Int64
}

public final class MemoryClient: MoonshotHTTPBase, @unchecked Sendable {
    public override init(_ opts: MoonshotOptions) { super.init(opts) }

    public func remember(agent: String, kind: MemoryKind, text: String, tags: [String] = []) async throws {
        guard !agent.isEmpty else { throw MoonshotError.invalidArgument("agent required") }
        guard !text.isEmpty else { throw MoonshotError.invalidArgument("text required") }
        let body: [String: Any] = [
            "agent": agent,
            "kind": kind.rawValue,
            "text": text,
            "tags": tags
        ]
        _ = try await request(method: "POST", path: "/api/v1/memory", body: body)
    }

    public func recall(agent: String, query: String, k: Int = 5) async throws -> [MemoryRecord] {
        guard !agent.isEmpty else { throw MoonshotError.invalidArgument("agent required") }
        guard !query.isEmpty else { throw MoonshotError.invalidArgument("query required") }
        guard k > 0 else { throw MoonshotError.invalidArgument("k must be > 0") }
        let body: [String: Any] = ["agent": agent, "query": query, "k": k]
        let (_, data) = try await request(method: "POST", path: "/api/v1/memory/recall", body: body)
        let obj = try parseObject(data)
        let arr = (obj["memories"] as? [[String: Any]]) ?? []
        return arr.map { r in
            MemoryRecord(
                agent: r["agent"] as? String ?? agent,
                kind: MemoryKind(rawValue: r["kind"] as? String ?? "") ?? .observation,
                text: r["text"] as? String ?? "",
                tags: (r["tags"] as? [String]) ?? [],
                timestampMs: (r["timestamp_ms"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }
}
