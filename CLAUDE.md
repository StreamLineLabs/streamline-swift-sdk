# CLAUDE.md — Streamline Swift SDK

## Overview

Swift client SDK for the Streamline streaming platform. Provides a WebSocket-based client for producing and consuming messages with auto-reconnect and offline buffering.

## Build & Test

```bash
swift build
swift test
```

## Project Structure

```
Sources/StreamlineSDK/
  StreamlineClient.swift   # Main client with WebSocket, reconnect, offline queue
  Models.swift             # StreamlineMessage, TopicInfo, ConsumerGroup, errors
  Configuration.swift      # StreamlineConfiguration options
Tests/
  StreamlineClientTests.swift
```

## Architecture

- **StreamlineClient** connects via `URLSessionWebSocketTask` (Foundation, no external deps).
- Connection state is exposed as a `ConnectionState` enum and reported via `StreamlineClientDelegate`.
- Disconnected produce calls are buffered in an offline queue (max 1000 messages) and drained on reconnect.
- Reconnection uses exponential backoff capped at `maxBackoff`.

## Conventions

- All public model types conform to `Sendable` and `Equatable`.
- Thread-safety via `NSLock` for shared mutable state.
- No third-party dependencies — uses only Foundation.
- Follows Swift API Design Guidelines for naming.
