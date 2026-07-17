import CryptoKit
import Foundation
import LocalMCPContracts

/// Producer-owned approval boundary. Implementations normally present UI.
public protocol PairingApproving: Sendable {
    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision
}

/// Logical pairing and per-request authorization independent of HTTP and Keychain.
public actor AuthorizationManager {
    private struct ConsumerScope: Hashable {
        let stableID: String
        let installationID: String
    }

    private let producerID: String
    private let store: any ProducerGrantStoring
    private let approval: any PairingApproving
    private let clock: any LocalMCPClock
    private let sleeper: any LocalMCPSleeping
    private let random: any RandomBytesGenerating
    private let pairingLifetime: TimeInterval
    private var usedNonceDigests: Set<Data> = []
    private var pendingScopes: Set<ConsumerScope> = []
    private var mutationLocked = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        producerID: String,
        store: any ProducerGrantStoring,
        approval: any PairingApproving,
        clock: any LocalMCPClock = SystemLocalMCPClock(),
        sleeper: any LocalMCPSleeping = SystemLocalMCPSleeper(),
        random: any RandomBytesGenerating = SystemRandomBytesGenerator(),
        pairingLifetime: TimeInterval = 120
    ) {
        self.producerID = producerID
        self.store = store
        self.approval = approval
        self.clock = clock
        self.sleeper = sleeper
        self.random = random
        self.pairingLifetime = pairingLifetime
    }

    public func pair(_ request: PairingRequest) async throws -> AuthorizationGrant {
        guard pairingLifetime > 0,
              request.schemaVersion == DiscoveryProfileVersion.current.rawValue,
              request.consumer.isValid
        else { throw LocalMCPError.pairingDenied }

        let scope = ConsumerScope(
            stableID: request.consumer.stableID,
            installationID: request.consumer.installationID
        )
        guard pendingScopes.insert(scope).inserted else {
            throw LocalMCPError.pairingDenied
        }
        defer { pendingScopes.remove(scope) }

        let nonceDigest = request.requestNonce.withUnsafeBytes {
            Data(SHA256.hash(data: Data($0)))
        }
        guard usedNonceDigests.insert(nonceDigest).inserted else {
            throw LocalMCPError.pairingReplayed
        }

        let startedAt = await clock.now()
        let expiresAt = startedAt.addingTimeInterval(pairingLifetime)
        let requestID: String
        do {
            requestID = try await randomIdentifier(byteCount: 16)
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch {
            throw LocalMCPError.pairingDenied
        }

        let challenge = PairingChallenge(
            requestID: requestID,
            consumer: request.consumer,
            verificationCode: PairingVerificationCode(nonce: request.requestNonce),
            expiresAt: expiresAt
        )

        let decision: PairingDecision
        let pairingLifetime = pairingLifetime
        do {
            decision = try await withThrowingTaskGroup(of: PairingDecision.self) { group in
                group.addTask { [approval] in
                    try await approval.decide(challenge)
                }
                group.addTask { [sleeper] in
                    try await sleeper.sleep(for: pairingLifetime)
                    throw LocalMCPError.pairingExpired
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw LocalMCPError.pairingDenied
                }
                return first
            }
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError where error == .pairingExpired {
            throw error
        } catch {
            throw LocalMCPError.pairingDenied
        }

        if Task.isCancelled { throw LocalMCPError.cancelled }
        guard await clock.now() < expiresAt else { throw LocalMCPError.pairingExpired }
        guard decision == .approve else { throw LocalMCPError.pairingDenied }

        let credential: AuthorizationCredential
        let metadata: AuthorizationGrantMetadata
        do {
            let grantID = try await randomIdentifier(byteCount: 16)
            credential = try await AuthorizationCredential(bytes: random.randomBytes(count: 32))
            metadata = AuthorizationGrantMetadata(
                grantID: grantID,
                producerID: producerID,
                consumer: request.consumer,
                issuedAt: await clock.now()
            )
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch {
            throw LocalMCPError.pairingDenied
        }

        let record = ProducerGrantRecord(metadata: metadata, credentialDigest: credential.digest)
        if Task.isCancelled { throw LocalMCPError.cancelled }
        await acquireMutationLock()
        defer { releaseMutationLock() }
        if Task.isCancelled { throw LocalMCPError.cancelled }
        do {
            try await store.saveReplacingActiveGrant(record)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        if Task.isCancelled {
            try? await store.remove(grantID: metadata.grantID)
            throw LocalMCPError.cancelled
        }
        return AuthorizationGrant(metadata: metadata, credential: credential)
    }

    public func authenticate(_ credential: AuthorizationCredential?) async throws -> AuthorizationGrantMetadata {
        guard let credential else { throw LocalMCPError.pairingRequired }
        let record: ProducerGrantRecord?
        do {
            record = try await store.record(matching: credential.digest)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        guard let record, record.metadata.producerID == producerID else {
            throw LocalMCPError.unauthorized
        }
        if record.metadata.revokedAt != nil { throw LocalMCPError.grantRevoked }
        if record.metadata.isExpired(at: await clock.now()) { throw LocalMCPError.unauthorized }
        return record.metadata
    }

    public func revoke(grantID: String) async throws {
        await acquireMutationLock()
        defer { releaseMutationLock() }
        let existing: ProducerGrantRecord?
        do {
            existing = try await store.record(grantID: grantID)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        guard var existing, existing.metadata.revokedAt == nil else { return }
        existing.metadata.revokedAt = await clock.now()
        do {
            try await store.saveReplacingActiveGrant(existing)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func record(grantID: String) async throws -> ProducerGrantRecord? {
        do {
            return try await store.record(grantID: grantID)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    private func randomIdentifier(byteCount: Int) async throws -> String {
        let bytes = try await random.randomBytes(count: byteCount)
        guard bytes.count == byteCount else { throw LocalMCPError.invalidConfiguration }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func acquireMutationLock() async {
        if !mutationLocked {
            mutationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationLock() {
        if mutationWaiters.isEmpty {
            mutationLocked = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}
