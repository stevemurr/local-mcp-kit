import CryptoKit
import Foundation

package enum LocalMCPBase64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> [UInt8]? {
        guard !value.contains("="),
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
              })
        else { return nil }

        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](data)
        return encode(bytes) == value ? bytes : nil
    }
}

/// An opaque 256-bit bearer credential.
///
/// The raw value is available only through an explicitly named closure for the
/// HTTP adapter and secure stores. Ordinary descriptions are redacted.
public struct AuthorizationCredential: Sendable, Hashable {
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

    public func withUnsafeEncodedValue<Result: Sendable>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try body(encodedValue)
    }

    public var digest: CredentialDigest {
        let tokenBytes = LocalMCPBase64URL.decode(encodedValue)!
        return CredentialDigest(uncheckedBytes: Array(SHA256.hash(data: Data(tokenBytes))))
    }
}

extension AuthorizationCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted credential>" }
    public var debugDescription: String { description }
}

/// A fixed-size credential digest stored by a producer instead of a bearer token.
public struct CredentialDigest: Sendable, Hashable {
    fileprivate let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        self.bytes = bytes
    }

    fileprivate init(uncheckedBytes bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    public func withUnsafeBytes<Result: Sendable>(
        _ body: ([UInt8]) throws -> Result
    ) rethrows -> Result {
        try body(bytes)
    }

    public func constantTimeEquals(_ other: CredentialDigest) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        var difference: UInt8 = 0
        for index in bytes.indices {
            difference |= bytes[index] ^ other.bytes[index]
        }
        return difference == 0
    }
}

extension CredentialDigest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted credential digest>" }
    public var debugDescription: String { description }
}

/// Non-secret metadata shared by the producer's digest record and consumer grant.
public struct AuthorizationGrantMetadata: Codable, Sendable, Hashable {
    public var grantID: String
    public var producerID: String
    public var consumer: ConsumerIdentity
    public var issuedAt: Date
    public var expiresAt: Date?
    public var revokedAt: Date?

    public init(
        grantID: String,
        producerID: String,
        consumer: ConsumerIdentity,
        issuedAt: Date,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.grantID = grantID
        self.producerID = producerID
        self.consumer = consumer
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { date >= $0 } ?? false
    }
}

/// The consumer-side grant. It intentionally does not conform to `Codable`.
public struct AuthorizationGrant: Sendable, Hashable {
    public var metadata: AuthorizationGrantMetadata
    public let credential: AuthorizationCredential
    public let endpointBinding: AuthorizationEndpointBinding?

    public init(
        metadata: AuthorizationGrantMetadata,
        credential: AuthorizationCredential,
        endpointBinding: AuthorizationEndpointBinding? = nil
    ) {
        self.metadata = metadata
        self.credential = credential
        self.endpointBinding = endpointBinding
    }
}

extension AuthorizationGrant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted authorization grant>" }

    public var debugDescription: String { description }
}

/// The producer-side form of a grant, containing only a digest.
public struct ProducerGrantRecord: Sendable, Hashable {
    public var metadata: AuthorizationGrantMetadata
    public let credentialDigest: CredentialDigest
    public var state: ProducerGrantState

    public init(
        metadata: AuthorizationGrantMetadata,
        credentialDigest: CredentialDigest,
        state: ProducerGrantState = .active
    ) {
        self.metadata = metadata
        self.credentialDigest = credentialDigest
        self.state = state
    }
}

/// Whether a producer credential can authenticate requests yet.
///
/// Channel-bound HTTP grants are staged until the consumer proves that it
/// decrypted the pairing response. A nil pending binding is retained solely
/// for transports that do not cross a process boundary, such as test doubles.
public enum ProducerGrantState: Codable, Sendable, Hashable {
    case active
    case pending(AuthorizationEndpointBinding?)
}

extension ProducerGrantRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted producer grant record>" }

    public var debugDescription: String { description }
}

/// A one-use 256-bit pairing nonce.
public struct PairingNonce: Sendable, Hashable, Codable {
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

    public func withUnsafeBytes<Result: Sendable>(_ body: ([UInt8]) throws -> Result) rethrows -> Result {
        try body(LocalMCPBase64URL.decode(encodedValue)!)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(encodedValue: value)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid pairing nonce.")
        }
    }
}

extension PairingNonce: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted pairing nonce>" }
    public var debugDescription: String { description }
}

