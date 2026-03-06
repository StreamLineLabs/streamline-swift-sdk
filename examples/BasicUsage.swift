/**
 Basic Streamline Swift SDK usage example.

 Prerequisites:
   1. Start a Streamline server:  streamline --playground
   2. Run with:  swift run BasicUsage (if integrated into a package)

 Demonstrates: connecting, producing, consuming, admin operations.
 */
import Foundation
import StreamlineSDK

@main
struct BasicUsage {
    static func main() async throws {
        // -- Configuration --
        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            autoReconnect: true,
            maxRetries: 5
        )

        // -- Admin Client (HTTP API) --
        let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!)

        // Create a topic
        try await admin.createTopic(name: "swift-demo", partitions: 3)
        print("✓ Created topic 'swift-demo'")

        // List topics
        let topics = try await admin.listTopics()
        print("Topics: \(topics.map { $0.name })")

        // -- Streaming Client (WebSocket) --
        let client = StreamlineClient(configuration: config)
        client.connect()
        print("✓ Connected to Streamline")

        // Produce messages
        for i in 1...5 {
            try client.produce(
                topic: "swift-demo",
                key: "user-\(i)",
                stringValue: #"{"event":"click","count":\#(i)}"#
            )
        }
        print("✓ Produced 5 messages")

        // Consume messages using AsyncStream
        print("Consuming messages:")
        var count = 0
        for await message in client.messages(topic: "swift-demo") {
            let value = String(data: message.value, encoding: .utf8) ?? ""
            print("  topic=\(message.topic) key=\(message.key ?? "nil") value=\(value)")
            count += 1
            if count >= 5 { break }
        }

        // -- SQL Query --
        let result = try await admin.query("SELECT * FROM `swift-demo` LIMIT 3")
        print("Query result: \(result.rowCount) rows, columns: \(result.columns)")

        // -- Consumer Groups --
        let groups = try await admin.listConsumerGroups()
        print("Consumer groups: \(groups.map { $0.id })")

        // -- Server Info --
        let info = try await admin.serverInfo()
        print("Server: v\(info.version), uptime=\(info.uptime)s, topics=\(info.topicCount)")

        // Cleanup
        try await admin.deleteTopic(name: "swift-demo")
        client.disconnect()
        print("✓ Done")
    }
}
