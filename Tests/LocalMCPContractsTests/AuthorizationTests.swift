import Foundation
import Testing
import LocalMCPContracts

@Suite("Pairing nonce and verification code")
struct PairingNonceTests {
    private let zeroNonceEncoding = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    @Test("The normative all-zero nonce and verification-code vector matches")
    func publishedTestVector() throws {
        let nonce = try PairingNonce(bytes: Array(repeating: 0, count: 32))
        let code = PairingVerificationCode(nonce: nonce)

        #expect(try encodedJSON(nonce) == "\"\(zeroNonceEncoding)\"")
        #expect(nonce.withUnsafeBytes { $0 } == Array(repeating: 0, count: 32))
        #expect(code.withUnsafeDisplayValue { $0 } == "XQ60K08A")
    }

    @Test("Pairing nonce Codable representation is one canonical base64url string")
    func nonceCodingRoundTrip() throws {
        let bytes = Array(UInt8.min ... UInt8(31))
        let nonce = try PairingNonce(bytes: bytes)
        let encoded = try JSONEncoder().encode(nonce)
        let decoded = try JSONDecoder().decode(PairingNonce.self, from: encoded)

        #expect(decoded == nonce)
        #expect(decoded.withUnsafeBytes { $0 } == bytes)
        #expect(String(decoding: encoded, as: UTF8.self) ==
            #""AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8""#)
    }

    @Test("Nonce construction rejects wrong lengths and noncanonical base64url")
    func rejectsInvalidNonce() {
        for count in [0, 31, 33] {
            expectLocalMCPError(.invalidConfiguration) {
                try PairingNonce(bytes: Array(repeating: 0, count: count))
            }
        }

        for encoded in [
            "",
            String(repeating: "A", count: 42),
            zeroNonceEncoding + "=",
            "+" + String(zeroNonceEncoding.dropFirst()),
            String(repeating: "A", count: 42) + "B",
        ] {
            expectLocalMCPError(.invalidConfiguration) {
                try PairingNonce(encodedValue: encoded)
            }
        }
    }

    @Test("Invalid nonce JSON is reported as a decoding failure")
    func invalidNonceJSON() {
        let fixture = Data(#""not-a-valid-nonce""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PairingNonce.self, from: fixture)
        }
    }

    @Test("Pairing request uses V1 coding keys and ignores additive fields")
    func pairingRequestCoding() throws {
        let nonce = try PairingNonce(bytes: Array(repeating: 0, count: 32))
        let request = PairingRequest(consumer: validConsumerIdentity, requestNonce: nonce)
        let golden = """
        {"consumer":{"id":"com.example.assistant","installationId":"3e260e1c-bb58-4247-9733-47352fbc6c98","name":"Example Assistant","version":"2.0.0"},"requestNonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","schemaVersion":"1"}
        """
        #expect(try encodedJSON(request) == golden)

        let forwardCompatibleFixture = """
        {
          "schemaVersion": "1",
          "requestNonce": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "future": true,
          "consumer": {
            "id": "com.example.assistant",
            "name": "Example Assistant",
            "version": "2.0.0",
            "installationId": "3e260e1c-bb58-4247-9733-47352fbc6c98",
            "futureConsumerField": 1
          }
        }
        """
        #expect(
            try JSONDecoder().decode(
                PairingRequest.self,
                from: Data(forwardCompatibleFixture.utf8)
            ) == request
        )
    }

    @Test("Nonce and verification-code descriptions never reveal their values")
    func pairingValueRedaction() throws {
        let nonce = try PairingNonce(bytes: Array(repeating: 0, count: 32))
        let code = PairingVerificationCode(nonce: nonce)

        #expect(nonce.description == "<redacted pairing nonce>")
        #expect(nonce.debugDescription == "<redacted pairing nonce>")
        #expect(String(describing: nonce) == "<redacted pairing nonce>")
        #expect(String(reflecting: nonce) == "<redacted pairing nonce>")
        #expect(!String(reflecting: nonce).contains(zeroNonceEncoding))

        #expect(code.description == "<redacted verification code>")
        #expect(code.debugDescription == "<redacted verification code>")
        #expect(String(describing: code) == "<redacted verification code>")
        #expect(String(reflecting: code) == "<redacted verification code>")
        #expect(!String(reflecting: code).contains("XQ60K08A"))
    }

    @Test("Pairing challenge retains only sanitized approval metadata")
    func pairingChallenge() throws {
        let nonce = try PairingNonce(bytes: Array(repeating: 0, count: 32))
        let code = PairingVerificationCode(nonce: nonce)
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let challenge = PairingChallenge(
            requestID: "request-123",
            consumer: validConsumerIdentity,
            verificationCode: code,
            expiresAt: expiry
        )

        #expect(challenge.requestID == "request-123")
        #expect(challenge.consumer == validConsumerIdentity)
        #expect(challenge.verificationCode == code)
        #expect(challenge.expiresAt == expiry)
        #expect(PairingDecision.approve != .deny)
    }
}

@Suite("Credentials and grants")
struct CredentialAndGrantTests {
    private var credentialBytes: [UInt8] {
        Array(UInt8.min ... UInt8(31))
    }

    private var alternateCredentialBytes: [UInt8] {
        Array(repeating: 0xff, count: 32)
    }