package struct PairingInitiatorSecrets: Sendable, Hashable {
    package let privateKeyRawRepresentation: [UInt8]
    package let clientSecret: PairingSecret
}

/// The versioned logical request used by both in-memory and HTTP pairing.
///
/// The compatibility initializer creates an unbound request for in-memory
/// transports. `init(bindingTo:)` is required for an HTTP producer. Its encoded
/// form contains only the public initiation fields; the ephemeral private key
/// and unrevealed secret are retained package-locally in the originating value.
public struct PairingRequest: Codable, Sendable, Hashable {
    public var schemaVersion: String
    public var consumer: ConsumerIdentity
    public var requestNonce: PairingNonce
    public var expectedProducerPublicKey: ChannelBindingPublicKey?
    public var expectedInstanceID: String?
    public var expectedEndpoint: String?
    public var consumerEphemeralPublicKey: ChannelBindingPublicKey?
    public var clientSecretCommitment: PairingCommitment?
    public var pairingID: PairingIdentifier?
    public var serverNonce: PairingNonce?
    public var revealedClientSecret: PairingSecret?

    package var initiatorSecrets: PairingInitiatorSecrets?

    public init(
        schemaVersion: String = DiscoveryProfileVersion.current.rawValue,
        consumer: ConsumerIdentity,
        requestNonce: PairingNonce
    ) {
        self.schemaVersion = schemaVersion
        self.consumer = consumer
        self.requestNonce = requestNonce
        expectedProducerPublicKey = nil
        expectedInstanceID = nil
        expectedEndpoint = nil
        consumerEphemeralPublicKey = nil
        clientSecretCommitment = nil
        pairingID = nil
        serverNonce = nil
        revealedClientSecret = nil
        initiatorSecrets = nil
    }

    /// Creates a channel-bound HTTP pairing initiation with fresh X25519 and
    /// 256-bit commitment material.
    public init(
        schemaVersion: String = DiscoveryProfileVersion.current.rawValue,
        consumer: ConsumerIdentity,
        requestNonce: PairingNonce,
        bindingTo instance: ProducerInstance
    ) throws {
        guard let channelBinding = instance.channelBinding,
              channelBinding.isSupported,
              LocalMCPValidation.isCanonicalLowercaseUUID(instance.instanceID),
              instance.endpoint.path == "/mcp"
        else {
            throw LocalMCPError.invalidConfiguration
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var generator = SystemRandomNumberGenerator()
        let secret = try PairingSecret(
            bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        )
        try self.init(
            schemaVersion: schemaVersion,
            consumer: consumer,
            requestNonce: requestNonce,
            expectedProducerPublicKey: channelBinding.publicKey,
            expectedInstanceID: instance.instanceID,
            expectedEndpoint: instance.endpoint.url.absoluteString,
            initiatorPrivateKeyRawRepresentation: Array(privateKey.rawRepresentation),
            clientSecret: secret
        )
    }

    package init(
        schemaVersion: String = DiscoveryProfileVersion.current.rawValue,
        consumer: ConsumerIdentity,
        requestNonce: PairingNonce,
        expectedProducerPublicKey: ChannelBindingPublicKey,
        expectedInstanceID: String,
        expectedEndpoint: String,
        initiatorPrivateKeyRawRepresentation: [UInt8],
        clientSecret: PairingSecret
    ) throws {
        guard schemaVersion == DiscoveryProfileVersion.current.rawValue,
              consumer.isValid,
              LocalMCPValidation.isCanonicalLowercaseUUID(expectedInstanceID),
              Self.isCanonicalMCPEndpoint(expectedEndpoint),
              initiatorPrivateKeyRawRepresentation.count == 32
        else {
            throw LocalMCPError.invalidConfiguration
        }
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(initiatorPrivateKeyRawRepresentation)
            )
        } catch {
            throw LocalMCPError.invalidConfiguration
        }

