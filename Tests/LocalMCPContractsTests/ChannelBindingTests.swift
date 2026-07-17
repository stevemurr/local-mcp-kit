import CryptoKit
import Foundation
import Testing
@testable import LocalMCPContracts

@Suite("Channel-binding values and descriptors")
struct ChannelBindingValueTests {
    private var publicKey: ChannelBindingPublicKey {
        get throws {
            try ChannelBindingPublicKey(rawRepresentation: Array(UInt8.min ... UInt8(31)))
        }
    }

    @Test("Public keys are exactly 32 bytes and use canonical base64url")
    func publicKeyCoding() throws {
        let key = try publicKey
        let expected = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

        #expect(key.canonicalEncodedValue == expected)
        #expect(key.rawRepresentation == Array(UInt8.min ... UInt8(31)))
        #expect(try encodedJSON(key) == "\"\(expected)\"")
        #expect(try JSONDecoder().decode(ChannelBindingPublicKey.self, from: JSONEncoder().encode(key)) == key)

        for count in [0, 31, 33] {
            expectLocalMCPError(.invalidConfiguration) {
                try ChannelBindingPublicKey(rawRepresentation: Array(repeating: 0, count: count))
            }
        }
        for encoded in ["", String(expected.dropLast()), expected + "=", "+" + expected.dropFirst()] {
            expectLocalMCPError(.invalidConfiguration) {
                try ChannelBindingPublicKey(encodedValue: encoded)
            }
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    ChannelBindingPublicKey.self,
                    from: Data("\"\(encoded)\"".utf8)
                )
            }
        }
    }

    @Test("Descriptor compatibility requires the one supported suite and a valid key")
    func descriptorCompatibility() throws {
        let binding = ProducerChannelBinding(publicKey: try publicKey)
        var descriptor = ProducerDescriptor(
            instanceID: validInstanceID,
            server: validProducerIdentity,
            channelBinding: binding
        )
        #expect(try DescriptorCompatibility.validate(descriptor) == .current)

        descriptor.channelBinding = nil
        expectLocalMCPError(.incompatibleDiscoveryProfile) {
            try DescriptorCompatibility.validate(descriptor)
        }

        descriptor.channelBinding = ProducerChannelBinding(
            suite: "x25519-future-suite",
            publicKey: try publicKey
        )
        expectLocalMCPError(.incompatibleDiscoveryProfile) {
            try DescriptorCompatibility.validate(descriptor)
        }

        let malformed = Data(
            """
            {
              "schemaVersion":"1",
              "instanceId":"\(validInstanceID)",
              "server":{"id":"com.example.notes","name":"Notes","version":"1.0.0"},
              "mcp":{"transport":"localmcp-secure-http","endpoint":"/mcp","protocolVersions":["2025-11-25"],"authentication":"pairing-channel"},
              "capabilities":{"tools":true},
              "channelBinding":{"suite":"\(ProducerChannelBinding.supportedSuite)","publicKey":"short"}
            }
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProducerDescriptor.self, from: malformed)
        }
    }

    @Test("Endpoint bindings reject unsupported or malformed identities")
    func endpointBindings() throws {
        let binding = ProducerChannelBinding(publicKey: try publicKey)
        #expect(AuthorizationEndpointBinding(instanceID: validInstanceID, channelBinding: binding).isValid)
        #expect(!AuthorizationEndpointBinding(instanceID: "NOT-A-UUID", channelBinding: binding).isValid)
        #expect(!AuthorizationEndpointBinding(
            instanceID: validInstanceID,
            channelBinding: ProducerChannelBinding(suite: "future", publicKey: try publicKey)
        ).isValid)
    }

    @Test("Pairing identifier, secret, and commitment enforce canonical 32-byte values")
    func fixedPairingValues() throws {
        let bytes = Array(UInt8.min ... UInt8(31))
        let encoded = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        #expect(try encodedJSON(PairingIdentifier(bytes: bytes)) == "\"\(encoded)\"")
        #expect(try encodedJSON(PairingSecret(bytes: bytes)) == "\"\(encoded)\"")
        #expect(try encodedJSON(PairingCommitment(bytes: bytes)) == "\"\(encoded)\"")

        for count in [0, 31, 33] {
            let invalidBytes = Array(repeating: UInt8(0), count: count)
            expectLocalMCPError(.invalidConfiguration) {
                try PairingIdentifier(bytes: invalidBytes)
            }
            expectLocalMCPError(.invalidConfiguration) {
                try PairingSecret(bytes: invalidBytes)
            }
            expectLocalMCPError(.invalidConfiguration) {
                try PairingCommitment(bytes: invalidBytes)
            }
        }
        for invalid in ["", String(encoded.dropLast()), encoded + "=", "+" + encoded.dropFirst()] {
            expectLocalMCPError(.invalidConfiguration) {
                try PairingIdentifier(encodedValue: invalid)
            }
            expectLocalMCPError(.invalidConfiguration) {
                try PairingSecret(encodedValue: invalid)
            }
            expectLocalMCPError(.invalidConfiguration) {
                try PairingCommitment(encodedValue: invalid)
            }
        }
    }
}

@Suite("Channel-bound pairing transcript")
struct ChannelBoundPairingTests {
    private let producerPrivateBytes = Array(UInt8(1) ... UInt8(32))
    private let consumerPrivateBytes = Array(UInt8(33) ... UInt8(64))
    private let requestNonceBytes = Array(repeating: UInt8(0), count: 32)
    private let clientSecretBytes = Array(UInt8(160) ... UInt8(191))
    private let pairingIDBytes = Array(UInt8(64) ... UInt8(95))
    private let serverNonceBytes = Array(UInt8(96) ... UInt8(127))

    private func fixture() throws -> (
        instance: ProducerInstance,
        binding: ProducerChannelBinding,
        initiation: PairingRequest,
        finalized: PairingRequest,
        transcript: PairingTranscript
    ) {
        let producerPrivate = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(producerPrivateBytes)
        )
        let producerPublic = try ChannelBindingPublicKey(producerPrivate.publicKey)
        let binding = ProducerChannelBinding(publicKey: producerPublic)
        let instance = ProducerInstance(
            identity: validProducerIdentity,
            instanceID: validInstanceID,
            endpoint: try LoopbackEndpoint(port: 49_152, path: "/mcp"),
            descriptorURL: try LoopbackEndpoint(
                port: 49_152,
                path: "/local-mcp/v1/descriptor.json"
            ),
            channelBinding: binding
        )
        let secret = try PairingSecret(bytes: clientSecretBytes)
        let initiation = try PairingRequest(
            consumer: validConsumerIdentity,
            requestNonce: PairingNonce(bytes: requestNonceBytes),
            expectedProducerPublicKey: producerPublic,
            expectedInstanceID: validInstanceID,
            expectedEndpoint: "http://127.0.0.1:49152/mcp",
            initiatorPrivateKeyRawRepresentation: consumerPrivateBytes,
            clientSecret: secret
        )
        let decodedInitiation = try JSONDecoder().decode(
            PairingRequest.self,
            from: JSONEncoder().encode(initiation)
        )
        let finalized = try decodedInitiation.serverFinalized(
            pairingID: PairingIdentifier(bytes: pairingIDBytes),
            serverNonce: PairingNonce(bytes: serverNonceBytes),
            revealedClientSecret: secret
        )
        let transcript = try PairingTranscript(
            finalizedRequest: finalized,
            producerID: validProducerIdentity.stableID,
            channelBinding: binding
        )
        return (instance, binding, initiation, finalized, transcript)
    }

    @Test("Local initiation encodes only public fields and retains secrets only locally")
    func initiationCodingAndValidation() throws {
        let value = try fixture()
        let initiation = value.initiation
        try initiation.validateChannelBoundInitiation(expected: value.instance)
        #expect(initiation.isChannelBoundInitiation)
        #expect(!initiation.isServerFinalized)
        #expect(initiation.initiatorPrivateKeyRawRepresentation == consumerPrivateBytes)
        let expectedSecret = try PairingSecret(bytes: clientSecretBytes)
        #expect(initiation.localClientSecret == expectedSecret)

        let encoded = try JSONEncoder().encode(initiation)
        let json = String(decoding: encoded, as: UTF8.self)
        let decoded = try JSONDecoder().decode(PairingRequest.self, from: encoded)
        #expect(decoded == initiation)
        #expect(decoded.initiatorPrivateKeyRawRepresentation == nil)
        #expect(decoded.localClientSecret == nil)
        #expect(!json.contains(expectedSecret.canonicalEncodedValue))
        #expect(!json.contains(LocalMCPBase64URL.encode(consumerPrivateBytes)))
        #expect(json.contains("expectedProducerPublicKey"))
        #expect(json.contains("clientSecretCommitment"))
    }

    @Test("Public initiation creates fresh private and commitment material")
    func publicInitiationUsesFreshMaterial() throws {
        let value = try fixture()
        let nonce = try PairingNonce(bytes: requestNonceBytes)
        let first = try PairingRequest(
            consumer: validConsumerIdentity,
            requestNonce: nonce,
            bindingTo: value.instance
        )
        let second = try PairingRequest(
            consumer: validConsumerIdentity,
            requestNonce: nonce,
            bindingTo: value.instance
        )

        try first.validateChannelBoundInitiation(expected: value.instance)
        try second.validateChannelBoundInitiation(expected: value.instance)
        #expect(first.initiatorPrivateKeyRawRepresentation?.count == 32)
        #expect(first.localClientSecret?.bytes.count == 32)
        #expect(first.consumerEphemeralPublicKey != second.consumerEphemeralPublicKey)
        #expect(first.clientSecretCommitment != second.clientSecretCommitment)

        var unbound = value.instance
        unbound.channelBinding = nil
        expectLocalMCPError(.invalidConfiguration) {
            try PairingRequest(
                consumer: validConsumerIdentity,
                requestNonce: nonce,
                bindingTo: unbound
            )
        }

        for endpoint in [
            "https://127.0.0.1:49152/mcp",
            "http://localhost:49152/mcp",
            "http://127.0.0.1:49152/%6dcp",
            "http://127.0.0.1:49152/mcp?query=1",
            "http://127.0.0.1:49152/other",
        ] {
            expectLocalMCPError(.invalidConfiguration) {
                try PairingRequest(
                    consumer: validConsumerIdentity,
                    requestNonce: nonce,
                    expectedProducerPublicKey: value.binding.publicKey,
                    expectedInstanceID: validInstanceID,
                    expectedEndpoint: endpoint,
                    initiatorPrivateKeyRawRepresentation: consumerPrivateBytes,
                    clientSecret: PairingSecret(bytes: clientSecretBytes)
                )
            }
        }
    }

    @Test("Finalization accepts only the committed reveal and drops initiator secrets")
    func finalization() throws {
        let value = try fixture()
        try value.finalized.validateServerFinalized(
            producerID: validProducerIdentity.stableID,
            channelBinding: value.binding
        )
        #expect(value.finalized.isServerFinalized)
        #expect(!value.finalized.isChannelBoundInitiation)
        #expect(value.finalized.initiatorPrivateKeyRawRepresentation == nil)
        #expect(value.finalized.localClientSecret == nil)

        expectLocalMCPError(.invalidConfiguration) {
            try value.initiation.serverFinalized(
                pairingID: PairingIdentifier(bytes: pairingIDBytes),
                serverNonce: PairingNonce(bytes: serverNonceBytes),
                revealedClientSecret: PairingSecret(bytes: Array(repeating: 0xff, count: 32))
            )
        }
    }

    @Test("Partial and ambiguous request phases are never accepted")
    func rejectsAmbiguousPhases() throws {
        let value = try fixture()
        var partial = value.initiation
        partial.consumerEphemeralPublicKey = nil
        #expect(!partial.isChannelBoundInitiation)
        #expect(!partial.isServerFinalized)
        #expect(throws: LocalMCPError.self) {
            try partial.validateChannelBoundInitiation(expected: value.instance)
        }

        var mixed = value.initiation
        mixed.pairingID = try PairingIdentifier(bytes: pairingIDBytes)
        #expect(!mixed.isChannelBoundInitiation)
        #expect(!mixed.isServerFinalized)
        #expect(throws: LocalMCPError.self) {
            try mixed.validateChannelBoundInitiation(expected: value.instance)
        }
    }

    @Test("The normative transcript, commitment, SAS, KDF, and AAD vectors match")
    func goldenVectors() throws {
        let value = try fixture()
        let commitment = try #require(value.initiation.clientSecretCommitment)
        let digestHex = value.transcript.withDigestBytes { hex($0) }
        let sas = PairingVerificationCode(transcript: value.transcript)
            .withUnsafeDisplayValue { $0 }

        let consumerKey = try PairingChannelCrypto.responseKey(
            privateKeyRawRepresentation: consumerPrivateBytes,
            peerPublicKey: value.binding.publicKey,
            transcript: value.transcript
        )
        let producerKey = try PairingChannelCrypto.responseKey(
            privateKeyRawRepresentation: producerPrivateBytes,
            peerPublicKey: try #require(value.initiation.consumerEphemeralPublicKey),
            transcript: value.transcript
        )
        let consumerKeyHex = consumerKey.withUnsafeBytes { hex(Array($0)) }
        let producerKeyHex = producerKey.withUnsafeBytes { hex(Array($0)) }
        let aadHex = hex(Array(PairingChannelCrypto.responseAAD(for: value.transcript)))

        var cursor = 0
        let protocolField = try readLengthPrefixedField(
            value.transcript.encodedBytes,
            cursor: &cursor
        )
        let suiteField = try readLengthPrefixedField(
            value.transcript.encodedBytes,
            cursor: &cursor
        )

        #expect(commitment.canonicalEncodedValue == "GxpL_s-rjhw-2nOdds6v_SKg0Kimuh33Er8D8Q6VJ58")
        #expect(value.transcript.encodedBytes.count == 522)
        #expect(protocolField == Array(PairingTranscript.protocolLabel.utf8))
        #expect(suiteField == Array(ProducerChannelBinding.supportedSuite.utf8))
        #expect(digestHex == "f127bc6b9a59cb2f027aacf0fd68ca6d26c9c0619f39e1f5f499a5d8a6a262b5")
        #expect(sas == "7BQ6R81W")
        #expect(sas.count == 8)
        #expect(sas.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        #expect(consumerKeyHex == "dd83873194697aa200848ec9b659d6a89af164ba2fd20b74e41f11828cfcb4e4")
        #expect(producerKeyHex == consumerKeyHex)
        #expect(aadHex == "4c6f63616c4d43504b69742070616972696e6720726573706f6e73652061616420763100f127bc6b9a59cb2f027aacf0fd68ca6d26c9c0619f39e1f5f499a5d8a6a262b5")
    }

    @Test("X25519 key agreement rejects low-order public keys")
    func rejectsLowOrderPublicKeys() throws {
        for bytes in [
            Array(repeating: UInt8(0), count: 32),
            [UInt8(1)] + Array(repeating: UInt8(0), count: 31),
        ] {
            let lowOrder = try ChannelBindingPublicKey(rawRepresentation: bytes)
            expectLocalMCPError(.invalidConfiguration) {
                try PairingChannelCrypto.sharedSecret(
                    privateKeyRawRepresentation: consumerPrivateBytes,
                    peerPublicKey: lowOrder
                )
            }
        }
    }
}

@Suite("Channel-bound grants")
struct ChannelBoundGrantTests {
    @Test("Grant endpoint bindings and pending state round-trip without secret material")
    func grantBindingAndState() throws {
        let binding = AuthorizationEndpointBinding(
            instanceID: validInstanceID,
            channelBinding: ProducerChannelBinding(
                publicKey: try ChannelBindingPublicKey(
                    rawRepresentation: Array(UInt8.min ... UInt8(31))
                )
            )
        )
        let metadata = AuthorizationGrantMetadata(
            grantID: "grant",
            producerID: validProducerIdentity.stableID,
            consumer: validConsumerIdentity,
            issuedAt: Date(timeIntervalSince1970: 0)
        )
        let credential = try AuthorizationCredential(bytes: Array(repeating: 7, count: 32))
        let grant = AuthorizationGrant(
            metadata: metadata,
            credential: credential,
            endpointBinding: binding
        )
        let record = ProducerGrantRecord(
            metadata: metadata,
            credentialDigest: credential.digest,
            state: .pending(binding)
        )

        #expect(grant.endpointBinding == binding)
        #expect(record.state == .pending(binding))
        #expect(
            try JSONDecoder().decode(
                ProducerGrantState.self,
                from: JSONEncoder().encode(record.state)
            ) == record.state
        )
        #expect(ProducerGrantRecord(metadata: metadata, credentialDigest: credential.digest).state == .active)
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func readLengthPrefixedField(_ bytes: [UInt8], cursor: inout Int) throws -> [UInt8] {
    guard cursor <= bytes.count - 4 else { throw LocalMCPError.invalidConfiguration }
    let length = Int(bytes[cursor]) << 24 |
        Int(bytes[cursor + 1]) << 16 |
        Int(bytes[cursor + 2]) << 8 |
        Int(bytes[cursor + 3])
    cursor += 4
    guard length >= 0, cursor <= bytes.count - length else {
        throw LocalMCPError.invalidConfiguration
    }
    defer { cursor += length }
    return Array(bytes[cursor ..< cursor + length])
}
