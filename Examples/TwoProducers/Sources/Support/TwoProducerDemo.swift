import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPProducer
import LocalMCPTesting

public enum DemoProducerKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case greeter
    case calculator

    public var id: String { rawValue }

    public var stableID: String {
        switch self {
        case .greeter: "com.example.localmcp.greeter"
        case .calculator: "com.example.localmcp.calculator"
        }
    }

    public var displayName: String {
        switch self {
        case .greeter: "Greeter Producer"
        case .calculator: "Calculator Producer"
        }
    }

    public var commandName: String {
        switch self {
        case .greeter: "greeting.hello"
        case .calculator: "math.add"
        }
    }
}

public enum DemoProducerStatus: String, Codable, Sendable {
    case offline
    case discovered
    case paired
    case revoked
}

/// Failure injection used only by the example's deterministic rollback tests.
public enum DemoPairingFinalizationFailure: Sendable, Equatable {
    case none
    case initialization(DemoProducerKind)
    case toolListing(DemoProducerKind)
}

public struct DemoProducerSnapshot: Identifiable, Sendable, Equatable {
    public let kind: DemoProducerKind
    public let stableID: String
    public let displayName: String
    public let endpoint: String?
    public let status: DemoProducerStatus
    public let tools: [String]
    public let lastResult: String?
    public let invocationCount: Int

    public var id: DemoProducerKind { kind }

    public var isPaired: Bool { status == .paired }
}

public struct TwoProducerDemoSnapshot: Sendable, Equatable {
    public let isRunning: Bool
    public let producers: [DemoProducerSnapshot]
    public let events: [String]

    public func producer(_ kind: DemoProducerKind) -> DemoProducerSnapshot? {
        producers.first { $0.kind == kind }
    }

    public static let empty = TwoProducerDemoSnapshot(
        isRunning: false,
        producers: DemoProducerKind.allCases.map { kind in
            DemoProducerSnapshot(
                kind: kind,
                stableID: kind.stableID,
                displayName: kind.displayName,
                endpoint: nil,
                status: .offline,
                tools: [],
                lastResult: nil,
                invocationCount: 0
            )
        },
        events: []
    )
}

