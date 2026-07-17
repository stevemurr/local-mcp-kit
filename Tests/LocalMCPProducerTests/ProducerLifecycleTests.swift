import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPTesting
import Testing
@testable import LocalMCPProducer

private let lifecycleIdentity = ProducerIdentity(
    stableID: "com.example.lifecycle",
    displayName: "Lifecycle",
    version: "1.0.0"
)

private let lifecycleInstanceID = "02b04cec-c3c5-4d20-b0f0-194f77a349ee"

private let lifecycleConsumer = ConsumerIdentity(
    stableID: "com.example.consumer",
    displayName: "Consumer",
    version: "1.0.0",
    installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
)

private func lifecycleDefinition(_ name: String) -> CommandDefinition {
    CommandDefinition(
        name: name,
        description: "Lifecycle command",
        inputSchema: .object(["type": .string("object")])
    )
}

private func makeLifecycleProducer(
    environment: InMemoryLocalMCPEnvironment,
    transport: any LocalMCPProducerTransport,
    configuration: LocalMCPProducerConfiguration = .localOnly(),
    approval: any PairingApproving = RecordingPairingApprover(),
    store: InMemoryProducerGrantStore = InMemoryProducerGrantStore()
) -> LocalMCPProducer {
    LocalMCPProducer(
        identity: lifecycleIdentity,
        configuration: configuration,
        instanceID: lifecycleInstanceID,
        transport: transport,
        advertiser: environment.advertiser,
        grantStore: store,
        approval: approval,
        clock: ManualLocalMCPClock(),
        random: SequenceRandomBytesGenerator()
    )
}

@Suite("Producer lifecycle")
struct ProducerLifecycleTests {
    @Test("Start and stop are idempotent, ordered, and restartable")
    func idempotentLifecycle() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = environment.makeProducerTransport()
        let producer = makeLifecycleProducer(environment: environment, transport: transport)
        #expect(await producer.state == .stopped)

        async let first: Void = producer.start()
        async let second: Void = producer.start()
        _ = try await (first, second)
        guard case let .running(firstInstance) = await producer.state else {
            Issue.record("Expected running state")
            return
        }
        #expect(await transport.callCounts().start == 1)
        #expect(await environment.discovery.snapshot() == [firstInstance])
        #expect(await environment.directory.serviceCount() == 1)

        async let firstStop: Void = producer.stop()
        async let secondStop: Void = producer.stop()
        _ = await (firstStop, secondStop)
        #expect(await producer.state == .stopped)
        #expect(await environment.discovery.snapshot().isEmpty)
        #expect(await environment.directory.serviceCount() == 0)

