#if canImport(CryptoKit)
@preconcurrency import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation

/// Result of an attestation verification.
public struct VerificationResult: Sendable, Equatable {
    /// Whether the signature was valid **and** `producerId` matched a
    /// pre-registered trusted key. Only trust `producerId` when this is `true`.
    public let verified: Bool
    /// The key_id asserted by the attestation envelope. This is the
    /// producer's self-declared identity and must not be treated as
    /// authenticated unless ``verified`` is `true`.
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

/// Verifies `streamline-attest` headers on consumed messages using local
/// Ed25519 public keys bound to explicitly trusted producer identities. No
/// network calls are made.
///
/// The attestation header contains a Base64-encoded JSON envelope with an
/// Ed25519 signature over the canonical bytes:
/// `topic|partition|offset|payload_sha256|schema_id|timestamp_ms|key_id`.
/// Verification succeeds only when the signed payload hash and record identity
/// exactly match the consumed message, **and** the envelope's `key_id` maps to
/// a caller-supplied trusted key.
///
/// The envelope's `key_id` is never used to look up or select a verification
/// key from an external/untrusted source, and a single configured key is
/// never treated as authoritative for an arbitrary self-asserted `key_id`.
/// Instead, each trusted identity must be registered up front — either as a
/// single `(publicKey, trustedKeyId)` pair or as a keyring of multiple
/// identities — so a `key_id` absent from that trust store fails closed
/// regardless of whether the accompanying signature is otherwise valid.
///
/// Example:
/// ```swift
/// let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
/// let verifier = StreamlineVerifier(publicKey: pubKey, trustedKeyId: "producer-key")
///
/// let result = verifier.verify(message: msg)
/// if result.verified {
///     print("Verified from \(result.producerId)")
/// }
/// ```
public final class StreamlineVerifier: Sendable {

    /// Kafka header name carrying the attestation envelope.
    public static let attestHeader = "streamline-attest"

    /// Trusted verification keys keyed by the producer identity (`key_id`)
    /// each key is authorized to represent. A `key_id` asserted in an
    /// attestation envelope is trusted only when it has a matching entry
    /// here; the envelope itself can never introduce a new identity.
    private let trustedKeys: [String: Curve25519.Signing.PublicKey]

    /// Creates a verifier that trusts a single producer identity.
    ///
    /// - Parameters:
    ///   - publicKey: The Ed25519 public key authorized to sign for `trustedKeyId`.
    ///   - trustedKeyId: The explicit `key_id` this key is trusted to represent.
    ///     Attestations asserting any other `key_id` are rejected before the
    ///     signature is checked.
    public init(publicKey: Curve25519.Signing.PublicKey, trustedKeyId: String) {
        self.trustedKeys = [trustedKeyId: publicKey]
    }

    /// Creates a verifier that trusts multiple producer identities, each
    /// bound to its own verification key (for key rotation or multi-producer
    /// deployments).
    ///
    /// A `key_id` in an attestation envelope is looked up in this trust store
    /// to select the specific key used for verification. A `key_id` with no
    /// entry fails closed regardless of who signed the envelope.
    ///
    /// - Parameter trustedKeys: Trusted `key_id` → Ed25519 public key mapping.
    ///   An empty map trusts no identities, so every attestation fails closed.
    public init(trustedKeys: [String: Curve25519.Signing.PublicKey]) {
        self.trustedKeys = trustedKeys
    }

    /// Retained for source compatibility with versions of this SDK prior to
    /// explicit `key_id` trust binding.
    ///
    /// This initializer intentionally does **not** trust the supplied key for
    /// an arbitrary self-asserted `key_id` the way the original, pre-security-
    /// fix implementation did. Doing so would let any envelope claim whatever
    /// `key_id` it likes and have it verified against this single key,
    /// defeating the point of binding trust to an explicit identity. Because
    /// no `trustedKeyId` is supplied, this verifier registers no trusted
    /// identities at all, so ``verify(message:)`` fails closed — every
    /// attestation returns ``VerificationResult/failed`` regardless of
    /// whether its signature would otherwise validate against `publicKey`.
    ///
    /// Prefer ``init(publicKey:trustedKeyId:)`` or ``init(trustedKeys:)``,
    /// both of which bind trust to an explicit `key_id`.
    @available(
        *,
        deprecated,
        message: """
        Fails closed: no trustedKeyId is supplied, so verify(message:) always \
        returns a failed result. Use init(publicKey:trustedKeyId:) or \
        init(trustedKeys:) to trust a specific key_id.
        """
    )
    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.trustedKeys = [:]
    }

    /// Verify the attestation on a `StreamlineMessage`.
    ///
    /// The message must include its server-assigned partition, offset, and
    /// headers. If any required metadata is absent, returns a failed result.
    ///
    /// - Parameter message: The consumed message to verify.
    /// - Returns: A ``VerificationResult`` indicating success or failure.
    public func verify(message: StreamlineMessage) -> VerificationResult {
        verifyAttestation(message: message, headers: message.headers)
    }

    /// Verify an attestation supplied separately from the message.
    ///
    /// Prefer ``verify(message:)`` so the header travels with the consumed
    /// record. This overload remains for source compatibility.
    ///
    /// - Parameters:
    ///   - message: The consumed message to verify.
    ///   - headers: Message headers dictionary.
    /// - Returns: A ``VerificationResult`` indicating success or failure.
    @available(*, deprecated, message: "Attach headers to StreamlineMessage and use verify(message:).")
    public func verify(message: StreamlineMessage, headers: [String: String]) -> VerificationResult {
        verifyAttestation(message: message, headers: headers)
    }

    private func verifyAttestation(
        message: StreamlineMessage,
        headers: [String: String]
    ) -> VerificationResult {
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

        // Bind the claimed producer identity to an explicitly trusted
        // verification key. The envelope's key_id is used only to look up a
        // key in our own trust store — never to select an arbitrary key from
        // an untrusted source — so a key_id we did not pre-register fails
        // closed here regardless of whether some other signature would have
        // been valid.
        guard let trustedPublicKey = trustedKeys[envelope.keyId] else {
            return .failed
        }

        let payloadHash = SHA256.hash(data: message.value)
            .map { String(format: "%02x", $0) }
            .joined()
        let signedPayloadHash = envelope.payloadSha256.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")

        guard signedPayloadHash.count == 64,
              signedPayloadHash.unicodeScalars.allSatisfy(hexadecimal.contains),
              payloadHash == signedPayloadHash,
              message.topic == envelope.topic,
              message.partition == envelope.partition,
              message.offset == envelope.offset
        else {
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

        guard trustedPublicKey.isValidSignature(signatureData, for: canonicalData) else {
            return .failed
        }

        return VerificationResult(
            verified: true,
            producerId: envelope.keyId,
            schemaId: envelope.schemaId != 0 ? envelope.schemaId : nil,
            contractId: envelope.contractId,
            timestampMs: envelope.timestampMs
        )
    }
}
