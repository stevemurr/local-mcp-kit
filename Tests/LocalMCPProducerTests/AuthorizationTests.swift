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

    @Test("Denial and approval failure persist nothing")
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
        await expectLocalError(.pairingDenied) {
            _ = try await failing.pair(pairingRequest(consumer("one"), byte: 2))
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

        let grant = try await manager.pair(pairingRequest(consumer("one"), byte: 5))
        try await manager.revoke(grantID: grant.metadata.grantID)
        try await manager.revoke(grantID: grant.metadata.grantID)
        await expectLocalError(.grantRevoked) { _ = try await manager.authenticate(grant.credential) }

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
}
