# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Added
- Producer message batching with configurable `batchSize` and `lingerMs` flush timer
- Producer retry logic with exponential backoff (configurable `retries` and `retryBackoffMs`)
- Compression type metadata included in WebSocket produce messages
- `ProducerConfig` parameter on `StreamlineClient.init()` for batching/retry configuration
- Expanded error handling documentation in README with all 10 `StreamlineError` cases
- CODEOWNERS file for review assignment

### Fixed
- fix: resolve memory leak in message buffer (2026-03-05)

### Changed
- feat: add async/await consumer API (2026-03-06)
- test: add XCTest for producer acknowledgements (2026-03-06)
- refactor: adopt Swift concurrency structured tasks (2026-03-06)

## [0.2.0] - 2026-02-28

### Added
- Swift native client with async/await support
- WebSocket-based transport layer
- Auto-reconnect with exponential backoff
- Offline message queue for connection interruptions
- Delegate-based event handling
- Sendable-safe types for structured concurrency
- iOS 15+ and macOS 13+ support
- XCTest suite with integration tests
- Batch message support
- TLS connection support
- Integration tests for message roundtrip
- Zero external dependencies

### Fixed
- Handle timeout on reconnect
- Resolve actor isolation warnings

### Changed
- Extract configuration to dedicated type

### Infrastructure
- Swift Package Manager (SPM) configuration
- Apache 2.0 license

