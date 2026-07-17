import Foundation
import LocalMCPContracts
import LocalMCPProducer
import LocalMCPTesting
@testable import LocalMCPTwoProducerExampleSupport
import Testing

private final class VerificationCodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ code: PairingVerificationCode) {
        lock.lock()
        defer { lock.unlock() }
        values.append(code.withUnsafeDisplayValue { $0 })
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private actor PairingApprovalPause {
    private var enteredKinds: Set<DemoProducerKind> = []
    private var entryWaiters: [DemoProducerKind: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func pause(_ kind: DemoProducerKind) async {
        enteredKinds.insert(kind)
        let waiters = entryWaiters.removeValue(forKey: kind) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered(_ kind: DemoProducerKind) async {
        guard !enteredKinds.contains(kind) else { return }
        await withCheckedContinuation { continuation in
            entryWaiters[kind, default: []].append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func expectDemoError<T>(
    _ expected: LocalMCPError,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
    }
}

private func withRunningDemo<Result: Sendable>(
    _ demo: TwoProducerDemo = TwoProducerDemo(),
    _ operation: (TwoProducerDemo) async throws -> Result
) async throws -> Result {
    do {
        _ = try await demo.start()
        let result = try await operation(demo)
        _ = await demo.stop()
        return result
    } catch {
        _ = await demo.stop()
        throw error
    }
}

@Suite("Two-producer example")
struct TwoProducerDemoTests {
    @Test("Empty snapshot describes both offline producers without endpoints")
    func emptySnapshot() {
        let snapshot = TwoProducerDemoSnapshot.empty
        #expect(snapshot.isRunning == false)
        #expect(snapshot.producers.map(\.kind) == [.greeter, .calculator])
        #expect(snapshot.producers.allSatisfy { $0.status == .offline })
        #expect(snapshot.producers.allSatisfy { $0.endpoint == nil })
        #expect(snapshot.events.isEmpty)
    }

    @Test("Starting discovers two compatible producers on distinct loopback endpoints")
    func startupAndDiscovery() async throws {
        try await withRunningDemo { demo in
            let snapshot = await demo.snapshot()
            #expect(snapshot.isRunning)
            #expect(snapshot.producers.map(\.kind) == [.greeter, .calculator])
            #expect(snapshot.producers.allSatisfy { $0.status == .discovered })
            #expect(snapshot.producers.compactMap(\.endpoint).count == 2)
            #expect(Set(snapshot.producers.compactMap(\.endpoint)).count == 2)
            #expect(snapshot.producers.compactMap(\.endpoint).allSatisfy {
                $0.hasPrefix("http://127.0.0.1:") && $0.hasSuffix("/mcp")
            })
            #expect(snapshot.events == ["Discovered Greeter Producer and Calculator Producer."])

            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.discoveredProducerIDs.sorted() == DemoProducerKind.allCases.map(\.stableID).sorted())
            #expect(diagnostics.serviceCount == 2)
            #expect(diagnostics.activeTransports.values.allSatisfy { $0 })
            #expect(diagnostics.producerStates.values.allSatisfy(Self.isRunning))
        }
    }

    @Test("Start is idempotent and does not duplicate services or events")
    func idempotentStart() async throws {
        try await withRunningDemo { demo in
            let first = await demo.snapshot()
            let second = try await demo.start()
            #expect(second == first)
            #expect(await demo.diagnostics().serviceCount == 2)
            #expect(second.events.count == 1)
        }
    }

    @Test("Both command paths reject calls before their own pairing")
    func unpairedGate() async throws {
        try await withRunningDemo { demo in
            await expectDemoError(.pairingRequired) {
                try await demo.sendGreeting(to: "Codex")
            }
            await expectDemoError(.pairingRequired) {
                try await demo.add(19, 23)
            }
            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.handlerInvocationCounts[.greeter] == 0)
            #expect(diagnostics.handlerInvocationCounts[.calculator] == 0)
            #expect(diagnostics.consumerGrantCount == 0)
        }
    }

    @Test("Pairing one producer initializes it and lists only its own command")
    func pairOneProducer() async throws {
        try await withRunningDemo { demo in
            let codes = VerificationCodeRecorder()
            let snapshot = try await demo.pair(with: .greeter) { code in
                codes.record(code)
            }

            #expect(snapshot.producer(.greeter)?.status == .paired)
            #expect(snapshot.producer(.greeter)?.tools == ["greeting.hello"])
            #expect(snapshot.producer(.calculator)?.status == .discovered)
            #expect(snapshot.producer(.calculator)?.tools.isEmpty == true)
            #expect(codes.snapshot().count == 1)

            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.approvalCounts[.greeter] == 1)
            #expect(diagnostics.approvalCounts[.calculator] == 0)
            #expect(diagnostics.producerGrantCounts[.greeter] == 1)
            #expect(diagnostics.producerGrantCounts[.calculator] == 0)
            #expect(diagnostics.consumerGrantCount == 1)
        }
    }

