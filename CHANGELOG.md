# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
