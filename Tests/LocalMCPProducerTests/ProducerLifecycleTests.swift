import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPProducer
import LocalMCPTesting
import Testing

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
    func configurationValidation() async {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = environment.makeProducerTransport()
        let producer = makeLifecycleProducer(
            environment: environment,
            transport: transport,
            configuration: .localOnly(endpointPath: "/wrong")
        )
        await expectLocalError(.invalidConfiguration) { try await producer.start() }
        #expect(await transport.callCounts().start == 0)
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
