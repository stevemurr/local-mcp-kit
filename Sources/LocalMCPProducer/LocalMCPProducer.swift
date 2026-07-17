import Foundation
import LocalMCPContracts
import LocalMCPDiscovery

/// Listener abstraction implemented by the in-memory test transport in Phase 1
/// and the loopback HTTP listener in Phase 2.
public protocol LocalMCPProducerTransport: Sendable {
    func start(
        endpointPath: String,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint

    /// Idempotently closes all acquired resources and must converge without failure.
    func stop() async
}

/// Immutable configuration whose public shape cannot express a non-loopback bind.
public struct LocalMCPProducerConfiguration: Sendable, Hashable {
    public let endpointPath: String
    public let descriptorPath: String
    public let pairingLifetime: TimeInterval

    public static func localOnly(
        endpointPath: String = "/mcp",
        descriptorPath: String = "/local-mcp/v1/descriptor.json",
        pairingLifetime: TimeInterval = 120
    ) -> LocalMCPProducerConfiguration {
        LocalMCPProducerConfiguration(
            endpointPath: endpointPath,
            descriptorPath: descriptorPath,
            pairingLifetime: pairingLifetime
        )
    }

    private init(endpointPath: String, descriptorPath: String, pairingLifetime: TimeInterval) {
        self.endpointPath = endpointPath
        self.descriptorPath = descriptorPath
        self.pairingLifetime = pairingLifetime
    }

