# Streamline Swift SDK Examples

## Prerequisites

- Swift 5.9+ / Xcode 15+
- A running Streamline 0.4.0 server. The repository fixture references:

  ```bash
  docker run -d -p 9092:9092 -p 9094:9094 ghcr.io/streamlinelabs/streamline:0.4.0
  ```

  If that manifest is unavailable or private in your environment, use an
  equivalent locally built 0.4.0 server; no registry credentials are bundled
  with this SDK.

## Examples

### Basic Usage

Demonstrates connecting, producing messages, consuming with async/await, and admin operations.

```bash
swift run BasicUsage
```

### Schema Registry

Demonstrates registering schemas (Avro/JSON), producing with schema validation, and checking compatibility.

```bash
swift run SchemaRegistryUsage
```

### SQL Queries

Demonstrates running SQL analytics queries on streaming data using the embedded DuckDB engine.

```bash
swift run QueryUsage
```

### Circuit Breaker

```bash
swift run CircuitBreakerUsage
```

### Security

Bearer token:

```bash
STREAMLINE_AUTH_TOKEN=dev-token swift run SecurityUsage
```

Platform TLS:

```bash
SECURITY_MODE=tls STREAMLINE_WSS_URL=wss://streamline.example.com:9092 swift run SecurityUsage
```

Custom CA bundles, mutual TLS, insecure certificate verification, and SASL are
not supported by the current URLSession WebSocket transport.

## Configuration

`QueryUsage` accepts `STREAMLINE_BOOTSTRAP` (host and port) and
`STREAMLINE_HTTP`. Other examples currently use the local fixture defaults.

## More Information

- [SDK Documentation](https://streamlinelabs.github.io/streamline-docs/docs/sdks/swift)
- [API Reference](https://github.com/streamlinelabs/streamline-swift-sdk#api-reference)