/// A complete in-process demonstration of one consumer identity talking to two
/// independent producers. The transport, stores, and discovery backend are the
/// Deterministic in-memory implementations; swapping those boundaries for the
/// production HTTP, Keychain, and Bonjour backends does not change this flow.
public actor TwoProducerDemo {
    private struct MutableProducerState: Sendable {
        var instance: ProducerInstance?
        var status: DemoProducerStatus = .offline
        var tools: [String] = []
        var lastResult: String?
        var invocationCount = 0
    }

    private let environment: InMemoryLocalMCPEnvironment
    private let consumerStore: InMemoryConsumerGrantStore
    private let consumerIdentity: ConsumerIdentity
    private let producers: [DemoProducerKind: LocalMCPProducer]
    private let transports: [DemoProducerKind: InMemoryProducerTransport]
    private let producerStores: [DemoProducerKind: InMemoryProducerGrantStore]
    private let approvers: [DemoProducerKind: DemoAutoPairingApprover]
    private let invocationCounters: [DemoProducerKind: DemoInvocationCounter]
    private let consumerRandomSources: [DemoProducerKind: SequenceRandomBytesGenerator]
    private var pendingPairingFinalizationFailure: DemoPairingFinalizationFailure

    private var configured = false
    private var lifecycleActive = false
    private var running = false
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var consumers: [DemoProducerKind: LocalMCPConsumer] = [:]
    private var grants: [DemoProducerKind: AuthorizationGrant] = [:]
    private var states: [DemoProducerKind: MutableProducerState] = [
        .greeter: MutableProducerState(),
        .calculator: MutableProducerState(),
    ]
    private var eventLog: [String] = []

    public init(
        firstPort: UInt16 = 46_000,
        calculatorTransportFailure: InMemoryTransportFailure = .none,
        pairingFinalizationFailure: DemoPairingFinalizationFailure = .none,
        pairingApprovalHook: (@Sendable (DemoProducerKind) async -> Void)? = nil
    ) {
        let environment = InMemoryLocalMCPEnvironment(firstPort: firstPort)
        let consumerStore = InMemoryConsumerGrantStore()
        let greeterTransport = InMemoryProducerTransport(directory: environment.directory)
        let calculatorTransport = InMemoryProducerTransport(
            directory: environment.directory,
            failure: calculatorTransportFailure
        )
        let greeterStore = InMemoryProducerGrantStore()
        let calculatorStore = InMemoryProducerGrantStore()
        let greeterApprover = DemoAutoPairingApprover(
            kind: .greeter,
            beforeDecision: pairingApprovalHook
        )
        let calculatorApprover = DemoAutoPairingApprover(
            kind: .calculator,
            beforeDecision: pairingApprovalHook
        )
        let greeterCounter = DemoInvocationCounter()
        let calculatorCounter = DemoInvocationCounter()

        self.environment = environment
        self.consumerStore = consumerStore
        pendingPairingFinalizationFailure = pairingFinalizationFailure
        consumerIdentity = ConsumerIdentity(
            stableID: "com.example.localmcp.demo-consumer",
            displayName: "Two Producer Demo Consumer",
            version: "1.0.0",
            installationID: "6f88a441-c5a8-433c-8f7e-866dbfeb129e"
        )
        transports = [
            .greeter: greeterTransport,
            .calculator: calculatorTransport,
        ]
        producerStores = [
            .greeter: greeterStore,
            .calculator: calculatorStore,
        ]
        approvers = [
            .greeter: greeterApprover,
            .calculator: calculatorApprover,
        ]
        invocationCounters = [
            .greeter: greeterCounter,
            .calculator: calculatorCounter,
        ]
        consumerRandomSources = [
            .greeter: SequenceRandomBytesGenerator(fallback: 30),
            .calculator: SequenceRandomBytesGenerator(fallback: 40),
        ]
        producers = [
            .greeter: LocalMCPProducer(
                identity: Self.identity(for: .greeter),
                instanceID: "11111111-1111-4111-8111-111111111111",
                transport: greeterTransport,
                advertiser: environment.advertiser,
                grantStore: greeterStore,
                approval: greeterApprover,
                random: SequenceRandomBytesGenerator(fallback: 10)
            ),
            .calculator: LocalMCPProducer(
                identity: Self.identity(for: .calculator),
                instanceID: "22222222-2222-4222-8222-222222222222",
                transport: calculatorTransport,
                advertiser: environment.advertiser,
                grantStore: calculatorStore,
                approval: calculatorApprover,
                random: SequenceRandomBytesGenerator(fallback: 20)
            ),
        ]
    }

    @discardableResult
    public func start() async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            try await startSerialized()
        }
    }

    private func startSerialized() async throws -> TwoProducerDemoSnapshot {
        if running { return makeSnapshot() }
        guard !lifecycleActive else { throw LocalMCPError.invalidLifecycleState }
        lifecycleActive = true

        do {
            try await configureIfNeeded()
            try await producer(.greeter).start()
            try await producer(.calculator).start()

            let instances = try await replayDiscoveredInstances(expectedCount: DemoProducerKind.allCases.count)
            let byStableID = Dictionary(
                uniqueKeysWithValues: instances.map { ($0.identity.stableID, $0) }
            )
            guard byStableID.count == DemoProducerKind.allCases.count else {
                throw LocalMCPError.producerUnavailable
            }

            consumers.removeAll(keepingCapacity: true)
            grants.removeAll(keepingCapacity: true)
            for kind in DemoProducerKind.allCases {
                guard let instance = byStableID[kind.stableID], instance.compatibility == .compatible else {
                    throw LocalMCPError.producerUnavailable
                }
                consumers[kind] = LocalMCPConsumer(
                    instance: instance,
                    identity: consumerIdentity,
                    connector: environment.directory,
                    grantStore: consumerStore,
                    random: consumerRandomSources[kind]!
                )
                states[kind]?.instance = instance
                states[kind]?.status = .discovered
                states[kind]?.tools = []
            }
            running = true
            appendEvent("Discovered Greeter Producer and Calculator Producer.")
            return makeSnapshot()
        } catch {
            await producer(.calculator).stop()
            await producer(.greeter).stop()
            clearRuntimeState()
            lifecycleActive = false
            if let error = error as? LocalMCPError { throw error }
            throw LocalMCPError.producerUnavailable
        }
    }

    /// Schedules another one-shot finalization failure for the next pairing.
    /// Used only by the example's deterministic rollback tests.
    public func schedulePairingFinalizationFailure(
        _ failure: DemoPairingFinalizationFailure
    ) {
        pendingPairingFinalizationFailure = failure
    }

    @discardableResult
    public func pair(
        with kind: DemoProducerKind,
        displayVerificationCode: (@Sendable (PairingVerificationCode) -> Void)? = nil
    ) async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            guard running, let consumer = consumers[kind] else {
                throw LocalMCPError.producerUnavailable
            }

            let grant = try await consumer.pair(displayVerificationCode: displayVerificationCode)
            do {
                if pendingPairingFinalizationFailure == .initialization(kind) {
                    pendingPairingFinalizationFailure = .none
                    throw LocalMCPError.commandFailed
                }
                _ = try await consumer.initialize(grant: grant)
                if pendingPairingFinalizationFailure == .toolListing(kind) {
                    pendingPairingFinalizationFailure = .none
                    throw LocalMCPError.commandFailed
                }
                let tools = try await consumer.listTools(grant: grant)
                guard tools.map(\.name) == [kind.commandName] else {
                    throw LocalMCPError.commandFailed
                }

                grants[kind] = grant
                states[kind]?.status = .paired
                states[kind]?.tools = tools.map(\.name)
                appendEvent("Paired with \(kind.displayName); the demo auto-approved the producer prompt.")
                return makeSnapshot()
            } catch {
                try? await producer(kind).revokeGrant(grant.metadata.grantID)
                try? await consumerStore.remove(
                    producerID: kind.stableID,
                    consumer: consumerIdentity,
                    ifCredentialMatches: grant.credential
                )
                grants.removeValue(forKey: kind)
                states[kind]?.status = .discovered
                states[kind]?.tools = []
                throw error
            }
        }
    }

    @discardableResult
    public func sendGreeting(to name: String) async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            let consumer = try pairedConsumer(for: .greeter)
            do {
                let output: GreetingOutput = try await consumer.call(
                    DemoProducerKind.greeter.commandName,
                    input: GreetingInput(name: name),
                    as: GreetingOutput.self
                )
                states[.greeter]?.lastResult = output.message
                states[.greeter]?.invocationCount += 1
                appendEvent("Called greeting.hello.")
                return makeSnapshot()
            } catch {
                handleCallFailure(error, kind: .greeter)
                throw error
            }
        }
    }

    @discardableResult
    public func add(_ left: Int, _ right: Int) async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            let consumer = try pairedConsumer(for: .calculator)
            do {
                let output: AddOutput = try await consumer.call(
                    DemoProducerKind.calculator.commandName,
                    input: AddInput(left: left, right: right),
                    as: AddOutput.self
                )
                states[.calculator]?.lastResult = "\(left) + \(right) = \(output.sum)"
                states[.calculator]?.invocationCount += 1
                appendEvent("Called math.add.")
                return makeSnapshot()
            } catch {
                handleCallFailure(error, kind: .calculator)
                throw error
            }
        }
    }

    /// Revokes one producer grant and deliberately attempts a list operation so
    /// the example proves that the consumer observes and purges the rejected grant.
    @discardableResult
    public func revoke(_ kind: DemoProducerKind) async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            guard running,
                  let grant = grants[kind],
                  let consumer = consumers[kind]
            else { throw LocalMCPError.pairingRequired }

            try await producer(kind).revokeGrant(grant.metadata.grantID)
            do {
                _ = try await consumer.listTools()
                throw LocalMCPError.commandFailed
            } catch let error as LocalMCPError where error == .grantRevoked || error == .unauthorized {
                grants.removeValue(forKey: kind)
                states[kind]?.status = .revoked
                appendEvent("Revoked \(kind.displayName)'s grant; the other producer remains paired.")
                return makeSnapshot()
            }
        }
    }

    @discardableResult
    public func stop() async -> TwoProducerDemoSnapshot {
        await withOperation {
            await stopSerialized()
        }
    }

    private func stopSerialized() async -> TwoProducerDemoSnapshot {
        guard lifecycleActive else { return makeSnapshot() }
        let currentConsumers = consumers
        let currentStates = states
        await producer(.calculator).stop()
        await producer(.greeter).stop()

        for (kind, consumer) in currentConsumers {
            if let instanceID = currentStates[kind]?.instance?.instanceID {
                await consumer.markRemoved(instanceID: instanceID)
            }
        }
        clearRuntimeState()
        lifecycleActive = false
        appendEvent("Stopped both producers and removed both discovery records.")
        return makeSnapshot()
    }

    @discardableResult
    public func reset() async throws -> TwoProducerDemoSnapshot {
        try await withOperation {
            _ = await stopSerialized()
            for counter in invocationCounters.values {
                await counter.reset()
            }
            eventLog.removeAll(keepingCapacity: true)
            for kind in DemoProducerKind.allCases {
                states[kind]?.lastResult = nil
                states[kind]?.invocationCount = 0
            }
            return try await startSerialized()
        }
    }

    public func snapshot() -> TwoProducerDemoSnapshot {
        makeSnapshot()
    }

    private func acquireOperation() async {
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func withOperation<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        await acquireOperation()
        do {
            let result = try await operation()
            releaseOperation()
            return result
        } catch {
            releaseOperation()
            throw error
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func configureIfNeeded() async throws {
        guard !configured else { return }
        let greeterCounter = invocationCounters[.greeter]!
        try await producer(.greeter).register(Self.greetingDefinition) {
            (input: GreetingInput, context: CommandContext) in
            try context.checkCancellation()
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                throw LocalMCPError.invalidCommandInput
            }
            await greeterCounter.record()
            return try .structured(
                GreetingOutput(message: "Hello, \(name)!"),
                text: "Hello, \(name)!"
            )
        }

        let calculatorCounter = invocationCounters[.calculator]!
        try await producer(.calculator).register(Self.addDefinition) {
            (input: AddInput, context: CommandContext) in
            try context.checkCancellation()
            let (sum, overflow) = input.left.addingReportingOverflow(input.right)
            guard !overflow else { throw LocalMCPError.invalidCommandInput }
            await calculatorCounter.record()
            return try .structured(
                AddOutput(sum: sum),
                text: "\(input.left) + \(input.right) = \(sum)"
            )
        }
        configured = true
    }

    private func replayDiscoveredInstances(expectedCount: Int) async throws -> [ProducerInstance] {
        let stream = await environment.discovery.events()
        var iterator = stream.makeAsyncIterator()
        var instances: [ProducerInstance] = []
        while instances.count < expectedCount, let event = await iterator.next() {
            if case let .added(instance) = event {
                instances.append(instance)
            }
        }
        guard instances.count == expectedCount else { throw LocalMCPError.producerUnavailable }
        return instances
    }

    private func pairedConsumer(for kind: DemoProducerKind) throws -> LocalMCPConsumer {
        guard running, let consumer = consumers[kind] else {
            throw LocalMCPError.producerUnavailable
        }
        guard states[kind]?.status == .paired, grants[kind] != nil else {
            throw LocalMCPError.pairingRequired
        }
        return consumer
    }

    private func handleCallFailure(_ error: any Error, kind: DemoProducerKind) {
        guard let localError = error as? LocalMCPError,
              localError == .grantRevoked || localError == .unauthorized
        else { return }
        grants.removeValue(forKey: kind)
        states[kind]?.status = .revoked
    }

    private func clearRuntimeState() {
        running = false
        consumers.removeAll(keepingCapacity: true)
        grants.removeAll(keepingCapacity: true)
        for kind in DemoProducerKind.allCases {
            states[kind]?.instance = nil
            states[kind]?.status = .offline
            states[kind]?.tools = []
            states[kind]?.lastResult = nil
            states[kind]?.invocationCount = 0
        }
    }

    private func appendEvent(_ event: String) {
        eventLog.append(event)
        if eventLog.count > 12 {
            eventLog.removeFirst(eventLog.count - 12)
        }
    }

    private func makeSnapshot() -> TwoProducerDemoSnapshot {
        let snapshots = DemoProducerKind.allCases.map { kind in
            let state = states[kind] ?? MutableProducerState()
            return DemoProducerSnapshot(
                kind: kind,
                stableID: kind.stableID,
                displayName: kind.displayName,
                endpoint: state.instance?.endpoint.url.absoluteString,
                status: state.status,
                tools: state.tools,
                lastResult: state.lastResult,
                invocationCount: state.invocationCount
            )
        }
        return TwoProducerDemoSnapshot(
            isRunning: running,
            producers: snapshots,
            events: eventLog
        )
    }

    private func producer(_ kind: DemoProducerKind) -> LocalMCPProducer {
        producers[kind]!
    }

    private nonisolated static func identity(for kind: DemoProducerKind) -> ProducerIdentity {
        ProducerIdentity(stableID: kind.stableID, displayName: kind.displayName, version: "1.0.0")
    }
}

