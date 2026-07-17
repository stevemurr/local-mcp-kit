import Foundation
import LocalMCPContracts
import LocalMCPDiscovery

/// Listener abstraction implemented by the deterministic in-memory transport
/// and the production numeric-loopback HTTP transport.
public protocol LocalMCPProducerTransport: Sendable {
    func start(
        endpointPath: String,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint

    /// Idempotently closes all acquired resources and must converge without failure.
    func stop() async
}

/// Additive transport capability for real listeners that also serve the
/// versioned descriptor. Existing in-memory/custom transports keep conforming
/// to `LocalMCPProducerTransport` unchanged.
public protocol LocalMCPDescriptorServingTransport: LocalMCPProducerTransport {
    func start(
        endpointPath: String,
        descriptorPath: String,
        descriptor: ProducerDescriptor,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint
}

/// A descriptor-serving transport that authenticates one listener epoch with
/// an in-memory process key. The producer obtains the public half before it
/// constructs or advertises the descriptor; `stop()` destroys the matching
/// private context so a later listener epoch cannot silently reuse it.
public protocol LocalMCPSecureDescriptorServingTransport: LocalMCPDescriptorServingTransport {
    func prepareProcessChannelBinding() async throws -> ProducerChannelBinding
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
            pairingLifetime > 0 && pairingLifetime <= 120
    }
}

public enum LocalMCPProducerState: Sendable, Hashable {
    case stopped
    case starting
    case running(ProducerInstance)
    case stopping
}

/// Separates the result observed by concurrent `start()` callers from the
/// underlying acquisition task. Stopping resolves the shared visible task
/// immediately while resource convergence can continue tracking the real task.
private final class ProducerStartAttempt: @unchecked Sendable {
    private let operation: LocalMCPAsyncOperation<ProducerInstance>
    private let visibleTask: Task<ProducerInstance, any Error>

    init(
        operation body: @escaping @Sendable () async throws -> ProducerInstance
    ) {
        let operation = LocalMCPAsyncOperation<ProducerInstance>(operation: body)
        self.operation = operation
        visibleTask = Task {
            try await operation.value(cancellationError: LocalMCPError.cancelled)
        }
    }

    func value() async throws -> ProducerInstance {
        try await visibleTask.value
    }

    func cancel() {
        operation.cancel(with: LocalMCPError.cancelled)
    }

    func awaitUnderlyingCompletion() async {
        await operation.awaitUnderlyingCompletion()
    }
}

private actor ProducerStartLaunchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in current { waiter.resume() }
    }
}

