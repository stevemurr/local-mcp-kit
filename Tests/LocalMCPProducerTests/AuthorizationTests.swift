import Foundation
import LocalMCPContracts
import LocalMCPProducer
import LocalMCPTesting
import Testing

private let authorizationProducerID = "com.example.producer"

private func consumer(_ suffix: String) -> ConsumerIdentity {
    ConsumerIdentity(
        stableID: "com.example.consumer.\(suffix)",
        displayName: "Consumer \(suffix)",
        version: "1.0.0",
        installationID: suffix == "one"
            ? "3e260e1c-bb58-4247-9733-47352fbc6c98"
            : "95a519b9-d823-4b84-913f-27211ef70773"
    )
}

private func pairingRequest(_ consumer: ConsumerIdentity, byte: UInt8) throws -> PairingRequest {
    PairingRequest(consumer: consumer, requestNonce: try PairingNonce(bytes: .init(repeating: byte, count: 32)))
}

@Suite("Pairing and authorization")
struct AuthorizationTests {
    @Test("Approval issues a scoped digest record and authenticates")
    func issuance() async throws {
        let store = InMemoryProducerGrantStore()
        let approval = RecordingPairingApprover()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: approval,
            clock: ManualLocalMCPClock(),
            random: SequenceRandomBytesGenerator()
        )
        let identity = consumer("one")
        let grant = try await manager.pair(pairingRequest(identity, byte: 9))

