import CryptoKit
import Foundation
import LocalMCPContracts
import Security

/// Keychain-backed consumer grant persistence.
///
/// The bearer credential exists only inside the encrypted Keychain value. The
/// item account is a SHA-256 scope identifier, so producer/consumer installation
/// identifiers are not copied into searchable Keychain attributes. Stored grants
/// are lookup metadata only: `LocalMCPConsumer` still requires an explicit
/// authority-binding operation before sending one to a discovered instance.
public actor KeychainConsumerGrantStore: ConsumerGrantStoring {
    public struct Configuration: Sendable, Hashable {
        public var service: String
        public var accessGroup: String?

        public init(
            service: String = "LocalMCPKit.consumer-grants.v1",
            accessGroup: String? = nil
        ) {
            self.service = service
            self.accessGroup = accessGroup
        }
    }

    private let configuration: Configuration
    private let keychain: any ConsumerKeychainAccess

    public init(configuration: Configuration = Configuration()) throws {
        guard Self.isValid(configuration: configuration) else {
            throw LocalMCPError.invalidConfiguration
        }
        self.configuration = configuration
        keychain = SystemConsumerKeychainAccess()
    }

    init(
        configuration: Configuration = Configuration(),
        keychain: any ConsumerKeychainAccess
    ) throws {
        guard Self.isValid(configuration: configuration) else {
            throw LocalMCPError.invalidConfiguration
        }
        self.configuration = configuration
        self.keychain = keychain
    }

    public func save(_ grant: AuthorizationGrant) async throws {
        guard grant.metadata.producerID == grant.metadata.producerID.lowercased(),
              LocalMCPValidation.isStableID(grant.metadata.producerID),
              grant.metadata.consumer.isValid,
              !grant.metadata.grantID.isEmpty,
              grant.endpointBinding?.isValid != false
        else {
            throw LocalMCPError.credentialStoreFailed
        }

        do {
            let payload = ConsumerGrantPayload(
                metadata: grant.metadata,
                encodedCredential: grant.credential.withUnsafeEncodedValue { $0 },
                endpointBinding: grant.endpointBinding
            )
            let data = try JSONEncoder().encode(payload)
            try keychain.upsert(
                scope: scope(
                    producerID: grant.metadata.producerID,
                    consumer: grant.metadata.consumer
                ),
                data: data
            )
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func grant(
        producerID: String,
        consumer: ConsumerIdentity
    ) async throws -> AuthorizationGrant? {
        guard LocalMCPValidation.isStableID(producerID), consumer.isValid else {
            throw LocalMCPError.credentialStoreFailed
        }
        do {
            guard let data = try keychain.read(scope: scope(producerID: producerID, consumer: consumer)) else {
                return nil
            }
            let grant = try Self.decodeGrant(data)
            guard grant.metadata.producerID == producerID,
                  grant.metadata.consumer.representsSameInstallation(as: consumer)
            else {
                throw LocalMCPError.credentialStoreFailed
            }
            return grant
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func remove(
        producerID: String,
        consumer: ConsumerIdentity,
        ifCredentialMatches credential: AuthorizationCredential?
    ) async throws {
        guard LocalMCPValidation.isStableID(producerID), consumer.isValid else {
            throw LocalMCPError.credentialStoreFailed
        }
        let itemScope = scope(producerID: producerID, consumer: consumer)
        do {
            if let credential {
                guard let data = try keychain.read(scope: itemScope) else { return }
                let stored = try Self.decodeGrant(data)
                guard stored.credential.digest.constantTimeEquals(credential.digest) else { return }
            }
            try keychain.delete(scope: itemScope)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    private func scope(producerID: String, consumer: ConsumerIdentity) -> ConsumerKeychainScope {
        let components = [
            "LocalMCPKit consumer grant v1",
            producerID,
            consumer.stableID,
            consumer.installationID,
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        let account = digest.map { String(format: "%02x", $0) }.joined()
        return ConsumerKeychainScope(
            service: configuration.service,
            account: account,
            accessGroup: configuration.accessGroup
        )
    }

    private static func decodeGrant(_ data: Data) throws -> AuthorizationGrant {
        let payload = try JSONDecoder().decode(ConsumerGrantPayload.self, from: data)
        let credential = try AuthorizationCredential(encodedValue: payload.encodedCredential)
        guard LocalMCPValidation.isStableID(payload.metadata.producerID),
              payload.metadata.consumer.isValid,
              !payload.metadata.grantID.isEmpty,
              payload.endpointBinding?.isValid != false
        else {
            throw LocalMCPError.credentialStoreFailed
        }
        return AuthorizationGrant(
            metadata: payload.metadata,
            credential: credential,
            endpointBinding: payload.endpointBinding
        )
    }

    private static func isValid(configuration: Configuration) -> Bool {
        validKeychainAttribute(configuration.service, maximumUTF8Length: 128) &&
            configuration.accessGroup.map {
                validKeychainAttribute($0, maximumUTF8Length: 256)
            } ?? true
    }

    private static func validKeychainAttribute(_ value: String, maximumUTF8Length: Int) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumUTF8Length &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

private struct ConsumerGrantPayload: Codable, Sendable {
    var metadata: AuthorizationGrantMetadata
    var encodedCredential: String
    var endpointBinding: AuthorizationEndpointBinding?
}

struct ConsumerKeychainScope: Sendable, Hashable {
    var service: String
    var account: String
    var accessGroup: String?
}

protocol ConsumerKeychainAccess: Sendable {
    func read(scope: ConsumerKeychainScope) throws -> Data?
    func upsert(scope: ConsumerKeychainScope, data: Data) throws
    func delete(scope: ConsumerKeychainScope) throws
}

enum ConsumerKeychainAccessError: Error, Sendable, Equatable {
    case status(OSStatus)
    case invalidResult
}

struct SystemConsumerKeychainAccess: ConsumerKeychainAccess {
    func read(scope: ConsumerKeychainScope) throws -> Data? {
        var query = Self.baseQuery(scope: scope)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ConsumerKeychainAccessError.status(status)
        }
        guard let data = result as? Data else {
            throw ConsumerKeychainAccessError.invalidResult
        }
        return data
    }

    func upsert(scope: ConsumerKeychainScope, data: Data) throws {
        let add = Self.addQuery(scope: scope, data: data)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw ConsumerKeychainAccessError.status(addStatus)
        }

        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(
            Self.baseQuery(scope: scope) as CFDictionary,
            attributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw ConsumerKeychainAccessError.status(updateStatus)
        }
    }

    func delete(scope: ConsumerKeychainScope) throws {
        let status = SecItemDelete(Self.baseQuery(scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConsumerKeychainAccessError.status(status)
        }
    }

    static func baseQuery(scope: ConsumerKeychainScope) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: scope.service,
            kSecAttrAccount: scope.account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup = scope.accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    static func addQuery(scope: ConsumerKeychainScope, data: Data) -> [CFString: Any] {
        var query = baseQuery(scope: scope)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData] = data
        return query
    }
}
