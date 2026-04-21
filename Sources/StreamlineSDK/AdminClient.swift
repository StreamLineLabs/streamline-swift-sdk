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
    private let session: URLSession

    // MARK: - Init

    public init(baseURL: URL, authToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.authToken = authToken
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
        try TopicNameValidator.validate(name)
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
        try TopicNameValidator.validate(name)
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

    // MARK: - Cluster Operations

    /// Get cluster overview including broker list and controller info.
    public func clusterInfo() async throws -> ClusterInfo {
        let data = try await request(.get, path: "/v1/cluster")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected cluster info object")
        }
        let brokersArray = dict["brokers"] as? [[String: Any]] ?? []
        let brokers = brokersArray.map { b in
            BrokerInfo(
                id: b["id"] as? Int ?? 0,
                host: b["host"] as? String ?? "",
                port: b["port"] as? Int ?? 9092,
                rack: b["rack"] as? String
            )
        }
        return ClusterInfo(
            clusterId: dict["cluster_id"] as? String ?? "",
            brokerId: dict["broker_id"] as? Int ?? 0,
            brokers: brokers,
            controller: dict["controller"] as? Int ?? -1
        )
    }

    /// List all brokers in the cluster.
    public func listBrokers() async throws -> [BrokerInfo] {
        return try await clusterInfo().brokers
    }

    // MARK: - Consumer Group Lag

    /// Get consumer lag for a specific consumer group.
    public func consumerGroupLag(groupId: String) async throws -> ConsumerGroupLag {
        let data = try await request(.get, path: "/v1/consumer-groups/\(groupId)/lag")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected consumer lag object")
        }
        let partitionsArray = dict["partitions"] as? [[String: Any]] ?? []
        let partitions = partitionsArray.map { p in
            ConsumerLag(
                topic: p["topic"] as? String ?? "",
                partition: p["partition"] as? Int ?? 0,
                currentOffset: p["current_offset"] as? Int64 ?? 0,
                endOffset: p["end_offset"] as? Int64 ?? 0,
                lag: p["lag"] as? Int64 ?? 0
            )
        }
        return ConsumerGroupLag(
            groupId: dict["group_id"] as? String ?? groupId,
            partitions: partitions,
            totalLag: dict["total_lag"] as? Int64 ?? partitions.reduce(0) { $0 + $1.lag }
        )
    }

    /// Get consumer lag for a specific topic within a consumer group.
    public func consumerGroupTopicLag(groupId: String, topic: String) async throws -> ConsumerGroupLag {
        let data = try await request(.get, path: "/v1/consumer-groups/\(groupId)/lag/\(topic)")
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamlineError.serializationError("Expected consumer lag object")
        }
        let partitionsArray = dict["partitions"] as? [[String: Any]] ?? []
        let partitions = partitionsArray.map { p in
            ConsumerLag(
                topic: p["topic"] as? String ?? topic,
                partition: p["partition"] as? Int ?? 0,
                currentOffset: p["current_offset"] as? Int64 ?? 0,
                endOffset: p["end_offset"] as? Int64 ?? 0,
                lag: p["lag"] as? Int64 ?? 0
            )
        }
        return ConsumerGroupLag(
            groupId: dict["group_id"] as? String ?? groupId,
            partitions: partitions,
            totalLag: dict["total_lag"] as? Int64 ?? partitions.reduce(0) { $0 + $1.lag }
        )
    }

    /// Reset consumer group offsets (dry run — returns what would change).
    public func resetOffsetsDryRun(groupId: String, topic: String, strategy: String = "earliest") async throws -> [ConsumerLag] {
        let body = try JSONSerialization.data(withJSONObject: ["topic": topic, "strategy": strategy])
        let data = try await request(.post, path: "/v1/consumer-groups/\(groupId)/reset-offsets/dry-run", body: body)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of consumer lag entries")
        }
        return array.map { p in
            ConsumerLag(
                topic: p["topic"] as? String ?? topic,
                partition: p["partition"] as? Int ?? 0,
                currentOffset: p["current_offset"] as? Int64 ?? 0,
                endOffset: p["end_offset"] as? Int64 ?? 0,
                lag: p["lag"] as? Int64 ?? 0
            )
        }
    }

    /// Reset consumer group offsets (executes the reset).
    public func resetOffsets(groupId: String, topic: String, strategy: String = "earliest") async throws {
        let body = try JSONSerialization.data(withJSONObject: ["topic": topic, "strategy": strategy])
        _ = try await request(.post, path: "/v1/consumer-groups/\(groupId)/reset-offsets", body: body)
    }

    // MARK: - Message Inspection

    /// Browse messages from a topic partition.
    public func inspectMessages(topic: String, partition: Int = 0, offset: Int64? = nil, limit: Int = 20) async throws -> [InspectedMessage] {
        var params = "?partition=\(partition)&limit=\(limit)"
        if let offset { params += "&offset=\(offset)" }
        let data = try await request(.get, path: "/v1/inspect/\(topic)\(params)")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of messages")
        }
        return array.map { m in
            InspectedMessage(
                offset: m["offset"] as? Int64 ?? 0,
                key: m["key"] as? String,
                value: m["value"] as? String ?? "",
                timestamp: m["timestamp"] as? Int64 ?? 0,
                partition: m["partition"] as? Int ?? partition,
                headers: m["headers"] as? [String: String] ?? [:]
            )
        }
    }

    /// Get the latest messages from a topic.
    public func latestMessages(topic: String, count: Int = 10) async throws -> [InspectedMessage] {
        let data = try await request(.get, path: "/v1/inspect/\(topic)/latest?count=\(count)")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of messages")
        }
        return array.map { m in
            InspectedMessage(
                offset: m["offset"] as? Int64 ?? 0,
                key: m["key"] as? String,
                value: m["value"] as? String ?? "",
                timestamp: m["timestamp"] as? Int64 ?? 0,
                partition: m["partition"] as? Int ?? 0,
                headers: m["headers"] as? [String: String] ?? [:]
            )
        }
    }

    // MARK: - Metrics

    /// Get metrics history from the server.
    public func metricsHistory() async throws -> [MetricPoint] {
        let data = try await request(.get, path: "/v1/metrics/history")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw StreamlineError.serializationError("Expected array of metrics")
        }
        return array.map { m in
            MetricPoint(
                name: m["name"] as? String ?? "",
                value: m["value"] as? Double ?? 0,
                labels: m["labels"] as? [String: String] ?? [:],
                timestamp: m["timestamp"] as? Int64 ?? 0
            )
        }
    }

    // MARK: - Internal HTTP

    // MARK: - Search

    /// Searches a topic using semantic search via the HTTP API.
    ///
    /// - Parameters:
    ///   - topic: Topic to search.
    ///   - query: Free-text search query.
    ///   - k: Maximum number of results (default 10).
    /// - Returns: Array of search results ordered by descending score.
    public func search(topic: String, query: String, k: Int = 10) async throws -> [SearchResult] {
        let payload: [String: Any] = ["query": query, "k": k]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(.post, path: "/api/v1/topics/\(topic)/search", body: bodyData)

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = dict["hits"] as? [[String: Any]] else {
            return []
        }

        return hits.map { h in
            SearchResult(
                partition: h["partition"] as? Int ?? 0,
                offset: h["offset"] as? Int64 ?? 0,
                score: h["score"] as? Double ?? 0.0,
                value: h["value"] as? String
            )
        }
    }

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
