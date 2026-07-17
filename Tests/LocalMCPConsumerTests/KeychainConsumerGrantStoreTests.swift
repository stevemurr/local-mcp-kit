import Foundation
import LocalMCPContracts
import Security
import Testing
@testable import LocalMCPConsumer

private let keychainConsumerIdentity = ConsumerIdentity(
    stableID: "com.example.keychain-consumer",
    displayName: "Keychain Consumer",
    version: "1.0.0",
    installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
)

private let keychainProducerIdentity = ProducerIdentity(
    stableID: "com.example.keychain-producer",
    displayName: "Keychain Producer",
    version: "1.0.0"
)

private func keychainGrant(byte: UInt8, grantID: String) throws -> AuthorizationGrant {
    AuthorizationGrant(
        metadata: AuthorizationGrantMetadata(
            grantID: grantID,
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity,
            issuedAt: Date(timeIntervalSince1970: 1_900_000_000)
        ),
        credential: try AuthorizationCredential(bytes: Array(repeating: byte, count: 32))
    )
}

private func expectConsumerStoreError(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected credentialStoreFailed.")
    } catch let error as LocalMCPError {
        #expect(error == .credentialStoreFailed)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error)).")
    }
}

private final class FakeConsumerKeychainAccess: ConsumerKeychainAccess, @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private var items: [ConsumerKeychainScope: Data] = [:]
    private var shouldFail = false

    func read(scope: ConsumerKeychainScope) throws -> Data? {
        try lock.withLock {
            if shouldFail { throw Failure.injected }
            return items[scope]
        }
    }

    func upsert(scope: ConsumerKeychainScope, data: Data) throws {
        try lock.withLock {
            if shouldFail { throw Failure.injected }
            items[scope] = data
        }
    }

    func delete(scope: ConsumerKeychainScope) throws {
        try lock.withLock {
            if shouldFail { throw Failure.injected }
            items.removeValue(forKey: scope)
        }
    }

    func setFailure(_ enabled: Bool) {
        lock.withLock { shouldFail = enabled }
    }

    func replaceOnlyItem(with data: Data) {
        lock.withLock {
            guard let scope = items.keys.first else { return }
            items[scope] = data
        }
    }

    func snapshot() -> [ConsumerKeychainScope: Data] {
        lock.withLock { items }
    }
}

private actor RejectingConnector: LocalMCPConnecting {
    private(set) var calls = 0

    func connect(to instance: ProducerInstance) async throws -> any LocalMCPService {
        calls += 1
        throw LocalMCPError.producerUnavailable
    }
}

@Suite("Keychain consumer grant store")
struct KeychainConsumerGrantStoreTests {
    @Test("Channel binding survives Keychain persistence")
    func channelBindingRoundTrip() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        let base = try keychainGrant(byte: 77, grantID: "bound-grant")
        let binding = AuthorizationEndpointBinding(
            instanceID: "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
            channelBinding: ProducerChannelBinding(
                publicKey: try ChannelBindingPublicKey(
                    rawRepresentation: Array(repeating: 0x4a, count: 32)
                )
            )
        )
        let expected = AuthorizationGrant(
            metadata: base.metadata,
            credential: base.credential,
            endpointBinding: binding
        )

