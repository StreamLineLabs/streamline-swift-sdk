> ⚠️ **Community-Maintained SDK** — This SDK is in Alpha quality and maintained by the community. For production use on Apple platforms, consider using the [Streamline WASM SDK](https://github.com/streamlinelabs/streamline-wasm-sdk) for browser/WebAssembly use cases. Contributions welcome!

# Streamline Swift SDK

[![CI](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml)
[![codecov](https://img.shields.io/codecov/c/github/streamlinelabs/streamline-swift-sdk?style=flat-square)](https://codecov.io/gh/streamlinelabs/streamline-swift-sdk)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org/)
[![Docs](https://img.shields.io/badge/docs-streamlinelabs.dev-blue.svg)](https://streamlinelabs.dev/docs/sdks/swift)

Swift client SDK for [Streamline](https://github.com/streamlinelabs/streamline) — *The Redis of Streaming*.

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 13+
- Streamline server 0.2.0 or later

## Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/streamlinelabs/streamline-swift-sdk.git", from: "0.2.0"),
]
```

## Quick Start

```swift
import StreamlineSDK

let config = StreamlineConfiguration(
    url: URL(string: "ws://localhost:9092")!,
    authToken: "my-token"
)

let client = StreamlineClient(configuration: config)
client.connect()

// Produce a message
try client.produce(topic: "events", key: "user-1", stringValue: "{\"action\":\"click\"}")

// Subscribe to a topic
client.subscribe(topic: "events") { message in
    print("Received: \(String(data: message.value, encoding: .utf8) ?? "")")
}

// Disconnect when done
client.disconnect()
```

## Admin Client

The `AdminClient` communicates with the Streamline HTTP REST API (port 9094) for topic management, consumer group inspection, and SQL queries.

```swift
let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!, authToken: "my-token")

// Topic management
try await admin.createTopic(name: "events", partitions: 3)
let topics = try await admin.listTopics()
let details = try await admin.describeTopic(name: "events")
try await admin.deleteTopic(name: "old-topic")

// Consumer groups
let groups = try await admin.listConsumerGroups()
let groupDetails = try await admin.describeConsumerGroup(groupId: "my-group")

// SQL queries
let result = try await admin.query("SELECT * FROM events LIMIT 10")
for row in result.rows { print(row) }

// Server info
let info = try await admin.serverInfo()
print("Version: \(info.version), Topics: \(info.topicCount)")
```

## AsyncStream Consumption

Consume messages using Swift's structured concurrency with `for await`:

```swift
// Stream messages as an AsyncStream
for await message in client.messages(topic: "events") {
    let value = String(data: message.value, encoding: .utf8) ?? ""
    print("Key: \(message.key ?? "nil"), Value: \(value)")
}
```

## Schema Registry

The SDK includes a full Schema Registry client:

```swift
let registry = SchemaRegistryClient(baseURL: URL(string: "http://localhost:9094")!)

// Register a schema
let id = try await registry.registerSchema(
    subject: "events-value", schema: avroJson, format: .avro
)

// Retrieve the latest schema
let schema = try await registry.getLatestSchema(subject: "events-value")
print("Version: \(schema.version), Type: \(schema.schemaType)")

// Check compatibility
let compatible = try await registry.checkCompatibility(
    subject: "events-value", schema: newSchema, format: .avro
)

// List subjects and versions
let subjects = try await registry.listSubjects()
let versions = try await registry.listVersions(subject: "events-value")
```

Supports **AVRO**, **PROTOBUF**, and **JSON** schema formats.

## Security

### TLS

```swift
let config = StreamlineConfiguration(
    url: URL(string: "wss://streamline.example.com:9092")!,
    tls: TlsConfig(enabled: true, caCertificatePath: "/etc/ssl/ca.pem")
)
```

### SASL Authentication

```swift
let config = StreamlineConfiguration(
    url: URL(string: "ws://streamline.example.com:9092")!,
    sasl: SaslConfig(mechanism: .scramSha256, username: "admin", password: "secret")
)
```

## Producer & Consumer Configuration

```swift
let config = StreamlineConfiguration(
    url: URL(string: "ws://localhost:9092")!,
    producerConfig: ProducerConfig(batchSize: 32768, compression: .lz4, acks: .all),
    consumerConfig: ConsumerConfig(groupId: "my-app", autoCommit: false, autoOffsetReset: .earliest)
)
```

## Features

- **WebSocket connection** to Streamline server
- **Admin client** — topic CRUD, consumer groups, SQL queries via HTTP REST API
- **Schema Registry** — register, retrieve, and validate schemas (Avro, Protobuf, JSON)
- **Security** — TLS encryption and SASL authentication (PLAIN, SCRAM-SHA-256/512)
- **Producer/Consumer config** — batching, compression, acknowledgments, consumer groups
- **AsyncStream consumption** — idiomatic `for await` streaming with automatic lifecycle
- **Circuit breaker** — CLOSED → OPEN → HALF_OPEN state machine protects against cascading failures
- **Retry policy** — exponential backoff with jitter for transient errors; integrates with `isRetryable` error classification
- **Structured error handling** — `StreamlineErrorCode` enum, `isRetryable` flag, and `hint` on every error case
- **Telemetry** — pluggable tracing with W3C Trace Context propagation
- **Auto-reconnect** with exponential backoff
- **Offline message queue** — messages produced while disconnected are buffered and sent on reconnect
- **Delegate pattern** for connection lifecycle events
- **Sendable-safe** types for structured concurrency

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `url` | *(required)* | WebSocket URL of the Streamline server |
| `autoReconnect` | `true` | Automatically reconnect on disconnection |
| `maxRetries` | `10` | Maximum reconnection attempts |
| `timeout` | `30` | Connection timeout in seconds |
| `authToken` | `nil` | Optional bearer token for authentication |
| `tls` | `nil` | TLS configuration (see [Security](#security)) |
| `sasl` | `nil` | SASL authentication (see [Security](#security)) |
| `producerConfig` | defaults | Producer tuning (see [Producer & Consumer Configuration](#producer--consumer-configuration)) |
| `consumerConfig` | defaults | Consumer tuning (see [Producer & Consumer Configuration](#producer--consumer-configuration)) |
| `initialBackoff` | `0.5` | Initial reconnection backoff (seconds) |
| `maxBackoff` | `30` | Maximum backoff cap (seconds) |

## Error Handling

All SDK errors are represented by the `StreamlineError` enum. Each case has a machine-readable `code` (`StreamlineErrorCode`), an `isRetryable` flag, and a human-friendly `hint`:

| Error | Code | Retryable? | Hint |
|-------|------|------------|------|
| `.notConnected` | `.connection` | Yes | Call connect() first |
| `.connectionFailed(String)` | `.connection` | Yes | Check server URL |
| `.authenticationFailed(String)` | `.authentication` | No | Verify credentials |
| `.authorizationFailed(String)` | `.authorization` | No | Check ACL permissions |
| `.timeout` | `.timeout` | Yes | Increase timeout |
| `.topicNotFound(String)` | `.topicNotFound` | No | Create topic first |
| `.serializationError(String)` | `.serialization` | No | Verify message format |
| `.offlineQueueFull` | `.offlineQueueFull` | No | Reduce send rate |
| `.circuitBreakerOpen(Int)` | `.circuitBreakerOpen` | Yes | Retry after reset timeout |
| `.producerError(String)` | `.producer` | Yes | Check message size |
| `.consumerError(String)` | `.consumer` | Yes | Check group config |
| `.adminOperationFailed(String)` | `.adminOperation` | Yes | Check connectivity |
| `.queryFailed(String)` | `.query` | No | Verify SQL syntax |
| `.schemaRegistryError(String)` | `.schemaRegistry` | Yes | Check registry connectivity |

```swift
do {
    try client.produce(topic: "my-topic", key: "key", value: Data("value".utf8))
} catch let error as StreamlineError {
    if error.isRetryable {
        print("Transient error (\(error.code)): \(error) — \(error.hint)")
    } else {
        print("Fatal error: \(error) — \(error.hint)")
    }
}
```

### Circuit Breaker

The SDK wraps produce and subscribe operations in a `CircuitBreaker`. After consecutive failures exceed the threshold, the breaker opens and rejects calls immediately:

```swift
let config = StreamlineConfiguration(
    url: wsURL,
    circuitBreakerConfig: CircuitBreakerConfig(failureThreshold: 5, resetTimeout: 30),
    retryPolicyConfig: RetryPolicyConfig(maxRetries: 3, baseDelay: 0.2, jitter: true)
)
let client = StreamlineClient(configuration: config)
print("Circuit state: \(client.circuitBreaker.state)") // .closed
```

### Retry Policy

The `RetryPolicy` retries transient failures (where `isRetryable == true`) with exponential backoff and jitter:

```swift
let policy = RetryPolicy(config: .init(maxRetries: 5, baseDelay: 0.1))
let result = try await policy.execute { try await riskyOperation() }
```

## Contributing

Contributions are welcome! This is a community-maintained SDK. Please see the [organization contributing guide](https://github.com/streamlinelabs/.github/blob/main/CONTRIBUTING.md) for guidelines.

## License

Apache-2.0