    private var metadata: AuthorizationGrantMetadata {
        AuthorizationGrantMetadata(
            grantID: "grant-123",
            producerID: validProducerIdentity.stableID,
            consumer: validConsumerIdentity,
            issuedAt: Date(timeIntervalSince1970: 1_900_000_000),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    @Test("Credentials use canonical unpadded base64url and round-trip explicitly")
    func credentialCoding() throws {
        let credential = try AuthorizationCredential(bytes: credentialBytes)
        let expected = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

        #expect(credential.withUnsafeEncodedValue { $0 } == expected)
        #expect(try AuthorizationCredential(encodedValue: expected) == credential)
    }

    @Test("Credentials reject wrong lengths and noncanonical encodings")
    func rejectsInvalidCredentials() {
        for count in [0, 31, 33] {
            expectLocalMCPError(.invalidConfiguration) {
                try AuthorizationCredential(bytes: Array(repeating: 0, count: count))
            }
        }

        let valid = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        for encoded in [
            "",
            String(valid.dropLast()),
            valid + "=",
            "+" + String(valid.dropFirst()),
            String(valid.dropLast()) + "9",
        ] {
            expectLocalMCPError(.invalidConfiguration) {
                try AuthorizationCredential(encodedValue: encoded)
            }
        }
    }

    @Test("Credential digests compare equal only for the same token")
    func credentialDigests() throws {
        let credential = try AuthorizationCredential(bytes: credentialBytes)
        let sameCredential = try AuthorizationCredential(bytes: credentialBytes)
        let alternateCredential = try AuthorizationCredential(bytes: alternateCredentialBytes)

        #expect(credential.digest == sameCredential.digest)
        #expect(credential.digest.constantTimeEquals(sameCredential.digest))
        #expect(credential.digest != alternateCredential.digest)
        #expect(!credential.digest.constantTimeEquals(alternateCredential.digest))
    }

    @Test("Credential digest hashes the decoded 32 token bytes")
    func credentialDigestKnownVector() throws {
        let credential = try AuthorizationCredential(bytes: credentialBytes)
        let digestHex = credential.digest.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        #expect(
            digestHex ==
                "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
        )
    }

    @Test("Explicit credential digests require exactly 32 bytes")
    func credentialDigestLength() throws {
        let bytes = Array(repeating: UInt8(0xab), count: 32)
        let digest = try CredentialDigest(bytes: bytes)
        #expect(digest.withUnsafeBytes { $0 } == bytes)

        for count in [0, 31, 33] {
            expectLocalMCPError(.invalidConfiguration) {
                try CredentialDigest(bytes: Array(repeating: 0, count: count))
            }
        }
    }

    @Test("Grant expiration is inclusive at the expiry instant")
    func grantExpiration() {
        let metadata = metadata
        let expiry = try! #require(metadata.expiresAt)

        #expect(!metadata.isExpired(at: expiry.addingTimeInterval(-0.001)))
        #expect(metadata.isExpired(at: expiry))
        #expect(metadata.isExpired(at: expiry.addingTimeInterval(1)))

        var nonExpiring = metadata
        nonExpiring.expiresAt = nil
        #expect(!nonExpiring.isExpired(at: .distantFuture))
    }

    @Test("Grant metadata is Codable without any bearer credential")
    func grantMetadataCoding() throws {
        var metadata = metadata
        metadata.revokedAt = Date(timeIntervalSince1970: 1_950_000_000)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(AuthorizationGrantMetadata.self, from: data)

        #expect(decoded == metadata)
        #expect(!String(decoding: data, as: UTF8.self).contains("accessToken"))
        #expect(!String(decoding: data, as: UTF8.self).contains("credential"))
    }

    @Test("Credential, digest, and both grant forms redact secret material")
    func redaction() throws {
        let credential = try AuthorizationCredential(bytes: credentialBytes)
        let rawCredential = credential.withUnsafeEncodedValue { $0 }
        let grant = AuthorizationGrant(metadata: metadata, credential: credential)
        let producerRecord = ProducerGrantRecord(
            metadata: metadata,
            credentialDigest: credential.digest
        )

        #expect(grant.metadata == metadata)
        #expect(grant.credential == credential)
        #expect(producerRecord.metadata == metadata)
        #expect(producerRecord.credentialDigest == credential.digest)

        let credentialRepresentations = [
            credential.description,
            credential.debugDescription,
            String(describing: credential),
            String(reflecting: credential),
        ]
        #expect(credentialRepresentations.allSatisfy { $0 == "<redacted credential>" })
        #expect(credentialRepresentations.allSatisfy { !$0.contains(rawCredential) })

        let digestRepresentations = [
            credential.digest.description,
            credential.digest.debugDescription,
            String(describing: credential.digest),
            String(reflecting: credential.digest),
        ]
        #expect(digestRepresentations.allSatisfy { $0 == "<redacted credential digest>" })
        #expect(digestRepresentations.allSatisfy { !$0.contains(rawCredential) })

        #expect(grant.description == "<redacted authorization grant>")
        #expect(grant.debugDescription == grant.description)
        #expect(String(describing: grant) == grant.description)
        #expect(String(reflecting: grant) == grant.description)
        #expect(!grant.description.contains(rawCredential))

        #expect(producerRecord.description == "<redacted producer grant record>")
        #expect(producerRecord.debugDescription == producerRecord.description)
        #expect(String(describing: producerRecord) == producerRecord.description)
        #expect(String(reflecting: producerRecord) == producerRecord.description)
        #expect(!producerRecord.description.contains(rawCredential))

        var hostileMetadata = metadata
        hostileMetadata.grantID = "\u{001B}[31m forged-log-entry\nnext-line"
        let hostileGrant = AuthorizationGrant(
            metadata: hostileMetadata,
            credential: credential
        )
        let hostileRecord = ProducerGrantRecord(
            metadata: hostileMetadata,
            credentialDigest: credential.digest
        )
        #expect(!hostileGrant.description.contains(hostileMetadata.grantID))
        #expect(!hostileRecord.description.contains(hostileMetadata.grantID))
    }
}
