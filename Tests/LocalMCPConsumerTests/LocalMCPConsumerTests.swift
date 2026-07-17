import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPTesting
import Testing

private struct ConsumerInput: Codable, Sendable, Equatable { let value: String }
private struct ConsumerOutput: Codable, Sendable, Equatable { let value: String }

private func expectLocalError(
    _ expected: LocalMCPError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
    }
}

private struct DeadlineWatchdogExpired: Error {}

/// Bounds a driven operation even when the consumer fails to enforce its
/// deadline; resolving does not join the hung operation, so the suite stays
/// bounded (and CI-safe) while the invariant is violated.
private func watchdogged<Success: Sendable>(
    _ body: @escaping @Sendable () async throws -> Success
) -> LocalMCPAsyncOperation<Success> {
    LocalMCPAsyncOperation(
        timeoutAfter: 2,
        timeoutError: DeadlineWatchdogExpired(),
        operation: body
    )
}

private func expectRequestTimedOut<Success: Sendable>(
    _ operation: LocalMCPAsyncOperation<Success>
) async {
    do {
        _ = try await operation.value()
        Issue.record("Expected requestTimedOut")
    } catch let error as LocalMCPError {
        #expect(error == .requestTimedOut)
    } catch is DeadlineWatchdogExpired {
        Issue.record("Operation was not bounded by its deadline")
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
    }
}

private let consumerIdentity = ConsumerIdentity(
    stableID: "com.example.assistant",
    displayName: "Assistant",
    version: "1.0.0",
    installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
)

private let producerIdentity = ProducerIdentity(
    stableID: "com.example.notes",
    displayName: "Notes",
    version: "1.0.0"
)

private func instance(
    id: String = "02b04cec-c3c5-4d20-b0f0-194f77a349ee",
    compatibility: ProducerCompatibility = .compatible,
    port: UInt16 = 42_000
) throws -> ProducerInstance {
    ProducerInstance(
        identity: producerIdentity,
        instanceID: id,
        endpoint: try LoopbackEndpoint(port: port, path: "/mcp"),
        descriptorURL: try LoopbackEndpoint(port: port, path: "/local-mcp/v1/descriptor.json"),
        compatibility: compatibility
    )
}

private func grant(
    consumer: ConsumerIdentity = consumerIdentity,
    byte: UInt8 = 7
) throws -> AuthorizationGrant {
    AuthorizationGrant(
        metadata: .init(
            grantID: "grant-\(byte)",
            producerID: producerIdentity.stableID,
            consumer: consumer,
            issuedAt: Date(timeIntervalSince1970: 0)
        ),
        credential: try AuthorizationCredential(bytes: .init(repeating: byte, count: 32))
    )
}

private struct StaticConnector: LocalMCPConnecting {
    let service: any LocalMCPService
    func connect(to instance: ProducerInstance) async throws -> any LocalMCPService { service }
}

private struct HangingConnector: LocalMCPConnecting {
    let gate: ConsumerTestGate
    let service: any LocalMCPService

    func connect(to instance: ProducerInstance) async throws -> any LocalMCPService {
        await gate.arriveAndWait()
        return service
    }
}

