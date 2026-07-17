import Foundation
import LocalMCPContracts
import LocalMCPTesting
import Security
import Testing
@testable import LocalMCPProducer

private let producerStoreProducerID = "com.example.keychain-producer"
private let producerStoreEndpointBinding = AuthorizationEndpointBinding(
    instanceID: "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
    channelBinding: ProducerChannelBinding(
        publicKey: try! ChannelBindingPublicKey(
            rawRepresentation: Array(repeating: 0x73, count: 32)
        )
    )
)

private func producerStoreConsumer(_ number: Int) -> ConsumerIdentity {
    ConsumerIdentity(
        stableID: "com.example.keychain-consumer-\(number)",
        displayName: "Consumer \(number)",
        version: "1.0.0",
        installationID: number == 1
            ? "3e260e1c-bb58-4247-9733-47352fbc6c98"
            : "95a519b9-d823-4b84-913f-27211ef70773"
    )
}

private func producerStoreRecord(
    grantID: String,
    consumerNumber: Int,
    credentialByte: UInt8
) throws -> (ProducerGrantRecord, AuthorizationCredential) {
    let credential = try AuthorizationCredential(
        bytes: Array(repeating: credentialByte, count: 32)
    )
    let record = ProducerGrantRecord(
        metadata: AuthorizationGrantMetadata(
            grantID: grantID,
            producerID: producerStoreProducerID,
            consumer: producerStoreConsumer(consumerNumber),
            issuedAt: Date(timeIntervalSince1970: 1_900_000_000)
        ),
        credentialDigest: credential.digest
    )
    return (record, credential)
}

