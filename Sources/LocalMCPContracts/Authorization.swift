import CryptoKit
import Foundation

private enum Base64URL {
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
/// future HTTP adapter and secure stores. Ordinary descriptions are redacted.
public struct AuthorizationCredential: Sendable, Hashable {
    private let encodedValue: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        encodedValue = Base64URL.encode(bytes)
    }

    public init(encodedValue: String) throws {
        guard Base64URL.decode(encodedValue)?.count == 32 else {
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
        let tokenBytes = Base64URL.decode(encodedValue)!
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

    public init(metadata: AuthorizationGrantMetadata, credential: AuthorizationCredential) {
        self.metadata = metadata
        self.credential = credential
    }
}

extension AuthorizationGrant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AuthorizationGrant(grantID: \(metadata.grantID), credential: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// The producer-side form of a grant, containing only a digest.
public struct ProducerGrantRecord: Sendable, Hashable {
    public var metadata: AuthorizationGrantMetadata
    public let credentialDigest: CredentialDigest

    public init(metadata: AuthorizationGrantMetadata, credentialDigest: CredentialDigest) {
        self.metadata = metadata
        self.credentialDigest = credentialDigest
    }
}

extension ProducerGrantRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ProducerGrantRecord(grantID: \(metadata.grantID), credentialDigest: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// A one-use 256-bit pairing nonce.
public struct PairingNonce: Sendable, Hashable, Codable {
    private let encodedValue: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw LocalMCPError.invalidConfiguration }
        encodedValue = Base64URL.encode(bytes)
    }

    public init(encodedValue: String) throws {
        guard Base64URL.decode(encodedValue)?.count == 32 else {
            throw LocalMCPError.invalidConfiguration
        }
        self.encodedValue = encodedValue
    }

    public func withUnsafeBytes<Result: Sendable>(_ body: ([UInt8]) throws -> Result) rethrows -> Result {
        try body(Base64URL.decode(encodedValue)!)
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

/// The versioned logical request used by both in-memory and future HTTP pairing.
public struct PairingRequest: Codable, Sendable, Hashable {
    public var schemaVersion: String
    public var consumer: ConsumerIdentity
    public var requestNonce: PairingNonce

    public init(
        schemaVersion: String = DiscoveryProfileVersion.current.rawValue,
        consumer: ConsumerIdentity,
        requestNonce: PairingNonce
    ) {
        self.schemaVersion = schemaVersion
        self.consumer = consumer
        self.requestNonce = requestNonce
    }
}

/// A short code shown by both apps while a pairing request is pending.
public struct PairingVerificationCode: Sendable, Hashable {
    private let value: String

    public init(nonce: PairingNonce) {
        let prefix = Array("LocalMCPKit pairing v1".utf8) + [0]
        let digest: [UInt8] = nonce.withUnsafeBytes { nonceBytes in
            Array(SHA256.hash(data: Data(prefix + nonceBytes)))
        }
        let firstTwentyBits = UInt32(digest[0]) << 12 | UInt32(digest[1]) << 4 | UInt32(digest[2]) >> 4
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var output = ""
        for shift in stride(from: 15, through: 0, by: -5) {
            output.append(alphabet[Int((firstTwentyBits >> UInt32(shift)) & 0x1f)])
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
    func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws
    func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord?
    func record(grantID: String) async throws -> ProducerGrantRecord?
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