private actor StubService: LocalMCPDisconnectingService {
    var pairingGrant: AuthorizationGrant
    var initialization: LocalMCPInitialization
    var definitions: [CommandDefinition]
    var result: CommandResult
    var authorizationError: LocalMCPError?
    var initializedError: LocalMCPError?
    let pairingGate: ConsumerTestGate?
    let initializeGate: ConsumerTestGate?
    let listGate: ConsumerTestGate?
    let callGate: ConsumerTestGate?
    let disconnectGate: ConsumerTestGate?
    private var listLifecycleFailuresRemaining = 0
    private var callLifecycleFailuresRemaining = 0
    private(set) var pairCalls = 0
    private(set) var initializeCalls = 0
    private(set) var initializedCalls = 0
    private(set) var listCalls = 0
    private(set) var commandCalls = 0
    private(set) var disconnectCalls = 0

    init(
        pairingGrant: AuthorizationGrant,
        result: CommandResult,
        pairingGate: ConsumerTestGate? = nil,
        initializeGate: ConsumerTestGate? = nil,
        listGate: ConsumerTestGate? = nil,
        callGate: ConsumerTestGate? = nil,
        disconnectGate: ConsumerTestGate? = nil
    ) {
        self.pairingGrant = pairingGrant
        self.pairingGate = pairingGate
        self.initializeGate = initializeGate
        self.listGate = listGate
        self.callGate = callGate
        self.disconnectGate = disconnectGate
        initialization = LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: producerIdentity,
            capabilities: .init()
        )
        definitions = [
            CommandDefinition(
                name: "echo",
                description: "Echo",
                inputSchema: .object(["type": .string("object")])
            )
        ]
        self.result = result
    }

    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        pairCalls += 1
        await pairingGate?.arriveAndWait()
        return pairingGrant
    }

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        initializeCalls += 1
        await initializeGate?.arriveAndWait()
        if let authorizationError { throw authorizationError }
        return initialization
    }

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        listCalls += 1
        await listGate?.arriveAndWait()
        if listLifecycleFailuresRemaining > 0 {
            listLifecycleFailuresRemaining -= 1
            throw LocalMCPError.invalidLifecycleState
        }
        if let authorizationError { throw authorizationError }
        return definitions
    }

    func initialized(credential: AuthorizationCredential?) async throws {
        initializedCalls += 1
        if let initializedError { throw initializedError }
        if let authorizationError { throw authorizationError }
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        commandCalls += 1
        await callGate?.arriveAndWait()
        if callLifecycleFailuresRemaining > 0 {
            callLifecycleFailuresRemaining -= 1
            throw LocalMCPError.invalidLifecycleState
        }
        if let authorizationError { throw authorizationError }
        return result
    }

    func disconnect(credential: AuthorizationCredential?) async {
        disconnectCalls += 1
        await disconnectGate?.arriveAndWait()
    }

    func setAuthorizationError(_ error: LocalMCPError?) { authorizationError = error }
    func setInitializedError(_ error: LocalMCPError?) { initializedError = error }
    func setInitialization(_ value: LocalMCPInitialization) { initialization = value }
    func setPairingGrant(_ value: AuthorizationGrant) { pairingGrant = value }
    func failNextListForMissingSession() { listLifecycleFailuresRemaining += 1 }
    func failNextCallForMissingSession() { callLifecycleFailuresRemaining += 1 }
    func counts() -> (
        pair: Int,
        initialize: Int,
        initialized: Int,
        list: Int,
        call: Int,
        disconnect: Int
    ) {
        (pairCalls, initializeCalls, initializedCalls, listCalls, commandCalls, disconnectCalls)
    }
}

private func makeConsumer(
    instance: ProducerInstance,
    service: StubService,
    connector: (any LocalMCPConnecting)? = nil,
    store: InMemoryConsumerGrantStore = InMemoryConsumerGrantStore(),
    random: any RandomBytesGenerating = SequenceRandomBytesGenerator()
) -> LocalMCPConsumer {
    LocalMCPConsumer(
        instance: instance,
        identity: consumerIdentity,
        connector: connector ?? StaticConnector(service: service),
        grantStore: store,
        clock: ManualLocalMCPClock(),
        random: random
    )
}

@Suite("Local MCP consumer")
struct LocalMCPConsumerTests {
    @Test("Unpaired operations fail without reaching the service")
    func pairingRequired() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("unused"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        await expectLocalError(.pairingRequired) { _ = try await consumer.listTools() }
        await expectLocalError(.pairingRequired) {
            _ = try await consumer.call("echo", arguments: .object([:]))
        }
        let counts = await service.counts()
        #expect(counts.list == 0)
        #expect(counts.call == 0)
    }

