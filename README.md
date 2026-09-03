> 🟡 **Beta SDK** — Validate behavior against your Streamline server version before production use. The current WebSocket transport does not provide transactions, broker acknowledgments, idempotent production, payload compression, SASL, custom CA bundles, or mutual TLS.

# Streamline Swift SDK

[![CI](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/streamlinelabs/streamline-swift-sdk/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org/)
[![Docs](https://img.shields.io/badge/docs-streamlinelabs.dev-blue.svg)](https://streamlinelabs.dev/docs/sdks/swift)

Swift client SDK for [Streamline](https://github.com/streamlinelabs/streamline) — *The Redis of Streaming*.

## Requirements

- Swift 5.9+ on Apple platforms; Swift 6.1+ on Linux
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
try config.validate()
client.connect()

// connect() is non-blocking. Messages produced while connecting are queued
// and flushed after the WebSocket open handshake succeeds.
try client.produce(topic: "events", key: "user-1", stringValue: "{\"action\":\"click\"}")

// Subscribe to a topic
client.subscribe(topic: "events") { message in
    print("Received: \(String(data: message.value, encoding: .utf8) ?? "")")
}

// Disconnect when done
client.disconnect()
```

## Transactions

Transactions are not implemented by the current WebSocket wire protocol.
The deprecated transaction methods remain source-compatible but always throw
`StreamlineError.transaction` rather than simulating atomic delivery.

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
    tls: TlsConfig(enabled: true)
)
try config.validate()
```

TLS uses `URLSession` and the platform trust store. Custom CA bundles, mutual
TLS client certificates/keys, and `insecureSkipVerify` are rejected because
the current transport does not apply them.

### Authentication

Use `authToken` for bearer-token authentication. SASL configuration types are
retained for source compatibility but rejected by `validate()` and `connect()`.

## Producer & Consumer Configuration

```swift
let config = StreamlineConfiguration(
    url: URL(string: "ws://localhost:9092")!,
    producerConfig: ProducerConfig(
        batchSize: 32768,
        lingerMs: 5,
        compression: .none,
        acks: .none
    ),
    consumerConfig: ConsumerConfig(groupId: "my-app", autoCommit: false, autoOffsetReset: .earliest)
)
try config.validate()
```

`batchSize` and `lingerMs` only buffer individual WebSocket sends on the
client. They do not create an atomic broker-side batch. Compression,
idempotence, and `.one`/`.all` acknowledgment modes fail validation. A
successful `.none` send means `URLSession` accepted the frame, not that a
broker persisted it. Retries may therefore produce duplicates.

Consumer `commitOffsets`, `position`, and `committed` currently throw
`StreamlineError.unsupported`. The WebSocket protocol has no verified durable
commit acknowledgement or authoritative offset-query response contract, and
the SDK does not substitute local bookkeeping as broker state.

## Features

- **WebSocket connection** to Streamline server
- **Admin client** — topic CRUD, consumer groups, SQL queries via HTTP REST API
- **Schema Registry** — register, retrieve, and validate schemas (Avro, Protobuf, JSON)
- **Security** — platform-default TLS via `wss://` and bearer tokens
- **Producer buffering** — size/linger-based flushing of individual sends with retry backoff
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
| `tls` | `nil` | Optional requirement for platform TLS with `wss://`; custom TLS material is rejected |
| `sasl` | `nil` | Deprecated and unsupported; non-nil values are rejected |
| `producerConfig` | defaults | Supported client-side buffering/retry settings |
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

The Swift SDK retries failed WebSocket sends with exponential backoff when
`ProducerConfig.retries > 0` (default: 3). Because broker acknowledgments and
idempotence are unavailable, a retry can duplicate a record.

```swift
let config = ProducerConfig(
    retries: 5,              // Max retry attempts
    retryBackoffMs: 200      // Base backoff (doubles each attempt)
)
let client = StreamlineClient(configuration: StreamlineConfiguration(
    url: wsURL,
    producerConfig: config
))
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

do {
    try breaker.check()
    try client.produce(topic: "events", key: "user-1", stringValue: "payload")
    breaker.recordSuccess()
} catch {
    breaker.recordFailure()
    throw error
}
```

When the circuit is open, `check()` returns `false` and operations should be skipped. See the [Circuit Breaker guide](https://streamlinelabs.dev/docs/features/circuit-breaker) for details.

## Examples

The [`examples/`](examples/) directory contains runnable examples:

| Example | Description |
|---------|-------------|
| [BasicUsage.swift](examples/BasicUsage.swift) | Produce, consume, and admin operations |
| [QueryUsage.swift](examples/QueryUsage.swift) | SQL analytics with the embedded query engine |
| [SchemaRegistryUsage.swift](examples/SchemaRegistryUsage.swift) | Schema registration and validation |
| [CircuitBreakerUsage.swift](examples/CircuitBreakerUsage.swift) | Resilient production with circuit breaker |
| [SecurityUsage.swift](examples/SecurityUsage.swift) | Bearer authentication and platform TLS |

## Moonshot Features

> ⚠️ **Experimental** — These features require Streamline server 0.3.0+ with moonshot feature flags enabled.

### Semantic Search

Query topics by meaning instead of offset. Requires a topic created with `semantic.embed=true`.

```swift
let results = try await admin.search(topic: "logs.app", query: "payment failure", k: 10)
for hit in results {
    print("[p\(hit.partition)] offset=\(hit.offset) score=\(String(format: "%.2f", hit.score))")
}
```

### Attestation Verification

Verify cryptographic provenance attestations attached to records by data contracts.

```swift
import StreamlineSDK

let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
let verifier = StreamlineVerifier(publicKey: publicKey, trustedKeyId: "producer-key")
let result = verifier.verify(message: message)
print("Verified: \(result.verified), Producer: \(result.producerId)")
```

Verification binds the signed SHA-256 digest, topic, partition, and offset to
the consumed `StreamlineMessage`. Messages without partition/offset/header
metadata fail closed.

A `key_id` in the attestation envelope is only trusted when it matches a
verification key registered up front — either the single `trustedKeyId`
passed to `init(publicKey:trustedKeyId:)`, or an entry in a keyring for
multi-producer setups:

```swift
let verifier = StreamlineVerifier(trustedKeys: [
    "producer-a": producerAPublicKey,
    "producer-b": producerBPublicKey,
])
```

The envelope's self-asserted `key_id` is never used to select or fetch a key
from an untrusted source; an unregistered `key_id` fails closed regardless of
whether some other signature would otherwise be valid.

### Agent Memory (MCP)

Use Streamline as persistent memory for AI agents via the MCP protocol.

```swift
let options = MoonshotOptions(httpURL: URL(string: "http://localhost:9094")!)
let memory = MemoryClient(options)
try await memory.remember(
    agent: "assistant",
    kind: .fact,
    text: "user prefers dark mode",
    tags: ["preferences"]
)
let results = try await memory.recall(
    agent: "assistant",
    query: "user preferences",
    k: 5
)
```

### Branched Streams

Create topic branches for replay, A/B testing, or counterfactual analysis.

```swift
let options = MoonshotOptions(httpURL: URL(string: "http://localhost:9094")!)
let branches = BranchAdminClient(options)
let branch = try await branches.createBranch(name: "experiment-v2", parent: "events")
for await msg in client.messages(topic: branch.name) {
    process(msg)
}
```

## Contributing

Contributions are welcome! This is a community-maintained SDK. Please see the [organization contributing guide](https://github.com/streamlinelabs/.github/blob/main/CONTRIBUTING.md) for guidelines.

For usage questions and compatibility help, see [SUPPORT.md](SUPPORT.md).

## License

Apache-2.0