        try await producer.start()
        guard case let .running(secondInstance) = await producer.state else {
            Issue.record("Expected restarted producer")
            return
        }
        #expect(secondInstance.instanceID == firstInstance.instanceID)
        #expect(secondInstance.endpoint != firstInstance.endpoint)
        #expect(await transport.callCounts().start == 2)
        await producer.stop()
        await producer.stop()
    }

    @Test("Configuration is validated before any resource acquisition")
    func configurationValidation() async throws {
        for configuration in [
            LocalMCPProducerConfiguration.localOnly(endpointPath: "/wrong"),
            .localOnly(pairingLifetime: 0),
            .localOnly(pairingLifetime: 120.001),
        ] {
            let environment = InMemoryLocalMCPEnvironment()
            let transport = environment.makeProducerTransport()
            let producer = makeLifecycleProducer(
                environment: environment,
                transport: transport,
                configuration: configuration
            )
            await expectLocalError(.invalidConfiguration) { try await producer.start() }
            #expect(await transport.callCounts().start == 0)
            #expect(await environment.discovery.snapshot().isEmpty)
            #expect(await producer.state == .stopped)
        }

        let boundaryEnvironment = InMemoryLocalMCPEnvironment()
        let boundaryProducer = makeLifecycleProducer(
            environment: boundaryEnvironment,
            transport: boundaryEnvironment.makeProducerTransport(),
            configuration: .localOnly(pairingLifetime: 120)
        )
        try await boundaryProducer.start()
        guard case .running = await boundaryProducer.state else {
            Issue.record("The normative 120-second pairing lifetime must be accepted")
            return
        }
        await boundaryProducer.stop()
    }

    @Test("Invalid production transport limits remain invalidConfiguration")
    func transportConfigurationErrorIsPreserved() async {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = LocalMCPHTTPProducerTransport(handlerTimeout: 0)
        let producer = makeLifecycleProducer(environment: environment, transport: transport)

        await expectLocalError(.invalidConfiguration) {
            try await producer.start()
        }
        #expect(await transport.boundEndpoint == nil)
        #expect(await environment.discovery.snapshot().isEmpty)
        #expect(await producer.state == .stopped)
    }

    @Test("Registration is frozen only for the running lifetime")
    func registrationLifecycle() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport()
        )
        try await producer.registerDynamic(lifecycleDefinition("before")) { _, _ in .text("ok") }
        try await producer.start()
        await expectLocalError(.invalidLifecycleState) {
            try await producer.registerDynamic(lifecycleDefinition("during")) { _, _ in .text("no") }
        }
        await producer.stop()
        try await producer.registerDynamic(lifecycleDefinition("after")) { _, _ in .text("ok") }
        try await producer.start()
        await producer.stop()
    }

    @Test("Transport failure before or after acquisition fully rolls back and can retry")
    func transportFailureRollback() async throws {
        for failure in [InMemoryTransportFailure.beforeRegistration, .afterRegistration] {
            let environment = InMemoryLocalMCPEnvironment()
            let transport = InMemoryProducerTransport(directory: environment.directory, failure: failure)
            let producer = makeLifecycleProducer(environment: environment, transport: transport)
            await expectLocalError(.bindFailed) { try await producer.start() }
            #expect(await producer.state == .stopped)
            #expect(await transport.isActive() == false)
            #expect(await environment.directory.serviceCount() == 0)
            #expect(await environment.discovery.snapshot().isEmpty)

            await transport.setFailure(.none)
            try await producer.start()
            #expect(await environment.directory.serviceCount() == 1)
            await producer.stop()
        }
    }

    @Test("Advertisement failure before or after publication fully rolls back and can retry")
    func advertisementFailureRollback() async throws {
        for failure in [InMemoryAdvertisementFailure.beforePublishing, .afterPublishing] {
            let catalog = DiscoveryCatalog()
            let directory = InMemoryServiceDirectory()
            let advertiser = InMemoryAdvertiser(catalog: catalog, failure: failure)
            let transport = InMemoryProducerTransport(directory: directory)
            let producer = LocalMCPProducer(
                identity: lifecycleIdentity,
                instanceID: lifecycleInstanceID,
                transport: transport,
                advertiser: advertiser,
                grantStore: InMemoryProducerGrantStore(),
                approval: RecordingPairingApprover(),
                random: SequenceRandomBytesGenerator()
            )
            await expectLocalError(.advertisementFailed) { try await producer.start() }
            #expect(await producer.state == .stopped)
            #expect(await catalog.snapshot().isEmpty)
            #expect(await directory.serviceCount() == 0)
            #expect(await transport.isActive() == false)

            await advertiser.setFailure(.none)
            try await producer.start()
            #expect(await catalog.snapshot().count == 1)
            await producer.stop()
        }
    }

    @Test("A transport cannot substitute a different endpoint path")
    func transportPathValidation() async {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = WrongPathTransport()
        let producer = makeLifecycleProducer(environment: environment, transport: transport)
        await expectLocalError(.bindFailed) { try await producer.start() }
        #expect(await transport.stopped)
        #expect(await environment.discovery.snapshot().isEmpty)
        #expect(await producer.state == .stopped)
    }

    @Test("Concurrent callers share one failed start transition")
    func concurrentFailedStart() async {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = InMemoryProducerTransport(
            directory: environment.directory,
            failure: .beforeRegistration
        )
        let producer = makeLifecycleProducer(environment: environment, transport: transport)
        let stream = await producer.stateUpdates()
        let collector = Task { () -> [LocalMCPProducerState] in
            var values: [LocalMCPProducerState] = []
            for await value in stream {
                values.append(value)
                if value == .stopped, values.count > 1 { break }
            }
            return values
        }

        async let first: Void = producer.start()
        async let second: Void = producer.start()
        _ = try? await (first, second)
        let values = await collector.value
        #expect(values == [.stopped, .starting, .stopped])
        #expect(await transport.callCounts().start == 1)
    }

    @Test("Stopping cancels and drains an active handler")
    func stopCancelsHandler() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producerStore = InMemoryProducerGrantStore()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport(),
            store: producerStore
        )
        let entered = AsyncSignal()
        try await producer.registerDynamic(lifecycleDefinition("wait")) { _, _ in
            await entered.signal()
            try await Task.sleep(nanoseconds: UInt64.max)
            return .text("unexpected")
        }
        try await producer.start()
        let consumer = ConsumerIdentity(
            stableID: "com.example.consumer",
            displayName: "Consumer",
            version: "1.0.0",
            installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
        )
        let grant = try await producer.requestPairing(
            PairingRequest(
                consumer: consumer,
                requestNonce: try PairingNonce(bytes: .init(repeating: 8, count: 32))
            )
        )
        let call = Task {
            try await producer.callCommand(
                .init(name: "wait", arguments: .object([:]), requestID: "request"),
                credential: grant.credential
            )
        }
        await entered.wait()
        await producer.stop()
        await expectLocalError(.cancelled) { _ = try await call.value }
        #expect(await producer.state == .stopped)
        #expect(await environment.directory.serviceCount() == 0)
    }

    @Test("Calls and pairing are unavailable outside running state")
    func unavailableGuards() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport()
        )
        await expectLocalError(.producerUnavailable) {
            _ = try await producer.listCommands(credential: nil)
        }
        await expectLocalError(.producerUnavailable) {
            _ = try await producer.requestPairing(
                PairingRequest(
                    consumer: lifecycleConsumer,
                    requestNonce: try PairingNonce(bytes: .init(repeating: 3, count: 32))
                )
            )
        }
    }

    @Test("Command listing cannot publish an old epoch after stop")
    func listCommandsRejectsLateDefinitions() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport()
        )
        try await producer.registerDynamic(lifecycleDefinition("listed")) { _, _ in
            .text("ok")
        }
        try await producer.start()
        let grant = try await producer.requestPairing(
            PairingRequest(
                consumer: lifecycleConsumer,
                requestNonce: try PairingNonce(bytes: .init(repeating: 57, count: 32))
            )
        )
        let definitionsEntered = AsyncSignal()
        let definitionsRelease = AsyncSignal()
        await producer.setListCommandsCheckpointForTesting {
            await definitionsEntered.signal()
            await definitionsRelease.wait()
        }

        let listing = Task {
            try await producer.listCommands(credential: grant.credential)
        }
        await definitionsEntered.wait()
        await producer.stop()
        await definitionsRelease.signal()
        await expectLocalError(.producerUnavailable) {
            _ = try await listing.value
        }
        #expect(await producer.state == .stopped)
    }

    @Test("A cancellation-insensitive handler cannot publish success after stop")
    func stopRejectsLateSuccess() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport()
        )
        let entered = AsyncSignal()
        try await producer.registerDynamic(lifecycleDefinition("late")) { _, _ in
            await entered.signal()
            do {
                try await Task.sleep(nanoseconds: UInt64.max)
            } catch {
                // Simulate defective host code that swallows cancellation.
            }
            return .text("late success")
        }
        try await producer.start()
        let grant = try await producer.requestPairing(
            PairingRequest(
                consumer: lifecycleConsumer,
                requestNonce: try PairingNonce(bytes: .init(repeating: 54, count: 32))
            )
        )
        let call = Task {
            try await producer.callCommand(
                .init(name: "late", arguments: .object([:]), requestID: "late-request"),
                credential: grant.credential
            )
        }
        await entered.wait()
        await producer.stop()
        await expectLocalError(.cancelled) { _ = try await call.value }
        #expect(await producer.state == .stopped)
    }

    @Test("Stop is bounded while a handler remains cancellation-insensitive")
    func boundedStopWithNonCooperativeHandler() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport()
        )
        let entered = AsyncSignal()
        let release = AsyncSignal()
        try await producer.registerDynamic(lifecycleDefinition("gated-late")) { _, _ in
            await entered.signal()
            await release.wait()
            return .text("late success")
        }
        try await producer.start()
        let grant = try await producer.requestPairing(
            PairingRequest(
                consumer: lifecycleConsumer,
                requestNonce: try PairingNonce(bytes: .init(repeating: 55, count: 32))
            )
        )
        let call = Task {
            try await producer.callCommand(
                .init(name: "gated-late", arguments: .object([:]), requestID: "gated-late"),
                credential: grant.credential
            )
        }
        await entered.wait()

        let clock = ContinuousClock()
        let started = clock.now
        await producer.stop()
        #expect(started.duration(to: clock.now) < .seconds(1))
        await expectLocalError(.cancelled) { _ = try await call.value }
        #expect(await producer.state == .stopped)
        #expect(await environment.directory.serviceCount() == 0)

        await release.signal()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await producer.state == .stopped)
    }

    @Test("Stopping during startup cannot leave a late listener or advertisement")
    func stopDuringStart() async throws {
        let catalog = DiscoveryCatalog()
        let directory = InMemoryServiceDirectory(firstPort: 46_000)
        let gate = AsyncSignal()
        let release = AsyncSignal()
        let stopEntered = AsyncSignal()
        let transport = GatedStartTransport(
            directory: directory,
            entered: gate,
            release: release,
            stopEntered: stopEntered
        )
        let producer = LocalMCPProducer(
            identity: lifecycleIdentity,
            instanceID: lifecycleInstanceID,
            transport: transport,
            advertiser: InMemoryAdvertiser(catalog: catalog),
            grantStore: InMemoryProducerGrantStore(),
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator()
        )
        let starting = Task { try await producer.start() }
        await gate.wait()
        let stopping = Task { await producer.stop() }
        await stopEntered.wait()
        await release.signal()
        await expectLocalError(.cancelled) { try await starting.value }
        await stopping.value
        #expect(await producer.state == .stopped)
        #expect(await catalog.snapshot().isEmpty)
        #expect(await directory.serviceCount() == 0)

        try await producer.start()
        #expect(await directory.serviceCount() == 1)
        await producer.stop()
    }

    @Test("Abandoned startup cleanup cannot cross into a restarted epoch")
    func abandonedStartupCannotTearDownRestart() async throws {
        let catalog = DiscoveryCatalog()
        let directory = InMemoryServiceDirectory(firstPort: 47_000)
        let startupEntered = AsyncSignal()
        let startupRelease = AsyncSignal()
        let withdrawEntered = AsyncSignal()
        let transportStopEntered = AsyncSignal()
        let cleanupRelease = AsyncSignal()
        let advertiser = EpochGatedAdvertiser(
            catalog: catalog,
            startupEntered: startupEntered,
            startupRelease: startupRelease,
            withdrawEntered: withdrawEntered,
            cleanupRelease: cleanupRelease
        )
        let transport = EpochGatedTransport(
            directory: directory,
            stopEntered: transportStopEntered,
            cleanupRelease: cleanupRelease
        )
        let producer = LocalMCPProducer(
            identity: lifecycleIdentity,
            instanceID: lifecycleInstanceID,
            transport: transport,
            advertiser: advertiser,
            grantStore: InMemoryProducerGrantStore(),
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator()
        )
        let firstResult = ObservedStartResult()
        let firstStart = Task {
            do {
                try await producer.start()
                await firstResult.record(.success)
            } catch let error as LocalMCPError {
                await firstResult.record(.localError(error))
            } catch {
                await firstResult.record(.otherError)
            }
        }
        await startupEntered.wait()
        #expect(await directory.serviceCount() == 1)
        #expect(await catalog.snapshot().count == 1)

        let clock = ContinuousClock()
        let stopStarted = clock.now
        await producer.stop()
        #expect(stopStarted.duration(to: clock.now) < .seconds(1))
        #expect(await producer.state == .stopped)
        #expect(await lifecycleEventually {
            await firstResult.value() == .localError(.cancelled)
        })
        await firstStart.value

        // Registration remains available after the visible bounded stop even
        // though defective old dependencies are still converging.
        try await producer.registerDynamic(lifecycleDefinition("after-abandon")) { _, _ in
            .text("ok")
        }

        let restarted = Task { try await producer.start() }
        #expect(await lifecycleEventually { await producer.state == .starting })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await transport.startCount() == 1)

        // Let the cancelled first startup return. Its own rollback and the
        // stop-time cleanup are still blocked and must remain ahead of restart.
        await startupRelease.signal()
        await withdrawEntered.wait()
        await transportStopEntered.wait()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await transport.startCount() == 1)

        await cleanupRelease.signal()
        #expect(await lifecycleEventually { await producer.state.isRunning })
        try await restarted.value
        #expect(await transport.startCount() == 2)
        #expect(await directory.serviceCount() == 1)
        #expect(await catalog.snapshot().count == 1)

        // Give every old unstructured continuation an opportunity to run. No
        // epoch-one cleanup may withdraw or close epoch two.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await producer.state.isRunning)
        #expect(await directory.serviceCount() == 1)
        #expect(await catalog.snapshot().count == 1)
        await producer.stop()
    }

    @Test("A queued restart cannot reseal the registry after a second bounded stop")
    func abandonedQueuedRestartCannotReseal() async throws {
        let catalog = DiscoveryCatalog()
        let directory = InMemoryServiceDirectory(firstPort: 48_000)
        let startupEntered = AsyncSignal()
        let startupRelease = AsyncSignal()
        let withdrawEntered = AsyncSignal()
        let transportStopEntered = AsyncSignal()
        let cleanupRelease = AsyncSignal()
        let advertiser = EpochGatedAdvertiser(
            catalog: catalog,
            startupEntered: startupEntered,
            startupRelease: startupRelease,
            withdrawEntered: withdrawEntered,
            cleanupRelease: cleanupRelease
        )
        let transport = EpochGatedTransport(
            directory: directory,
            stopEntered: transportStopEntered,
            cleanupRelease: cleanupRelease
        )
        let producer = LocalMCPProducer(
            identity: lifecycleIdentity,
            instanceID: lifecycleInstanceID,
            transport: transport,
            advertiser: advertiser,
            grantStore: InMemoryProducerGrantStore(),
            approval: RecordingPairingApprover(),
            random: SequenceRandomBytesGenerator()
        )

        let firstResult = ObservedStartResult()
        let first = Task {
            let observation = await observeStart(of: producer)
            await firstResult.record(observation)
        }
        await startupEntered.wait()
        await producer.stop()
        #expect(await lifecycleEventually {
            await firstResult.value() == .localError(.cancelled)
        })
        await first.value

        // This restart is sealed by the producer actor, then waits behind the
        // still-blocked epoch-one resource barrier without acquiring anything.
        let queuedResult = ObservedStartResult()
        let queued = Task {
            let observation = await observeStart(of: producer)
            await queuedResult.record(observation)
        }
        #expect(await lifecycleEventually { await producer.state == .starting })
        #expect(await transport.startCount() == 1)
        await producer.stop()
        #expect(await lifecycleEventually {
            await queuedResult.value() == .localError(.cancelled)
        })
        await queued.value
        #expect(await producer.state == .stopped)

        try await producer.registerDynamic(lifecycleDefinition("during-convergence")) { _, _ in
            .text("ok")
        }
        await startupRelease.signal()
        await cleanupRelease.signal()
        #expect(await lifecycleEventually { await transport.stopCount() >= 5 })
        try? await Task.sleep(for: .milliseconds(30))

        // Neither abandoned acquisition task is permitted to mutate sealing
        // after the actor's stopped transition and unseal.
        try await producer.registerDynamic(lifecycleDefinition("after-convergence")) { _, _ in
            .text("ok")
        }
        #expect(await producer.state == .stopped)
    }

    @Test("Stopping cancels a pending approval and issues no grant")
    func stopCancelsPairing() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let entered = AsyncSignal()
        let approval = SuspendedApprover(entered: entered)
        let store = InMemoryProducerGrantStore()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport(),
            approval: approval,
            store: store
        )
        try await producer.start()
        let pairing = Task {
            try await producer.requestPairing(
                PairingRequest(
                    consumer: lifecycleConsumer,
                    requestNonce: try PairingNonce(bytes: .init(repeating: 44, count: 32))
                )
            )
        }
        await entered.wait()
        await producer.stop()
        await expectLocalError(.cancelled) { _ = try await pairing.value }
        #expect(await store.count() == 0)
    }

    @Test("Stop does not join a pending approval that ignores cancellation")
    func boundedStopWithNonCooperativeApproval() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let store = InMemoryProducerGrantStore()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: environment.makeProducerTransport(),
            approval: GatedSuspendedApprover(entered: entered, release: release),
            store: store
        )
        try await producer.start()
        let pairing = Task {
            try await producer.requestPairing(
                PairingRequest(
                    consumer: lifecycleConsumer,
                    requestNonce: try PairingNonce(bytes: .init(repeating: 56, count: 32))
                )
            )
        }
        await entered.wait()

        let clock = ContinuousClock()
        let started = clock.now
        await producer.stop()
        #expect(started.duration(to: clock.now) < .seconds(1))
        await expectLocalError(.cancelled) { _ = try await pairing.value }
        #expect(await store.count() == 0)

        await release.signal()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await store.count() == 0)
    }
}

