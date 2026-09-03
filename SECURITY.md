# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.4.x   | :white_check_mark: |
| < 0.4   | :x:                |

## Reporting a Vulnerability

Please report security vulnerabilities to **security@streamlinelabs.dev**.

**Do NOT open public issues for security vulnerabilities.**

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 5 business days
- **Fix Timeline**: Communicated after assessment

We follow responsible disclosure practices and will credit reporters (with permission) in our release notes.

## Security Best Practices

- Use `wss://` for network transport and rely on the platform trust store.
- Use `authToken` for bearer authentication.
- Do not assume `TlsConfig` custom CA/mTLS/insecure fields or `SaslConfig`
  are applied. Version 0.4.0 rejects those settings.
- Treat producer retries as potentially duplicating records; broker
  acknowledgments and idempotent production are not available.
- Verify provenance with `StreamlineVerifier`, which binds the signed payload
  digest and record identity.

For production deployments, review the [Streamline Security Documentation](https://github.com/streamlinelabs/streamline-docs).
