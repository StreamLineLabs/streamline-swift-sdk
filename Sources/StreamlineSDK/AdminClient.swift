import Foundation

/// HTTP-based admin client for managing Streamline server resources.
///
/// Unlike ``StreamlineClient`` which uses WebSocket for real-time messaging,
/// the admin client communicates via the HTTP REST API (default port 9094)
/// for topic management, consumer group inspection, and SQL queries.
///
/// ```swift
/// let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!)
/// try await admin.createTopic(name: "events", partitions: 3)
/// let topics = try await admin.listTopics()
/// let result = try await admin.query("SELECT * FROM events LIMIT 10")
/// ```
public final class AdminClient: @unchecked Sendable {

    // MARK: - Properties

    private let baseURL: URL
    private let authToken: String?
    private let saslConfig: SaslConfig?
    private let session: URLSession

    // MARK: - Init

    public init(baseURL: URL, authToken: String? = nil, saslConfig: SaslConfig? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.saslConfig = saslConfig
        self.session = session
    }

    // MARK: - Topic Operations

    /// List all topics on the server.
    public func listTopics() async throws -> [TopicInfo] {
        let data = try await request(.get, path: "/v1/topics")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of topics")
        }
        return array.map { dict in
            TopicInfo(
                name: dict["name"] as? String ?? "",
                partitions: dict["partitions"] as? Int ?? 1,
                replicationFactor: dict["replication_factor"] as? Int ?? 1,
                messageCount: dict["message_count"] as? Int64 ?? 0
            )
        }
    }

    /// Get detailed information about a specific topic.
    public func describeTopic(name: String) async throws -> TopicDescription {
        let data = try await request(.get, path: "/v1/topics/\(name)")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected topic object")
        }
        let configDict = dict["config"] as? [String: String] ?? [:]
        return TopicDescription(
            name: dict["name"] as? String ?? name,
            partitions: dict["partitions"] as? Int ?? 1,
            replicationFactor: dict["replication_factor"] as? Int ?? 1,
            messageCount: dict["message_count"] as? Int64 ?? 0,
            config: configDict
        )
    }

    /// Create a new topic.
    public func createTopic(name: String, partitions: Int = 1, replicationFactor: Int = 1, config: [String: String] = [:]) async throws {
        var body: [String: Any] = [
            "name": name,
            "partitions": partitions,
            "replication_factor": replicationFactor,
        ]
        if !config.isEmpty {
            body["config"] = config
        }
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(.post, path: "/v1/topics", body: jsonData)
    }

    /// Delete a topic by name.
    public func deleteTopic(name: String) async throws {
        _ = try await request(.delete, path: "/v1/topics/\(name)")
    }

    // MARK: - Consumer Group Operations

    /// List all consumer groups.
    public func listConsumerGroups() async throws -> [ConsumerGroup] {
        let data = try await request(.get, path: "/v1/consumer-groups")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of consumer groups")
        }
        return array.map { dict in
            ConsumerGroup(
                id: dict["id"] as? String ?? "",
                members: dict["members"] as? [String] ?? [],
                state: dict["state"] as? String ?? "unknown"
            )
        }
    }

    /// Get detailed information about a specific consumer group.
    public func describeConsumerGroup(groupId: String) async throws -> ConsumerGroupDescription {
        let data = try await request(.get, path: "/v1/consumer-groups/\(groupId)")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected consumer group object")
        }
        let membersArray = dict["members"] as? [[String: Any]] ?? []
        let members = membersArray.map { m in
            ConsumerGroupMember(
                id: m["id"] as? String ?? "",
                clientId: m["client_id"] as? String ?? "",
                host: m["host"] as? String ?? "",
                assignments: m["assignments"] as? [String] ?? []
            )
        }
        return ConsumerGroupDescription(
            id: dict["id"] as? String ?? groupId,
            state: dict["state"] as? String ?? "unknown",
            members: members,
            protocolType: dict["protocol"] as? String ?? ""
        )
    }

    /// Delete a consumer group.
    public func deleteConsumerGroup(groupId: String) async throws {
        _ = try await request(.delete, path: "/v1/consumer-groups/\(groupId)")
    }

    // MARK: - Query Operations

    /// Execute a SQL query against the streaming data.
    ///
    /// ```swift
    /// let result = try await admin.query("SELECT * FROM events WHERE key = 'user-1' LIMIT 10")
    /// for row in result.rows { print(row) }
    /// ```
    public func query(_ sql: String) async throws -> QueryResult {
        let body = try JSONSerialization.data(withJSONObject: ["query": sql])
        let data = try await request(.post, path: "/v1/query", body: body)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.queryFailed("Invalid query response format")
        }
        let columns = dict["columns"] as? [String] ?? []
        let rows = (dict["rows"] as? [[String]]) ?? []
        let rowCount = dict["row_count"] as? Int ?? rows.count
        return QueryResult(columns: columns, rows: rows, rowCount: rowCount)
    }

    // MARK: - Server Info

    /// Get server health and version information.
    public func serverInfo() async throws -> ServerInfo {
        let data = try await request(.get, path: "/v1/info")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected server info object")
        }
        return ServerInfo(
            version: dict["version"] as? String ?? "",
            uptime: dict["uptime"] as? Int64 ?? 0,
            topicCount: dict["topic_count"] as? Int ?? 0,
            messageCount: dict["message_count"] as? Int64 ?? 0
        )
    }

    /// Check if the server is healthy.
    public func isHealthy() async -> Bool {
        do {
            _ = try await request(.get, path: "/health/live")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internal HTTP

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    private func request(_ method: HTTPMethod, path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw StreamlineError.adminOperationFailed("Invalid URL: \(path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue

        // Apply auth: bearer token takes precedence, then SASL credentials
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let sasl = saslConfig {
            let credentials = Data("\(sasl.username):\(sasl.password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue(sasl.mechanism.rawValue, forHTTPHeaderField: "X-Streamline-SASL-Mechanism")
        }

        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StreamlineError.adminOperationFailed("Request failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamlineError.adminOperationFailed("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StreamlineError.authenticationFailed("Unauthorized: \(body)")
        case 404:
            throw StreamlineError.topicNotFound(path)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StreamlineError.adminOperationFailed("HTTP \(httpResponse.statusCode): \(body)")
        }
    }
}
