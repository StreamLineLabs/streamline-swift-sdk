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

- Swift 5.9 or later
- Xcode 15+ (macOS) or Swift toolchain (Linux)

## Development Setup

```bash
# Clone your fork
git clone https://github.com/<your-username>/streamline-swift-sdk.git
cd streamline-swift-sdk

# Build the project
swift build

# Run tests
swift test
```

## Code Style

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and short
- Use structured concurrency patterns (async/await)

## Running Tests

```bash
# Run all tests
swift test

# Run with verbose output
swift test --verbose

# Run with code coverage
swift test --enable-code-coverage

# Run specific test class
swift test --filter StreamlineClientTests

# Run conformance tests only
swift test --filter ConformanceTests

# Integration tests (requires running Streamline server)
docker compose -f docker-compose.test.yml up -d
swift test --filter ConformanceTests
docker compose -f docker-compose.test.yml down
```

## Pull Request Guidelines

- Write clear commit messages
- Add tests for new functionality
- Update documentation if needed
- Ensure `swift build` and `swift test` pass before submitting

## Reporting Issues

- Use the **Bug Report** or **Feature Request** issue templates
- Search existing issues before creating a new one
- Include reproduction steps for bugs

## Code of Conduct

All contributors are expected to follow our [Code of Conduct](https://github.com/streamlinelabs/.github/blob/main/CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.