    public var isValid: Bool {
        endpointPath == "/mcp" &&
            descriptorPath == "/local-mcp/v1/descriptor.json" &&
            pairingLifetime > 0 && pairingLifetime <= 600
    }
}

public enum LocalMCPProducerState: Sendable, Hashable {
    case stopped
    case starting
    case running(ProducerInstance)
    case stopping
}

/// Hosts typed commands and enforces pairing before dispatch.
public actor LocalMCPProducer: LocalMCPService {
    private let identity: ProducerIdentity
    private let configuration: LocalMCPProducerConfiguration
    private let instanceID: String
    private let transport: any LocalMCPProducerTransport
    private let advertiser: any LocalMCPAdvertising
    private let registry: CommandRegistry
    private let authorization: AuthorizationManager

    private var lifecycleState: LocalMCPProducerState = .stopped
    private var lifecycleGeneration: UInt64 = 0
    private var startTask: Task<ProducerInstance, any Error>?
    private var stopTask: Task<Void, Never>?
    private var activePairings: [UUID: Task<AuthorizationGrant, any Error>] = [:]
    private var activeCalls: [UUID: Task<CommandResult, any Error>] = [:]
    private var stateSubscribers: [UUID: AsyncStream<LocalMCPProducerState>.Continuation] = [:]

    public init(
        identity: ProducerIdentity,
        configuration: LocalMCPProducerConfiguration = .localOnly(),
        instanceID: String = UUID().uuidString.lowercased(),
        transport: any LocalMCPProducerTransport,
        advertiser: any LocalMCPAdvertising,
        grantStore: any ProducerGrantStoring,
        approval: any PairingApproving,
        clock: any LocalMCPClock = SystemLocalMCPClock(),
        sleeper: any LocalMCPSleeping = SystemLocalMCPSleeper(),
        random: any RandomBytesGenerating = SystemRandomBytesGenerator()
    ) {
        self.identity = identity
        self.configuration = configuration
        self.instanceID = instanceID
        self.transport = transport
        self.advertiser = advertiser
        registry = CommandRegistry(clock: clock, sleeper: sleeper)
        authorization = AuthorizationManager(
            producerID: identity.stableID,
            store: grantStore,
            approval: approval,
            clock: clock,
            sleeper: sleeper,
            random: random,
            pairingLifetime: configuration.pairingLifetime
        )
    }

    public var state: LocalMCPProducerState { lifecycleState }

    public func stateUpdates() -> AsyncStream<LocalMCPProducerState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LocalMCPProducerState>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        stateSubscribers[id] = continuation
        continuation.yield(lifecycleState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        return stream
    }

    public func register<Input: Decodable & Sendable>(
        _ definition: CommandDefinition,
        handler: @escaping @Sendable (Input, CommandContext) async throws -> CommandResult
    ) async throws {
        guard lifecycleState == .stopped, stopTask == nil, startTask == nil else {
            throw LocalMCPError.invalidLifecycleState
        }
        try await registry.register(definition, handler: handler)
    }

    public func registerDynamic(
        _ definition: CommandDefinition,
        handler: @escaping CommandRegistry.DynamicHandler
    ) async throws {
        guard lifecycleState == .stopped, stopTask == nil, startTask == nil else {
            throw LocalMCPError.invalidLifecycleState
        }
        try await registry.registerDynamic(definition, handler: handler)
    }

    /// Starts once; concurrent callers await the same startup attempt.
    public func start() async throws {
        if case .running = lifecycleState { return }

        if let stopTask {
            await stopTask.value
            await finishStoppingIfNeeded()
        }

        if let existing = startTask {
            let generation = lifecycleGeneration
            try await finishStart(existing, generation: generation)
            return
        }

        guard lifecycleState == .stopped,
              identity.isValid,
              configuration.isValid,
              LocalMCPValidation.isCanonicalLowercaseUUID(instanceID)
        else { throw LocalMCPError.invalidConfiguration }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        let identity = identity
        let instanceID = instanceID
        let configuration = configuration
        let transport = transport
        let advertiser = advertiser
        let registry = registry
        let service: any LocalMCPService = self

        let task = Task<ProducerInstance, any Error> {
            await registry.seal()
            if Task.isCancelled { throw LocalMCPError.cancelled }
            let endpoint: LoopbackEndpoint
            do {
                endpoint = try await transport.start(
                    endpointPath: configuration.endpointPath,
                    service: service
                )
            } catch is CancellationError {
                await transport.stop()
                throw LocalMCPError.cancelled
            } catch {
                // A listener may have acquired resources before reporting failure.
                await transport.stop()
                throw LocalMCPError.bindFailed
            }

            guard endpoint.path == configuration.endpointPath else {
                await transport.stop()
                throw LocalMCPError.bindFailed
            }

            do {
                try Task.checkCancellation()
                let descriptorEndpoint = try LoopbackEndpoint(
                    port: endpoint.port,
                    path: configuration.descriptorPath
                )
                let instance = ProducerInstance(
                    identity: identity,
                    instanceID: instanceID,
                    endpoint: endpoint,
                    descriptorURL: descriptorEndpoint
                )
                let descriptor = ProducerDescriptor(
                    instanceID: instanceID,
                    server: identity,
                    mcp: MCPDescriptor(endpoint: configuration.endpointPath)
                )
                try await advertiser.advertise(instance: instance, descriptor: descriptor)
                try Task.checkCancellation()
                return instance
            } catch is CancellationError {
                await advertiser.withdraw(instanceID: instanceID)
                await transport.stop()
                throw LocalMCPError.cancelled
            } catch let error as LocalMCPError where error == .invalidConfiguration {
                await advertiser.withdraw(instanceID: instanceID)
                await transport.stop()
                throw error
            } catch {
                // Defensively withdraw even when the backend threw after publishing.
                await advertiser.withdraw(instanceID: instanceID)
                await transport.stop()
                throw LocalMCPError.advertisementFailed
            }
        }
        startTask = task
        publish(.starting)
        try await finishStart(task, generation: generation)
    }

    /// Withdraws discovery before closing the endpoint. Repeated calls coalesce.
    public func stop() async {
        if lifecycleState == .stopped, startTask == nil, stopTask == nil { return }
        if let existing = stopTask {
            await existing.value
            await finishStoppingIfNeeded()
            return
        }

        lifecycleGeneration &+= 1
        publish(.stopping)
        let pendingStart = startTask
        pendingStart?.cancel()
        startTask = nil
        let pendingPairings = Array(activePairings.values)
        let pendingCalls = Array(activeCalls.values)
        pendingPairings.forEach { $0.cancel() }
        pendingCalls.forEach { $0.cancel() }

        let advertiser = advertiser
        let transport = transport
        let instanceID = instanceID
        let cleanup = Task<Void, Never> {
            await advertiser.withdraw(instanceID: instanceID)
            // Closing acceptance first also unblocks a listener that is still
            // suspended inside startup.
            await transport.stop()
            for task in pendingPairings { _ = try? await task.value }
            for task in pendingCalls { _ = try? await task.value }
            _ = try? await pendingStart?.value
            // A cancellation-insensitive backend may have completed after the
            // first cleanup pass. A second pass makes shutdown convergent.
            await advertiser.withdraw(instanceID: instanceID)
            await transport.stop()
        }
        stopTask = cleanup
        await cleanup.value
        await finishStoppingIfNeeded()
    }

    public func revokeGrant(_ grantID: String) async throws {
        try await authorization.revoke(grantID: grantID)
    }

    public func grantRecord(_ grantID: String) async throws -> ProducerGrantRecord? {
        try await authorization.record(grantID: grantID)
    }

    // MARK: LocalMCPService

    public func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        guard case .running = lifecycleState else { throw LocalMCPError.producerUnavailable }
        let generation = lifecycleGeneration
        let operationID = UUID()
        let task = Task<AuthorizationGrant, any Error> { [authorization] in
            try await authorization.pair(request)
        }
        activePairings[operationID] = task
        defer { activePairings.removeValue(forKey: operationID) }
        let grant = try await task.value
        guard generation == lifecycleGeneration, case .running = lifecycleState else {
            try? await authorization.revoke(grantID: grant.metadata.grantID)
            throw LocalMCPError.producerUnavailable
        }
        return grant
    }