private func expectProducerStoreError(
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

private final class FakeProducerKeychainAccess: ProducerKeychainAccess, @unchecked Sendable {
    enum Failure: Error { case injected }

    private let lock = NSLock()
    private var items: [ProducerKeychainScope: Data] = [:]
    private var shouldFail = false

    func readAll(service: String, accessGroup: String?) throws -> [Data] {
        try lock.withLock {
            if shouldFail { throw Failure.injected }
            return items.compactMap { scope, data in
                scope.service == service && scope.accessGroup == accessGroup ? data : nil
            }
        }
    }

    func upsert(scope: ProducerKeychainScope, data: Data) throws {
        try lock.withLock {
            if shouldFail { throw Failure.injected }
            items[scope] = data
        }
    }

    func delete(scope: ProducerKeychainScope) throws {
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

    func snapshot() -> [ProducerKeychainScope: Data] {
        lock.withLock { items }
    }
}

@Suite("Keychain producer grant store")
struct KeychainProducerGrantStoreTests {
    @Test("Pending rotation preserves the active grant until exact-bound activation")
    func pendingActivationIsAtomicAndBound() async throws {
        let keychain = FakeProducerKeychainAccess()
        let store = try KeychainProducerGrantStore(keychain: keychain)
        let (old, oldCredential) = try producerStoreRecord(
            grantID: "old-active",
            consumerNumber: 1,
            credentialByte: 81
        )
        var (candidate, candidateCredential) = try producerStoreRecord(
            grantID: "pending-candidate",
            consumerNumber: 1,
            credentialByte: 82
        )
        candidate.state = .pending(producerStoreEndpointBinding)

        try await store.saveReplacingActiveGrant(old)
        try await store.stagePendingGrant(candidate)
        #expect(keychain.snapshot().count == 1)
        #expect(try await store.record(matching: oldCredential.digest) == old)
        #expect(try await store.record(matching: candidateCredential.digest) == candidate)

        let wrongBinding = AuthorizationEndpointBinding(
            instanceID: "95a519b9-d823-4b84-913f-27211ef70773",
            channelBinding: producerStoreEndpointBinding.channelBinding
        )
        #expect(
            try await store.activatePendingGrant(
                matching: candidateCredential.digest,
                binding: wrongBinding
            ) == nil
        )
        #expect(try await store.record(matching: oldCredential.digest) == old)

        let activated = try #require(
            try await store.activatePendingGrant(
                matching: candidateCredential.digest,
                binding: producerStoreEndpointBinding
            )
        )
        #expect(activated.state == .active)
        #expect(try await store.record(matching: oldCredential.digest) == nil)
        #expect(
            try await store.activatePendingGrant(
                matching: candidateCredential.digest,
                binding: producerStoreEndpointBinding
            ) == activated
        )

        let reopened = try KeychainProducerGrantStore(keychain: keychain)
        #expect(try await reopened.record(grantID: activated.metadata.grantID) == activated)
    }

    @Test("Digest-only records survive a new store instance")
    func roundTrip() async throws {
        let keychain = FakeProducerKeychainAccess()
        let configuration = KeychainProducerGrantStore.Configuration(
            service: "com.example.tests.producer-grants",
            accessGroup: "TEAMID.com.example.shared"
        )
        let first = try KeychainProducerGrantStore(
            configuration: configuration,
            keychain: keychain
        )
        let (expected, credential) = try producerStoreRecord(
            grantID: "grant-1",
            consumerNumber: 1,
            credentialByte: 7
        )
        try await first.saveReplacingActiveGrant(expected)

        let second = try KeychainProducerGrantStore(
            configuration: configuration,
            keychain: keychain
        )
        #expect(try await second.record(grantID: "grant-1") == expected)
        #expect(try await second.record(matching: credential.digest) == expected)

        let items = keychain.snapshot()
        #expect(items.count == 1)
        let scope = try #require(items.keys.first)
        #expect(scope.account.count == 64)
        #expect(!scope.account.contains(expected.metadata.producerID))
        #expect(!scope.account.contains(expected.metadata.consumer.stableID))
        #expect(!scope.account.contains(expected.metadata.consumer.installationID))
        let rawCredential = credential.withUnsafeEncodedValue { $0 }
        #expect(!scope.account.contains(rawCredential))
        #expect(items.values.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(rawCredential) })
    }

    @Test("Rotation replaces only the matching consumer installation")
    func rotationAndIsolation() async throws {
        let keychain = FakeProducerKeychainAccess()
        let store = try KeychainProducerGrantStore(keychain: keychain)
        let (old, oldCredential) = try producerStoreRecord(
            grantID: "old",
            consumerNumber: 1,
            credentialByte: 1
        )
        let (rotated, rotatedCredential) = try producerStoreRecord(
            grantID: "rotated",
            consumerNumber: 1,
            credentialByte: 2
        )
        let (other, otherCredential) = try producerStoreRecord(
            grantID: "other",
            consumerNumber: 2,
            credentialByte: 3
        )

        try await store.saveReplacingActiveGrant(old)
        try await store.saveReplacingActiveGrant(other)
        try await store.saveReplacingActiveGrant(rotated)

        #expect(keychain.snapshot().count == 2)
        #expect(try await store.record(grantID: "old") == nil)
        #expect(try await store.record(matching: oldCredential.digest) == nil)
        #expect(try await store.record(matching: rotatedCredential.digest) == rotated)
        #expect(try await store.record(matching: otherCredential.digest) == other)
    }

    @Test("Enumeration is empty or deterministic and removal is idempotent")
    func enumerationAndRemoval() async throws {
        let keychain = FakeProducerKeychainAccess()
        let store = try KeychainProducerGrantStore(keychain: keychain)
        #expect(try await store.records().isEmpty)

        let (zRecord, _) = try producerStoreRecord(
            grantID: "z-last",
            consumerNumber: 1,
            credentialByte: 10
        )
        let (aRecord, _) = try producerStoreRecord(
            grantID: "a-first",
            consumerNumber: 2,
            credentialByte: 11
        )
        try await store.saveReplacingActiveGrant(zRecord)
        try await store.saveReplacingActiveGrant(aRecord)
        #expect(try await store.records().map(\.metadata.grantID) == ["a-first", "z-last"])

        try await store.remove(grantID: "a-first")
        try await store.remove(grantID: "a-first")
        #expect(try await store.records().map(\.metadata.grantID) == ["z-last"])
    }

    @Test("Corrupt records and Keychain failures map to one sanitized error")
    func failuresAreSanitized() async throws {
        let keychain = FakeProducerKeychainAccess()
        let store = try KeychainProducerGrantStore(keychain: keychain)
        let (record, credential) = try producerStoreRecord(
            grantID: "corrupt",
            consumerNumber: 1,
            credentialByte: 12
        )
        try await store.saveReplacingActiveGrant(record)
        keychain.replaceOnlyItem(with: Data("seeded-token-looking-corruption".utf8))

        await expectProducerStoreError { _ = try await store.records() }
        await expectProducerStoreError { _ = try await store.record(grantID: "corrupt") }
        await expectProducerStoreError { _ = try await store.record(matching: credential.digest) }

        keychain.setFailure(true)
        await expectProducerStoreError { try await store.remove(grantID: "corrupt") }
    }

    @Test("Configuration rejects unsafe Keychain attribute values")
    func configurationValidation() {
        let invalidConfigurations = [
            KeychainProducerGrantStore.Configuration(service: ""),
            KeychainProducerGrantStore.Configuration(service: " trailing "),
            KeychainProducerGrantStore.Configuration(service: "line\nfeed"),
            KeychainProducerGrantStore.Configuration(service: String(repeating: "a", count: 129)),
            KeychainProducerGrantStore.Configuration(accessGroup: ""),
            KeychainProducerGrantStore.Configuration(accessGroup: "group\nname"),
        ]

        for configuration in invalidConfigurations {
            #expect(throws: LocalMCPError.invalidConfiguration) {
                try KeychainProducerGrantStore(configuration: configuration)
            }
        }
    }

    @Test("System queries force non-synchronizing ThisDeviceOnly items")
    func systemQueryPolicy() {
        let scope = ProducerKeychainScope(
            service: "com.example.tests",
            account: String(repeating: "a", count: 64),
            accessGroup: "TEAMID.com.example.shared"
        )
        let query = SystemProducerKeychainAccess().addQuery(scope: scope, data: Data([1, 2, 3]))

        #expect(CFEqual(query[kSecAttrSynchronizable] as CFTypeRef?, kCFBooleanFalse))
        #expect(CFEqual(query[kSecAttrAccessible] as CFTypeRef?, kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
        #expect(query[kSecAttrAccessGroup] as? String == scope.accessGroup)
        #expect(query[kSecAttrService] as? String == scope.service)
        #expect(query[kSecAttrAccount] as? String == scope.account)
        // Default uses the legacy file-based keychain; the flag is absent.
        #expect(query[kSecUseDataProtectionKeychain] == nil)

        // Sandboxed apps opt into the data-protection keychain, which honors
        // the keychain access group inside the sandbox.
        let dataProtected = SystemProducerKeychainAccess(useDataProtectionKeychain: true)
            .addQuery(scope: scope, data: Data([1, 2, 3]))
        #expect(CFEqual(dataProtected[kSecUseDataProtectionKeychain] as CFTypeRef?, kCFBooleanTrue))
    }

    @Test("LocalMCPProducer exposes deterministic digest-only grant enumeration")
    func producerEnumerationWrapper() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let store = InMemoryProducerGrantStore()
        let (zRecord, _) = try producerStoreRecord(
            grantID: "z-last",
            consumerNumber: 1,
            credentialByte: 20
        )
        let (aRecord, _) = try producerStoreRecord(
            grantID: "a-first",
            consumerNumber: 2,
            credentialByte: 21
        )
        try await store.saveReplacingActiveGrant(zRecord)
        try await store.saveReplacingActiveGrant(aRecord)
        let producer = LocalMCPProducer(
            identity: ProducerIdentity(
                stableID: producerStoreProducerID,
                displayName: "Producer",
                version: "1.0.0"
            ),
            transport: environment.makeProducerTransport(),
            advertiser: environment.advertiser,
            grantStore: store,
            approval: RecordingPairingApprover()
        )

        let records = try await producer.grantRecords()
        #expect(records.map(\.metadata.grantID) == ["a-first", "z-last"])
        #expect(records.allSatisfy { $0.description == "<redacted producer grant record>" })
    }
}
