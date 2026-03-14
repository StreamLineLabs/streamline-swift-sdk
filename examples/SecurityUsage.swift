/**
 Security example for Streamline Swift SDK.

 Prerequisites:
   1. Start a Streamline server with auth enabled
   2. Set environment variables as shown below

 Run with:
   SASL_USERNAME=admin SASL_PASSWORD=admin-secret swift run SecurityUsage
   SECURITY_MODE=tls CA_PATH=certs/ca.pem swift run SecurityUsage
 */
import Foundation
import StreamlineSDK

@main
struct SecurityUsage {
    static func main() async throws {
        print("Streamline Security Examples")
        print(String(repeating: "=", count: 40))
        print()

        let mode = ProcessInfo.processInfo.environment["SECURITY_MODE"] ?? "sasl_plain"

        switch mode {
        case "scram":
            try await scramExample()
        case "tls":
            try await tlsExample()
        default:
            try await saslPlainExample()
        }

        print("Done!")
    }

    static func saslPlainExample() async throws {
        print("SASL/PLAIN Authentication")
        print(String(repeating: "-", count: 40))

        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            authToken: nil,
            sasl: SaslConfig(
                mechanism: .plain,
                username: envOr("SASL_USERNAME", fallback: "admin"),
                password: envOr("SASL_PASSWORD", fallback: "admin-secret")
            )
        )

        let client = StreamlineClient(configuration: config)
        client.connect()
        print("  Connected with SASL/PLAIN")

        try client.produce(topic: "secure-topic", stringValue: "authenticated message")
        print("  Produced message to secure-topic")

        client.disconnect()
        print("  Disconnected.\n")
    }

    static func scramExample() async throws {
        print("SASL/SCRAM-SHA-256 Authentication")
        print(String(repeating: "-", count: 40))

        let config = StreamlineConfiguration(
            url: URL(string: "ws://localhost:9092")!,
            sasl: SaslConfig(
                mechanism: .scramSha256,
                username: envOr("SASL_USERNAME", fallback: "admin"),
                password: envOr("SASL_PASSWORD", fallback: "admin-secret")
            )
        )

        let client = StreamlineClient(configuration: config)
        client.connect()
        print("  Connected with SCRAM-SHA-256")

        client.disconnect()
        print("  Disconnected.\n")
    }

    static func tlsExample() async throws {
        print("TLS Encrypted Connection")
        print(String(repeating: "-", count: 40))

        let config = StreamlineConfiguration(
            url: URL(string: "wss://localhost:9093")!,
            tls: TlsConfig(
                enabled: true,
                caCertificatePath: envOr("CA_PATH", fallback: "certs/ca.pem"),
                clientCertificatePath: ProcessInfo.processInfo.environment["CLIENT_CERT_PATH"],
                clientKeyPath: ProcessInfo.processInfo.environment["CLIENT_KEY_PATH"]
            )
        )

        let client = StreamlineClient(configuration: config)
        client.connect()
        print("  Connected with TLS")

        client.disconnect()
        print("  Disconnected.\n")
    }

    static func envOr(_ key: String, fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }
}
