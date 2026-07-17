import Foundation
import LocalMCPContracts

/// Actor-backed producer grant storage that mirrors digest-only persistence.
public actor InMemoryProducerGrantStore: ProducerGrantStoring {
    private struct Scope: Hashable {
        let producerID: String
        let consumerID: String
        let installationID: String
    }

    private var records: [String: ProducerGrantRecord] = [:]
    private var activeGrantByScope: [Scope: String] = [:]

    public init() {}

    public func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws {
        let scope = Scope(
            producerID: record.metadata.producerID,
            consumerID: record.metadata.consumer.stableID,
            installationID: record.metadata.consumer.installationID
        )
        if let previousID = activeGrantByScope[scope], previousID != record.metadata.grantID {
            records.removeValue(forKey: previousID)
        }
        records[record.metadata.grantID] = record
        activeGrantByScope[scope] = record.metadata.grantID
    }

    public func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord? {
        records.values.first { $0.credentialDigest.constantTimeEquals(digest) }
    }

    public func record(grantID: String) async throws -> ProducerGrantRecord? {
        records[grantID]
    }

    public func remove(grantID: String) async throws {
        guard let record = records.removeValue(forKey: grantID) else { return }
        let scope = Scope(
            producerID: record.metadata.producerID,
            consumerID: record.metadata.consumer.stableID,
            installationID: record.metadata.consumer.installationID
        )
        if activeGrantByScope[scope] == grantID {
            activeGrantByScope.removeValue(forKey: scope)
        }
    }

    public func count() -> Int { records.count }

    public func allRecords() -> [ProducerGrantRecord] {
        records.values.sorted { $0.metadata.grantID < $1.metadata.grantID }
    }
}

/// Actor-backed consumer storage, keyed by stable producer and installation.
public actor InMemoryConsumerGrantStore: ConsumerGrantStoring {
    private struct Scope: Hashable {
        let producerID: String
        let consumerID: String
        let installationID: String
    }

    private var grants: [Scope: AuthorizationGrant] = [:]

    public init() {}

    public func save(_ grant: AuthorizationGrant) async throws {
        grants[scope(producerID: grant.metadata.producerID, consumer: grant.metadata.consumer)] = grant
    }

    public func grant(producerID: String, consumer: ConsumerIdentity) async throws -> AuthorizationGrant? {
        grants[scope(producerID: producerID, consumer: consumer)]
    }

    public func remove(
        producerID: String,
        consumer: ConsumerIdentity,
        ifCredentialMatches credential: AuthorizationCredential?
    ) async throws {
        let key = scope(producerID: producerID, consumer: consumer)
        guard let stored = grants[key] else { return }
        if let credential, stored.credential != credential { return }
        grants.removeValue(forKey: key)
    }

    public func count() -> Int { grants.count }

    private func scope(producerID: String, consumer: ConsumerIdentity) -> Scope {
        Scope(
            producerID: producerID,
            consumerID: consumer.stableID,
            installationID: consumer.installationID
        )
    }
}