/// Hosts typed commands and enforces pairing before dispatch.
public actor LocalMCPProducer: LocalMCPService {
    private static let shutdownStepTimeout: TimeInterval = 0.25

    private let identity: ProducerIdentity
    private let configuration: LocalMCPProducerConfiguration
    private let instanceID: String
    private let transport: any LocalMCPProducerTransport
    private let advertiser: any LocalMCPAdvertising
    private let registry: CommandRegistry
    private let authorization: AuthorizationManager

    private var lifecycleState: LocalMCPProducerState = .stopped
    private var lifecycleGeneration: UInt64 = 0
    private var startTask: ProducerStartAttempt?
    private var stopTask: Task<Void, Never>?
    /// Completion of every resource operation belonging to an abandoned epoch.
    /// A later start must await this before touching the shared dependencies.
    private var resourceConvergence: Task<Void, Never>?
    private var activePairings: [UUID: LocalMCPAsyncOperation<AuthorizationGrant>] = [:]
    private var activeCalls: [UUID: LocalMCPAsyncOperation<CommandResult>] = [:]
    private var stateSubscribers: [UUID: AsyncStream<LocalMCPProducerState>.Continuation] = [:]
    private var listCommandsCheckpointForTesting: (@Sendable () async -> Void)?

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
        let authorization = authorization
        let service: any LocalMCPService = self
        let previousConvergence = resourceConvergence
        let launchGate = ProducerStartLaunchGate()

        let task = ProducerStartAttempt {
            await launchGate.wait()
            if Task.isCancelled { throw LocalMCPError.cancelled }
            if let previousConvergence {
                await previousConvergence.value
            }
            if Task.isCancelled { throw LocalMCPError.cancelled }
            let channelBinding: ProducerChannelBinding?
            do {
                if transport is any LocalMCPDescriptorServingTransport {
                    guard let secureTransport = transport
                        as? any LocalMCPSecureDescriptorServingTransport
                    else { throw LocalMCPError.invalidConfiguration }
                    channelBinding = try await secureTransport.prepareProcessChannelBinding()
                } else {
                    channelBinding = nil
                }
            } catch is CancellationError {
                await transport.stop()
                throw LocalMCPError.cancelled
            } catch let error as LocalMCPError {
                await transport.stop()
                throw error
            } catch {
                await transport.stop()
                throw LocalMCPError.invalidConfiguration
            }
            let endpointBinding = channelBinding.map {
                AuthorizationEndpointBinding(instanceID: instanceID, channelBinding: $0)
            }
            do {
                try await authorization.setEndpointBinding(endpointBinding)
            } catch {
                await transport.stop()
                throw LocalMCPError.invalidConfiguration
            }
            let descriptor = ProducerDescriptor(
                instanceID: instanceID,
                server: identity,
                mcp: MCPDescriptor(endpoint: configuration.endpointPath),
                channelBinding: channelBinding
            )
            let endpoint: LoopbackEndpoint
            do {
                if let descriptorTransport = transport as? any LocalMCPDescriptorServingTransport {
                    endpoint = try await descriptorTransport.start(
                        endpointPath: configuration.endpointPath,
                        descriptorPath: configuration.descriptorPath,
                        descriptor: descriptor,
                        service: service
                    )
                } else {
                    endpoint = try await transport.start(
                        endpointPath: configuration.endpointPath,
                        service: service
                    )
                }
            } catch is CancellationError {
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw LocalMCPError.cancelled
            } catch let error as LocalMCPError where error == .invalidConfiguration {
                // Transport implementations validate their own public knobs
                // before acquisition. Preserve that stable configuration error
                // instead of misreporting it as an operating-system bind failure.
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw error
            } catch {
                // A listener may have acquired resources before reporting failure.
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw LocalMCPError.bindFailed
            }

            guard endpoint.path == configuration.endpointPath else {
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
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
                    descriptorURL: descriptorEndpoint,
                    channelBinding: channelBinding
                )
                try await advertiser.advertise(instance: instance, descriptor: descriptor)
                try Task.checkCancellation()
                return instance
            } catch is CancellationError {
                await advertiser.withdraw(instanceID: instanceID)
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw LocalMCPError.cancelled
            } catch let error as LocalMCPError where error == .invalidConfiguration {
                await advertiser.withdraw(instanceID: instanceID)
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw error
            } catch {
                // Defensively withdraw even when the backend threw after publishing.
                await advertiser.withdraw(instanceID: instanceID)
                await authorization.clearEndpointBinding(ifMatching: endpointBinding)
                await transport.stop()
                throw LocalMCPError.advertisementFailed
            }
        }
        startTask = task
        publish(.starting)
        // Seal from the lifecycle actor before releasing unstructured resource
        // acquisition. A cancelled/abandoned task can therefore never reseal a
        // registry after stop has visibly returned it to the stopped state.
        await registry.seal()
        let ownsLifecycle = generation == lifecycleGeneration
            && startTask === task
            && lifecycleState == .starting
        await launchGate.open()
        guard ownsLifecycle else {
            // A newer run owns sealed state; only a visibly stopped producer
            // should be unsealed by this stale start continuation.
            if lifecycleState == .stopped {
                await registry.unseal()
            }
            throw LocalMCPError.cancelled
        }
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
        try? await authorization.setEndpointBinding(nil)
        let pendingStart = startTask
        pendingStart?.cancel()
        startTask = nil
        let pendingPairings = Array(activePairings.values)
        let pendingCalls = Array(activeCalls.values)
        activePairings.removeAll(keepingCapacity: false)
        activeCalls.removeAll(keepingCapacity: false)
        pendingPairings.forEach { $0.cancel(with: LocalMCPError.cancelled) }
        pendingCalls.forEach { $0.cancel(with: LocalMCPError.cancelled) }

        let advertiser = advertiser
        let transport = transport
        let authorization = authorization
        let instanceID = instanceID
        let withdraw = LocalMCPAsyncOperation<Void>(
            timeoutAfter: Self.shutdownStepTimeout,
            timeoutError: LocalMCPError.cancelled
        ) {
            await advertiser.withdraw(instanceID: instanceID)
        }
        let visibleWithdraw = Task<Void, Never> {
            _ = try? await withdraw.value(cancellationError: LocalMCPError.cancelled)
        }

        // Preserve withdraw-before-close ordering even when withdrawal ignores
        // cancellation. The close step receives its own bounded grace period
        // after the visible withdrawal result has resolved.
        let close = LocalMCPAsyncOperation<Void>(
            timeout: {
                await visibleWithdraw.value
                try await Task.sleep(
                    nanoseconds: UInt64(Self.shutdownStepTimeout * 1_000_000_000)
                )
            },
            timeoutError: LocalMCPError.cancelled
        ) {
            await visibleWithdraw.value
            await transport.stop()
        }
        let visibleClose = Task<Void, Never> {
            _ = try? await close.value(cancellationError: LocalMCPError.cancelled)
        }
        let cleanup = Task<Void, Never> {
            await visibleWithdraw.value
            await visibleClose.value
        }

        // Keep every losing operation owned by this epoch. A later start waits
        // for this task, including a final cleanup after a startup that acquired
        // resources late. No old stop/withdraw can therefore overlap a new run.
        let convergence = Task<Void, Never> {
            await withdraw.awaitUnderlyingCompletion()
            await close.awaitUnderlyingCompletion()
            await pendingStart?.awaitUnderlyingCompletion()
            await advertiser.withdraw(instanceID: instanceID)
            await transport.stop()
            try? await authorization.setEndpointBinding(nil)
        }
        resourceConvergence = convergence
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

    /// Lists persisted producer-side grants in deterministic grant-ID order.
    /// Records contain credential digests only; bearer credentials are never exposed.
    public func grantRecords() async throws -> [ProducerGrantRecord] {
        try await authorization.records()
    }

    func setListCommandsCheckpointForTesting(
        _ checkpoint: (@Sendable () async -> Void)?
    ) {
        listCommandsCheckpointForTesting = checkpoint
    }

    // MARK: LocalMCPService

    public func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        guard case .running = lifecycleState else { throw LocalMCPError.producerUnavailable }
        let generation = lifecycleGeneration
        let operationID = UUID()
        let operation = LocalMCPAsyncOperation<AuthorizationGrant> { [authorization] in
            try await authorization.pair(request)
        }
        activePairings[operationID] = operation
        let grant: AuthorizationGrant
        do {
            grant = try await operation.value(cancellationError: LocalMCPError.cancelled)
            activePairings.removeValue(forKey: operationID)
        } catch {
            activePairings.removeValue(forKey: operationID)
            throw error
        }
        guard generation == lifecycleGeneration, case .running = lifecycleState else {
            try? await authorization.revoke(grantID: grant.metadata.grantID)
            throw LocalMCPError.producerUnavailable
        }
        return grant
    }

    public func authenticate(credential: AuthorizationCredential?) async throws {
        try ensureRunning()
        _ = try await authorization.authenticate(credential)
        try ensureRunning()
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
        let generation = lifecycleGeneration
        _ = try await authorization.authenticate(credential)
        try ensureRunning()
        if let checkpoint = listCommandsCheckpointForTesting {
            listCommandsCheckpointForTesting = nil
            await checkpoint()
        }
        let definitions = await registry.definitions()
        guard generation == lifecycleGeneration, case .running = lifecycleState else {
            throw LocalMCPError.producerUnavailable
        }
        return definitions
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
        let generation = lifecycleGeneration
        let grant = try await authorization.authenticate(credential)
        try ensureRunning()
        let context = CommandContext(
            consumer: grant.consumer,
            grantID: grant.grantID,
            requestID: request.requestID,
            deadline: request.deadline
        )
        let operationID = UUID()
        let operation = LocalMCPAsyncOperation<CommandResult> { [registry] in
            try await registry.invoke(request, context: context)
        }
        activeCalls[operationID] = operation
        do {
            let result = try await operation.value(cancellationError: LocalMCPError.cancelled)
            activeCalls.removeValue(forKey: operationID)
            guard generation == lifecycleGeneration, case .running = lifecycleState else {
                throw LocalMCPError.producerUnavailable
            }
            return result
        } catch {
            activeCalls.removeValue(forKey: operationID)
            throw error
        }
    }

    // MARK: Lifecycle internals

    private func finishStart(
        _ task: ProducerStartAttempt,
        generation: UInt64
    ) async throws {
        do {
            let instance = try await task.value()
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
