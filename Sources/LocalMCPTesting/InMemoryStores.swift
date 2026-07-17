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
    private var pendingGrantByScope: [Scope: String] = [:]

    public init() {}

    public func stagePendingGrant(_ record: ProducerGrantRecord) async throws {
        guard case .pending = record.state else {
            throw LocalMCPError.credentialStoreFailed
        }
        let scope = scope(for: record)
        if let previousID = pendingGrantByScope[scope], previousID != record.metadata.grantID {
            records.removeValue(forKey: previousID)
        }
        records[record.metadata.grantID] = record
        pendingGrantByScope[scope] = record.metadata.grantID
    }

    public func activatePendingGrant(
        matching digest: CredentialDigest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> ProducerGrantRecord? {
        let matches = records.values.filter { $0.credentialDigest.constantTimeEquals(digest) }
        guard matches.count <= 1 else { throw LocalMCPError.credentialStoreFailed }
        guard var record = matches.first else { return nil }
        if record.state == .active { return record }
        guard case let .pending(expectedBinding) = record.state,
              expectedBinding == binding
        else { return nil }

        let scope = scope(for: record)
        guard pendingGrantByScope[scope] == record.metadata.grantID else {
            throw LocalMCPError.credentialStoreFailed
        }
        if let previousID = activeGrantByScope[scope], previousID != record.metadata.grantID {
            records.removeValue(forKey: previousID)
        }
        record.state = .active
        records[record.metadata.grantID] = record
        pendingGrantByScope.removeValue(forKey: scope)
        activeGrantByScope[scope] = record.metadata.grantID
        return record
    }

    public func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws {
        guard record.state == .active else {
            throw LocalMCPError.credentialStoreFailed
        }
        let scope = scope(for: record)
        if let previousID = activeGrantByScope[scope], previousID != record.metadata.grantID {
            records.removeValue(forKey: previousID)
        }
        records[record.metadata.grantID] = record
        activeGrantByScope[scope] = record.metadata.grantID
    }

    public func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord? {
        let matches = records.values.filter { $0.credentialDigest.constantTimeEquals(digest) }
        guard matches.count <= 1 else { throw LocalMCPError.credentialStoreFailed }
        return matches.first
    }

    public func record(grantID: String) async throws -> ProducerGrantRecord? {
        records[grantID]
    }

    public func records() async throws -> [ProducerGrantRecord] {
        records.values.sorted { $0.metadata.grantID < $1.metadata.grantID }
    }

    public func remove(grantID: String) async throws {
        guard let record = records.removeValue(forKey: grantID) else { return }
        let scope = scope(for: record)
        if activeGrantByScope[scope] == grantID {
            activeGrantByScope.removeValue(forKey: scope)
        }
        if pendingGrantByScope[scope] == grantID {
            pendingGrantByScope.removeValue(forKey: scope)
        }
    }

    public func count() -> Int { records.count }

    public func allRecords() -> [ProducerGrantRecord] {
        records.values.sorted { $0.metadata.grantID < $1.metadata.grantID }
    }

    private func scope(for record: ProducerGrantRecord) -> Scope {
        Scope(
            producerID: record.metadata.producerID,
            consumerID: record.metadata.consumer.stableID,
            installationID: record.metadata.consumer.installationID
        )
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
