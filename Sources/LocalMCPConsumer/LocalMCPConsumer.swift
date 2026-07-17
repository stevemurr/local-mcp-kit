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
        let instance: ProducerInstance
        let credential: AuthorizationCredential
        let task: Task<NegotiationOutcome, any Error>
    }

    private var instance: ProducerInstance
    private var available = true
    private var routingGeneration: UInt64 = 0
    private var activeGrant: (instance: ProducerInstance, grant: AuthorizationGrant)?
    private var connection: ConnectionState?
    private var negotiation: NegotiationState?
    private var pairingInProgress = false
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
    /// authenticated. A future Phase 4 mechanism may re-bind persisted trust.
    public func update(instance next: ProducerInstance) throws {
        guard next.identity.stableID == instance.identity.stableID else {
            throw LocalMCPError.invalidConfiguration
        }
        if next != instance || !available {
            routingGeneration &+= 1
            activeGrant = nil
            connection = nil
            negotiation?.task.cancel()
            negotiation = nil
        }
        instance = next
        available = true
    }

    public func markRemoved(instanceID: String) {
        if instance.instanceID == instanceID {
            routingGeneration &+= 1
            available = false
            activeGrant = nil
            connection = nil
            negotiation?.task.cancel()
            negotiation = nil
        }
    }

    /// Begins explicit pairing. The callback lets consumer UI display the same
    /// short code as the producer approval prompt.
    @discardableResult
    public func pair(
        displayVerificationCode: (@Sendable (PairingVerificationCode) -> Void)? = nil
    ) async throws -> AuthorizationGrant {
        guard !pairingInProgress else { throw LocalMCPError.pairingDenied }
        pairingInProgress = true
        defer { pairingInProgress = false }
        let target = try currentTarget()
        guard identity.isValid else { throw LocalMCPError.invalidConfiguration }

        let nonce: PairingNonce
        do {
            nonce = try await PairingNonce(bytes: random.randomBytes(count: 32))
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch {
            throw LocalMCPError.pairingDenied
        }
        try ensureCurrent(target)
        displayVerificationCode?(PairingVerificationCode(nonce: nonce))

        let service = try await connect(to: target)
        let grant = try await service.requestPairing(
            PairingRequest(consumer: identity, requestNonce: nonce)
        )
        guard grant.metadata.producerID == target.instance.identity.stableID,
              grant.metadata.consumer.representsSameInstallation(as: identity),
              grant.metadata.revokedAt == nil,
              !grant.metadata.isExpired(at: await clock.now())
        else { throw LocalMCPError.unauthorized }
        try ensureCurrent(target)

        do {
            try await grantStore.save(grant)
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
        negotiation?.task.cancel()
        negotiation = nil
        connection = nil
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
        let service = try await initializedService(grant: grant, target: target)
        do {
            return try await service.listCommands(credential: grant.credential)
        } catch {
            try await handleAuthorizationFailure(error, attemptedGrant: grant, target: target)
            throw error
        }
    }

    public func call(
        _ name: String,
        arguments: JSONValue,
        grant explicitGrant: AuthorizationGrant? = nil,
        deadline: Date? = nil
    ) async throws -> CommandResult {
        let target = try currentTarget()
        let grant = try await usableGrant(explicitGrant, for: target)
        let service = try await initializedService(grant: grant, target: target)
        let requestID = try await randomIdentifier()
        try ensureCurrent(target)
        do {
            return try await service.callCommand(
                CommandCallRequest(
                    name: name,
                    arguments: arguments,
                    requestID: requestID,
                    deadline: deadline
                ),
                credential: grant.credential
            )
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
              grant.metadata.consumer.representsSameInstallation(as: identity)
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
                let outcome = try await negotiation.task.value
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
                clearNegotiation(instance: target.instance, credential: grant.credential)
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
            let initialization = try await service.initialize(
                supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                credential: credential
            )
            guard initialization.protocolVersion == MCPProtocolVersion.current.rawValue else {
                throw LocalMCPError.incompatibleMCPProtocol
            }
            guard initialization.server.stableID == targetInstance.identity.stableID else {
                throw LocalMCPError.unauthorized
            }
            try await service.initialized(credential: credential)
            return NegotiationOutcome(service: service, initialization: initialization)
        }
        negotiation = NegotiationState(
            instance: target.instance,
            credential: grant.credential,
            task: task
        )
        do {
            let outcome = try await task.value
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
            clearNegotiation(instance: target.instance, credential: grant.credential)
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
            service = try await connector.connect(to: target.instance)
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

    private func randomIdentifier() async throws -> String {
        do {
            let bytes = try await random.randomBytes(count: 16)
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

    private func handleAuthorizationFailure(
        _ error: any Error,
        attemptedGrant: AuthorizationGrant,
        target: Target
    ) async throws {
        guard let localError = error as? LocalMCPError,
              localError == .unauthorized || localError == .grantRevoked
        else { return }
        do {
            try await grantStore.remove(
                producerID: target.instance.identity.stableID,
                consumer: identity,
                ifCredentialMatches: attemptedGrant.credential
            )
        } catch {
            throw LocalMCPError.credentialStoreFailed
        }
        if activeGrant?.grant.credential == attemptedGrant.credential {
            activeGrant = nil
        }
        if connection?.credential == attemptedGrant.credential {
            connection = nil
        }
    }
}
