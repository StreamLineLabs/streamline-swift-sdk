# Contributing to Streamline Swift SDK

Thank you for your interest in contributing to the Streamline Swift SDK! This guide will help you get started.

## Getting Started

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Run tests and linting
5. Commit your changes (`git commit -m "Add my feature"`)
6. Push to your fork (`git push origin feature/my-feature`)
7. Open a Pull Request

## Prerequisites

- Swift 5.9 or later (macOS/Xcode; Apple's Foundation is complete at any
  supported version).
- **Linux: Swift 6.1 or later.** swift-corelibs-foundation's
  `URLSession.data(for:)` and the completion-handler overloads of
  `URLSessionWebSocketTask` that `StreamlineClient`/`AdminClient` depend on
  are incomplete before 6.1 — the package fails to compile on Linux with an
  older toolchain regardless of the `swift-crypto` dependency. This is also
  the version pinned across CI (`ci.yml`, `integration.yml`, `codeql.yml`,
  `release.yml`); see the `swift-crypto` dependency comment in `Package.swift`
  for the full reasoning.
- Xcode 15+ (macOS) or Swift 6.1+ toolchain (Linux)

## Development Setup

```bash
# Clone your fork
git clone https://github.com/<your-username>/streamline-swift-sdk.git
cd streamline-swift-sdk

# Build the project
swift build

# Run tests
swift test

# Compile every runnable example
swift build

make integration-test
```

## Code Style

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and short
- Use structured concurrency patterns (async/await)

## Pull Request Guidelines

- Write clear commit messages
- Add tests for new functionality
- Update documentation if needed
- Ensure `swift build` and `swift test` pass before submitting
- Keep the SDK version constant, release tag, and changelog entry aligned
- Do not weaken unsupported-feature validation to simulate delivery or security guarantees

## Reporting Issues

- Use the **Bug Report** or **Feature Request** issue templates
- Search existing issues before creating a new one
- Include reproduction steps for bugs
- Use [SUPPORT.md](SUPPORT.md) for usage and compatibility questions

## Code of Conduct

All contributors are expected to follow our [Code of Conduct](https://github.com/streamlinelabs/.github/blob/main/CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