private actor WrongPathTransport: LocalMCPProducerTransport {
    private(set) var stopped = false

    func start(endpointPath: String, service: any LocalMCPService) async throws -> LoopbackEndpoint {
        try LoopbackEndpoint(port: 45_000, path: "/wrong")
    }

    func stop() async { stopped = true }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func lifecycleEventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private extension LocalMCPProducerState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

private enum StartObservation: Sendable, Equatable {
    case pending
    case success
    case localError(LocalMCPError)
    case otherError
}

private actor ObservedStartResult {
    private var result: StartObservation = .pending

    func record(_ result: StartObservation) {
        self.result = result
    }

    func value() -> StartObservation {
        result
    }
}

private func observeStart(of producer: LocalMCPProducer) async -> StartObservation {
    do {
        try await producer.start()
        return .success
    } catch let error as LocalMCPError {
        return .localError(error)
    } catch {
        return .otherError
    }
}

private actor EpochGatedTransport: LocalMCPProducerTransport {
    private let directory: InMemoryServiceDirectory
    private let stopEntered: AsyncSignal
    private let cleanupRelease: AsyncSignal
    private var endpoint: LoopbackEndpoint?
    private var starts = 0
    private var stops = 0

    init(
        directory: InMemoryServiceDirectory,
        stopEntered: AsyncSignal,
        cleanupRelease: AsyncSignal
    ) {
        self.directory = directory
        self.stopEntered = stopEntered
        self.cleanupRelease = cleanupRelease
    }

    func start(endpointPath: String, service: any LocalMCPService) async throws -> LoopbackEndpoint {
        starts += 1
        if let endpoint { return endpoint }
        let endpoint = try await directory.register(path: endpointPath, service: service)
        self.endpoint = endpoint
        return endpoint
    }

    func stop() async {
        stops += 1
        await stopEntered.signal()
        await cleanupRelease.wait()
        guard let endpoint else { return }
        await directory.unregister(endpoint)
        self.endpoint = nil
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor EpochGatedAdvertiser: LocalMCPAdvertising {
    private let catalog: DiscoveryCatalog
    private let startupEntered: AsyncSignal
    private let startupRelease: AsyncSignal
    private let withdrawEntered: AsyncSignal
    private let cleanupRelease: AsyncSignal
    private var advertisements = 0

    init(
        catalog: DiscoveryCatalog,
        startupEntered: AsyncSignal,
        startupRelease: AsyncSignal,
        withdrawEntered: AsyncSignal,
        cleanupRelease: AsyncSignal
    ) {
        self.catalog = catalog
        self.startupEntered = startupEntered
        self.startupRelease = startupRelease
        self.withdrawEntered = withdrawEntered
        self.cleanupRelease = cleanupRelease
    }

    func advertise(instance: ProducerInstance, descriptor: ProducerDescriptor) async throws {
        advertisements += 1
        try await catalog.advertise(instance: instance, descriptor: descriptor)
        if advertisements == 1 {
            await startupEntered.signal()
            await startupRelease.wait()
        }
    }

    func withdraw(instanceID: String) async {
        await withdrawEntered.signal()
        await cleanupRelease.wait()
        await catalog.withdraw(instanceID: instanceID)
    }
}

private actor GatedStartTransport: LocalMCPProducerTransport {
    private let directory: InMemoryServiceDirectory
    private let entered: AsyncSignal
    private let release: AsyncSignal
    private let stopEntered: AsyncSignal
    private var endpoint: LoopbackEndpoint?

    init(
        directory: InMemoryServiceDirectory,
        entered: AsyncSignal,
        release: AsyncSignal,
        stopEntered: AsyncSignal
    ) {
        self.directory = directory
        self.entered = entered
        self.release = release
        self.stopEntered = stopEntered
    }

    func start(endpointPath: String, service: any LocalMCPService) async throws -> LoopbackEndpoint {
        await entered.signal()
        await release.wait()
        if let endpoint { return endpoint }
        let endpoint = try await directory.register(path: endpointPath, service: service)
        self.endpoint = endpoint
        return endpoint
    }

    func stop() async {
        await stopEntered.signal()
        if let endpoint {
            await directory.unregister(endpoint)
            self.endpoint = nil
        }
    }
}

private struct SuspendedApprover: PairingApproving {
    let entered: AsyncSignal

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        await entered.signal()
        try await Task.sleep(nanoseconds: UInt64.max)
        return .approve
    }
}

private struct GatedSuspendedApprover: PairingApproving {
    let entered: AsyncSignal
    let release: AsyncSignal

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        _ = challenge
        await entered.signal()
        await release.wait()
        return .approve
    }
}
