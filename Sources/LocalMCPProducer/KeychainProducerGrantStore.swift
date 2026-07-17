import CryptoKit
import Foundation
import LocalMCPContracts
import Security

/// Keychain-backed producer grant persistence.
///
/// Each consumer installation has one atomically replaceable item. Its encrypted
/// value can hold one active and one pending digest so rotation never destroys
/// the old authority before the consumer proves delivery. Plaintext bearer
/// credentials are never accepted by or recoverable from this store.
public actor KeychainProducerGrantStore: ProducerGrantStoring {
    public struct Configuration: Sendable, Hashable {
        public var service: String
        public var accessGroup: String?
        /// Use the data-protection keychain instead of the legacy file-based
        /// (login) keychain. Sandboxed apps MUST enable this: the file-based
        /// keychain does not honor a keychain access group inside the sandbox,
        /// so `SecItem` calls fail. Enabling it requires the app to carry a
        /// `keychain-access-groups` entitlement (a team-derived group).
        public var useDataProtectionKeychain: Bool

        public init(
            service: String = "LocalMCPKit.producer-grants.v1",
            accessGroup: String? = nil,
            useDataProtectionKeychain: Bool = false
        ) {
            self.service = service
            self.accessGroup = accessGroup
            self.useDataProtectionKeychain = useDataProtectionKeychain
        }
    }

    private let configuration: Configuration
    private let keychain: any ProducerKeychainAccess

    public init(configuration: Configuration = Configuration()) throws {
        guard Self.isValid(configuration: configuration) else {
            throw LocalMCPError.invalidConfiguration
        }
        self.configuration = configuration
        keychain = SystemProducerKeychainAccess(
            useDataProtectionKeychain: configuration.useDataProtectionKeychain
        )
    }

    init(
        configuration: Configuration = Configuration(),
        keychain: any ProducerKeychainAccess
    ) throws {
        guard Self.isValid(configuration: configuration) else {
            throw LocalMCPError.invalidConfiguration
        }
        self.configuration = configuration
        self.keychain = keychain
    }

    public func stagePendingGrant(_ record: ProducerGrantRecord) async throws {
        guard Self.isValid(record: record), case .pending = record.state else {
            throw LocalMCPError.credentialStoreFailed
        }
        do {
            let existing = try bundle(for: record.metadata)
            try writeBundle(
                active: existing.active,
                pending: record,
                metadata: record.metadata
            )
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func activatePendingGrant(
        matching digest: CredentialDigest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> ProducerGrantRecord? {
        do {
            let matches = try loadRecords().filter {
                $0.credentialDigest.constantTimeEquals(digest)
            }
            guard matches.count <= 1 else {
                throw LocalMCPError.credentialStoreFailed
            }
            guard var record = matches.first else { return nil }
            if record.state == .active { return record }
            guard case let .pending(expectedBinding) = record.state,
                  expectedBinding == binding
            else { return nil }

            let existing = try bundle(for: record.metadata)
            guard existing.pending?.metadata.grantID == record.metadata.grantID else {
                throw LocalMCPError.credentialStoreFailed
            }
            record.state = .active
            try writeBundle(active: record, pending: nil, metadata: record.metadata)
            return record
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws {
        guard Self.isValid(record: record), record.state == .active else {
            throw LocalMCPError.credentialStoreFailed
        }
        do {
            let existing = try bundle(for: record.metadata)
            try writeBundle(
                active: record,
                pending: existing.pending,
                metadata: record.metadata
            )
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord? {
        do {
            let matches = try loadRecords().filter {
                $0.credentialDigest.constantTimeEquals(digest)
            }
            guard matches.count <= 1 else {
                throw LocalMCPError.credentialStoreFailed
            }
            return matches.first
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func record(grantID: String) async throws -> ProducerGrantRecord? {
        guard !grantID.isEmpty else { throw LocalMCPError.credentialStoreFailed }
        do {
            let matches = try loadRecords().filter { $0.metadata.grantID == grantID }
            guard matches.count <= 1 else {
                throw LocalMCPError.credentialStoreFailed
            }
            return matches.first
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func remove(grantID: String) async throws {
        guard !grantID.isEmpty else { throw LocalMCPError.credentialStoreFailed }
        do {
            let matches = try loadRecords().filter { $0.metadata.grantID == grantID }
            guard matches.count <= 1 else {
                throw LocalMCPError.credentialStoreFailed
            }
            if let record = matches.first {
                let existing = try bundle(for: record.metadata)
                let active = existing.active?.metadata.grantID == grantID
                    ? nil
                    : existing.active
                let pending = existing.pending?.metadata.grantID == grantID
                    ? nil
                    : existing.pending
                try writeBundle(active: active, pending: pending, metadata: record.metadata)
            }
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func records() async throws -> [ProducerGrantRecord] {
        do {
            return try loadRecords().sorted { $0.metadata.grantID < $1.metadata.grantID }
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    private func loadRecords() throws -> [ProducerGrantRecord] {
        try keychain.readAll(
            service: configuration.service,
            accessGroup: configuration.accessGroup
        ).flatMap(Self.decodeRecords)
    }

    private func bundle(
        for metadata: AuthorizationGrantMetadata
    ) throws -> (active: ProducerGrantRecord?, pending: ProducerGrantRecord?) {
        let scoped = try loadRecords().filter { Self.sameScope($0.metadata, metadata) }
        let active = scoped.filter { $0.state == .active }
        let pending = scoped.filter {
            if case .pending = $0.state { return true }
            return false
        }
        guard active.count <= 1, pending.count <= 1 else {
            throw LocalMCPError.credentialStoreFailed
        }
        return (active.first, pending.first)
    }

    private func writeBundle(
        active: ProducerGrantRecord?,
        pending: ProducerGrantRecord?,
        metadata: AuthorizationGrantMetadata
    ) throws {
        let itemScope = scope(metadata: metadata)
        guard active != nil || pending != nil else {
            try keychain.delete(scope: itemScope)
            return
        }
        if let active {
            guard active.state == .active, Self.sameScope(active.metadata, metadata) else {
                throw LocalMCPError.credentialStoreFailed
            }
        }
        if let pending {
            guard case .pending = pending.state,
                  Self.sameScope(pending.metadata, metadata)
            else { throw LocalMCPError.credentialStoreFailed }
        }
        guard active?.metadata.grantID != pending?.metadata.grantID else {
            throw LocalMCPError.credentialStoreFailed
        }
        let payload = ProducerGrantBundlePayload(
            version: 2,
            active: active.map(Self.payload),
            pending: pending.map(Self.payload)
        )
        try keychain.upsert(scope: itemScope, data: JSONEncoder().encode(payload))
    }

    private func scope(metadata: AuthorizationGrantMetadata) -> ProducerKeychainScope {
        let components = [
            "LocalMCPKit producer grant v1",
            metadata.producerID,
            metadata.consumer.stableID,
            metadata.consumer.installationID,
        ]
        let digest = SHA256.hash(data: Data(components.joined(separator: "\0").utf8))
        let account = digest.map { String(format: "%02x", $0) }.joined()
        return ProducerKeychainScope(
            service: configuration.service,
            account: account,
            accessGroup: configuration.accessGroup
        )
    }

    private static func decodeRecords(_ data: Data) throws -> [ProducerGrantRecord] {
        let decoder = JSONDecoder()
        if let bundle = try? decoder.decode(ProducerGrantBundlePayload.self, from: data) {
            guard bundle.version == 2, bundle.active != nil || bundle.pending != nil else {
                throw LocalMCPError.credentialStoreFailed
            }
            var records: [ProducerGrantRecord] = []
            if let active = bundle.active {
                records.append(try record(from: active, state: .active))
            }
            if let pending = bundle.pending {
                records.append(try record(from: pending, state: .pending(pending.endpointBinding)))
            }
            guard records.count == Set(records.map(\.metadata.grantID)).count,
                  records.dropFirst().allSatisfy({
                      sameScope($0.metadata, records[0].metadata)
                  })
            else { throw LocalMCPError.credentialStoreFailed }
            return records
        }

        // V1 pre-channel-binding payloads migrate as active grants.
        let legacy = try decoder.decode(LegacyProducerGrantPayload.self, from: data)
        return [try record(
            from: ProducerGrantPayload(
                metadata: legacy.metadata,
                credentialDigest: legacy.credentialDigest,
                endpointBinding: nil
            ),
            state: .active
        )]
    }

    private static func record(
        from payload: ProducerGrantPayload,
        state: ProducerGrantState
    ) throws -> ProducerGrantRecord {
        let digest = try CredentialDigest(bytes: [UInt8](payload.credentialDigest))
        let record = ProducerGrantRecord(
            metadata: payload.metadata,
            credentialDigest: digest,
            state: state
        )
        guard isValid(record: record) else { throw LocalMCPError.credentialStoreFailed }
        return record
    }

    private static func payload(_ record: ProducerGrantRecord) -> ProducerGrantPayload {
        let endpointBinding: AuthorizationEndpointBinding?
        if case let .pending(binding) = record.state {
            endpointBinding = binding
        } else {
            endpointBinding = nil
        }
        return ProducerGrantPayload(
            metadata: record.metadata,
            credentialDigest: record.credentialDigest.withUnsafeBytes { Data($0) },
            endpointBinding: endpointBinding
        )
    }

    private static func sameScope(
        _ lhs: AuthorizationGrantMetadata,
        _ rhs: AuthorizationGrantMetadata
    ) -> Bool {
        lhs.producerID == rhs.producerID &&
            lhs.consumer.representsSameInstallation(as: rhs.consumer)
    }

    private static func isValid(record: ProducerGrantRecord) -> Bool {
        let stateIsValid: Bool
        switch record.state {
        case .active:
            stateIsValid = true
        case let .pending(binding):
            stateIsValid = binding?.isValid != false
        }
        return LocalMCPValidation.isStableID(record.metadata.producerID) &&
            record.metadata.consumer.isValid &&
            !record.metadata.grantID.isEmpty &&
            stateIsValid
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

private struct ProducerGrantPayload: Codable, Sendable {
    var metadata: AuthorizationGrantMetadata
    var credentialDigest: Data
    var endpointBinding: AuthorizationEndpointBinding?
}

private struct ProducerGrantBundlePayload: Codable, Sendable {
    var version: Int
    var active: ProducerGrantPayload?
    var pending: ProducerGrantPayload?
}

private struct LegacyProducerGrantPayload: Codable, Sendable {
    var metadata: AuthorizationGrantMetadata
    var credentialDigest: Data
}

struct ProducerKeychainScope: Sendable, Hashable {
    var service: String
    var account: String
    var accessGroup: String?
}

protocol ProducerKeychainAccess: Sendable {
    func readAll(service: String, accessGroup: String?) throws -> [Data]
    func upsert(scope: ProducerKeychainScope, data: Data) throws
    func delete(scope: ProducerKeychainScope) throws
}

enum ProducerKeychainAccessError: Error, Sendable, Equatable {
    case status(OSStatus)
    case invalidResult
}

struct SystemProducerKeychainAccess: ProducerKeychainAccess {
    let useDataProtectionKeychain: Bool

    init(useDataProtectionKeychain: Bool = false) {
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    func readAll(service: String, accessGroup: String?) throws -> [Data] {
        var query = serviceQuery(service: service, accessGroup: accessGroup)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ProducerKeychainAccessError.status(status)
        }
        if let values = result as? [Data] { return values }
        if let value = result as? Data { return [value] }
        throw ProducerKeychainAccessError.invalidResult
    }

    func upsert(scope: ProducerKeychainScope, data: Data) throws {
        let add = addQuery(scope: scope, data: data)
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw ProducerKeychainAccessError.status(addStatus)
        }

        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(
            baseQuery(scope: scope) as CFDictionary,
            attributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw ProducerKeychainAccessError.status(updateStatus)
        }
    }

    func delete(scope: ProducerKeychainScope) throws {
        let status = SecItemDelete(baseQuery(scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProducerKeychainAccessError.status(status)
        }
    }

    func baseQuery(scope: ProducerKeychainScope) -> [CFString: Any] {
        var query = serviceQuery(service: scope.service, accessGroup: scope.accessGroup)
        query[kSecAttrAccount] = scope.account
        return query
    }

    func serviceQuery(service: String, accessGroup: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue as Any
        }
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    func addQuery(scope: ProducerKeychainScope, data: Data) -> [CFString: Any] {
        var query = baseQuery(scope: scope)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData] = data
        return query
    }
}