        self.schemaVersion = schemaVersion
        self.consumer = consumer
        self.requestNonce = requestNonce
        self.expectedProducerPublicKey = expectedProducerPublicKey
        self.expectedInstanceID = expectedInstanceID
        self.expectedEndpoint = expectedEndpoint
        consumerEphemeralPublicKey = try ChannelBindingPublicKey(privateKey.publicKey)
        clientSecretCommitment = try PairingChannelCrypto.commitment(for: clientSecret)
        pairingID = nil
        serverNonce = nil
        revealedClientSecret = nil
        initiatorSecrets = PairingInitiatorSecrets(
            privateKeyRawRepresentation: initiatorPrivateKeyRawRepresentation,
            clientSecret: clientSecret
        )
    }

    private init(
        schemaVersion: String,
        consumer: ConsumerIdentity,
        requestNonce: PairingNonce,
        expectedProducerPublicKey: ChannelBindingPublicKey?,
        expectedInstanceID: String?,
        expectedEndpoint: String?,
        consumerEphemeralPublicKey: ChannelBindingPublicKey?,
        clientSecretCommitment: PairingCommitment?,
        pairingID: PairingIdentifier?,
        serverNonce: PairingNonce?,
        revealedClientSecret: PairingSecret?,
        initiatorSecrets: PairingInitiatorSecrets?
    ) {
        self.schemaVersion = schemaVersion
        self.consumer = consumer
        self.requestNonce = requestNonce
        self.expectedProducerPublicKey = expectedProducerPublicKey
        self.expectedInstanceID = expectedInstanceID
        self.expectedEndpoint = expectedEndpoint
        self.consumerEphemeralPublicKey = consumerEphemeralPublicKey
        self.clientSecretCommitment = clientSecretCommitment
        self.pairingID = pairingID
        self.serverNonce = serverNonce
        self.revealedClientSecret = revealedClientSecret
        self.initiatorSecrets = initiatorSecrets
    }

    /// Returns the producer-side logical request after the consumer has
    /// revealed its committed secret. The returned value never retains the
    /// initiator's ephemeral private key.
    public func serverFinalized(
        pairingID: PairingIdentifier,
        serverNonce: PairingNonce,
        revealedClientSecret: PairingSecret
    ) throws -> PairingRequest {
        guard isChannelBoundInitiation,
              let clientSecretCommitment,
              clientSecretCommitment.constantTimeEquals(
                  try PairingChannelCrypto.commitment(for: revealedClientSecret)
              )
        else {
            throw LocalMCPError.invalidConfiguration
        }
        return PairingRequest(
            schemaVersion: schemaVersion,
            consumer: consumer,
            requestNonce: requestNonce,
            expectedProducerPublicKey: expectedProducerPublicKey,
            expectedInstanceID: expectedInstanceID,
            expectedEndpoint: expectedEndpoint,
            consumerEphemeralPublicKey: consumerEphemeralPublicKey,
            clientSecretCommitment: clientSecretCommitment,
            pairingID: pairingID,
            serverNonce: serverNonce,
            revealedClientSecret: revealedClientSecret,
            initiatorSecrets: nil
        )
    }

    /// True only for one complete initiation and no completion fields.
    public var isChannelBoundInitiation: Bool {
        expectedProducerPublicKey != nil &&
            expectedInstanceID != nil &&
            expectedEndpoint != nil &&
            consumerEphemeralPublicKey != nil &&
            clientSecretCommitment != nil &&
            pairingID == nil &&
            serverNonce == nil &&
            revealedClientSecret == nil
    }

    /// True only for one complete producer-side request and no local private
    /// material.
    public var isServerFinalized: Bool {
        expectedProducerPublicKey != nil &&
            expectedInstanceID != nil &&
            expectedEndpoint != nil &&
            consumerEphemeralPublicKey != nil &&
            clientSecretCommitment != nil &&
            pairingID != nil &&
            serverNonce != nil &&
            revealedClientSecret != nil &&
            initiatorSecrets == nil
    }

    package var initiatorPrivateKeyRawRepresentation: [UInt8]? {
        initiatorSecrets?.privateKeyRawRepresentation
    }

    package var localClientSecret: PairingSecret? {
        initiatorSecrets?.clientSecret
    }

    package func validateChannelBoundInitiation(expected instance: ProducerInstance) throws {
        guard isChannelBoundInitiation,
              schemaVersion == DiscoveryProfileVersion.current.rawValue,
              consumer.isValid,
              LocalMCPValidation.isCanonicalLowercaseUUID(instance.instanceID),
              let channelBinding = instance.channelBinding,
              channelBinding.isSupported,
              expectedProducerPublicKey == channelBinding.publicKey,
              expectedInstanceID == instance.instanceID,
              expectedEndpoint == instance.endpoint.url.absoluteString,
              instance.endpoint.path == "/mcp"
        else {
            throw LocalMCPError.invalidConfiguration
        }
    }

    package func validateServerFinalized(
        producerID: String,
        channelBinding: ProducerChannelBinding
    ) throws {
        guard isServerFinalized,
              schemaVersion == DiscoveryProfileVersion.current.rawValue,
              consumer.isValid,
              LocalMCPValidation.isStableID(producerID),
              channelBinding.isSupported,
              expectedProducerPublicKey == channelBinding.publicKey,
              let expectedInstanceID,
              LocalMCPValidation.isCanonicalLowercaseUUID(expectedInstanceID),
              let expectedEndpoint,
              Self.isCanonicalMCPEndpoint(expectedEndpoint),
              let clientSecretCommitment,
              let revealedClientSecret,
              clientSecretCommitment.constantTimeEquals(
                  try PairingChannelCrypto.commitment(for: revealedClientSecret)
              )
        else {
            throw LocalMCPError.invalidConfiguration
        }
    }

    private static func isCanonicalMCPEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              (1...65_535).contains(port),
              components.path == "/mcp",
              components.percentEncodedPath == "/mcp",
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else { return false }
        return components.url?.absoluteString == value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case consumer
        case requestNonce
        case expectedProducerPublicKey
        case expectedInstanceID = "expectedInstanceId"
        case expectedEndpoint
        case consumerEphemeralPublicKey
        case clientSecretCommitment
        case pairingID = "pairingId"
        case serverNonce
        case revealedClientSecret
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(String.self, forKey: .schemaVersion),
            consumer: try container.decode(ConsumerIdentity.self, forKey: .consumer),
            requestNonce: try container.decode(PairingNonce.self, forKey: .requestNonce),
            expectedProducerPublicKey: try container.decodeIfPresent(
                ChannelBindingPublicKey.self,
                forKey: .expectedProducerPublicKey
            ),
            expectedInstanceID: try container.decodeIfPresent(String.self, forKey: .expectedInstanceID),
            expectedEndpoint: try container.decodeIfPresent(String.self, forKey: .expectedEndpoint),
            consumerEphemeralPublicKey: try container.decodeIfPresent(
                ChannelBindingPublicKey.self,
                forKey: .consumerEphemeralPublicKey
            ),
            clientSecretCommitment: try container.decodeIfPresent(
                PairingCommitment.self,
                forKey: .clientSecretCommitment
            ),
            pairingID: try container.decodeIfPresent(PairingIdentifier.self, forKey: .pairingID),
            serverNonce: try container.decodeIfPresent(PairingNonce.self, forKey: .serverNonce),
            revealedClientSecret: try container.decodeIfPresent(
                PairingSecret.self,
                forKey: .revealedClientSecret
            ),
            initiatorSecrets: nil
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(consumer, forKey: .consumer)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encodeIfPresent(expectedProducerPublicKey, forKey: .expectedProducerPublicKey)
        try container.encodeIfPresent(expectedInstanceID, forKey: .expectedInstanceID)
        try container.encodeIfPresent(expectedEndpoint, forKey: .expectedEndpoint)
        try container.encodeIfPresent(consumerEphemeralPublicKey, forKey: .consumerEphemeralPublicKey)
        try container.encodeIfPresent(clientSecretCommitment, forKey: .clientSecretCommitment)
        try container.encodeIfPresent(pairingID, forKey: .pairingID)
        try container.encodeIfPresent(serverNonce, forKey: .serverNonce)
        try container.encodeIfPresent(revealedClientSecret, forKey: .revealedClientSecret)
    }

    public static func == (lhs: PairingRequest, rhs: PairingRequest) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion &&
            lhs.consumer == rhs.consumer &&
            lhs.requestNonce == rhs.requestNonce &&
            lhs.expectedProducerPublicKey == rhs.expectedProducerPublicKey &&
            lhs.expectedInstanceID == rhs.expectedInstanceID &&
            lhs.expectedEndpoint == rhs.expectedEndpoint &&
            lhs.consumerEphemeralPublicKey == rhs.consumerEphemeralPublicKey &&
            lhs.clientSecretCommitment == rhs.clientSecretCommitment &&
            lhs.pairingID == rhs.pairingID &&
            lhs.serverNonce == rhs.serverNonce &&
            lhs.revealedClientSecret == rhs.revealedClientSecret
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(consumer)
        hasher.combine(requestNonce)
        hasher.combine(expectedProducerPublicKey)
        hasher.combine(expectedInstanceID)
        hasher.combine(expectedEndpoint)
        hasher.combine(consumerEphemeralPublicKey)
        hasher.combine(clientSecretCommitment)
        hasher.combine(pairingID)
        hasher.combine(serverNonce)
        hasher.combine(revealedClientSecret)
    }
}

