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

private actor StubService: LocalMCPService {
    var pairingGrant: AuthorizationGrant
    var initialization: LocalMCPInitialization
    var definitions: [CommandDefinition]
    var result: CommandResult
    var authorizationError: LocalMCPError?
    let pairingGate: ConsumerTestGate?
    let initializeGate: ConsumerTestGate?
    private(set) var pairCalls = 0
    private(set) var initializeCalls = 0
    private(set) var initializedCalls = 0
    private(set) var listCalls = 0
    private(set) var commandCalls = 0

    init(
        pairingGrant: AuthorizationGrant,
        result: CommandResult,
        pairingGate: ConsumerTestGate? = nil,
        initializeGate: ConsumerTestGate? = nil
    ) {
        self.pairingGrant = pairingGrant
        self.pairingGate = pairingGate
        self.initializeGate = initializeGate
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
        if let authorizationError { throw authorizationError }
        return definitions
    }

    func initialized(credential: AuthorizationCredential?) async throws {
        initializedCalls += 1
        if let authorizationError { throw authorizationError }
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        commandCalls += 1
        if let authorizationError { throw authorizationError }
        return result
    }

    func setAuthorizationError(_ error: LocalMCPError?) { authorizationError = error }
    func setInitialization(_ value: LocalMCPInitialization) { initialization = value }
    func counts() -> (pair: Int, initialize: Int, initialized: Int, list: Int, call: Int) {
        (pairCalls, initializeCalls, initializedCalls, listCalls, commandCalls)
    }
}

private func makeConsumer(
    instance: ProducerInstance,
    service: StubService,
    store: InMemoryConsumerGrantStore = InMemoryConsumerGrantStore()
) -> LocalMCPConsumer {
    LocalMCPConsumer(
        instance: instance,
        identity: consumerIdentity,
        connector: StaticConnector(service: service),
        grantStore: store,
        clock: ManualLocalMCPClock(),
        random: SequenceRandomBytesGenerator()
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
