> 🟢 **Beta SDK** — This SDK is feature-complete with tests and CI for iOS/macOS. For browser/WebAssembly use cases, also see the [WASM SDK](https://github.com/streamlinelabs/streamline-wasm-sdk). Contributions welcome!

# Streamline Swift SDK

[![CI](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml)
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

### Cluster & Monitoring

```swift
let admin = AdminClient(baseURL: URL(string: "http://localhost:9094")!)

// Cluster overview
let cluster = try await admin.clusterInfo()
print("Cluster: \(cluster.clusterId), Brokers: \(cluster.brokers.count)")

// Consumer group lag monitoring
let lag = try await admin.consumerGroupLag(groupId: "my-group")
print("Total lag: \(lag.totalLag)")
for p in lag.partitions { print("  \(p.topic):\(p.partition) lag=\(p.lag)") }

// Message inspection
let messages = try await admin.inspectMessages(topic: "events", partition: 0, limit: 10)
for m in messages { print("offset=\(m.offset) value=\(m.value)") }

// Latest messages
let latest = try await admin.latestMessages(topic: "events", count: 5)

// Server metrics
let metrics = try await admin.metricsHistory()
for m in metrics { print("\(m.name)=\(m.value)") }

// Offset management
let dryRun = try await admin.resetOffsetsDryRun(groupId: "my-group", topic: "events")
try await admin.resetOffsets(groupId: "my-group", topic: "events")
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

All SDK errors are represented by the `StreamlineError` enum. Each case provides context about the failure:

| Error | Description | Retryable? |
|-------|-------------|------------|
| `.notConnected` | Client is not connected to the server | Yes — reconnects automatically |
| `.connectionFailed(String)` | Connection attempt failed with reason | Yes — retry with backoff |
| `.authenticationFailed(String)` | Server rejected credentials | No |
| `.timeout` | Operation timed out | Yes |
| `.topicNotFound(String)` | Requested topic does not exist | No — create the topic first |
| `.serializationError(String)` | Message encoding/decoding failed | No |
| `.offlineQueueFull` | Offline buffer capacity exceeded | No — reduce send rate |
| `.adminOperationFailed(String)` | Admin API call failed | Depends on cause |
| `.queryFailed(String)` | SQL query execution failed | Depends on cause |
| `.schemaRegistryError(String)` | Schema registry operation failed | Depends on cause |

```swift
do {
    try client.produce(topic: "my-topic", key: "key", value: Data("value".utf8))
} catch let error as StreamlineError {
    switch error {
    case .notConnected:
        print("Not connected — messages are queued offline")
    case .connectionFailed(let reason):
        print("Connection failed: \(reason)")
    case .topicNotFound(let name):
        print("Topic not found: \(name)")
    case .timeout:
        print("Operation timed out — consider increasing timeout")
    case .offlineQueueFull:
        print("Offline queue full — reduce send rate or increase queue size")
    default:
        print("Error: \(error.localizedDescription)")
    }
}
```

### Retry Strategy

The Swift SDK automatically retries failed sends with exponential backoff when `ProducerConfig.retries > 0` (default: 3). Configure retry behavior:

```swift
let config = ProducerConfig(
    retries: 5,              // Max retry attempts
    retryBackoffMs: 200      // Base backoff (doubles each attempt)
)
let client = StreamlineClient(
    configuration: StreamlineConfiguration(url: wsURL),
    producerConfig: config
)
```

## Circuit Breaker

Protect your application from cascading failures when the Streamline server is unresponsive:

```swift
import StreamlineSDK

let breaker = CircuitBreaker(config: CircuitBreakerConfig(
    failureThreshold: 5,      // Open after 5 consecutive failures
    successThreshold: 2,      // Close after 2 half-open successes
    openTimeout: 30.0         // 30s before probing
))

if breaker.check() {
    do {
        try client.produce(topic: "events", key: "user-1", stringValue: "payload")
        breaker.recordSuccess()
    } catch {
        breaker.recordFailure()
        throw error
    }
}
```

When the circuit is open, `check()` returns `false` and operations should be skipped. See the [Circuit Breaker guide](https://streamlinelabs.dev/docs/features/circuit-breaker) for details.

## Contributing

Contributions are welcome! This is a community-maintained SDK. Please see the [organization contributing guide](https://github.com/streamlinelabs/.github/blob/main/CONTRIBUTING.md) for guidelines.

## License

Apache-2.0
