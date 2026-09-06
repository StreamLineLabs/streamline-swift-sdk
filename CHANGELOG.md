# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Security
- Bind local attestation verification to the consumed payload SHA-256, topic,
  partition, and offset.
- Bind attestation `key_id`/producer identity to an explicitly trusted
  verification key (single `trustedKeyId` or a multi-producer keyring)
  instead of trusting the envelope's self-asserted `key_id`; unregistered
  identities fail closed even with an otherwise-valid signature. The
  deprecated, source-compatible `StreamlineVerifier(publicKey:)` initializer
  (no `trustedKeyId`) is kept for callers upgrading from older versions, but
  registers no trusted identity, so it now fails closed for every
  attestation instead of resurrecting the old implicit-trust behavior.
- Reject unapplied custom TLS, mutual TLS, insecure verification, and SASL
  configuration.
- Encode user-controlled HTTP path segments and pin CI actions/fixtures.
- Synchronize reconnect task creation/cancellation with a generation counter
  and an explicit closed flag so an explicit `disconnect()` can no longer
  race against `handleDisconnection` and have a stale reconnect attempt
  resurrect a connection after the caller asked to close it.

### Fixed
- Wait for WebSocket ping readiness before reporting a connected state.
- Register and correlate offset query continuations by request ID.
- `commitOffsets` fails closed with `StreamlineError.unsupported`: the
  current WebSocket protocol has no verified commit-acknowledgement
  contract, so it no longer sends an invented request shape or claims broker
  success.
- `position(topic:partition:)`/`committed(topic:partition:)` keep their
  pre-existing, non-throwing `async -> Int64?` source shape — existing
  callers do not need to add `try`. They no longer invent a request/response
  round trip over an undefined WebSocket contract or dress up a local cache
  as broker-authoritative; `position` reports only the client's own
  non-authoritative local seek bookkeeping (or `nil`), clearly documented as
  such, and `committed` always returns `nil` (this SDK never durably commits
  offsets). New, separately named `queryPosition(topic:partition:)` /
  `queryCommitted(topic:partition:)` `async throws` APIs are added for
  callers who need an explicit failure instead: both always throw
  `StreamlineError.unsupported`.
- Batch flush and offline-queue drain no longer silently drop records on
  failure. `flushBatch()`'s per-message retries were already requeued when
  no socket was available, but a message that exhausted its retry budget (or
  whose socket disappeared mid-backoff) was previously only reported to the
  delegate and then discarded; it is now requeued into the offline buffer,
  front-of-line, for the next reconnect to redrive. `drainOfflineQueue()`
  previously re-drove buffered messages through `produce()` with `try?`,
  silently swallowing failures (e.g. an open circuit breaker) after already
  clearing the queue; failures are now collected, requeued in their original
  order, and surfaced once to the delegate instead of vanishing. Repeated
  single-message requeues (one per independently exhausted in-flight send)
  now insert after previously-requeued entries instead of always at index 0,
  preserving their relative order instead of reversing it.
- `ConsumerConfig` now has a `validate()` (wired into
  `StreamlineConfiguration.validate()`/`connect()`, matching
  `ProducerConfig.validate()`) that rejects any option implying unsupported
  consumer-group, commit, offset-reset, session, heartbeat, or max-poll
  semantics: a non-nil `groupId`, `autoCommit == true`, a non-default
  `sessionTimeoutMs`/`heartbeatIntervalMs`/`maxPollRecords`, or an
  `autoOffsetReset` other than `.latest`. None of these are wired to any real
  broker-side behavior on the current WebSocket transport (consumption is
  plain topic subscription plus local `poll(maxRecords:)`), so silently
  accepting them was misleading. The `autoCommit` default changed from
  `true` to `false` so the neutral, standalone-consumer default
  (`ConsumerConfig()`) is itself the one shape that validates.
