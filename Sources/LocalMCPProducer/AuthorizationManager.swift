import CryptoKit
import Foundation
import LocalMCPContracts

/// Producer-owned approval boundary. Implementations normally present UI.
public protocol PairingApproving: Sendable {
    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision
}

/// Logical pairing and per-request authorization independent of HTTP and Keychain.
public actor AuthorizationManager {
    private static let nonceRetention: TimeInterval = 10 * 60

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
    private var usedNonceDigests: [Data: Date] = [:]
    private var pendingNonceDigests: Set<Data> = []
    private var pendingScopes: Set<ConsumerScope> = []
    private var endpointBinding: AuthorizationEndpointBinding?
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

    func setEndpointBinding(_ binding: AuthorizationEndpointBinding?) throws {
        guard binding?.isValid != false else { throw LocalMCPError.invalidConfiguration }
        endpointBinding = binding
    }

    func clearEndpointBinding(ifMatching binding: AuthorizationEndpointBinding?) {
        if endpointBinding == binding {
            endpointBinding = nil
        }
    }

    public func pair(_ request: PairingRequest) async throws -> AuthorizationGrant {
        guard pairingLifetime > 0, pairingLifetime <= 120,
              request.schemaVersion == DiscoveryProfileVersion.current.rawValue,
              request.consumer.isValid
        else { throw LocalMCPError.pairingDenied }

        let pairingBinding: AuthorizationEndpointBinding?
        do {
            pairingBinding = try validatedPairingBinding(for: request)
        } catch {
            throw LocalMCPError.pairingDenied
        }

        let scope = ConsumerScope(
            stableID: request.consumer.stableID,
            installationID: request.consumer.installationID
        )
        guard pendingScopes.insert(scope).inserted else {
            throw LocalMCPError.pairingDenied
        }

        do {
            let grant = try await completePairing(request, binding: pairingBinding)
            pendingScopes.remove(scope)
            return grant
        } catch {
            pendingScopes.remove(scope)
            throw error
        }
    }

    private func completePairing(
        _ request: PairingRequest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> AuthorizationGrant {
        let nonceDigest = request.requestNonce.withUnsafeBytes {
            Data(SHA256.hash(data: Data($0)))
        }
        let startedAt = await clock.now()
        pruneUsedNonceDigests(at: startedAt)
        guard usedNonceDigests[nonceDigest] == nil,
              pendingNonceDigests.insert(nonceDigest).inserted
        else {
            throw LocalMCPError.pairingReplayed
        }
        usedNonceDigests[nonceDigest] = startedAt

        do {
            let grant = try await finishPairing(
                request,
                binding: binding,
                startedAt: startedAt
            )
            pendingNonceDigests.remove(nonceDigest)
            return grant
        } catch {
            pendingNonceDigests.remove(nonceDigest)
            throw error
        }
    }

    private func finishPairing(
        _ request: PairingRequest,
        binding: AuthorizationEndpointBinding?,
        startedAt: Date
    ) async throws -> AuthorizationGrant {

        let expiresAt = startedAt.addingTimeInterval(pairingLifetime)
        let requestID: String
        do {
            requestID = try await randomIdentifier(byteCount: 16)
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError where error == .cancelled {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
        }

        let verificationCode: PairingVerificationCode
        if let binding {
            let transcript: PairingTranscript
            do {
                transcript = try PairingTranscript(
                    finalizedRequest: request,
                    producerID: producerID,
                    channelBinding: binding.channelBinding
                )
            } catch {
                throw LocalMCPError.pairingDenied
            }
            verificationCode = PairingVerificationCode(transcript: transcript)
        } else {
            verificationCode = PairingVerificationCode(nonce: request.requestNonce)
        }

        let challenge = PairingChallenge(
            requestID: requestID,
            consumer: request.consumer,
            verificationCode: verificationCode,
            expiresAt: expiresAt
        )

        let decision: PairingDecision
        let pairingLifetime = pairingLifetime
        do {
            let operation = LocalMCPAsyncOperation<PairingDecision>(
                timeout: { [sleeper] in
                    try await sleeper.sleep(for: pairingLifetime)
                },
                timeoutError: LocalMCPError.pairingExpired
            ) { [approval] in
                try await approval.decide(challenge)
            }
            decision = try await operation.value(cancellationError: LocalMCPError.cancelled)
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError where error == .pairingExpired {
            throw error
        } catch let error as LocalMCPError where error == .cancelled {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
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
        } catch let error as LocalMCPError where error == .cancelled {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
        }

        let record = ProducerGrantRecord(
            metadata: metadata,
            credentialDigest: credential.digest,
            state: .pending(binding)
        )
        if Task.isCancelled { throw LocalMCPError.cancelled }
        await acquireMutationLock()
        guard !Task.isCancelled, endpointBinding == binding else {
            releaseMutationLock()
            throw LocalMCPError.cancelled
        }
        do {
            try await store.stagePendingGrant(record)
        } catch {
            releaseMutationLock()
            throw LocalMCPError.credentialStoreFailed
        }
        if Task.isCancelled || endpointBinding != binding {
            let removed = await removeStagedGrant(metadata.grantID)
            releaseMutationLock()
            throw removed ? LocalMCPError.cancelled : LocalMCPError.credentialStoreFailed
        }
        releaseMutationLock()
        return AuthorizationGrant(
            metadata: metadata,
            credential: credential,
            endpointBinding: binding
        )
    }

    public func authenticate(_ credential: AuthorizationCredential?) async throws -> AuthorizationGrantMetadata {
        guard let credential else { throw LocalMCPError.pairingRequired }
        let record: ProducerGrantRecord?
        do {
            record = try await store.activatePendingGrant(
                matching: credential.digest,
                binding: endpointBinding
            )
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        guard let record,
              record.state == .active,
              record.metadata.producerID == producerID
        else {
            throw LocalMCPError.unauthorized
        }
        if record.metadata.revokedAt != nil { throw LocalMCPError.grantRevoked }
        if record.metadata.isExpired(at: await clock.now()) { throw LocalMCPError.unauthorized }
        return record.metadata
    }

    public func revoke(grantID: String) async throws {
        await acquireMutationLock()
        let existing: ProducerGrantRecord?
        do {
            existing = try await store.record(grantID: grantID)
        } catch {
            releaseMutationLock()
            throw LocalMCPError.credentialStoreFailed
        }
        guard var existing,
              existing.metadata.producerID == producerID
        else {
            releaseMutationLock()
            return
        }
        if case .pending = existing.state {
            do {
                try await store.remove(grantID: existing.metadata.grantID)
            } catch {
                releaseMutationLock()
                throw LocalMCPError.credentialStoreFailed
            }
            releaseMutationLock()
            return
        }
        guard existing.metadata.revokedAt == nil else {
            releaseMutationLock()
            return
        }
        existing.metadata.revokedAt = await clock.now()
        do {
            try await store.saveReplacingActiveGrant(existing)
        } catch {
            releaseMutationLock()
            throw LocalMCPError.credentialStoreFailed
        }
        releaseMutationLock()
    }

    public func record(grantID: String) async throws -> ProducerGrantRecord? {
        do {
            let record = try await store.record(grantID: grantID)
            return record?.metadata.producerID == producerID ? record : nil
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    public func records() async throws -> [ProducerGrantRecord] {
        do {
            return try await store.records()
                .filter { $0.metadata.producerID == producerID }
                .sorted { $0.metadata.grantID < $1.metadata.grantID }
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    private func randomIdentifier(byteCount: Int) async throws -> String {
        let bytes = try await random.randomBytes(count: byteCount)
        guard bytes.count == byteCount else { throw LocalMCPError.invalidConfiguration }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func removeStagedGrant(_ grantID: String) async -> Bool {
        let rollback = Task<Void, any Error> { [store] in
            try await store.remove(grantID: grantID)
        }
        do {
            try await rollback.value
            return true
        } catch {
            return false
        }
    }

    private func validatedPairingBinding(
        for request: PairingRequest
    ) throws -> AuthorizationEndpointBinding? {
        if let endpointBinding {
            guard request.isServerFinalized,
                  request.expectedInstanceID == endpointBinding.instanceID,
                  request.expectedProducerPublicKey == endpointBinding.channelBinding.publicKey
            else { throw LocalMCPError.pairingDenied }
            try request.validateServerFinalized(
                producerID: producerID,
                channelBinding: endpointBinding.channelBinding
            )
            return endpointBinding
        }

        guard request.expectedProducerPublicKey == nil,
              request.expectedInstanceID == nil,
              request.expectedEndpoint == nil,
              request.consumerEphemeralPublicKey == nil,
              request.clientSecretCommitment == nil,
              request.pairingID == nil,
              request.serverNonce == nil,
              request.revealedClientSecret == nil,
              request.initiatorPrivateKeyRawRepresentation == nil,
              request.localClientSecret == nil
        else { throw LocalMCPError.pairingDenied }
        return nil
    }

    private func pruneUsedNonceDigests(at now: Date) {
        usedNonceDigests = usedNonceDigests.filter { digest, usedAt in
            pendingNonceDigests.contains(digest)
                || now.timeIntervalSince(usedAt) < Self.nonceRetention
        }
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