/// An eight-character, 40-bit Crockford Base32 code shown by both apps while a
/// pairing request is pending.
public struct PairingVerificationCode: Sendable, Hashable {
    private let value: String

    public init(nonce: PairingNonce) {
        let prefix = Array("LocalMCPKit pairing v1".utf8) + [0]
        let digest: [UInt8] = nonce.withUnsafeBytes { nonceBytes in
            Array(SHA256.hash(data: Data(prefix + nonceBytes)))
        }
        self.init(firstFortyDigestBits: digest)
    }

    public init(transcript: PairingTranscript) {
        self = PairingChannelCrypto.verificationCode(for: transcript)
    }

    package init(firstFortyDigestBits digest: [UInt8]) {
        precondition(digest.count >= 5)
        let firstFortyBits = UInt64(digest[0]) << 32 |
            UInt64(digest[1]) << 24 |
            UInt64(digest[2]) << 16 |
            UInt64(digest[3]) << 8 |
            UInt64(digest[4])
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var output = ""
        for shift in stride(from: 35, through: 0, by: -5) {
            output.append(alphabet[Int((firstFortyBits >> UInt64(shift)) & 0x1f)])
        }
        value = output
    }

    public func withUnsafeDisplayValue<Result: Sendable>(
        _ body: (String) throws -> Result
    ) rethrows -> Result {
        try body(value)
    }
}

