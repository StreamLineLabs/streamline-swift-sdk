# Support

## Supported Release

The supported SDK line is `0.4.x`, tested against Streamline server `0.4.0`.
Older SDK releases do not receive security or compatibility fixes.

## Getting Help

- Search existing GitHub issues before opening a new one.
- Use the bug report template for reproducible SDK defects.
- Include the SDK version, server version, platform, Swift/Xcode version,
  connection URL scheme, and a minimal reproduction.

The project does not provide a private general-support channel or guaranteed
response time.

## Security Reports

Do not report vulnerabilities in public issues. Follow
[SECURITY.md](SECURITY.md) and email `security@streamlinelabs.dev`.

## Current Transport Limitations

Version 0.4.0 supports platform TLS via `wss://` and bearer tokens. It does not
support custom CA bundles, mutual TLS, insecure certificate verification,
SASL, transactions, broker acknowledgments, idempotent production, or payload
compression. Those options fail validation rather than silently weakening
security or delivery guarantees.
