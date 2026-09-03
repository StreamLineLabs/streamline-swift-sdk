/**
 * Streamline SQL Query Example (Swift)
 *
 * Demonstrates using Streamline's embedded analytics engine (DuckDB)
 * to run SQL queries on streaming data.
 *
 * Prerequisites:
 *   - Streamline server running
 *   - Add StreamlineSDK package dependency
 *
 * Run:
 *   swift run QueryUsage
 */
import Foundation
import StreamlineSDK

@main
struct QueryUsage {
    static func main() async throws {
        let bootstrap = ProcessInfo.processInfo.environment["STREAMLINE_BOOTSTRAP"] ?? "localhost:9092"
        let httpUrl = ProcessInfo.processInfo.environment["STREAMLINE_HTTP"] ?? "http://localhost:9094"
        let websocketURL = URL(string: "ws://\(bootstrap)")!
        let adminURL = URL(string: httpUrl)!

        let client = StreamlineClient(
            configuration: StreamlineConfiguration(url: websocketURL)
        )
        let admin = AdminClient(baseURL: adminURL)
        client.connect()

        // Produce sample data
        try await admin.createTopic(name: "events", partitions: 1)
        for i in 0..<10 {
            try client.produce(
                topic: "events",
                stringValue: #"{"user":"user-\#(i)","action":"click","value":\#(i * 10)}"#
            )
        }
        print("Produced 10 events")

        // Simple SELECT
        print("\n--- All events (limit 5) ---")
        let result = try await admin.query("SELECT * FROM `events` LIMIT 5")
        print("Columns: \(result.columns)")
        print("Rows: \(result.rowCount)")
        for row in result.rows {
            print("  \(row)")
        }

        // Aggregation
        print("\n--- Count by action ---")
        let agg = try await admin.query("SELECT action, COUNT(*) as cnt FROM `events` GROUP BY action")
        for row in agg.rows {
            print("  \(row)")
        }

        // Filtered query
        print("\n--- High-value events ---")
        let filtered = try await admin.query("SELECT * FROM `events` WHERE value > 50 ORDER BY value DESC")
        print("Found \(filtered.rowCount) high-value events")
        for row in filtered.rows {
            print("  \(row)")
        }

        client.disconnect()
        print("\nDone!")
    }
}
