/**
 Schema Registry usage example for the Streamline Swift SDK.

 Prerequisites:
   1. Start a Streamline server with schema registry enabled:
      streamline --playground
   2. Run with:  swift run SchemaRegistryUsage

 Demonstrates: registering schemas, retrieving schemas, checking
 compatibility, and managing subjects.
 */
import Foundation
import StreamlineSDK

@main
struct SchemaRegistryUsage {
    static func main() async throws {
        let registry = SchemaRegistryClient(
            baseURL: URL(string: "http://localhost:9094")!
        )

        // -- Register an Avro schema --
        let avroSchema = """
        {
          "type": "record",
          "name": "UserEvent",
          "namespace": "io.streamline.examples",
          "fields": [
            {"name": "userId", "type": "string"},
            {"name": "action", "type": "string"},
            {"name": "timestamp", "type": "long"}
          ]
        }
        """

        let schemaId = try await registry.registerSchema(
            subject: "user-events-value",
            schema: avroSchema,
            format: .avro
        )
        print("✓ Registered schema with ID: \(schemaId)")

        // -- Retrieve the latest schema --
        let latest = try await registry.getLatestSchema(subject: "user-events-value")
        print("Latest: subject=\(latest.subject), version=\(latest.version), type=\(latest.schemaType)")

        // -- List all subjects --
        let subjects = try await registry.listSubjects()
        print("Registered subjects: \(subjects)")

        // -- List versions --
        let versions = try await registry.listVersions(subject: "user-events-value")
        print("Versions: \(versions)")

        // -- Evolve the schema (add optional field) --
        let evolvedSchema = """
        {
          "type": "record",
          "name": "UserEvent",
          "namespace": "io.streamline.examples",
          "fields": [
            {"name": "userId", "type": "string"},
            {"name": "action", "type": "string"},
            {"name": "timestamp", "type": "long"},
            {"name": "source", "type": ["null", "string"], "default": null}
          ]
        }
        """

        let compatible = try await registry.checkCompatibility(
            subject: "user-events-value",
            schema: evolvedSchema,
            format: .avro
        )
        print("Schema compatible: \(compatible)")

        if compatible {
            let newId = try await registry.registerSchema(
                subject: "user-events-value",
                schema: evolvedSchema,
                format: .avro
            )
            print("✓ Registered evolved schema with ID: \(newId)")
        }

        // -- JSON Schema example --
        let jsonSchema = #"{"type":"object","required":["orderId","amount"]}"#
        let jsonId = try await registry.registerSchema(
            subject: "orders-value",
            schema: jsonSchema,
            format: .json
        )
        print("✓ Registered JSON schema with ID: \(jsonId)")

        // Cleanup
        _ = try await registry.deleteSubject("user-events-value")
        _ = try await registry.deleteSubject("orders-value")
        print("✓ Done")
    }
}
