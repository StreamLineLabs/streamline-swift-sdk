/**
 Security example for Streamline Swift SDK.

 Prerequisites:
   1. Start a Streamline server with auth enabled
   2. Set environment variables as shown below

 Run with:
   STREAMLINE_AUTH_TOKEN=dev-token swift run SecurityUsage
   SECURITY_MODE=tls STREAMLINE_WSS_URL=wss://localhost:9093 swift run SecurityUsage
 */
import Foundation
import StreamlineSDK

@main
struct SecurityUsage {
    static func main() async throws {
        print("Streamline Security Examples")
        print(String(repeating: "=", count: 40))
        print()

        let mode = ProcessInfo.processInfo.environment["SECURITY_MODE"] ?? "bearer"

        switch mode {
        case "tls":
            try await tlsExample()
        default:
            try await bearerTokenExample()
        }

        print("Done!")
    }

    static func bearerTokenExample() async throws {
        print("Bearer Token Authentication")
        print(String(repeating: "-", count: 40))

        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            authToken: envOr("STREAMLINE_AUTH_TOKEN", fallback: "dev-token")
        )
        try config.validate()

        let client = StreamlineClient(configuration: config)
        client.connect()
        print("  Connection initiated with a bearer token")

        try client.produce(topic: "secure-topic", stringValue: "authenticated message")
        print("  Queued message for secure-topic")

        client.disconnect()
        print("  Disconnected.\n")
    }

    static func tlsExample() async throws {
        print("Platform TLS Connection")
        print(String(repeating: "-", count: 40))

        let url = envOr("STREAMLINE_WSS_URL", fallback: "wss://localhost:9093")
        let config = StreamlineConfiguration(
            url: URL(string: url)!,
            tls: TlsConfig(enabled: true)
        )
        try config.validate()

        let client = StreamlineClient(configuration: config)
        client.connect()
        print("  WSS connection initiated with platform certificate validation")

        client.disconnect()
        print("  Disconnected.\n")
    }

    static func envOr(_ key: String, fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }
}