    @Test("Pairing stores the grant and enables the negotiated lifecycle, list, and call")
    func happyPath() async throws {
        let expectedGrant = try grant()
        let output = ConsumerOutput(value: "hello")
        let service = StubService(pairingGrant: expectedGrant, result: try .structured(output, text: "hello"))
        let store = InMemoryConsumerGrantStore()
        let consumer = makeConsumer(instance: try instance(), service: service, store: store)
        let display = VerificationDisplayRecorder()

        let paired = try await consumer.pair { code in display.record(code) }
        #expect(paired == expectedGrant)
        #expect(display.count == 1)
        #expect(await store.count() == 1)
        #expect(try await consumer.storedGrant() == expectedGrant)
        #expect(try await consumer.initialize().server == producerIdentity)
        #expect(try await consumer.listTools().map(\.name) == ["echo"])
        let decoded: ConsumerOutput = try await consumer.call(
            "echo",
            input: ConsumerInput(value: "hello"),
            as: ConsumerOutput.self,
            grant: paired
        )
        #expect(decoded == output)
        let counts = await service.counts()
        #expect(counts.pair == 1)
        #expect(counts.initialize == 1)
        #expect(counts.initialized == 1)
        #expect(counts.list == 1)
        #expect(counts.call == 1)
    }

    @Test("Presentation-only consumer identity changes do not change grant scope")
    func identityScope() async throws {
        let oldIdentity = ConsumerIdentity(
            stableID: consumerIdentity.stableID,
            displayName: "Old Name",
            version: "0.9.0",
            installationID: consumerIdentity.installationID
        )
        let oldGrant = try grant(consumer: oldIdentity)
        let service = StubService(pairingGrant: oldGrant, result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        #expect(try await consumer.listTools().count == 1)
    }

    @Test("Explicit grants from another scope are rejected locally")
    func wrongScope() async throws {
        let expected = try grant()
        let service = StubService(pairingGrant: expected, result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        let other = ConsumerIdentity(
            stableID: "com.example.other",
            displayName: "Other",
            version: "1",
            installationID: "95a519b9-d823-4b84-913f-27211ef70773"
        )
        await expectLocalError(.unauthorized) {
            _ = try await consumer.listTools(grant: grant(consumer: other, byte: 9))
        }
        #expect(await service.counts().list == 0)
    }

    @Test("Incompatible and removed instances remain distinct")
    func availabilityStates() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("ok"))
        let incompatibleProfile = makeConsumer(
            instance: try instance(compatibility: .incompatibleDiscoveryProfile("2")),
            service: service
        )
        await expectLocalError(.incompatibleDiscoveryProfile) { _ = try await incompatibleProfile.pair() }

        let incompatibleMCP = makeConsumer(
            instance: try instance(compatibility: .incompatibleMCPProtocol(["future"])),
            service: service
        )
        await expectLocalError(.incompatibleMCPProtocol) { _ = try await incompatibleMCP.pair() }

        let current = try instance()
        let removed = makeConsumer(instance: current, service: service)
        await removed.markRemoved(instanceID: current.instanceID)
        await expectLocalError(.producerUnavailable) { _ = try await removed.pair() }
    }

