# Streamline Swift SDK Examples

## Prerequisites

- Swift 5.9+ / Xcode 15+
- A running Streamline server (`docker run -d -p 9092:9092 -p 9094:9094 ghcr.io/streamlinelabs/streamline:latest`)

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

## Configuration

By default, examples connect to `localhost:9092`. Set `STREAMLINE_BOOTSTRAP` to override:

```bash
STREAMLINE_BOOTSTRAP=my-server:9092 swift run BasicUsage
```

## More Information

- [SDK Documentation](https://streamlinelabs.github.io/streamline-docs/docs/sdks/swift)
- [API Reference](https://github.com/streamlinelabs/streamline-swift-sdk#api-reference)
