#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
@testable import StreamlineSDK
import XCTest

final class StreamlineVerifierTests: XCTestCase {
    private let privateKey = Curve25519.Signing.PrivateKey()

    func testValidAttestationBindsPayloadAndRecordIdentity() throws {
        let payload = Data("verified payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 2,
            offset: 42
        )
        let message = StreamlineMessage(
            topic: "events",
            value: payload,
            offset: 42,
            partition: 2,
            headers: headers
        )

        let result = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
            .verify(message: message)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.producerId, "producer-key")
        XCTAssertEqual(result.schemaId, 7)
        XCTAssertEqual(result.contractId, "orders-v1")
    }

    func testUntrustedKeyIdFailsVerificationEvenWithValidSignature() throws {
        // A signature from a key we do trust, but asserting an identity
        // (key_id) we never registered, must not verify: the envelope's
        // self-declared key_id must not be able to select or invent trust.
        let payload = Data("verified payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 2,
            offset: 42,
            keyId: "unregistered-producer"
        )
        let message = StreamlineMessage(
            topic: "events",
            value: payload,
            offset: 42,
            partition: 2,
            headers: headers
        )

        let result = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
            .verify(message: message)

        XCTAssertFalse(result.verified)
    }

    func testKeyringOnlyTrustsRegisteredIdentities() throws {
        let otherKey = Curve25519.Signing.PrivateKey()
        let payload = Data("verified payload".utf8)

        let headersForTrusted = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 0,
            offset: 1,
            keyId: "producer-a"
        )
        let headersForOther = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 0,
            offset: 1,
            keyId: "producer-b",
            signingKey: otherKey
        )
        let headersForImpersonation = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 0,
            offset: 1,
            keyId: "producer-b" // signed by producer-a's key but claims producer-b's identity
        )

        let verifier = StreamlineVerifier(trustedKeys: [
            "producer-a": privateKey.publicKey,
            "producer-b": otherKey.publicKey,
        ])

        let trustedResult = verifier.verify(message: StreamlineMessage(
            topic: "events", value: payload, offset: 1, partition: 0, headers: headersForTrusted
        ))
        XCTAssertTrue(trustedResult.verified)
        XCTAssertEqual(trustedResult.producerId, "producer-a")

        let otherResult = verifier.verify(message: StreamlineMessage(
            topic: "events", value: payload, offset: 1, partition: 0, headers: headersForOther
        ))
        XCTAssertTrue(otherResult.verified)
        XCTAssertEqual(otherResult.producerId, "producer-b")

        // producer-a's key cannot impersonate producer-b: the signature was
        // computed with producer-a's key, but the trust store only accepts
        // producer-b's own key for that identity, so this must fail.
        let impersonationResult = verifier.verify(message: StreamlineMessage(
            topic: "events", value: payload, offset: 1, partition: 0, headers: headersForImpersonation
        ))
        XCTAssertFalse(impersonationResult.verified)
        XCTAssertEqual(impersonationResult.producerId, "")
    }

    func testEmptyKeyringFailsClosedForAnyIdentity() throws {
        let payload = Data("payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 0,
            offset: 1
        )
        let message = StreamlineMessage(
            topic: "events", value: payload, offset: 1, partition: 0, headers: headers
        )

        let result = StreamlineVerifier(trustedKeys: [:]).verify(message: message)

        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.producerId, "")
    }

    /// Regression test for the deprecated, source-compatible
    /// `init(publicKey:)` initializer (retained for callers upgrading from
    /// versions prior to explicit key-id trust binding). It must fail closed
    /// for every attestation — including one with an otherwise perfectly
    /// valid signature from the exact key supplied — because no
    /// `trustedKeyId` was given to bind that key to a specific identity.
    func testDeprecatedPublicKeyOnlyInitializerFailsClosedEvenWithValidSignature() throws {
        let payload = Data("verified payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "events",
            partition: 2,
            offset: 42,
            keyId: "producer-key"
        )
        let message = StreamlineMessage(
            topic: "events",
            value: payload,
            offset: 42,
            partition: 2,
            headers: headers
        )

        let deprecatedVerifier = StreamlineVerifier(publicKey: privateKey.publicKey)
        let result = deprecatedVerifier.verify(message: message)

        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.producerId, "")
        XCTAssertEqual(result, .failed)

        // Sanity check: the exact same envelope verifies successfully when
        // the equivalent key is instead bound to a trusted key_id, proving
        // the failure above is specifically due to the missing binding and
        // not a malformed test fixture.
        let boundVerifier = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
        XCTAssertTrue(boundVerifier.verify(message: message).verified)
    }

    func testPayloadTamperingFailsVerification() throws {
        let originalPayload = Data("original".utf8)
        let headers = try attestationHeaders(
            payload: originalPayload,
            topic: "events",
            partition: 0,
            offset: 10
        )
        let tamperedMessage = StreamlineMessage(
            topic: "events",
            value: Data("tampered".utf8),
            offset: 10,
            partition: 0,
            headers: headers
        )

        let result = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
            .verify(message: tamperedMessage)

        XCTAssertFalse(result.verified)
    }

    func testTopicOrPartitionSubstitutionFailsVerification() throws {
        let payload = Data("payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "orders",
            partition: 1,
            offset: 99
        )
        let substitutedTopic = StreamlineMessage(
            topic: "payments",
            value: payload,
            offset: 99,
            partition: 1,
            headers: headers
        )
        let substitutedPartition = StreamlineMessage(
            topic: "orders",
            value: payload,
            offset: 99,
            partition: 2,
            headers: headers
        )
        let verifier = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")

        XCTAssertFalse(verifier.verify(message: substitutedTopic).verified)
        XCTAssertFalse(verifier.verify(message: substitutedPartition).verified)
    }

    func testAttestationReplayAtDifferentOffsetFailsVerification() throws {
        let payload = Data("payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "orders",
            partition: 1,
            offset: 100
        )
        let replayedMessage = StreamlineMessage(
            topic: "orders",
            value: payload,
            offset: 101,
            partition: 1,
            headers: headers
        )

        let result = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
            .verify(message: replayedMessage)

        XCTAssertFalse(result.verified)
    }

    func testMissingRecordMetadataFailsVerification() throws {
        let payload = Data("payload".utf8)
        let headers = try attestationHeaders(
            payload: payload,
            topic: "orders",
            partition: 1,
            offset: 100
        )
        let incompleteMessage = StreamlineMessage(
            topic: "orders",
            value: payload,
            headers: headers
        )

        let result = StreamlineVerifier(publicKey: privateKey.publicKey, trustedKeyId: "producer-key")
            .verify(message: incompleteMessage)

        XCTAssertFalse(result.verified)
    }

    private func attestationHeaders(
        payload: Data,
        topic: String,
        partition: Int,
        offset: Int64,
        keyId: String = "producer-key",
        signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> [String: String] {
        let signer = signingKey ?? privateKey
        let payloadHash = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        let schemaId = 7
        let timestampMs: Int64 = 1_725_000_000_000
        let canonical =
            "\(topic)|\(partition)|\(offset)|\(payloadHash)|\(schemaId)|\(timestampMs)|\(keyId)"
        let signature = try signer.signature(for: Data(canonical.utf8))
        let envelope: [String: Any] = [
            "payload_sha256": payloadHash,
            "topic": topic,
            "partition": partition,
            "offset": offset,
            "schema_id": schemaId,
            "timestamp_ms": timestampMs,
            "key_id": keyId,
            "signature": signature.base64EncodedString(),
            "contract_id": "orders-v1",
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return [StreamlineVerifier.attestHeader: data.base64EncodedString()]
    }
}
