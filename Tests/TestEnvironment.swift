import Foundation
@testable import StreamlineSDK

/// Test helper that provides configuration for integration tests.
///
/// Reads connection details from environment variables set by CI or
/// `docker-compose.test.yml`. Falls back to localhost defaults.
///
/// **Usage in tests:**
/// ```swift
/// let config = TestEnvironment.configuration()
/// let client = StreamlineClient(configuration: config)
/// client.connect()
/// ```
///
/// **Running locally:**
/// ```bash
/// docker compose -f docker-compose.test.yml up -d
/// STREAMLINE_INTEGRATION=true swift test
/// ```
enum TestEnvironment {

    /// Returns `true` when a Streamline server is available for integration tests.
    static var isIntegrationEnabled: Bool {
        ProcessInfo.processInfo.environment["STREAMLINE_INTEGRATION"] == "true"
    }

    /// Kafka-protocol bootstrap address.
    static var bootstrapServers: String {
        ProcessInfo.processInfo.environment["STREAMLINE_BOOTSTRAP"] ?? "localhost:9092"
    }

    /// HTTP API base URL.
    static var httpUrl: String {
        ProcessInfo.processInfo.environment["STREAMLINE_HTTP"] ?? "http://localhost:9094"
    }

    /// WebSocket URL for SDK connections.
    static var webSocketUrl: URL {
        let host = bootstrapServers.components(separatedBy: ":").first ?? "localhost"
        let port = bootstrapServers.components(separatedBy: ":").last ?? "9092"
        return URL(string: "ws://\(host):\(port)")!
    }

    /// Creates a `StreamlineConfiguration` pointed at the test server.
    static func configuration(
        circuitBreakerConfig: CircuitBreakerConfig = CircuitBreakerConfig(),
        retryPolicyConfig: RetryPolicyConfig = RetryPolicyConfig()
    ) -> StreamlineConfiguration {
        StreamlineConfiguration(
            url: webSocketUrl,
            autoReconnect: false,
            maxRetries: 0,
            timeout: 10,
            circuitBreakerConfig: circuitBreakerConfig,
            retryPolicyConfig: retryPolicyConfig
        )
    }

    /// Waits for the server health endpoint to respond.
    /// Returns `true` if healthy, `false` on timeout.
    static func waitForServer(timeoutSeconds: Int = 15) -> Bool {
        let healthUrl = URL(string: "\(httpUrl)/health")!
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            var request = URLRequest(url: healthUrl, timeoutInterval: 2)
            request.httpMethod = "GET"

            let semaphore = DispatchSemaphore(value: 0)
            var success = false

            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    success = true
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if success { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}