private struct GreetingInput: Codable, Sendable {
    let name: String
}

private struct GreetingOutput: Codable, Sendable {
    let message: String
}

private struct AddInput: Codable, Sendable {
    let left: Int
    let right: Int
}

private struct AddOutput: Codable, Sendable {
    let sum: Int
}

private extension TwoProducerDemo {
    static let greetingDefinition = CommandDefinition(
        name: DemoProducerKind.greeter.commandName,
        title: "Say hello",
        description: "Returns a greeting for a supplied name.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(80),
                ]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("message")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .init(readOnly: true, idempotent: true)
    )

    static let addDefinition = CommandDefinition(
        name: DemoProducerKind.calculator.commandName,
        title: "Add integers",
        description: "Adds two signed integers.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "left": .object(["type": .string("integer")]),
                "right": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("left"), .string("right")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sum": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("sum")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .init(readOnly: true, idempotent: true)
    )
}

actor DemoAutoPairingApprover: PairingApproving {
    private let kind: DemoProducerKind
    private let beforeDecision: (@Sendable (DemoProducerKind) async -> Void)?
    private var approvalCount = 0

    init(
        kind: DemoProducerKind,
        beforeDecision: (@Sendable (DemoProducerKind) async -> Void)?
    ) {
        self.kind = kind
        self.beforeDecision = beforeDecision
    }

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        approvalCount += 1
        await beforeDecision?(kind)
        return .approve
    }

    func count() -> Int { approvalCount }
}