        #expect(grant.metadata.producerID == authorizationProducerID)
        #expect(grant.metadata.consumer == identity)
        #expect(await store.count() == 1)
        #expect(await approval.challenges().count == 1)
        #expect(try await manager.authenticate(grant.credential) == grant.metadata)
        #expect(!String(reflecting: grant).contains(grant.credential.withUnsafeEncodedValue { $0 }))
    }

    @Test("Denial is distinct from approval subsystem failure and both persist nothing")
    func denial() async throws {
        let store = InMemoryProducerGrantStore()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: RecordingPairingApprover(decision: .deny),
            random: SequenceRandomBytesGenerator()
        )
        await expectLocalError(.pairingDenied) {
            _ = try await manager.pair(pairingRequest(consumer("one"), byte: 1))
        }
        #expect(await store.count() == 0)

        struct ApprovalFailure: Error {}
        let failing = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: ClosurePairingApprover { _ in throw ApprovalFailure() },
            random: SequenceRandomBytesGenerator()
        )
        await expectLocalError(.producerUnavailable) {
            _ = try await failing.pair(pairingRequest(consumer("one"), byte: 2))
        }
        #expect(await store.count() == 0)

        let randomFailure = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: RecordingPairingApprover(),
            random: FailingAuthorizationRandom()
        )
        await expectLocalError(.producerUnavailable) {
            _ = try await randomFailure.pair(pairingRequest(consumer("one"), byte: 8))
        }
        #expect(await store.count() == 0)
    }

    @Test("Expiry is fail-closed after suspended approval")
    func expiry() async throws {
        let store = InMemoryProducerGrantStore()
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 10))
        let approval = ClosurePairingApprover { _ in
            await clock.advance(by: 120)
            return .approve
        }
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: approval,
            clock: clock,
            random: SequenceRandomBytesGenerator(),
            pairingLifetime: 120
        )
        await expectLocalError(.pairingExpired) {
            _ = try await manager.pair(pairingRequest(consumer("one"), byte: 3))
        }
        #expect(await store.count() == 0)
    }

    @Test("Expiry actively cancels an approval that is still pending")
    func activeExpiry() async throws {
        let store = InMemoryProducerGrantStore()
        let approval = ClosurePairingApprover { _ in
            try await Task.sleep(nanoseconds: UInt64.max)
            return .approve
        }
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: approval,
            clock: ManualLocalMCPClock(),
            sleeper: ImmediateLocalMCPSleeper(),
            random: SequenceRandomBytesGenerator()
        )
        await expectLocalError(.pairingExpired) {
            _ = try await manager.pair(pairingRequest(consumer("one"), byte: 33))
        }
        #expect(await store.count() == 0)
        // The pending scope was released, so a new nonce reaches approval again.
        await expectLocalError(.pairingExpired) {
            _ = try await manager.pair(pairingRequest(consumer("one"), byte: 34))
        }
    }

    @Test("A pairing nonce is one-use, including after denial")
    func nonceReplay() async throws {
        let store = InMemoryProducerGrantStore()
        let approval = RecordingPairingApprover(decision: .deny)
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: approval,
            random: SequenceRandomBytesGenerator()
        )
        let request = try pairingRequest(consumer("one"), byte: 4)
        await expectLocalError(.pairingDenied) { _ = try await manager.pair(request) }
        await approval.setDecision(.approve)
        await expectLocalError(.pairingReplayed) { _ = try await manager.pair(request) }
        #expect(await store.count() == 0)
    }

    @Test("A used nonce is rejected for ten minutes and reusable only after retention")
    func nonceRetention() async throws {
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 1_000))
        let approval = RecordingPairingApprover(decision: .deny)
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: InMemoryProducerGrantStore(),
            approval: approval,
            clock: clock,
            random: SequenceRandomBytesGenerator()
        )
        let request = try pairingRequest(consumer("one"), byte: 44)

        await expectLocalError(.pairingDenied) { _ = try await manager.pair(request) }
        await clock.advance(by: 599)
        await expectLocalError(.pairingReplayed) { _ = try await manager.pair(request) }
        #expect(await approval.challenges().count == 1)

        await clock.advance(by: 2)
        await expectLocalError(.pairingDenied) { _ = try await manager.pair(request) }
        #expect(await approval.challenges().count == 2)
    }

    @Test("A nonce remains replay-protected while its original attempt is pending")
    func pendingNonceProtection() async throws {
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 2_000))
        let approval = GatedPairingApprover()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: InMemoryProducerGrantStore(),
            approval: approval,
            clock: clock,
            random: SequenceRandomBytesGenerator()
        )
        let firstRequest = try pairingRequest(consumer("one"), byte: 45)
        let replayRequest = try pairingRequest(consumer("two"), byte: 45)

        let firstAttempt = Task {
            try await manager.pair(firstRequest)
        }
        await approval.waitUntilEntered()
        await clock.advance(by: 601)
        await expectLocalError(.pairingReplayed) {
            _ = try await manager.pair(replayRequest)
        }

        await approval.release()
        await expectLocalError(.pairingExpired) { _ = try await firstAttempt.value }
        #expect(await approval.challengeCount() == 1)
    }

    @Test("Missing, wrong, revoked, and expired credentials are rejected")
    func authenticationFailures() async throws {
        let store = InMemoryProducerGrantStore()
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 0))
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: RecordingPairingApprover(),
            clock: clock,
            random: SequenceRandomBytesGenerator()
        )
        await expectLocalError(.pairingRequired) { _ = try await manager.authenticate(nil) }
        let wrong = try AuthorizationCredential(bytes: .init(repeating: 200, count: 32))
        await expectLocalError(.unauthorized) { _ = try await manager.authenticate(wrong) }

        // Revoking a never-activated candidate removes it entirely, so the
        // credential later fails as unauthorized: an attacker holding a
        // rolled-back candidate cannot distinguish it from a credential that
        // never existed.
        let grant = try await manager.pair(pairingRequest(consumer("one"), byte: 5))
        try await manager.revoke(grantID: grant.metadata.grantID)
        try await manager.revoke(grantID: grant.metadata.grantID)
        await expectLocalError(.unauthorized) { _ = try await manager.authenticate(grant.credential) }

        // Revoking an activated grant keeps an auditable revoked record, and
        // the local API reports the distinct revocation state.
        let activated = try await manager.pair(pairingRequest(consumer("three"), byte: 6))
        _ = try await manager.authenticate(activated.credential)
        try await manager.revoke(grantID: activated.metadata.grantID)
        try await manager.revoke(grantID: activated.metadata.grantID)
        await expectLocalError(.grantRevoked) {
            _ = try await manager.authenticate(activated.credential)
        }

        let expiringMetadata = AuthorizationGrantMetadata(
            grantID: "expires",
            producerID: authorizationProducerID,
            consumer: consumer("two"),
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 10)
        )
        let expiringCredential = try AuthorizationCredential(bytes: .init(repeating: 201, count: 32))
        try await store.saveReplacingActiveGrant(
            .init(metadata: expiringMetadata, credentialDigest: expiringCredential.digest)
        )
        await clock.set(Date(timeIntervalSince1970: 10))
        await expectLocalError(.unauthorized) { _ = try await manager.authenticate(expiringCredential) }
    }

    @Test("Fresh approval rotates one consumer without affecting another")
    func rotationAndIsolation() async throws {
        let store = InMemoryProducerGrantStore()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator()
        )
        let first = try await manager.pair(pairingRequest(consumer("one"), byte: 10))
        let second = try await manager.pair(pairingRequest(consumer("two"), byte: 11))
        let rotated = try await manager.pair(pairingRequest(consumer("one"), byte: 12))

        #expect(await store.count() == 2)
        await expectLocalError(.unauthorized) { _ = try await manager.authenticate(first.credential) }
        #expect(try await manager.authenticate(second.credential).consumer == consumer("two"))
        #expect(try await manager.authenticate(rotated.credential).consumer == consumer("one"))
        #expect(first.credential != second.credential)
        #expect(first.credential != rotated.credential)
    }

    @Test("Expiry returns without joining an approval that ignores cancellation")
    func nonCooperativeApprovalExpiry() async throws {
        let store = InMemoryProducerGrantStore()
        let approval = NonCooperativePairingApprover()
        let sleeper = ControlledAuthorizationSleeper()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: approval,
            sleeper: sleeper,
            random: SequenceRandomBytesGenerator(),
            pairingLifetime: 120
        )
        let attempt = Task {
            try await manager.pair(pairingRequest(consumer("one"), byte: 72))
        }
        await approval.waitUntilEntered()
        await sleeper.waitUntilSleeping()

        let clock = ContinuousClock()
        let started = clock.now
        await sleeper.fire()
        await expectLocalError(.pairingExpired) { _ = try await attempt.value }
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await store.count() == 0)

        await approval.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await store.count() == 0)
    }

    @Test("Direct managers reject pairing lifetimes beyond the V1 cap")
    func directLifetimeCap() async throws {
        let approval = RecordingPairingApprover()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: InMemoryProducerGrantStore(),
            approval: approval,
            random: SequenceRandomBytesGenerator(),
            pairingLifetime: 120.001
        )
        await expectLocalError(.pairingDenied) {
            _ = try await manager.pair(pairingRequest(consumer("one"), byte: 73))
        }
        #expect(await approval.challenges().isEmpty)
    }

    @Test("Post-commit cancellation rolls a rotation back to the prior grant")
    func cancellationRollback() async throws {
        let store = PostCommitCancellationStore()
        let manager = AuthorizationManager(
            producerID: authorizationProducerID,
            store: store,
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator()
        )
        let prior = try await manager.pair(pairingRequest(consumer("one"), byte: 74))
        _ = try await manager.authenticate(prior.credential)
        let rotation = Task {
            try await manager.pair(pairingRequest(consumer("one"), byte: 75))
        }
        await store.waitForSecondCommit()
        rotation.cancel()
        await store.releaseSecondSave()

        await expectLocalError(.cancelled) { _ = try await rotation.value }
        #expect(try await manager.authenticate(prior.credential) == prior.metadata)
        let records = try await manager.records()
        #expect(records.count == 1)
        #expect(records.first?.metadata.grantID == prior.metadata.grantID)
    }

    @Test("Managers sharing a store cannot inspect or revoke another producer's grants")
    func sharedStoreProducerIsolation() async throws {
        let store = InMemoryProducerGrantStore()
        let firstManager = AuthorizationManager(
            producerID: "com.example.producer.first",
            store: store,
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator(fallback: 1)
        )
        let secondManager = AuthorizationManager(
            producerID: "com.example.producer.second",
            store: store,
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator(fallback: 101)
        )
        let firstGrant = try await firstManager.pair(
            pairingRequest(consumer("one"), byte: 76)
        )
        let secondGrant = try await secondManager.pair(
            pairingRequest(consumer("two"), byte: 77)
        )

        #expect(try await firstManager.records().map(\.metadata.producerID) == ["com.example.producer.first"])
        #expect(try await secondManager.records().map(\.metadata.producerID) == ["com.example.producer.second"])
        #expect(try await firstManager.record(grantID: secondGrant.metadata.grantID) == nil)
        #expect(try await secondManager.record(grantID: firstGrant.metadata.grantID) == nil)

        try await firstManager.revoke(grantID: secondGrant.metadata.grantID)
        #expect(try await secondManager.authenticate(secondGrant.credential) == secondGrant.metadata)
        try await secondManager.revoke(grantID: firstGrant.metadata.grantID)
        #expect(try await firstManager.authenticate(firstGrant.credential) == firstGrant.metadata)
    }
}

