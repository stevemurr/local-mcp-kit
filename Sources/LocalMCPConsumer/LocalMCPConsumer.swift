import Foundation
import LocalMCPContracts

/// A transport-neutral consumer wrapper for pairing and the negotiated MCP lifecycle.
public actor LocalMCPConsumer {
    private struct Target: Sendable {
        let instance: ProducerInstance
        let generation: UInt64
    }

    private struct ConnectionState: Sendable {
        let instance: ProducerInstance
        let service: any LocalMCPService
        var credential: AuthorizationCredential?
        var initialization: LocalMCPInitialization?
    }

    private struct NegotiationOutcome: Sendable {
        let service: any LocalMCPService
        let initialization: LocalMCPInitialization
    }

    private struct NegotiationState: Sendable {
        let id: UUID
        let instance: ProducerInstance
        let credential: AuthorizationCredential
        let task: Task<NegotiationOutcome, any Error>
        var waiters: Int
    }

    private struct ActiveOperation: Sendable {
        let cancel: @Sendable (LocalMCPError) -> Void
    }

    private var instance: ProducerInstance
    private var available = true
    private var routingGeneration: UInt64 = 0
    private var activeGrant: (instance: ProducerInstance, grant: AuthorizationGrant)?
    private var connection: ConnectionState?
    private var negotiation: NegotiationState?
    private var pairingToken: UUID?
    private var activeOperations: [UUID: ActiveOperation] = [:]
    private let identity: ConsumerIdentity
    private let connector: any LocalMCPConnecting
    private let grantStore: any ConsumerGrantStoring
    private let clock: any LocalMCPClock
    private let random: any RandomBytesGenerating

    public init(
        instance: ProducerInstance,
        identity: ConsumerIdentity,
        connector: any LocalMCPConnecting,
        grantStore: any ConsumerGrantStoring,
        clock: any LocalMCPClock = SystemLocalMCPClock(),
        random: any RandomBytesGenerating = SystemRandomBytesGenerator()
    ) {
        self.instance = instance
        self.identity = identity
        self.connector = connector
        self.grantStore = grantStore
        self.clock = clock
        self.random = random
    }

    public var producerInstance: ProducerInstance { instance }
    public var isAvailable: Bool { available }

    /// Updates routing for the same stable producer after a discovery transition.
    /// Any material change drops in-memory trust because the advertisement is not
    /// authenticated. V1 requires a fresh explicit producer approval/rebinding
    /// before a changed instance receives any persisted bearer.
    public func update(instance next: ProducerInstance) async throws {
        guard next.identity.stableID == instance.identity.stableID else {
            throw LocalMCPError.invalidConfiguration
        }
        var staleConnection: ConnectionState?
        if next != instance || !available {
            staleConnection = invalidateRouting()
        }
        instance = next
        available = true
        await disconnect(staleConnection)
    }

    public func markRemoved(instanceID: String) async {
        if instance.instanceID == instanceID {
            let staleConnection = invalidateRouting()
            available = false
            await disconnect(staleConnection)
        }
    }

    /// Cancels in-flight work, terminates the cached MCP session, and makes the
    /// consumer unavailable until a later explicit `update(instance:)`.
    public func close() async {
        let staleConnection = invalidateRouting()
        available = false
        await disconnect(staleConnection)
    }

    /// Begins explicit pairing. The callback lets consumer UI display the same
    /// short code as the producer approval prompt.
    @discardableResult
    public func pair(
        displayVerificationCode: (@Sendable (PairingVerificationCode) -> Void)? = nil
    ) async throws -> AuthorizationGrant {
        guard pairingToken == nil else { throw LocalMCPError.pairingDenied }
        let token = UUID()
        pairingToken = token

        do {
            let grant = try await completePairing(
                displayVerificationCode: displayVerificationCode
            )
            clearPairing(token)
            return grant
        } catch {
            clearPairing(token)
            throw error
        }
    }

    private func completePairing(
        displayVerificationCode: (@Sendable (PairingVerificationCode) -> Void)?
    ) async throws -> AuthorizationGrant {
        let target = try currentTarget()
        guard identity.isValid else { throw LocalMCPError.invalidConfiguration }

        let nonce: PairingNonce
        do {
            let random = random
            let bytes = try await performTracked(for: target) {
                try await random.randomBytes(count: 32)
            }
            nonce = try PairingNonce(bytes: bytes)
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError {
            if error == .cancelled || error == .producerUnavailable { throw error }
            throw LocalMCPError.producerUnavailable
        } catch {
            throw LocalMCPError.producerUnavailable
        }
        try ensureCurrent(target)
        let service = try await connect(to: target)
        let request: PairingRequest
        do {
            if target.instance.channelBinding != nil {
                request = try PairingRequest(
                    consumer: identity,
                    requestNonce: nonce,
                    bindingTo: target.instance
                )
            } else {
                request = PairingRequest(consumer: identity, requestNonce: nonce)
            }
        } catch {
            throw LocalMCPError.invalidConfiguration
        }

        let grant: AuthorizationGrant
        if target.instance.channelBinding != nil {
            guard let reportingService = service
                as? any LocalMCPPairingCodeReportingService
            else { throw LocalMCPError.incompatibleDiscoveryProfile }
            grant = try await performTracked(for: target) {
                try await reportingService.requestPairing(
                    request,
                    displayVerificationCode: { code in
                        displayVerificationCode?(code)
                    }
                )
            }
        } else {
            displayVerificationCode?(PairingVerificationCode(nonce: nonce))
            grant = try await performTracked(for: target) {
                try await service.requestPairing(request)
            }
        }
        let expectedEndpointBinding = target.instance.channelBinding.map {
            AuthorizationEndpointBinding(
                instanceID: target.instance.instanceID,
                channelBinding: $0
            )
        }
        guard grant.metadata.producerID == target.instance.identity.stableID,
              grant.metadata.consumer.representsSameInstallation(as: identity),
              grant.metadata.revokedAt == nil,
              !grant.metadata.isExpired(at: await clock.now()),
              grant.endpointBinding == expectedEndpointBinding
        else { throw LocalMCPError.unauthorized }
        try ensureCurrent(target)

        let grantStore = grantStore
        let producerID = target.instance.identity.stableID
        let identity = identity
        do {
            try await performTracked(for: target) {
                try await grantStore.save(grant)
                if Task.isCancelled {
                    try? await grantStore.remove(
                        producerID: producerID,
                        consumer: identity,
                        ifCredentialMatches: grant.credential
                    )
                    throw LocalMCPError.cancelled
                }
            }
        } catch let error as LocalMCPError
            where error == .producerUnavailable || error == .cancelled
        {
            throw error
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        do {
            try ensureCurrent(target)
        } catch {
            try? await grantStore.remove(
                producerID: target.instance.identity.stableID,
                consumer: identity,
                ifCredentialMatches: grant.credential
            )
            throw error
        }
        if let negotiation {
            abandonNegotiation(negotiation.task, credential: negotiation.credential)
        }
        negotiation = nil
        let staleConnection = connection
        connection = nil
        activeGrant = nil
        cancelActiveOperations(with: .cancelled)
        await disconnect(staleConnection)
        if Task.isCancelled { throw LocalMCPError.cancelled }
        do {
            try ensureCurrent(target)
        } catch {
            try? await grantStore.remove(
                producerID: target.instance.identity.stableID,
                consumer: identity,
                ifCredentialMatches: grant.credential
            )
            throw error
        }
        activeGrant = (target.instance, grant)
        return grant
    }

    /// Reads persisted material for operator UI or an explicit, authenticated
    /// re-binding flow. It is never sent automatically to a new process instance.
    public func storedGrant() async throws -> AuthorizationGrant? {
        let producerID = instance.identity.stableID
        do {
            return try await grantStore.grant(producerID: producerID, consumer: identity)
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
    }

    /// Performs initialize and the required initialized notification on one
    /// cached connection. An explicit grant is an authority-bearing operation;
    /// callers must provision or authenticate the target before supplying it.
    public func initialize(grant explicitGrant: AuthorizationGrant? = nil) async throws -> LocalMCPInitialization {
        let target = try currentTarget()
        let grant = try await usableGrant(explicitGrant, for: target)
        return try await negotiateIfNeeded(grant: grant, target: target)
    }

    public func listTools(grant explicitGrant: AuthorizationGrant? = nil) async throws -> [CommandDefinition] {
        let target = try currentTarget()
        let grant = try await usableGrant(explicitGrant, for: target)
        var service = try await initializedService(grant: grant, target: target)
        for attempt in 0 ... 1 {
            let attemptService = service
            do {
                return try await performTracked(for: target) {
                    try await attemptService.listCommands(credential: grant.credential)
                }
            } catch let error as LocalMCPError
                where error == .invalidLifecycleState && attempt == 0
            {
                clearCachedInitialization(grant: grant, target: target)
                service = try await initializedService(grant: grant, target: target)
            } catch {
                try await handleAuthorizationFailure(error, attemptedGrant: grant, target: target)
                throw error
            }
        }
        throw LocalMCPError.invalidLifecycleState
    }

    public func call(
        _ name: String,
        arguments: JSONValue,
        grant explicitGrant: AuthorizationGrant? = nil,
        deadline: Date? = nil
    ) async throws -> CommandResult {
        let target = try currentTarget()
        let grant = try await usableGrant(explicitGrant, for: target)
        let requestID = try await randomIdentifier(for: target)
        try ensureCurrent(target)
        let request = CommandCallRequest(
            name: name,
            arguments: arguments,
            requestID: requestID,
            deadline: deadline
        )
        let service = try await initializedService(grant: grant, target: target)
        do {
            return try await performTracked(for: target) {
                try await service.callCommand(request, credential: grant.credential)
            }
        } catch let error as LocalMCPError where error == .invalidLifecycleState {
            clearCachedInitialization(grant: grant, target: target)
            _ = try await initializedService(grant: grant, target: target)
            throw error
        } catch {
            try await handleAuthorizationFailure(error, attemptedGrant: grant, target: target)
            throw error
        }
    }

    public func call<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ name: String,
        input: Input,
        as outputType: Output.Type = Output.self,
        grant explicitGrant: AuthorizationGrant? = nil,
        deadline: Date? = nil
    ) async throws -> Output {
        let arguments: JSONValue
        do {
            arguments = try JSONValue.encode(input)
        } catch {
            throw LocalMCPError.invalidCommandInput
        }
        let result = try await call(
            name,
            arguments: arguments,
            grant: explicitGrant,
            deadline: deadline
        )
        return try result.decode(as: outputType)
    }

    private func usableGrant(
        _ explicitGrant: AuthorizationGrant?,
        for target: Target
    ) async throws -> AuthorizationGrant {
        let grant: AuthorizationGrant
        if let explicitGrant {
            grant = explicitGrant
        } else if let activeGrant, activeGrant.instance == target.instance {
            grant = activeGrant.grant
        } else {
            throw LocalMCPError.pairingRequired
        }

        guard grant.metadata.producerID == target.instance.identity.stableID,
              grant.metadata.consumer.representsSameInstallation(as: identity),
              grant.endpointBinding == target.instance.channelBinding.map({
                  AuthorizationEndpointBinding(
                      instanceID: target.instance.instanceID,
                      channelBinding: $0
                  )
              })
        else { throw LocalMCPError.unauthorized }
        if grant.metadata.revokedAt != nil { throw LocalMCPError.grantRevoked }
        if grant.metadata.isExpired(at: await clock.now()) { throw LocalMCPError.unauthorized }
        try ensureCurrent(target)

        // Supplying a grant explicitly binds it only to this captured target.
        if explicitGrant != nil {
            activeGrant = (target.instance, grant)
        }
        return grant
    }

    private func initializedService(
        grant: AuthorizationGrant,
        target: Target
    ) async throws -> any LocalMCPService {
        if let connection,
           connection.instance == target.instance,
           connection.credential == grant.credential,
           connection.initialization != nil
        {
            return connection.service
        }
        _ = try await negotiateIfNeeded(grant: grant, target: target)
        guard let connection,
              connection.instance == target.instance,
              connection.credential == grant.credential,
              connection.initialization != nil
        else { throw LocalMCPError.producerUnavailable }
        return connection.service
    }

    private func negotiateIfNeeded(
        grant: AuthorizationGrant,
        target: Target
    ) async throws -> LocalMCPInitialization {
        if let connection,
           connection.instance == target.instance,
           connection.credential == grant.credential,
           let initialization = connection.initialization
        {
            return initialization
        }

        if let negotiation,
           negotiation.instance == target.instance,
           negotiation.credential == grant.credential
        {
            do {
                let outcome = try await awaitNegotiation(
                    id: negotiation.id,
                    task: negotiation.task,
                    grant: grant,
                    target: target
                )
                try ensureCurrent(target)
                connection = ConnectionState(
                    instance: target.instance,
                    service: outcome.service,
                    credential: grant.credential,
                    initialization: outcome.initialization
                )
                clearNegotiation(instance: target.instance, credential: grant.credential)
                return outcome.initialization
            } catch {
                try await handleAuthorizationFailure(error, attemptedGrant: grant, target: target)
                throw error
            }
        }

        let cachedService = connection?.instance == target.instance ? connection?.service : nil
        let connector = connector
        let targetInstance = target.instance
        let credential = grant.credential
        let task = Task<NegotiationOutcome, any Error> {
            let service: any LocalMCPService
            if let cachedService {
                service = cachedService
            } else {
                service = try await connector.connect(to: targetInstance)
            }
            do {
                if Task.isCancelled { throw LocalMCPError.cancelled }
                let initialization = try await service.initialize(
                    supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                    credential: credential
                )
                if Task.isCancelled { throw LocalMCPError.cancelled }
                guard initialization.protocolVersion == MCPProtocolVersion.current.rawValue else {
                    throw LocalMCPError.incompatibleMCPProtocol
                }
                guard initialization.server.isValid,
                      initialization.server.stableID == targetInstance.identity.stableID
                else {
                    throw LocalMCPError.unauthorized
                }
                guard initialization.capabilities.tools else {
                    throw LocalMCPError.incompatibleMCPProtocol
                }
                try await service.initialized(credential: credential)
                if Task.isCancelled { throw LocalMCPError.cancelled }
                return NegotiationOutcome(service: service, initialization: initialization)
            } catch {
                await disconnectService(service, credential: credential)
                throw error
            }
        }
        let negotiationID = UUID()
        negotiation = NegotiationState(
            id: negotiationID,
            instance: target.instance,
            credential: grant.credential,
            task: task,
            waiters: 0
        )
        do {
            let outcome = try await awaitNegotiation(
                id: negotiationID,
                task: task,
                grant: grant,
                target: target
            )
            try ensureCurrent(target)
            connection = ConnectionState(
                instance: target.instance,
                service: outcome.service,
                credential: grant.credential,
                initialization: outcome.initialization
            )
            clearNegotiation(instance: target.instance, credential: grant.credential)
            return outcome.initialization
        } catch {
            try await handleAuthorizationFailure(error, attemptedGrant: grant, target: target)
            throw error
        }
    }

    private func currentTarget() throws -> Target {
        try validate(instance: instance, available: available)
        return Target(instance: instance, generation: routingGeneration)
    }

    private func ensureCurrent(_ target: Target) throws {
        guard available,
              routingGeneration == target.generation,
              instance == target.instance
        else { throw LocalMCPError.producerUnavailable }
    }

    private func validate(instance: ProducerInstance, available: Bool) throws {
        guard available else { throw LocalMCPError.producerUnavailable }
        switch instance.compatibility {
        case .compatible:
            return
        case .incompatibleDiscoveryProfile:
            throw LocalMCPError.incompatibleDiscoveryProfile
        case .incompatibleMCPProtocol:
            throw LocalMCPError.incompatibleMCPProtocol
        }
    }

    private func connect(to target: Target) async throws -> any LocalMCPService {
        if let connection, connection.instance == target.instance {
            return connection.service
        }
        let service: any LocalMCPService
        do {
            let connector = connector
            let targetInstance = target.instance
            service = try await performTracked(for: target) {
                let service = try await connector.connect(to: targetInstance)
                if Task.isCancelled {
                    await disconnectService(service, credential: nil)
                    throw LocalMCPError.cancelled
                }
                return service
            }
        } catch let error as LocalMCPError {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
        }
        try ensureCurrent(target)
        connection = ConnectionState(
            instance: target.instance,
            service: service,
            credential: nil,
            initialization: nil
        )
        return service
    }

    private func randomIdentifier(for target: Target) async throws -> String {
        do {
            let random = random
            let bytes = try await performTracked(for: target) {
                try await random.randomBytes(count: 16)
            }
            guard bytes.count == 16 else { throw LocalMCPError.commandFailed }
            return bytes.map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError {
            throw error
        } catch {
            throw LocalMCPError.commandFailed
        }
    }

    private func clearNegotiation(
        instance: ProducerInstance,
        credential: AuthorizationCredential
    ) {
        if negotiation?.instance == instance, negotiation?.credential == credential {
            negotiation = nil
        }
    }

    private func awaitNegotiation(
        id: UUID,
        task: Task<NegotiationOutcome, any Error>,
        grant: AuthorizationGrant,
        target: Target
    ) async throws -> NegotiationOutcome {
        guard var current = negotiation, current.id == id else {
            throw LocalMCPError.producerUnavailable
        }
        current.waiters += 1
        negotiation = current

        do {
            let outcome = try await performTracked(for: target) {
                try await task.value
            }
            finishNegotiationWait(id: id, failed: false, task: task, grant: grant)
            return outcome
        } catch {
            finishNegotiationWait(id: id, failed: true, task: task, grant: grant)
            throw error
        }
    }

    private func finishNegotiationWait(
        id: UUID,
        failed: Bool,
        task: Task<NegotiationOutcome, any Error>,
        grant: AuthorizationGrant
    ) {
        guard var current = negotiation, current.id == id else { return }
        current.waiters = max(0, current.waiters - 1)
        if failed, current.waiters == 0 {
            negotiation = nil
            abandonNegotiation(task, credential: grant.credential)
        } else {
            negotiation = current
        }
    }

    private func abandonNegotiation(
        _ task: Task<NegotiationOutcome, any Error>,
        credential: AuthorizationCredential
    ) {
        task.cancel()
        Task {
            if case let .success(outcome) = await task.result {
                await disconnectService(outcome.service, credential: credential)
            }
        }
    }

    private func clearPairing(_ token: UUID) {
        if pairingToken == token { pairingToken = nil }
    }

    private func performTracked<Success: Sendable>(
        for target: Target,
        operation body: @escaping @Sendable () async throws -> Success
    ) async throws -> Success {
        let operation = LocalMCPAsyncOperation(operation: body)
        let operationID = UUID()
        activeOperations[operationID] = ActiveOperation(
            cancel: { error in
                operation.cancel(with: error)
            }
        )

        do {
            let value = try await operation.value(
                cancellationError: LocalMCPError.cancelled
            )
            activeOperations[operationID] = nil
            try ensureCurrent(target)
            return value
        } catch {
            activeOperations[operationID] = nil
            do {
                try ensureCurrent(target)
            } catch {
                throw LocalMCPError.producerUnavailable
            }
            if error is CancellationError { throw LocalMCPError.cancelled }
            throw error
        }
    }

    private func invalidateRouting() -> ConnectionState? {
        routingGeneration &+= 1
        activeGrant = nil
        pairingToken = nil

        if let negotiation {
            abandonNegotiation(negotiation.task, credential: negotiation.credential)
        }
        negotiation = nil

        cancelActiveOperations(with: .producerUnavailable)

        let staleConnection = connection
        connection = nil
        return staleConnection
    }

    private func cancelActiveOperations(with error: LocalMCPError) {
        let cancellations = activeOperations.values.map(\.cancel)
        activeOperations.removeAll(keepingCapacity: true)
        for cancel in cancellations { cancel(error) }
    }

    private func clearCachedInitialization(
        grant: AuthorizationGrant,
        target: Target
    ) {
        guard let current = connection,
              current.instance == target.instance,
              current.credential == grant.credential
        else { return }
        connection = ConnectionState(
            instance: current.instance,
            service: current.service,
            credential: current.credential,
            initialization: nil
        )
        if negotiation?.instance == target.instance,
           negotiation?.credential == grant.credential
        {
            negotiation?.task.cancel()
            negotiation = nil
        }
    }

    private func disconnect(_ staleConnection: ConnectionState?) async {
        guard let staleConnection,
              let credential = staleConnection.credential
        else { return }
        await disconnectService(staleConnection.service, credential: credential)
    }

    private func handleAuthorizationFailure(
        _ error: any Error,
        attemptedGrant: AuthorizationGrant,
        target: Target
    ) async throws {
        guard let localError = error as? LocalMCPError,
              localError == .unauthorized || localError == .grantRevoked
        else { return }
        var storeRemovalFailed = false
        do {
            try await grantStore.remove(
                producerID: target.instance.identity.stableID,
                consumer: identity,
                ifCredentialMatches: attemptedGrant.credential
            )
        } catch {
            storeRemovalFailed = true
        }
        if activeGrant?.grant.credential == attemptedGrant.credential {
            activeGrant = nil
        }
        var rejectedConnection: ConnectionState?
        if connection?.credential == attemptedGrant.credential {
            rejectedConnection = connection
            connection = nil
        }
        await disconnect(rejectedConnection)
        if storeRemovalFailed { throw LocalMCPError.credentialStoreFailed }
    }
}

private func disconnectService(
    _ service: any LocalMCPService,
    credential: AuthorizationCredential?
) async {
    guard let disconnecting = service as? any LocalMCPDisconnectingService else { return }
    let operation = LocalMCPAsyncOperation<Void>(
        timeoutAfter: 2,
        timeoutError: LocalMCPError.cancelled
    ) {
        await disconnecting.disconnect(credential: credential)
    }
    _ = try? await operation.value(cancellationError: LocalMCPError.cancelled)
}
