import CryptoKit
import Foundation

/// Result of an attestation verification.
public struct VerificationResult: Sendable, Equatable {
    /// Whether the Ed25519 signature was valid.
    public let verified: Bool
    /// The key_id from the attestation envelope.
    public let producerId: String
    /// Schema id (nil when zero / absent).
    public let schemaId: Int?
    /// Optional contract id.
    public let contractId: String?
    /// Attestation timestamp in epoch milliseconds.
    public let timestampMs: Int64

    /// A failed verification result.
    public static let failed = VerificationResult(
        verified: false, producerId: "", schemaId: nil,
        contractId: nil, timestampMs: 0
    )
}

/// Parsed attestation envelope from the `streamline-attest` header.
private struct AttestationEnvelope: Decodable {
    let payloadSha256: String
    let topic: String
    let partition: Int
    let offset: Int64
    let schemaId: Int
    let timestampMs: Int64
    let keyId: String
    let signature: String
    let contractId: String?

    enum CodingKeys: String, CodingKey {
        case payloadSha256 = "payload_sha256"
        case topic, partition, offset
        case schemaId = "schema_id"
        case timestampMs = "timestamp_ms"
        case keyId = "key_id"
        case signature
        case contractId = "contract_id"
    }
}

/// Verifies `streamline-attest` headers on consumed messages using a local
/// Ed25519 public key. No network calls are made.
///
/// The attestation header contains a Base64-encoded JSON envelope with an
/// Ed25519 signature over the canonical bytes:
/// `topic|partition|offset|payload_sha256|schema_id|timestamp_ms|key_id`.
///
/// Example:
/// ```swift
/// let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
/// let verifier = StreamlineVerifier(publicKey: pubKey)
///
/// let result = verifier.verify(message: msg)
/// if result.verified {
///     print("Verified from \(result.producerId)")
/// }
/// ```
public final class StreamlineVerifier: Sendable {

    /// Kafka header name carrying the attestation envelope.
    public static let attestHeader = "streamline-attest"

    private let publicKey: Curve25519.Signing.PublicKey

    /// Creates a verifier backed by the given Ed25519 public key.
    ///
    /// - Parameter publicKey: A `Curve25519.Signing.PublicKey`.
    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// Verify the attestation on a `StreamlineMessage`.
    ///
    /// The message must carry headers. If the `streamline-attest` header is
    /// missing, returns a failed result.
    ///
    /// - Parameter message: The consumed message to verify.
    /// - Parameter headers: Message headers dictionary.
    /// - Returns: A ``VerificationResult`` indicating success or failure.
    public func verify(message: StreamlineMessage, headers: [String: String]) -> VerificationResult {
        guard let headerValue = headers[Self.attestHeader] else {
            return .failed
        }

        guard let decodedData = Data(base64Encoded: headerValue) else {
            return .failed
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(AttestationEnvelope.self, from: decodedData) else {
            return .failed
        }

        let canonical =
            "\(envelope.topic)|\(envelope.partition)|\(envelope.offset)"
            + "|\(envelope.payloadSha256)|\(envelope.schemaId)"
            + "|\(envelope.timestampMs)|\(envelope.keyId)"

        guard let canonicalData = canonical.data(using: .utf8) else {
            return .failed
        }

        guard let signatureData = Data(base64Encoded: envelope.signature) else {
            return .failed
        }

        let verified = publicKey.isValidSignature(signatureData, for: canonicalData)

        return VerificationResult(
            verified: verified,
            producerId: envelope.keyId,
            schemaId: envelope.schemaId != 0 ? envelope.schemaId : nil,
            contractId: envelope.contractId,
            timestampMs: envelope.timestampMs
        )
    }
}