    @Test("One consumer installation receives independent grants for both producers")
    func independentGrants() async throws {
        try await withRunningDemo { demo in
            let greeterCodes = VerificationCodeRecorder()
            let calculatorCodes = VerificationCodeRecorder()
            _ = try await demo.pair(with: .greeter) { code in
                greeterCodes.record(code)
            }
            let snapshot = try await demo.pair(with: .calculator) { code in
                calculatorCodes.record(code)
            }

            #expect(snapshot.producers.allSatisfy { $0.isPaired })
            #expect(snapshot.producer(.greeter)?.tools == ["greeting.hello"])
            #expect(snapshot.producer(.calculator)?.tools == ["math.add"])

            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.consumerGrantCount == 2)
            #expect(diagnostics.producerGrantCounts[.greeter] == 1)
            #expect(diagnostics.producerGrantCounts[.calculator] == 1)
            #expect(diagnostics.approvalCounts[.greeter] == 1)
            #expect(diagnostics.approvalCounts[.calculator] == 1)
            let codes = greeterCodes.snapshot() + calculatorCodes.snapshot()
            #expect(codes.count == 2)
            #expect(Set(codes).count == 2)
        }
    }

    @Test("Typed greeting and addition calls route to the correct handlers")
    func typedCalls() async throws {
        try await withRunningDemo { demo in
            _ = try await demo.pair(with: .greeter)
            _ = try await demo.pair(with: .calculator)
            let greeted = try await demo.sendGreeting(to: "  Codex  ")
            let calculated = try await demo.add(19, 23)

            #expect(greeted.producer(.greeter)?.lastResult == "Hello, Codex!")
            #expect(greeted.producer(.calculator)?.lastResult == nil)
            #expect(calculated.producer(.calculator)?.lastResult == "19 + 23 = 42")
            #expect(calculated.producer(.greeter)?.lastResult == "Hello, Codex!")
            #expect(calculated.producer(.greeter)?.invocationCount == 1)
            #expect(calculated.producer(.calculator)?.invocationCount == 1)

            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.handlerInvocationCounts[.greeter] == 1)
            #expect(diagnostics.handlerInvocationCounts[.calculator] == 1)
        }
    }

    @Test("Greeting validation rejects blank and oversized names before recording an invocation")
    func greetingValidation() async throws {
        try await withRunningDemo { demo in
            _ = try await demo.pair(with: .greeter)
            await expectDemoError(.invalidCommandInput) {
                try await demo.sendGreeting(to: "   ")
            }
            await expectDemoError(.invalidCommandInput) {
                try await demo.sendGreeting(to: String(repeating: "a", count: 81))
            }
            #expect(await demo.diagnostics().handlerInvocationCounts[.greeter] == 0)

            let snapshot = try await demo.sendGreeting(to: String(repeating: "a", count: 80))
            #expect(snapshot.producer(.greeter)?.lastResult?.count == 88)
            #expect(await demo.diagnostics().handlerInvocationCounts[.greeter] == 1)
        }
    }

    @Test("Addition rejects signed integer overflow without recording an invocation")
    func additionOverflow() async throws {
        try await withRunningDemo { demo in
            _ = try await demo.pair(with: .calculator)
            await expectDemoError(.invalidCommandInput) {
                try await demo.add(Int.max, 1)
            }
            await expectDemoError(.invalidCommandInput) {
                try await demo.add(Int.min, -1)
            }
            #expect(await demo.diagnostics().handlerInvocationCounts[.calculator] == 0)
            let snapshot = try await demo.add(-5, 2)
            #expect(snapshot.producer(.calculator)?.lastResult == "-5 + 2 = -3")
            #expect(await demo.diagnostics().handlerInvocationCounts[.calculator] == 1)
        }
    }

    @Test("Revoking one grant is observed by its consumer and leaves the other producer usable")
    func isolatedRevocation() async throws {
        try await withRunningDemo { demo in
            _ = try await demo.pair(with: .greeter)
            _ = try await demo.pair(with: .calculator)
            let revoked = try await demo.revoke(.greeter)

            #expect(revoked.producer(.greeter)?.status == .revoked)
            #expect(revoked.producer(.calculator)?.status == .paired)
            await expectDemoError(.pairingRequired) {
                try await demo.sendGreeting(to: "blocked")
            }
            let calculated = try await demo.add(1, 2)
            #expect(calculated.producer(.calculator)?.lastResult == "1 + 2 = 3")

            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.consumerGrantCount == 1)
            #expect(diagnostics.producerGrantCounts[.greeter] == 1)
            #expect(diagnostics.revokedProducerGrantCounts[.greeter] == 1)
            #expect(diagnostics.producerGrantCounts[.calculator] == 1)

            let repaired = try await demo.pair(with: .greeter)
            #expect(repaired.producer(.greeter)?.status == .paired)
            #expect(await demo.diagnostics().approvalCounts[.greeter] == 2)
        }
    }

    @Test("Stop is idempotent and removes both discovery and transport resources")
    func stopCleanup() async throws {
        let demo = TwoProducerDemo()
        _ = try await demo.start()
        _ = try await demo.pair(with: .greeter)
        let first = await demo.stop()
        let second = await demo.stop()

        #expect(first.isRunning == false)
        #expect(first.producers.allSatisfy { $0.status == .offline && $0.endpoint == nil })
        #expect(second == first)
        let diagnostics = await demo.diagnostics()
        #expect(diagnostics.discoveredProducerIDs.isEmpty)
        #expect(diagnostics.serviceCount == 0)
        #expect(diagnostics.activeTransports.values.allSatisfy { !$0 })
        #expect(diagnostics.producerStates.values.allSatisfy { $0 == .stopped })
    }

    @Test("Reset starts fresh sessions that require and permit a fresh pairing")
    func resetDoesNotReuseTrust() async throws {
        try await withRunningDemo { demo in
            _ = try await demo.pair(with: .greeter)
            _ = try await demo.sendGreeting(to: "Before")
            let beforeEndpoint = await demo.snapshot().producer(.greeter)?.endpoint
            let reset = try await demo.reset()

            #expect(reset.isRunning)
            #expect(reset.producers.allSatisfy { $0.status == .discovered })
            #expect(reset.producers.allSatisfy { $0.lastResult == nil && $0.invocationCount == 0 })
            #expect(reset.producer(.greeter)?.endpoint != beforeEndpoint)
            await expectDemoError(.pairingRequired) {
                try await demo.sendGreeting(to: "After")
            }
            let repaired = try await demo.pair(with: .greeter)
            #expect(repaired.producer(.greeter)?.status == .paired)
            let called = try await demo.sendGreeting(to: "After")
            #expect(called.producer(.greeter)?.lastResult == "Hello, After!")
            #expect(await demo.diagnostics().approvalCounts[.greeter] == 2)
            #expect(await demo.diagnostics().serviceCount == 2)
        }
    }

    @Test("A second-producer bind failure rolls back the first producer and partial registration")
    func startupRollback() async {
        let demo = TwoProducerDemo(calculatorTransportFailure: .afterRegistration)
        await expectDemoError(.bindFailed) {
            try await demo.start()
        }
        let snapshot = await demo.snapshot()
        #expect(snapshot.isRunning == false)
        #expect(snapshot.producers.allSatisfy { $0.status == .offline })

        let diagnostics = await demo.diagnostics()
        #expect(diagnostics.discoveredProducerIDs.isEmpty)
        #expect(diagnostics.serviceCount == 0)
        #expect(diagnostics.activeTransports.values.allSatisfy { !$0 })
        #expect(diagnostics.producerStates.values.allSatisfy { $0 == .stopped })
    }

    @Test(
        "Pairing finalization failures revoke and remove the partial grant",
        arguments: [
            DemoPairingFinalizationFailure.initialization(.greeter),
            DemoPairingFinalizationFailure.toolListing(.calculator),
        ]
    )
    func pairingFinalizationRollback(_ failure: DemoPairingFinalizationFailure) async throws {
        let kind: DemoProducerKind
        switch failure {
        case let .initialization(failedKind), let .toolListing(failedKind):
            kind = failedKind
        case .none:
            Issue.record("A failure point is required")
            return
        }

        let demo = TwoProducerDemo(pairingFinalizationFailure: failure)
        try await withRunningDemo(demo) { demo in
            await expectDemoError(.commandFailed) {
                try await demo.pair(with: kind)
            }

            let failed = await demo.snapshot()
            #expect(failed.producer(kind)?.status == .discovered)
            #expect(failed.producer(kind)?.tools.isEmpty == true)
            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.consumerGrantCount == 0)
            switch failure {
            case .initialization:
                // The candidate never authenticated, so safe rotation removes
                // the unactivated pending grant instead of revoking it.
                #expect(diagnostics.producerGrantCounts[kind] == 0)
                #expect(diagnostics.revokedProducerGrantCounts[kind] == 0)
            case .toolListing:
                // Initialization activated the candidate, so rollback keeps a
                // revoked record rather than deleting an activated credential.
                #expect(diagnostics.producerGrantCounts[kind] == 1)
                #expect(diagnostics.revokedProducerGrantCounts[kind] == 1)
            case .none:
                Issue.record("A failure point is required")
            }
            await expectDemoError(.pairingRequired) {
                if kind == .greeter {
                    try await demo.sendGreeting(to: "blocked")
                } else {
                    try await demo.add(1, 2)
                }
            }

            let repaired = try await demo.pair(with: kind)
            #expect(repaired.producer(kind)?.status == .paired)
            let repairedDiagnostics = await demo.diagnostics()
            #expect(repairedDiagnostics.consumerGrantCount == 1)
            #expect(repairedDiagnostics.producerGrantCounts[kind] == 1)
            #expect(repairedDiagnostics.revokedProducerGrantCounts[kind] == 0)
        }
    }

    @Test("A failed rotation candidate is removed without disturbing the active grant")
    func rotationFailurePreservesActiveGrant() async throws {
        let demo = TwoProducerDemo()
        try await withRunningDemo(demo) { demo in
            _ = try await demo.pair(with: .greeter)
            let paired = await demo.diagnostics()
            #expect(paired.consumerGrantCount == 1)
            #expect(paired.producerGrantCounts[.greeter] == 1)
            #expect(paired.revokedProducerGrantCounts[.greeter] == 0)

            await demo.schedulePairingFinalizationFailure(.initialization(.greeter))
            await expectDemoError(.commandFailed) {
                try await demo.pair(with: .greeter)
            }

            // The failed rotation candidate is cleaned up while the previously
            // activated producer grant record survives untouched.
            let diagnostics = await demo.diagnostics()
            #expect(diagnostics.producerGrantCounts[.greeter] == 1)
            #expect(diagnostics.revokedProducerGrantCounts[.greeter] == 0)
            #expect(diagnostics.consumerGrantCount == 0)

            let repaired = try await demo.pair(with: .greeter)
            #expect(repaired.producer(.greeter)?.status == .paired)
            let repairedDiagnostics = await demo.diagnostics()
            #expect(repairedDiagnostics.consumerGrantCount == 1)
            #expect(repairedDiagnostics.producerGrantCounts[.greeter] == 1)
            #expect(repairedDiagnostics.revokedProducerGrantCounts[.greeter] == 0)
        }
    }

    @Test("Reset queues behind an in-flight pairing instead of tearing down its producer")
    func resetSerializesWithPairing() async throws {
        let pause = PairingApprovalPause()
        let demo = TwoProducerDemo { kind in
            await pause.pause(kind)
        }
        _ = try await demo.start()

        let pairing = Task {
            try await demo.pair(with: .greeter)
        }
        await pause.waitUntilEntered(.greeter)
        let resetting = Task {
            try await demo.reset()
        }

        var queuedOperations = 0
        for _ in 0..<1_000 {
            queuedOperations = await demo.diagnostics().queuedOperationCount
            if queuedOperations > 0 { break }
            await Task.yield()
        }
        #expect(queuedOperations == 1)

        await pause.release()
        let paired = try await pairing.value
        #expect(paired.producer(.greeter)?.status == .paired)
        let reset = try await resetting.value
        #expect(reset.isRunning)
        #expect(reset.producers.allSatisfy { $0.status == .discovered })
        #expect(await demo.diagnostics().serviceCount == 2)
        _ = await demo.stop()
    }

    @Test("Safe snapshots and events never retain verification codes or credential terminology")
    func safePresentationState() async throws {
        try await withRunningDemo { demo in
            let codes = VerificationCodeRecorder()
            let snapshot = try await demo.pair(with: .greeter) { code in
                codes.record(code)
            }
            let recordedCodes = codes.snapshot()
            #expect(recordedCodes.count == 1)
            let presentation = snapshot.events.joined(separator: "\n")
            #expect(!presentation.contains(recordedCodes[0]))
            #expect(!presentation.localizedCaseInsensitiveContains("credential"))
            #expect(!presentation.localizedCaseInsensitiveContains("nonce"))
            #expect(!presentation.localizedCaseInsensitiveContains("grantid"))
        }
    }

    private static func isRunning(_ state: LocalMCPProducerState) -> Bool {
        if case .running = state { return true }
        return false
    }
}