- Fixed an Admin-client path-encoding regression test that asserted against
  the *decoded* `URL.path` instead of the encoded wire path. `URL.path`
  silently turns a percent-encoded `%2F` back into a literal `/`, so a
  safely-confined, percent-encoded path-traversal segment and an actual,
  unescaped traversal segment decode to the exact same string — the test
  could not actually tell them apart. It now asserts against
  `URLComponents.percentEncodedPath`.
- Make integration tests blocking and target live-fixture tests.
- Compile all examples as SwiftPM executable products.
- Add conditional `swift-crypto` support (`Crypto` module) so release builds
  compile on Linux/Windows/Android; Apple platforms continue to use
  `CryptoKit` unchanged.
- Pinned the `swift-crypto` dependency exactly to the reviewed and tested
  `4.5.2` release (previously a floating `1.0.0..<5.0.0` range) and aligned
  every workflow that builds this package (`ci.yml`, `integration.yml`,
  `codeql.yml`, `release.yml`) on Swift 6.1 for Linux jobs. 6.1 is a hard
  floor for Linux builds independent of swift-crypto: swift-corelibs-
  foundation's `URLSession.data(for:)` and the completion-handler overloads
  of `URLSessionWebSocketTask` that `StreamlineClient`/`AdminClient` use are
  incomplete on Linux before 6.1 (confirmed by building this package under
  `swift:5.9/5.10/6.0/6.1-jammy` — only 6.1 succeeds), and it must also be
  new enough to parse the pinned swift-crypto manifest.
  `ci.yml`'s `check`/`integration-test` jobs previously had no Swift
  toolchain setup at all for `ubuntu-latest`, which could not have built
  anything on Linux; both now set up Swift explicitly.

### Changed
- Fail closed for unsupported transactions, broker acknowledgments,
  idempotence, and payload compression.
- Document batching as client-side buffering of individual WebSocket sends.



## [0.3.0] - 2026-04-20

### Added
- `MoonshotClients.swift` — URLSession + async/await clients for the
  Streamline Moonshot HTTP control plane (port `9094`): `BranchesClient`,
  `ContractsClient`, `AttestationClient`, `SearchClient`, `MemoryClient`.
- Shared `MoonshotOptions`, `MoonshotError`, and `Codable` DTOs.

### Added
- Producer message batching with configurable `batchSize` and `lingerMs` flush timer
- Producer retry logic with exponential backoff (configurable `retries` and `retryBackoffMs`)
- Compression type metadata included in WebSocket produce messages
- `ProducerConfig` parameter on `StreamlineClient.init()` for batching/retry configuration
- Circuit breaker pattern (`CircuitBreaker`) with configurable thresholds and NSLock thread safety
- `ErrorCode` enum with `isRetryable` and `hint` computed properties on `StreamlineError`
- Consumer offset management: `commitOffsets`, `seekToOffset`, `seekToBeginning`, `seekToEnd`, `position`, `committed`
- AdminClient: cluster info via `clusterInfo()` and `listBrokers()`
- AdminClient: consumer group lag monitoring via `consumerGroupLag()` and `consumerGroupTopicLag()`
- AdminClient: offset reset via `resetOffsets()` and `resetOffsetsDryRun()`
- AdminClient: message inspection via `inspectMessages()` and `latestMessages()`
- AdminClient: server metrics via `metricsHistory()`
- Model types: `ClusterInfo`, `BrokerInfo`, `ConsumerLag`, `ConsumerGroupLag`, `InspectedMessage`, `MetricPoint`
- Server-queried `position()` and `committed()` on `StreamlineClient` (replaces local-only tracking)
- Tests for all new AdminClient methods (MockURLProtocol based)
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

- feat: implement exponential backoff for reconnection logic
- refactor: separate ConnectionManager from StreamlineClient
- docs: document Swift Package dependency setup
- fix: prevent connection timeout on high-latency networks
- chore: update Swift Package manifest for Xcode 16