private actor GatedPairingApprover: PairingApproving {
    private var entered = false
    private var released = false
    private var challengeTotal = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        _ = challenge
        challengeTotal += 1
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .deny
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func challengeCount() -> Int { challengeTotal }
}

private actor NonCooperativePairingApprover: PairingApproving {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        _ = challenge
        entered = true
        let current = entryWaiters
        entryWaiters.removeAll()
        for waiter in current { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .approve
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor ControlledAuthorizationSleeper: LocalMCPSleeping {
    private var sleeping = false
    private var fired = false
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var fireWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for interval: TimeInterval) async throws {
        _ = interval
        sleeping = true
        let current = sleepWaiters
        sleepWaiters.removeAll()
        for waiter in current { waiter.resume() }
        if !fired {
            await withCheckedContinuation { fireWaiters.append($0) }
        }
    }

    func waitUntilSleeping() async {
        if sleeping { return }
        await withCheckedContinuation { sleepWaiters.append($0) }
    }

    func fire() {
        fired = true
        let current = fireWaiters
        fireWaiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor PostCommitCancellationStore: ProducerGrantStoring {
    private var recordsByID: [String: ProducerGrantRecord] = [:]
    private var activeGrantID: String?
    private var pendingGrantID: String?
    private var saveCount = 0
    private var secondCommitted = false
    private var secondReleased = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func stagePendingGrant(_ record: ProducerGrantRecord) async throws {
        guard case .pending = record.state else {
            throw LocalMCPError.credentialStoreFailed
        }
        saveCount += 1
        if let pendingGrantID, pendingGrantID != record.metadata.grantID {
            recordsByID.removeValue(forKey: pendingGrantID)
        }
        recordsByID[record.metadata.grantID] = record
        pendingGrantID = record.metadata.grantID

        if saveCount == 2 {
            secondCommitted = true
            let current = commitWaiters
            commitWaiters.removeAll()
            for waiter in current { waiter.resume() }
            if !secondReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
    }

    func activatePendingGrant(
        matching digest: CredentialDigest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> ProducerGrantRecord? {
        guard var record = recordsByID.values.first(where: {
            $0.credentialDigest.constantTimeEquals(digest)
        }) else { return nil }
        if record.state == .active { return record }
        guard case let .pending(expected) = record.state, expected == binding else { return nil }
        if let activeGrantID, activeGrantID != record.metadata.grantID {
            recordsByID.removeValue(forKey: activeGrantID)
        }
        record.state = .active
        recordsByID[record.metadata.grantID] = record
        activeGrantID = record.metadata.grantID
        pendingGrantID = nil
        return record
    }

    func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws {
        guard record.state == .active else { throw LocalMCPError.credentialStoreFailed }
        if let activeGrantID, activeGrantID != record.metadata.grantID {
            recordsByID.removeValue(forKey: activeGrantID)
        }
        recordsByID[record.metadata.grantID] = record
        activeGrantID = record.metadata.grantID
    }

    func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord? {
        recordsByID.values.first { $0.credentialDigest.constantTimeEquals(digest) }
    }

    func record(grantID: String) async throws -> ProducerGrantRecord? {
        recordsByID[grantID]
    }

    func records() async throws -> [ProducerGrantRecord] {
        recordsByID.values.sorted { $0.metadata.grantID < $1.metadata.grantID }
    }

    func remove(grantID: String) async throws {
        recordsByID.removeValue(forKey: grantID)
        if activeGrantID == grantID { activeGrantID = nil }
        if pendingGrantID == grantID { pendingGrantID = nil }
    }

    func waitForSecondCommit() async {
        if secondCommitted { return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    func releaseSecondSave() {
        secondReleased = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private struct FailingAuthorizationRandom: RandomBytesGenerating {
    struct Failure: Error {}
    func randomBytes(count: Int) async throws -> [UInt8] {
        _ = count
        throw Failure()
    }
}
