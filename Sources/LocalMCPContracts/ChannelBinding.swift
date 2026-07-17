import CryptoKit
import Foundation

/// The only channel-binding suite defined by the V1 discovery profile.
public struct ProducerChannelBinding: Codable, Sendable, Hashable {
    public static let supportedSuite = "x25519-hkdf-sha256-chacha20poly1305-v1"

    public var suite: String
    public var publicKey: ChannelBindingPublicKey

    public init(
        suite: String = ProducerChannelBinding.supportedSuite,
        publicKey: ChannelBindingPublicKey
    ) {
        self.suite = suite
        self.publicKey = publicKey
    }

    public var isSupported: Bool {
        suite == Self.supportedSuite
    }
}

/// A canonical, unpadded base64url-encoded 32-byte X25519 public key.
public struct ChannelBindingPublicKey: Codable, Sendable, Hashable {
    private let encodedValue: String

    public init(rawRepresentation: [UInt8]) throws {
        guard rawRepresentation.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        encodedValue = LocalMCPBase64URL.encode(rawRepresentation)
    }

    public init(encodedValue: String) throws {
        guard LocalMCPBase64URL.decode(encodedValue)?.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        self.encodedValue = encodedValue
    }

    package init(_ publicKey: Curve25519.KeyAgreement.PublicKey) throws {
        try self.init(rawRepresentation: Array(publicKey.rawRepresentation))
    }

    package var rawRepresentation: [UInt8] {
        LocalMCPBase64URL.decode(encodedValue)!
    }

    package var canonicalEncodedValue: String { encodedValue }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedValue = try container.decode(String.self)
        do {
            try self.init(encodedValue: encodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid channel-binding public key."
            )
        }
    }
}

extension ChannelBindingPublicKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<channel-binding public key>" }
    public var debugDescription: String { description }
}

/// The non-secret endpoint identity persisted with a consumer grant.
public struct AuthorizationEndpointBinding: Codable, Sendable, Hashable {
    public var instanceID: String
    public var channelBinding: ProducerChannelBinding

    public init(instanceID: String, channelBinding: ProducerChannelBinding) {
        self.instanceID = instanceID
        self.channelBinding = channelBinding
    }

    public var isValid: Bool {
        LocalMCPValidation.isCanonicalLowercaseUUID(instanceID) && channelBinding.isSupported
    }
}

/// A canonical, unpadded base64url-encoded 32-byte pairing identifier.
public struct PairingIdentifier: Codable, Sendable, Hashable {
    private let encodedValue: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        encodedValue = LocalMCPBase64URL.encode(bytes)
    }

    public init(encodedValue: String) throws {
        guard LocalMCPBase64URL.decode(encodedValue)?.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        self.encodedValue = encodedValue
    }

    package var bytes: [UInt8] { LocalMCPBase64URL.decode(encodedValue)! }
    package var canonicalEncodedValue: String { encodedValue }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedValue = try container.decode(String.self)
        do {
            try self.init(encodedValue: encodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid pairing identifier."
            )
        }
    }
}

extension PairingIdentifier: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted pairing identifier>" }
    public var debugDescription: String { description }
}

/// A 32-byte random secret committed to by the consumer before the producer
/// contributes its pairing nonce.
public struct PairingSecret: Codable, Sendable, Hashable {
    private let encodedValue: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        encodedValue = LocalMCPBase64URL.encode(bytes)
    }

    public init(encodedValue: String) throws {
        guard LocalMCPBase64URL.decode(encodedValue)?.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        self.encodedValue = encodedValue
    }

    package var bytes: [UInt8] { LocalMCPBase64URL.decode(encodedValue)! }
    package var canonicalEncodedValue: String { encodedValue }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedValue = try container.decode(String.self)
        do {
            try self.init(encodedValue: encodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid pairing secret.")
        }
    }
}

extension PairingSecret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted pairing secret>" }
    public var debugDescription: String { description }
}

/// A SHA-256 commitment to a pairing secret.
public struct PairingCommitment: Codable, Sendable, Hashable {
    private let encodedValue: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        encodedValue = LocalMCPBase64URL.encode(bytes)
    }

    public init(encodedValue: String) throws {
        guard LocalMCPBase64URL.decode(encodedValue)?.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        self.encodedValue = encodedValue
    }

    package var bytes: [UInt8] { LocalMCPBase64URL.decode(encodedValue)! }
    package var canonicalEncodedValue: String { encodedValue }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedValue = try container.decode(String.self)
        do {
            try self.init(encodedValue: encodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid pairing commitment."
            )
        }
    }

    package func constantTimeEquals(_ other: PairingCommitment) -> Bool {
        let lhs = bytes
        let rhs = other.bytes
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

extension PairingCommitment: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<pairing commitment>" }
    public var debugDescription: String { description }
}

/// The V1 pairing transcript and its SHA-256 digest.
public struct PairingTranscript: Sendable, Hashable {
    public static let protocolLabel = "LocalMCPKit pairing transcript v1"