        try await store.save(expected)
        let restored = try await store.grant(
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity
        )
        #expect(restored == expected)
    }

    @Test("Grant survives a new store instance and secret scope fields are hashed")
    func roundTripAndHashedScope() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let configuration = KeychainConsumerGrantStore.Configuration(
            service: "com.example.tests.consumer-grants",
            accessGroup: "TEAMID.com.example.shared"
        )
        let first = try KeychainConsumerGrantStore(
            configuration: configuration,
            keychain: keychain
        )
        let expected = try keychainGrant(byte: 7, grantID: "grant-7")
        try await first.save(expected)

        let second = try KeychainConsumerGrantStore(
            configuration: configuration,
            keychain: keychain
        )
        let restored = try await second.grant(
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity
        )
        #expect(restored == expected)

        let items = keychain.snapshot()
        #expect(items.count == 1)
        let scope = try #require(items.keys.first)
        #expect(scope.service == configuration.service)
        #expect(scope.accessGroup == configuration.accessGroup)
        #expect(scope.account.count == 64)
        #expect(!scope.account.contains(keychainProducerIdentity.stableID))
        #expect(!scope.account.contains(keychainConsumerIdentity.stableID))
        #expect(!scope.account.contains(keychainConsumerIdentity.installationID))
        #expect(!scope.account.contains(expected.credential.withUnsafeEncodedValue { $0 }))
    }

    @Test("Rotation atomically replaces the installation-scoped item")
    func rotationAndConditionalRemoval() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        let old = try keychainGrant(byte: 1, grantID: "old")
        let rotated = try keychainGrant(byte: 2, grantID: "rotated")

        try await store.save(old)
        try await store.save(rotated)
        #expect(keychain.snapshot().count == 1)

        try await store.remove(
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity,
            ifCredentialMatches: old.credential
        )
        #expect(
            try await store.grant(
                producerID: keychainProducerIdentity.stableID,
                consumer: keychainConsumerIdentity
            ) == rotated
        )

        try await store.remove(
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity,
            ifCredentialMatches: rotated.credential
        )
        #expect(
            try await store.grant(
                producerID: keychainProducerIdentity.stableID,
                consumer: keychainConsumerIdentity
            ) == nil
        )
        #expect(keychain.snapshot().isEmpty)
    }

    @Test("Unconditional removal is idempotent")
    func unconditionalRemoval() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        try await store.save(try keychainGrant(byte: 3, grantID: "grant-3"))

        for _ in 0..<2 {
            try await store.remove(
                producerID: keychainProducerIdentity.stableID,
                consumer: keychainConsumerIdentity,
                ifCredentialMatches: nil
            )
        }
        #expect(keychain.snapshot().isEmpty)
    }

    @Test("A stale conditional removal cannot race away a rotated grant")
    func conditionalRemovalRace() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        let old = try keychainGrant(byte: 31, grantID: "old-race")
        let rotated = try keychainGrant(byte: 32, grantID: "rotated-race")
        try await store.save(old)

        async let save: Void = store.save(rotated)
        async let staleRemoval: Void = store.remove(
            producerID: keychainProducerIdentity.stableID,
            consumer: keychainConsumerIdentity,
            ifCredentialMatches: old.credential
        )
        _ = try await (save, staleRemoval)

        #expect(
            try await store.grant(
                producerID: keychainProducerIdentity.stableID,
                consumer: keychainConsumerIdentity
            ) == rotated
        )
    }

    @Test("Corrupt payloads and Keychain failures map to one sanitized error")
    func failuresAreSanitized() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        try await store.save(try keychainGrant(byte: 4, grantID: "grant-4"))
        keychain.replaceOnlyItem(with: Data("seeded-secret-corruption".utf8))

        await expectConsumerStoreError {
            _ = try await store.grant(
                producerID: keychainProducerIdentity.stableID,
                consumer: keychainConsumerIdentity
            )
        }

        keychain.setFailure(true)
        await expectConsumerStoreError {
            try await store.save(try keychainGrant(byte: 5, grantID: "grant-5"))
        }
    }

    @Test("Configuration rejects unsafe Keychain attribute values")
    func configurationValidation() {
        let invalidConfigurations = [
            KeychainConsumerGrantStore.Configuration(service: ""),
            KeychainConsumerGrantStore.Configuration(service: " leading"),
            KeychainConsumerGrantStore.Configuration(service: "line\nfeed"),
            KeychainConsumerGrantStore.Configuration(service: String(repeating: "a", count: 129)),
            KeychainConsumerGrantStore.Configuration(accessGroup: ""),
            KeychainConsumerGrantStore.Configuration(accessGroup: "group\nname"),
        ]

        for configuration in invalidConfigurations {
            #expect(throws: LocalMCPError.invalidConfiguration) {
                try KeychainConsumerGrantStore(configuration: configuration)
            }
        }
    }

    @Test("System queries force non-synchronizing ThisDeviceOnly items")
    func systemQueryPolicy() throws {
        let scope = ConsumerKeychainScope(
            service: "com.example.tests",
            account: String(repeating: "a", count: 64),
            accessGroup: "TEAMID.com.example.shared"
        )
        let query = SystemConsumerKeychainAccess.addQuery(scope: scope, data: Data([1, 2, 3]))

        #expect(CFEqual(query[kSecAttrSynchronizable] as CFTypeRef?, kCFBooleanFalse))
        #expect(CFEqual(query[kSecAttrAccessible] as CFTypeRef?, kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
        #expect(query[kSecAttrAccessGroup] as? String == scope.accessGroup)
        #expect(query[kSecAttrService] as? String == scope.service)
        #expect(query[kSecAttrAccount] as? String == scope.account)
    }

    @Test("Persisted stable-ID lookup never authorizes a replacement instance")
    func replacementInstanceNeedsExplicitBinding() async throws {
        let keychain = FakeConsumerKeychainAccess()
        let store = try KeychainConsumerGrantStore(keychain: keychain)
        let grant = try keychainGrant(byte: 6, grantID: "grant-6")
        try await store.save(grant)

        let replacement = ProducerInstance(
            identity: keychainProducerIdentity,
            instanceID: "95a519b9-d823-4b84-913f-27211ef70773",
            endpoint: try LoopbackEndpoint(port: 49_152, path: "/mcp"),
            descriptorURL: try LoopbackEndpoint(
                port: 49_152,
                path: "/local-mcp/v1/descriptor.json"
            )
        )
        let connector = RejectingConnector()
        let consumer = LocalMCPConsumer(
            instance: replacement,
            identity: keychainConsumerIdentity,
            connector: connector,
            grantStore: store
        )

        #expect(try await consumer.storedGrant() == grant)
        do {
            _ = try await consumer.initialize()
            Issue.record("A persisted grant was sent without explicit instance binding.")
        } catch let error as LocalMCPError {
            #expect(error == .pairingRequired)
        }
        #expect(await connector.calls == 0)
    }
}