    public func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        try ensureRunning()
        _ = try await authorization.authenticate(credential)
        try ensureRunning()
        guard supportedProtocolVersions.contains(MCPProtocolVersion.current.rawValue) else {
            throw LocalMCPError.incompatibleMCPProtocol
        }
        return LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: identity,
            capabilities: ProducerCapabilities(tools: true)
        )
    }

    public func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        try ensureRunning()
        _ = try await authorization.authenticate(credential)
        try ensureRunning()
        return await registry.definitions()
    }

    public func initialized(credential: AuthorizationCredential?) async throws {
        try ensureRunning()
        _ = try await authorization.authenticate(credential)
        try ensureRunning()
    }

    public func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        try ensureRunning()
        let grant = try await authorization.authenticate(credential)
        try ensureRunning()
        let context = CommandContext(
            consumer: grant.consumer,
            grantID: grant.grantID,
            requestID: request.requestID,
            deadline: request.deadline
        )
        let operationID = UUID()
        let task = Task<CommandResult, any Error> { [registry] in
            try await registry.invoke(request, context: context)
        }
        activeCalls[operationID] = task
        defer { activeCalls.removeValue(forKey: operationID) }
        return try await task.value
    }

    // MARK: Lifecycle internals

    private func finishStart(
        _ task: Task<ProducerInstance, any Error>,
        generation: UInt64
    ) async throws {
        do {
            let instance = try await task.value
            guard generation == lifecycleGeneration else {
                throw LocalMCPError.cancelled
            }
            if case .running = lifecycleState { return }
            guard lifecycleState == .starting else {
                throw LocalMCPError.cancelled
            }
            startTask = nil
            publish(.running(instance))
        } catch {
            if generation == lifecycleGeneration, lifecycleState == .starting {
                startTask = nil
                await registry.unseal()
                publish(.stopped)
            }
            if let error = error as? LocalMCPError { throw error }
            throw LocalMCPError.bindFailed
        }
    }

    private func finishStoppingIfNeeded() async {
        guard lifecycleState == .stopping else { return }
        stopTask = nil
        await registry.unseal()
        publish(.stopped)
    }

    private func ensureRunning() throws {
        guard case .running = lifecycleState else {
            throw LocalMCPError.producerUnavailable
        }
    }

    private func publish(_ state: LocalMCPProducerState) {
        lifecycleState = state
        for continuation in stateSubscribers.values {
            continuation.yield(state)
        }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers.removeValue(forKey: id)
    }
}
