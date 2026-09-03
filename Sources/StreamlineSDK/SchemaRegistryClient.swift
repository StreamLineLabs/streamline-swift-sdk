import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP-based Schema Registry client for managing schemas.
///
/// Uses Swift actor isolation for thread-safe access to the schema cache
/// and internal state. Communicates with the Streamline Schema Registry API
/// to register, retrieve, and validate schemas. Supports Avro, Protobuf,
/// and JSON Schema.
///
/// ```swift
/// let registry = SchemaRegistryClient(baseURL: URL(string: "http://localhost:9094")!)
/// let id = try await registry.registerSchema(subject: "orders-value", schema: schemaJSON, format: .json)
/// let schema = try await registry.getLatestSchema(subject: "orders-value")
/// let compatible = try await registry.checkCompatibility(subject: "orders-value", schema: newSchema, format: .json)
/// ```
public actor SchemaRegistryClient {

    // MARK: - Properties

    private let baseURL: URL
    private let authToken: String?
    private let session: URLSession
    private var cache: [String: SchemaInfo] = [:]

    // MARK: - Init

    public init(baseURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.session = session
    }

    // MARK: - Cache Management

    /// Clear the entire schema cache.
    public func clearCache() {
        cache.removeAll()
    }

    /// Return a cached schema if available.
    public func cachedSchema(subject: String, version: Int) -> SchemaInfo? {
        cache[cacheKey(subject: subject, version: version)]
    }

    /// Number of entries currently in the cache.
    public var cacheCount: Int {
        cache.count
    }

    private func cacheKey(subject: String, version: Int) -> String {
        "\(subject):\(version)"
    }

    // MARK: - Schema Operations

    /// Register a new schema under the given subject.
    ///
    /// - Returns: The schema ID assigned by the registry.
    public func registerSchema(subject: String, schema: String, format: SchemaFormat) async throws -> Int {
        let body: [String: Any] = [
            "schemaType": format.rawValue,
            "schema": schema,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await request(.post, path: "/subjects/\(encode(subject))/versions", body: data)
        guard let dict = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let id = dict["id"] as? Int else {
            throw StreamlineError.schemaRegistryError("Invalid register response")
        }
        return id
    }

    /// Get a specific version of a schema (with caching).
    public func getSchema(subject: String, version: Int) async throws -> SchemaInfo {
        let key = cacheKey(subject: subject, version: version)
        if let cached = cache[key] {
            return cached
        }
        let data = try await request(.get, path: "/subjects/\(encode(subject))/versions/\(version)")
        let info = try parseSchemaInfo(data)
        cache[key] = info
        return info
    }

    /// Get the latest schema for a subject.
    public func getLatestSchema(subject: String) async throws -> SchemaInfo {
        let data = try await request(.get, path: "/subjects/\(encode(subject))/versions/latest")
        let info = try parseSchemaInfo(data)
        // Cache by version once known
        let key = cacheKey(subject: subject, version: info.version)
        cache[key] = info
        return info
    }

    /// Get a schema by its global ID.
    public func getSchemaById(_ id: Int) async throws -> SchemaInfo {
        let data = try await request(.get, path: "/schemas/ids/\(id)")
        return try parseSchemaInfo(data)
    }

    /// List all registered subjects.
    public func listSubjects() async throws -> [String] {
        let data = try await request(.get, path: "/subjects")
        guard let subjects = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw StreamlineError.schemaRegistryError("Expected array of subjects")
        }
        return subjects
    }

    /// List all versions for a subject.
    public func listVersions(subject: String) async throws -> [Int] {
        let data = try await request(.get, path: "/subjects/\(encode(subject))/versions")
        guard let versions = try JSONSerialization.jsonObject(with: data) as? [Int] else {
            throw StreamlineError.schemaRegistryError("Expected array of version numbers")
        }
        return versions
    }

    /// Delete a subject and all its versions.
    public func deleteSubject(subject: String) async throws {
        _ = try await request(.delete, path: "/subjects/\(encode(subject))")
        // Evict cached entries for this subject
        cache = cache.filter { !$0.key.hasPrefix("\(subject):") }
    }

    // MARK: - Compatibility

    /// Check if a schema is compatible with the latest version.
    ///
    /// - Returns: `true` if the new schema is backward-compatible.
    public func checkCompatibility(subject: String, schema: String, format: SchemaFormat = .json) async throws -> Bool {
        let body: [String: Any] = [
            "schemaType": format.rawValue,
            "schema": schema,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(
            .post,
            path: "/compatibility/subjects/\(encode(subject))/versions/latest",
            body: bodyData
        )
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isCompatible = dict["is_compatible"] as? Bool else {
            throw StreamlineError.schemaRegistryError("Invalid compatibility response")
        }
        return isCompatible
    }

    /// Get the compatibility level for a subject.
    public func getCompatibilityLevel(subject: String) async throws -> CompatibilityLevel {
        let data = try await request(.get, path: "/config/\(encode(subject))")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let levelStr = dict["compatibilityLevel"] as? String ?? dict["compatibility"] as? String,
              let level = CompatibilityLevel(rawValue: levelStr) else {
            throw StreamlineError.schemaRegistryError("Invalid compatibility level response")
        }
        return level
    }

    /// Set the compatibility level for a subject.
    public func setCompatibilityLevel(subject: String, level: CompatibilityLevel) async throws {
        let body: [String: Any] = ["compatibility": level.rawValue]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(.put, path: "/config/\(encode(subject))", body: bodyData)
    }

    // MARK: - Internal

    private func parseSchemaInfo(_ data: Data) throws -> SchemaInfo {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.schemaRegistryError("Invalid schema response")
        }
        let typeStr = dict["schema_type"] as? String ?? dict["schemaType"] as? String ?? ""
        guard let format = SchemaFormat(rawValue: typeStr) else {
            throw StreamlineError.schemaRegistryError("Unknown schema format: \(typeStr)")
        }
        return SchemaInfo(
            id: dict["id"] as? Int ?? 0,
            subject: dict["subject"] as? String ?? "",
            version: dict["version"] as? Int ?? 0,
            format: format,
            schema: dict["schema"] as? String ?? ""
        )
    }

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    private func request(_ method: HTTPMethod, path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw StreamlineError.schemaRegistryError("Invalid URL: \(path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StreamlineError.schemaRegistryError("Request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamlineError.schemaRegistryError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StreamlineError.authenticationFailed("Unauthorized: \(body)")
        case 404:
            throw StreamlineError.schemaRegistryError("Subject not found")
        case 409:
            throw StreamlineError.schemaRegistryError("Incompatible schema")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StreamlineError.schemaRegistryError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func encode(_ subject: String) -> String {
        URLPathSegmentEncoder.encode(subject)
    }
}