    package let encodedBytes: [UInt8]
    package let digestBytes: [UInt8]

    public init(
        finalizedRequest request: PairingRequest,
        producerID: String,
        channelBinding: ProducerChannelBinding
    ) throws {
        try request.validateServerFinalized(
            producerID: producerID,
            channelBinding: channelBinding
        )

        guard let expectedInstanceID = request.expectedInstanceID,
              let expectedEndpoint = request.expectedEndpoint,
              let expectedProducerPublicKey = request.expectedProducerPublicKey,
              let consumerEphemeralPublicKey = request.consumerEphemeralPublicKey,
              let clientSecretCommitment = request.clientSecretCommitment,
              let pairingID = request.pairingID,
              let serverNonce = request.serverNonce,
              let revealedClientSecret = request.revealedClientSecret
        else {
            throw LocalMCPError.invalidConfiguration
        }

        let fields: [[UInt8]] = [
            Array(Self.protocolLabel.utf8),
            Array(channelBinding.suite.utf8),
            Array(request.schemaVersion.utf8),
            Array(producerID.utf8),
            Array(expectedInstanceID.utf8),
            Array(expectedEndpoint.utf8),
            expectedProducerPublicKey.rawRepresentation,
            Array(request.consumer.stableID.utf8),
            Array(request.consumer.displayName.utf8),
            Array(request.consumer.version.utf8),
            Array(request.consumer.installationID.utf8),
            request.requestNonce.withUnsafeBytes { $0 },
            consumerEphemeralPublicKey.rawRepresentation,
            clientSecretCommitment.bytes,
            pairingID.bytes,
            serverNonce.withUnsafeBytes { $0 },
            revealedClientSecret.bytes,
        ]

        var encoded: [UInt8] = []
        encoded.reserveCapacity(fields.reduce(0) { $0 + 4 + $1.count })
        for field in fields {
            guard field.count <= Int(UInt32.max) else {
                throw LocalMCPError.invalidConfiguration
            }
            let length = UInt32(field.count)
            encoded.append(UInt8(truncatingIfNeeded: length >> 24))
            encoded.append(UInt8(truncatingIfNeeded: length >> 16))
            encoded.append(UInt8(truncatingIfNeeded: length >> 8))
            encoded.append(UInt8(truncatingIfNeeded: length))
            encoded.append(contentsOf: field)
        }
        encodedBytes = encoded
        digestBytes = Array(SHA256.hash(data: Data(encoded)))
    }

    /// Makes a stable transcript digest available without exposing any secret
    /// that was not already present in the finalized request.
    public func withDigestBytes<Result: Sendable>(
        _ body: ([UInt8]) throws -> Result
    ) rethrows -> Result {
        try body(digestBytes)
    }
}

/// V1 pairing-channel primitives shared by the consumer and HTTP adapter.
package enum PairingChannelCrypto {
    static let commitmentDomain = Array("LocalMCPKit pairing commitment v1".utf8) + [0]
    static let sasDomain = Array("LocalMCPKit SAS v1".utf8) + [0]
    static let responseKeyInfo = Data("LocalMCPKit pairing response key v1".utf8)
    static let responseAADDomain = Array("LocalMCPKit pairing response aad v1".utf8) + [0]

    package static func commitment(for secret: PairingSecret) throws -> PairingCommitment {
        try PairingCommitment(
            bytes: Array(SHA256.hash(data: Data(commitmentDomain + secret.bytes)))
        )
    }

    package static func verificationCode(for transcript: PairingTranscript) -> PairingVerificationCode {
        let digest = Array(SHA256.hash(data: Data(sasDomain + transcript.digestBytes)))
        return PairingVerificationCode(firstFortyDigestBits: digest)
    }

    package static func sharedSecret(
        privateKeyRawRepresentation: [UInt8],
        peerPublicKey: ChannelBindingPublicKey
    ) throws -> SharedSecret {
        guard privateKeyRawRepresentation.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(privateKeyRawRepresentation)
            )
            let publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(peerPublicKey.rawRepresentation)
            )
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            var allZero: UInt8 = 0
            sharedSecret.withUnsafeBytes { buffer in
                for byte in buffer {
                    allZero |= byte
                }
            }
            guard allZero != 0 else { throw LocalMCPError.invalidConfiguration }
            return sharedSecret
        } catch let error as LocalMCPError {
            throw error
        } catch {
            throw LocalMCPError.invalidConfiguration
        }
    }

    package static func responseKey(
        privateKeyRawRepresentation: [UInt8],
        peerPublicKey: ChannelBindingPublicKey,
        transcript: PairingTranscript
    ) throws -> SymmetricKey {
        let secret = try sharedSecret(
            privateKeyRawRepresentation: privateKeyRawRepresentation,
            peerPublicKey: peerPublicKey
        )
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(transcript.digestBytes),
            sharedInfo: responseKeyInfo,
            outputByteCount: 32
        )
    }

    package static func responseAAD(for transcript: PairingTranscript) -> Data {
        Data(responseAADDomain + transcript.digestBytes)
    }
}