extension PairingVerificationCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted verification code>" }
    public var debugDescription: String { description }
}

/// Sanitized information passed to a producer-owned approval UI.
public struct PairingChallenge: Sendable, Hashable {
    public var requestID: String
    public var consumer: ConsumerIdentity
    public var verificationCode: PairingVerificationCode
    public var expiresAt: Date

    public init(
        requestID: String,
        consumer: ConsumerIdentity,
        verificationCode: PairingVerificationCode,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.consumer = consumer
        self.verificationCode = verificationCode
        self.expiresAt = expiresAt
    }
}

public enum PairingDecision: Sendable, Hashable {
    case approve
    case deny
}

/// Producer persistence stores digests and grant metadata, never bearer strings.
public protocol ProducerGrantStoring: Sendable {
    /// Persists a credential that must not authenticate until activation.
    func stagePendingGrant(_ record: ProducerGrantRecord) async throws
    /// Atomically promotes only an exact pending endpoint binding. An already
    /// active matching record is returned unchanged, making retries idempotent.
    func activatePendingGrant(
        matching digest: CredentialDigest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> ProducerGrantRecord?
    func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws
    func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord?
    func record(grantID: String) async throws -> ProducerGrantRecord?
    func records() async throws -> [ProducerGrantRecord]
    func remove(grantID: String) async throws
}

/// Consumer persistence stores its own plaintext grant through a secure backend.
public protocol ConsumerGrantStoring: Sendable {
    func save(_ grant: AuthorizationGrant) async throws
    func grant(producerID: String, consumer: ConsumerIdentity) async throws -> AuthorizationGrant?
    /// Removes only when `credential` is nil or still matches the stored value.
    /// This prevents a stale failed request from deleting a concurrently rotated grant.
    func remove(
        producerID: String,
        consumer: ConsumerIdentity,
        ifCredentialMatches credential: AuthorizationCredential?
    ) async throws
}

public protocol LocalMCPClock: Sendable {
    func now() async -> Date
}

public protocol LocalMCPSleeping: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemLocalMCPClock: LocalMCPClock {
    public init() {}
    public func now() async -> Date { Date() }
}

public struct SystemLocalMCPSleeper: LocalMCPSleeping {
    public init() {}

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        let nanoseconds = UInt64(min(interval, 86_400) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public protocol RandomBytesGenerating: Sendable {
    func randomBytes(count: Int) async throws -> [UInt8]
}

public struct SystemRandomBytesGenerator: RandomBytesGenerating {
    public init() {}

    public func randomBytes(count: Int) async throws -> [UInt8] {
        guard (1...4_096).contains(count) else { throw LocalMCPError.invalidConfiguration }
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