actor DemoInvocationCounter {
    private var value = 0

    func record() { value += 1 }
    func reset() { value = 0 }
    func count() -> Int { value }
}

struct TwoProducerDemoDiagnostics: Sendable {
    let discoveredProducerIDs: [String]
    let serviceCount: Int
    let activeTransports: [DemoProducerKind: Bool]
    let producerGrantCounts: [DemoProducerKind: Int]
    let revokedProducerGrantCounts: [DemoProducerKind: Int]
    let consumerGrantCount: Int
    let approvalCounts: [DemoProducerKind: Int]
    let handlerInvocationCounts: [DemoProducerKind: Int]
    let producerStates: [DemoProducerKind: LocalMCPProducerState]
    let queuedOperationCount: Int
}

extension TwoProducerDemo {
    func diagnostics() async -> TwoProducerDemoDiagnostics {
        var activeTransports: [DemoProducerKind: Bool] = [:]
        var producerGrantCounts: [DemoProducerKind: Int] = [:]
        var revokedProducerGrantCounts: [DemoProducerKind: Int] = [:]
        var approvalCounts: [DemoProducerKind: Int] = [:]
        var handlerInvocationCounts: [DemoProducerKind: Int] = [:]
        var producerStates: [DemoProducerKind: LocalMCPProducerState] = [:]

        for kind in DemoProducerKind.allCases {
            activeTransports[kind] = await transports[kind]!.isActive()
            producerGrantCounts[kind] = await producerStores[kind]!.count()
            revokedProducerGrantCounts[kind] = await producerStores[kind]!
                .allRecords()
                .filter { $0.metadata.revokedAt != nil }
                .count
            approvalCounts[kind] = await approvers[kind]!.count()
            handlerInvocationCounts[kind] = await invocationCounters[kind]!.count()
            producerStates[kind] = await producers[kind]!.state
        }

        return TwoProducerDemoDiagnostics(
            discoveredProducerIDs: await environment.discovery.snapshot().map(\.identity.stableID),
            serviceCount: await environment.directory.serviceCount(),
            activeTransports: activeTransports,
            producerGrantCounts: producerGrantCounts,
            revokedProducerGrantCounts: revokedProducerGrantCounts,
            consumerGrantCount: await consumerStore.count(),
            approvalCounts: approvalCounts,
            handlerInvocationCounts: handlerInvocationCounts,
            producerStates: producerStates,
            queuedOperationCount: operationWaiters.count
        )
    }
}
