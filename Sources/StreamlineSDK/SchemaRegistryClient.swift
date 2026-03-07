import Foundation

/// HTTP-based Schema Registry client for managing schemas.
///
/// Communicates with the Streamline Schema Registry API to register,
/// retrieve, and validate schemas. Supports Avro, Protobuf, and JSON Schema.
///
/// ```swift
/// let registry = SchemaRegistryClient(baseURL: URL(string: "http://localhost:9094")!)
/// let id = try await registry.registerSchema(subject: "orders-value", schema: schemaJSON, format: .json)
/// let schema = try await registry.getLatestSchema(subject: "orders-value")
/// let compatible = try await registry.checkCompatibility(subject: "orders-value", schema: newSchema, format: .json)
/// ```
public final class SchemaRegistryClient: @unchecked Sendable {

    // MARK: - Properties

    private let baseURL: URL
    private var authToken: String?
    private let session: URLSession

    // MARK: - Cache (TTL-based)

    private struct CacheEntry {
        let value: SchemaInfo
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var schemaByIdCache: [Int: CacheEntry] = [:]
    private var latestSchemaCache: [String: CacheEntry] = [:]
    private let cacheTtl: TimeInterval = 60 // 1 minute

    private func getCached(byId id: Int) -> SchemaInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = schemaByIdCache[id], Date() < entry.expiresAt else {
            schemaByIdCache.removeValue(forKey: id)
            return nil
        }
        return entry.value
    }

    private func getCached(bySubject subject: String) -> SchemaInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = latestSchemaCache[subject], Date() < entry.expiresAt else {
            latestSchemaCache.removeValue(forKey: subject)
            return nil
        }
        return entry.value
    }

    private func cache(_ info: SchemaInfo, subject: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let entry = CacheEntry(value: info, expiresAt: Date().addingTimeInterval(cacheTtl))
        schemaByIdCache[info.id] = entry
        if let subject { latestSchemaCache[subject] = entry }
    }

    /// Clear all cached schemas.
    public func clearCache() {
        lock.lock(); defer { lock.unlock() }
        schemaByIdCache.removeAll()
        latestSchemaCache.removeAll()
    }

    // MARK: - Init

    public init(baseURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.session = session
    }

    /// Set an authentication token for API requests.
    public func setAuthToken(_ token: String) {
        authToken = token
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
        // Invalidate latest cache for this subject on new registration
        clearCacheForSubject(subject)
        return id
    }

    private func clearCacheForSubject(_ subject: String) {
        lock.lock(); defer { lock.unlock() }
        latestSchemaCache.removeValue(forKey: subject)
    }

    /// Get the latest schema for a subject.
    public func getLatestSchema(subject: String) async throws -> SchemaInfo {
        if let cached = getCached(bySubject: subject) { return cached }
        let data = try await request(.get, path: "/subjects/\(encode(subject))/versions/latest")
        let info = try parseSchemaInfo(data)
        cache(info, subject: subject)
        return info
    }

    /// Get a specific version of a schema.
    public func getSchemaVersion(subject: String, version: Int) async throws -> SchemaInfo {
        let data = try await request(.get, path: "/subjects/\(encode(subject))/versions/\(version)")
        let info = try parseSchemaInfo(data)
        cache(info)
        return info
    }

    /// Get a schema by its global ID.
    public func getSchemaById(_ id: Int) async throws -> SchemaInfo {
        if let cached = getCached(byId: id) { return cached }
        let data = try await request(.get, path: "/schemas/ids/\(id)")
        let info = try parseSchemaInfo(data)
        cache(info)
        return info
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

    /// Check if a schema is compatible with the latest version.
    ///
    /// - Returns: `true` if the new schema is backward-compatible.
    public func checkCompatibility(subject: String, schema: String, format: SchemaFormat) async throws -> Bool {
        let body: [String: Any] = [
            "schemaType": format.rawValue,
            "schema": schema,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(.post, path: "/compatibility/subjects/\(encode(subject))/versions/latest", body: bodyData)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isCompatible = dict["is_compatible"] as? Bool else {
            throw StreamlineError.schemaRegistryError("Invalid compatibility response")
        }
        return isCompatible
    }

    /// Delete a subject and all its versions.
    ///
    /// - Returns: Array of deleted version numbers.
    public func deleteSubject(_ subject: String) async throws -> [Int] {
        let data = try await request(.delete, path: "/subjects/\(encode(subject))")
        guard let versions = try JSONSerialization.jsonObject(with: data) as? [Int] else {
            throw StreamlineError.schemaRegistryError("Expected array of deleted versions")
        }
        return versions
    }

    // MARK: - Internal

    private func parseSchemaInfo(_ data: Data) throws -> SchemaInfo {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.schemaRegistryError("Invalid schema response")
        }
        return SchemaInfo(
            subject: dict["subject"] as? String ?? "",
            id: dict["id"] as? Int ?? 0,
            version: dict["version"] as? Int ?? 0,
            schemaType: dict["schema_type"] as? String ?? dict["schemaType"] as? String ?? "",
            schema: dict["schema"] as? String ?? ""
        )
    }

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
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
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StreamlineError.schemaRegistryError("HTTP \(httpResponse.statusCode): \(body)")
        }
    }

    private func encode(_ subject: String) -> String {
        subject.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? subject
    }
}
