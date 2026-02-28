> ⚠️ **Community-Maintained SDK** — This SDK is in Alpha quality and maintained by the community. For production use on Apple platforms, consider using the [Streamline WASM SDK](https://github.com/streamlinelabs/streamline-wasm-sdk) for browser/WebAssembly use cases. Contributions welcome!

# Streamline Swift SDK

Swift client SDK for [Streamline](https://github.com/streamlinelabs/streamline) — *The Redis of Streaming*.

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 13+

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

## Features

- **WebSocket connection** to Streamline server
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
| `initialBackoff` | `0.5` | Initial reconnection backoff (seconds) |
| `maxBackoff` | `30` | Maximum backoff cap (seconds) |

## License

Apache-2.0
