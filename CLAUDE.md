# CLAUDE.md — Streamline Swift SDK

## Overview

Swift client SDK for the Streamline streaming platform. Provides a WebSocket-based client for real-time messaging, an HTTP-based admin client for topic/group management, AsyncStream-based consumption, and Sendable-safe types.

## Build & Test

```bash
swift build
swift test
```

## Project Structure

```
Sources/StreamlineSDK/
  StreamlineClient.swift   # WebSocket client with reconnect, offline queue, AsyncStream consumption
  AdminClient.swift        # HTTP REST admin client (topics, groups, queries, server info)
  Models.swift             # StreamlineMessage, TopicInfo, ConsumerGroup, descriptions, errors
  Configuration.swift      # StreamlineConfiguration options
Tests/
  StreamlineClientTests.swift  # Comprehensive tests for models, config, errors, admin init
```

## Architecture

- **StreamlineClient** connects via `URLSessionWebSocketTask` (Foundation, no external deps) for real-time messaging.
- **AdminClient** uses `URLSession` HTTP calls to the REST API (port 9094) for admin operations.
- **AsyncStream consumption** via `messages(topic:)` wraps subscription callbacks into `AsyncStream<StreamlineMessage>`.
- Connection state is exposed as a `ConnectionState` enum and reported via `StreamlineClientDelegate`.
- Disconnected produce calls are buffered in an offline queue (max 1000 messages) and drained on reconnect.
- Reconnection uses exponential backoff capped at `maxBackoff`.

## Conventions

- All public model types conform to `Sendable` and `Equatable`.
- Thread-safety via `NSLock` for shared mutable state.
- No third-party dependencies — uses only Foundation.
- Admin operations use async/await (`async throws`).
- Error cases include `.adminOperationFailed` and `.queryFailed` for admin-specific failures.
- Follows Swift API Design Guidelines for naming.