    @Test("A new process instance cannot receive a persisted bearer implicitly")
    func replacementInstanceGate() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        try await consumer.update(instance: try instance(
            id: "20208e3d-f872-46d7-8847-f5a446d12299",
            port: 42_001
        ))
        await expectLocalError(.pairingRequired) { _ = try await consumer.listTools() }
        #expect(await service.counts().list == 0)
    }

    @Test("Authorization rejection clears only the credential that failed")
    func rejectedCredentialCleanup() async throws {
        let first = try grant(byte: 10)
        let service = StubService(pairingGrant: first, result: .text("ok"))
        let store = InMemoryConsumerGrantStore()
        let consumer = makeConsumer(instance: try instance(), service: service, store: store)
        _ = try await consumer.pair()
        let replacement = try grant(byte: 11)
        try await store.save(replacement)
        await service.setAuthorizationError(.unauthorized)
        await expectLocalError(.unauthorized) { _ = try await consumer.listTools() }
        #expect(try await store.grant(
            producerID: producerIdentity.stableID,
            consumer: consumerIdentity
        ) == replacement)
    }

    @Test("A transient producer authorization-store outage preserves the cached grant")
    func authorizationStoreOutagePreservesGrant() async throws {
        let expected = try grant(byte: 12)
        let service = StubService(pairingGrant: expected, result: .text("ok"))
        let store = InMemoryConsumerGrantStore()
        let consumer = makeConsumer(instance: try instance(), service: service, store: store)
        _ = try await consumer.pair()
        _ = try await consumer.initialize()

        await service.setAuthorizationError(.credentialStoreFailed)
        await expectLocalError(.credentialStoreFailed) {
            _ = try await consumer.listTools()
        }
        #expect(try await store.grant(
            producerID: producerIdentity.stableID,
            consumer: consumerIdentity
        ) == expected)

        await service.setAuthorizationError(nil)
        #expect(try await consumer.listTools().map(\.name) == ["echo"])
    }

    @Test("Initialize validates the negotiated protocol and server identity")
    func initializeValidation() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        await service.setInitialization(.init(
            protocolVersion: "future",
            server: producerIdentity,
            capabilities: .init()
        ))
        await expectLocalError(.incompatibleMCPProtocol) { _ = try await consumer.initialize() }

        await service.setInitialization(.init(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: .init(stableID: "com.example.impostor", displayName: "Impostor", version: "1"),
            capabilities: .init()
        ))
        await expectLocalError(.unauthorized) { _ = try await consumer.initialize() }
    }

    @Test("Initialize rejects malformed peer identity and a missing tools capability")
    func initializeMetadataValidation() async throws {
        let malformedService = StubService(pairingGrant: try grant(), result: .text("unused"))
        let malformedConsumer = makeConsumer(
            instance: try instance(),
            service: malformedService
        )
        _ = try await malformedConsumer.pair()
        await malformedService.setInitialization(.init(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: .init(
                stableID: producerIdentity.stableID,
                displayName: "Hostile\u{1B}[31m",
                version: "1.0.0"
            ),
            capabilities: .init()
        ))
        await expectLocalError(.unauthorized) {
            _ = try await malformedConsumer.initialize()
        }
        #expect(await malformedService.counts().disconnect == 1)

        let noToolsService = StubService(pairingGrant: try grant(byte: 8), result: .text("unused"))
        let noToolsConsumer = makeConsumer(instance: try instance(), service: noToolsService)
        _ = try await noToolsConsumer.pair()
        await noToolsService.setInitialization(.init(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: producerIdentity,
            capabilities: .init(tools: false)
        ))
        await expectLocalError(.incompatibleMCPProtocol) {
            _ = try await noToolsConsumer.initialize()
        }
        #expect(await noToolsService.counts().disconnect == 1)
    }

    @Test("An initialized-notification failure terminates the partial session")
    func initializedFailureCleanup() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("unused"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        await service.setInitializedError(.commandFailed)

        await expectLocalError(.commandFailed) {
            _ = try await consumer.initialize()
        }
        #expect(await service.counts().disconnect == 1)
    }

    @Test("Peer validation failure has a hard bound even when disconnect ignores cancellation")
    func boundedValidationFailureCleanup() async throws {
        let disconnectGate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            disconnectGate: disconnectGate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        await service.setInitialization(.init(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: .init(
                stableID: producerIdentity.stableID,
                displayName: "Invalid\u{1B}",
                version: "1.0.0"
            ),
            capabilities: .init()
        ))

        let clock = ContinuousClock()
        let start = clock.now
        let initialization = Task { try await consumer.initialize() }
        await disconnectGate.waitUntilArrived()
        await expectLocalError(.unauthorized) {
            _ = try await initialization.value
        }
        #expect(start.duration(to: clock.now) < .seconds(3))
        await disconnectGate.release()
    }

    @Test("Typed calls require structured, decodable, non-error content")
    func typedOutputFailures() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("text only"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        await expectLocalError(.commandFailed) {
            let _: ConsumerOutput = try await consumer.call(
                "echo",
                input: ConsumerInput(value: "x"),
                as: ConsumerOutput.self
            )
        }
    }

    @Test("Concurrent operations coalesce one initialize and initialized lifecycle")
    func coalescedNegotiation() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("ok"),
            initializeGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        async let first = consumer.listTools()
        await gate.waitUntilArrived()
        async let second = consumer.listTools()
        await gate.release()
        _ = try await (first, second)
        let counts = await service.counts()
        #expect(counts.initialize == 1)
        #expect(counts.initialized == 1)
        #expect(counts.list == 2)
    }

    @Test("A consumer serializes overlapping pairing attempts")
    func serializedPairing() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("ok"),
            pairingGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        let first = Task { try await consumer.pair() }
        await gate.waitUntilArrived()
        await expectLocalError(.pairingDenied) { _ = try await consumer.pair() }
        await gate.release()
        _ = try await first.value
        #expect(await service.counts().pair == 1)
    }

    @Test("Successful re-pair terminates the session authenticated by the rotated grant")
    func repairingDisconnectsOldSession() async throws {
        let firstGrant = try grant(byte: 7)
        let secondGrant = try grant(byte: 8)
        let service = StubService(pairingGrant: firstGrant, result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        _ = try await consumer.initialize()

        await service.setPairingGrant(secondGrant)
        #expect(try await consumer.pair() == secondGrant)

        #expect(await service.counts().disconnect == 1)
        #expect(try await consumer.listTools().map(\.name) == ["echo"])
        let counts = await service.counts()
        #expect(counts.initialize == 2)
        #expect(counts.initialized == 2)
    }

    @Test("Caller cancellation during re-pair cleanup cannot return a successful grant")
    func cancelledRepairCleanup() async throws {
        let disconnectGate = ConsumerTestGate()
        let firstGrant = try grant(byte: 7)
        let secondGrant = try grant(byte: 8)
        let service = StubService(
            pairingGrant: firstGrant,
            result: .text("ok"),
            disconnectGate: disconnectGate
        )
        let store = InMemoryConsumerGrantStore()
        let consumer = makeConsumer(
            instance: try instance(),
            service: service,
            store: store
        )
        _ = try await consumer.pair()
        _ = try await consumer.initialize()
        await service.setPairingGrant(secondGrant)

        let repairing = Task { try await consumer.pair() }
        await disconnectGate.waitUntilArrived()
        repairing.cancel()
        await expectLocalError(.cancelled) {
            _ = try await repairing.value
        }
        #expect(try await consumer.storedGrant() == secondGrant)
        await disconnectGate.release()
    }

    @Test("A route update cancels a noncooperative list and disconnects its old session")
    func updateCancelsList() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("stale"),
            listGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        let staleList = Task { try await consumer.listTools() }
        await gate.waitUntilArrived()
        try await consumer.update(instance: try instance(
            id: "20208e3d-f872-46d7-8847-f5a446d12299",
            port: 42_001
        ))

        await expectLocalError(.producerUnavailable) {
            _ = try await staleList.value
        }
        #expect(await service.counts().disconnect == 1)
        await gate.release()
    }

    @Test("Removal cancels a noncooperative call and discards its late result")
    func removalCancelsCall() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("must-not-escape"),
            callGate: gate
        )
        let current = try instance()
        let consumer = makeConsumer(instance: current, service: service)
        _ = try await consumer.pair()

        let staleCall = Task {
            try await consumer.call("echo", arguments: .object([:]))
        }
        await gate.waitUntilArrived()
        await consumer.markRemoved(instanceID: current.instanceID)

        await expectLocalError(.producerUnavailable) {
            _ = try await staleCall.value
        }
        #expect(await service.counts().disconnect == 1)
        await gate.release()
        #expect(await consumer.isAvailable == false)
    }

    @Test("A terminated session retries only safe list and never replays a tool call")
    func terminatedSessionRecovery() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        await service.failNextListForMissingSession()
        #expect(try await consumer.listTools().map(\.name) == ["echo"])
        var counts = await service.counts()
        #expect(counts.initialize == 2)
        #expect(counts.initialized == 2)
        #expect(counts.list == 2)

        await service.failNextCallForMissingSession()
        await expectLocalError(.invalidLifecycleState) {
            _ = try await consumer.call("echo", arguments: .object([:]))
        }
        counts = await service.counts()
        #expect(counts.initialize == 3)
        #expect(counts.initialized == 3)
        #expect(counts.call == 1)

        #expect(try await consumer.call("echo", arguments: .object([:])) == .text("ok"))
        counts = await service.counts()
        #expect(counts.initialize == 3)
        #expect(counts.call == 2)
    }

    @Test("Close terminates the cached session and rejects later operations")
    func close() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("ok"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        _ = try await consumer.initialize()

        await consumer.close()

        #expect(await service.counts().disconnect == 1)
        #expect(await consumer.isAvailable == false)
        await expectLocalError(.producerUnavailable) {
            _ = try await consumer.listTools()
        }
    }

    @Test("Removal during nonce generation remains producer unavailable")
    func removalDuringNonceGeneration() async throws {
        let gate = ConsumerTestGate()
        let random = GatedRandomBytesGenerator(gate: gate)
        let service = StubService(pairingGrant: try grant(), result: .text("unused"))
        let current = try instance()
        let consumer = makeConsumer(
            instance: current,
            service: service,
            random: random
        )

        let pairing = Task { try await consumer.pair() }
        await gate.waitUntilArrived()
        await consumer.markRemoved(instanceID: current.instanceID)

        await expectLocalError(.producerUnavailable) {
            _ = try await pairing.value
        }
        await gate.release()
        #expect(await service.counts().pair == 0)
    }

    @Test("Cancelling the only initialize waiter abandons and disconnects its late session")
    func cancelledInitializeCleanup() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            initializeGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        let initialization = Task { try await consumer.initialize() }
        await gate.waitUntilArrived()
        initialization.cancel()
        await expectLocalError(.cancelled) {
            _ = try await initialization.value
        }

        await gate.release()
        #expect(await eventuallyConsumerTest {
            await service.counts().disconnect == 1
        })
    }

    @Test("Cancelling one coalesced initialize waiter preserves the other")
    func oneCancelledInitializeWaiter() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            initializeGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        let first = Task { try await consumer.initialize() }
        await gate.waitUntilArrived()
        let second = Task { try await consumer.initialize() }
        for _ in 0 ..< 20 { await Task.yield() }

        first.cancel()
        await expectLocalError(.cancelled) {
            _ = try await first.value
        }
        #expect(await service.counts().disconnect == 0)

        await gate.release()
        #expect(try await second.value.server == producerIdentity)
        let counts = await service.counts()
        #expect(counts.initialize == 1)
        #expect(counts.initialized == 1)
        #expect(counts.disconnect == 0)
    }

    @Test("Deadlines bound every operation against a connector that never returns")
    func deadlinesBoundEveryOperationAgainstHangingConnector() async throws {
        let connectGate = ConsumerTestGate()
        let service = StubService(pairingGrant: try grant(), result: .text("unused"))
        let consumer = makeConsumer(
            instance: try instance(),
            service: service,
            connector: HangingConnector(gate: connectGate, service: service)
        )
        let g = try grant()
        let deadline = Date().addingTimeInterval(0.25)
        let clock = ContinuousClock()
        let start = clock.now

        let first = watchdogged {
            try await consumer.initialize(grant: g, deadline: deadline)
        }
        await connectGate.waitUntilArrived()
        let coalesced = watchdogged {
            try await consumer.initialize(grant: g, deadline: deadline)
        }
        let list = watchdogged {
            try await consumer.listTools(grant: g, deadline: deadline)
        }
        let call = watchdogged {
            try await consumer.call(
                "echo",
                arguments: .object([:]),
                grant: g,
                deadline: deadline
            )
        }
        let pairing = watchdogged {
            try await consumer.pair(deadline: deadline)
        }

        await expectRequestTimedOut(first)
        await expectRequestTimedOut(coalesced)
        await expectRequestTimedOut(list)
        await expectRequestTimedOut(call)
        await expectRequestTimedOut(pairing)
        #expect(start.duration(to: clock.now) < .seconds(3))
        await connectGate.release()
    }

    @Test("A deadline bounds a hanging initialize and abandons the sole waiter's negotiation")
    func deadlineBoundsHangingInitializeAndAbandonsSoleWaiter() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            initializeGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        let clock = ContinuousClock()
        let start = clock.now
        let initialization = watchdogged {
            try await consumer.initialize(deadline: Date().addingTimeInterval(0.25))
        }
        await gate.waitUntilArrived()
        await expectRequestTimedOut(initialization)
        #expect(start.duration(to: clock.now) < .seconds(3))

        await gate.release()
        #expect(await eventuallyConsumerTest {
            await service.counts().disconnect == 1
        })
    }

    @Test("A timed-out coalesced waiter preserves the surviving negotiation")
    func timedOutWaiterPreservesSurvivingNegotiation() async throws {
        let gate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            initializeGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()

        let first = Task { try await consumer.initialize() }
        await gate.waitUntilArrived()
        let second = watchdogged {
            try await consumer.initialize(deadline: Date().addingTimeInterval(0.2))
        }
        for _ in 0 ..< 20 { await Task.yield() }

        await expectRequestTimedOut(second)
        #expect(await service.counts().disconnect == 0)

        await gate.release()
        #expect(try await first.value.server == producerIdentity)
        let counts = await service.counts()
        #expect(counts.initialize == 1)
        #expect(counts.initialized == 1)
        #expect(counts.disconnect == 0)
    }

    @Test("Deadlines bound hung list and call on an initialized session")
    func deadlineBoundsHungListAndCall() async throws {
        let listGate = ConsumerTestGate()
        let callGate = ConsumerTestGate()
        let service = StubService(
            pairingGrant: try grant(),
            result: .text("unused"),
            listGate: listGate,
            callGate: callGate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)
        _ = try await consumer.pair()
        _ = try await consumer.initialize()

        let clock = ContinuousClock()
        let start = clock.now
        let list = watchdogged {
            try await consumer.listTools(deadline: Date().addingTimeInterval(0.2))
        }
        let call = watchdogged {
            try await consumer.call(
                "echo",
                arguments: .object([:]),
                deadline: Date().addingTimeInterval(0.2)
            )
        }
        await expectRequestTimedOut(list)
        await expectRequestTimedOut(call)
        #expect(start.duration(to: clock.now) < .seconds(3))
        await listGate.release()
        await callGate.release()
    }

    @Test("An already-expired deadline fails fast without reaching the service")
    func expiredDeadlineFailsFastWithoutReachingService() async throws {
        let service = StubService(pairingGrant: try grant(), result: .text("unused"))
        let consumer = makeConsumer(instance: try instance(), service: service)
        let g = try grant()
        let past = Date().addingTimeInterval(-1)

        await expectLocalError(.requestTimedOut) {
            _ = try await consumer.initialize(grant: g, deadline: past)
        }
        await expectLocalError(.requestTimedOut) {
            _ = try await consumer.listTools(grant: g, deadline: past)
        }
        await expectLocalError(.requestTimedOut) {
            _ = try await consumer.call(
                "echo",
                arguments: .object([:]),
                grant: g,
                deadline: past
            )
        }
        await expectLocalError(.requestTimedOut) {
            _ = try await consumer.pair(deadline: past)
        }
        let counts = await service.counts()
        #expect(counts.pair == 0)
        #expect(counts.initialize == 0)
        #expect(counts.initialized == 0)
        #expect(counts.list == 0)
        #expect(counts.call == 0)
    }

    @Test("A timed-out pair releases the single-flight token for retry")
    func timedOutPairReleasesSingleFlightForRetry() async throws {
        let gate = ConsumerTestGate()
        let expectedGrant = try grant()
        let service = StubService(
            pairingGrant: expectedGrant,
            result: .text("unused"),
            pairingGate: gate
        )
        let consumer = makeConsumer(instance: try instance(), service: service)

        let clock = ContinuousClock()
        let start = clock.now
        let pairing = watchdogged {
            try await consumer.pair(deadline: Date().addingTimeInterval(0.2))
        }
        await gate.waitUntilArrived()
        await expectRequestTimedOut(pairing)
        #expect(start.duration(to: clock.now) < .seconds(3))

        await gate.release()
        #expect(try await consumer.pair() == expectedGrant)
        #expect(try await consumer.listTools().map(\.name) == ["echo"])
    }
}

private final class VerificationDisplayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [PairingVerificationCode] = []

    func record(_ code: PairingVerificationCode) {
        lock.withLock { codes.append(code) }
    }

    var count: Int { lock.withLock { codes.count } }
}

private actor ConsumerTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedRandomBytesGenerator: RandomBytesGenerating {
    let gate: ConsumerTestGate

    init(gate: ConsumerTestGate) {
        self.gate = gate
    }

    func randomBytes(count: Int) async throws -> [UInt8] {
        await gate.arriveAndWait()
        return Array(repeating: 7, count: count)
    }
}

private func eventuallyConsumerTest(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
