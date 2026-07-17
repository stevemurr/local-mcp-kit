import Foundation
import LocalMCPContracts
import LocalMCPDiscovery

final class BonjourOrderedEventPump<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumPendingCount: Int
    private let overflowEvent: Event
    private let handler: @Sendable (Event) async -> Void
    private var pending: [Event] = []
    private var isDraining = false
    private var didOverflow = false

    init(
        maximumPendingCount: Int,
        overflowEvent: Event,
        handler: @escaping @Sendable (Event) async -> Void
    ) {
        precondition(maximumPendingCount > 0)
        self.maximumPendingCount = maximumPendingCount
        self.overflowEvent = overflowEvent
        self.handler = handler
    }

    func yield(_ event: Event) {
        let shouldStart = lock.withLock {
            guard !didOverflow else { return false }
            if pending.count == maximumPendingCount {
                // Dropping an arbitrary DNS-SD transition could leave phantom
                // state. Replace the queue with a terminal event so the owner
                // invalidates this operation and rebuilds from a fresh browse.
                pending.removeAll(keepingCapacity: true)
                pending.append(overflowEvent)
                didOverflow = true
            } else {
                pending.append(event)
            }
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
        guard shouldStart else { return }
        Task { await drain() }
    }

    private func drain() async {
        while let event = next() {
            await handler(event)
        }
    }

    private func next() -> Event? {
        lock.withLock {
            guard !pending.isEmpty else {
                isDraining = false
                return nil
            }
            return pending.removeFirst()
        }
    }
}

struct BonjourRetryPolicy: Sendable, Equatable {
    var initialDelay: TimeInterval
    var multiplier: Double
    var maximumDelay: TimeInterval

    static let production = BonjourRetryPolicy(
        initialDelay: 0.25,
        multiplier: 2,
        maximumDelay: 5
    )

    func delay(afterFailure failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = Double(min(failureCount - 1, 32))
        return min(initialDelay * pow(multiplier, exponent), maximumDelay)
    }
}

/// Production DNS-SD backend for LocalMCPKit's machine-local discovery profile.
///
/// No public initializer accepts a domain or interface. Registration, browsing,
/// resolution, and callback acceptance are permanently confined to
/// `kDNSServiceInterfaceIndexLocalOnly`. Resolved hostnames are retained only as
/// untrusted callback data and never used to construct a URL.
public actor BonjourLocalMCPDiscovery: LocalMCPAdvertising, LocalMCPBrowsing {
    private struct DesiredRegistration: Sendable {
        var request: BonjourRegistrationRequest
        var token: UUID
        var failureCount: Int
    }

    private struct Registration: Sendable {
        var request: BonjourRegistrationRequest
        var operation: any BonjourDNSServiceOperation
        var token: UUID
    }

    private struct RegistrationAttempt: Sendable {
        var token: UUID
        var task: Task<any BonjourDNSServiceOperation, any Error>
    }

    private struct RegistrationRetry: Sendable {
        var desiredToken: UUID
        var retryToken: UUID
        var task: Task<Void, Never>
    }

    private let backend: any BonjourDNSServiceBackend
    private let descriptorLoader: any BonjourDescriptorLoading
    private let catalog: DiscoveryCatalog
    private let sleeper: any LocalMCPSleeping
    private let retryPolicy: BonjourRetryPolicy
    private let maximumPendingEvents: Int

    private var browsingRequested = false
    private var browseOperation: (any BonjourDNSServiceOperation)?
    private var browseRetryTask: Task<Void, Never>?
    private var browseRetryToken: UUID?
    private var browseFailureCount = 0
    private var browseGeneration: UInt64 = 0
    private var presentServices: Set<BonjourServiceKey> = []
    private var resolveOperations: [BonjourServiceKey: any BonjourDNSServiceOperation] = [:]
    private var descriptorTasks: [BonjourServiceKey: Task<ProducerDescriptor, any Error>] = [:]
    private var serviceRetryTasks: [BonjourServiceKey: Task<Void, Never>] = [:]
    private var serviceAttemptTokens: [BonjourServiceKey: UUID] = [:]
    private var serviceFailureCounts: [BonjourServiceKey: Int] = [:]
    private var instanceIDByService: [BonjourServiceKey: String] = [:]
    private var serviceOwnersByInstanceID: [String: Set<BonjourServiceKey>] = [:]

    private var desiredRegistrations: [String: DesiredRegistration] = [:]
    private var registrations: [String: Registration] = [:]
    private var registrationAttempts: [String: RegistrationAttempt] = [:]
    private var registrationRetries: [String: RegistrationRetry] = [:]
    private var pendingRegistrationFailures: [String: UUID] = [:]

    public init() {
        backend = SystemBonjourDNSServiceBackend()
        descriptorLoader = URLSessionBonjourDescriptorLoader()
        catalog = DiscoveryCatalog()
        sleeper = SystemLocalMCPSleeper()
        retryPolicy = .production
        maximumPendingEvents = 256
    }

    init(
        backend: any BonjourDNSServiceBackend,
        descriptorLoader: any BonjourDescriptorLoading,
        catalog: DiscoveryCatalog = DiscoveryCatalog(),
        sleeper: any LocalMCPSleeping = SystemLocalMCPSleeper(),
        retryPolicy: BonjourRetryPolicy = .production,
        maximumPendingEvents: Int = 256
    ) {
        precondition(maximumPendingEvents > 0)
        self.backend = backend
        self.descriptorLoader = descriptorLoader
        self.catalog = catalog
        self.sleeper = sleeper
        self.retryPolicy = retryPolicy
        self.maximumPendingEvents = maximumPendingEvents
    }

    /// Starts the long-lived LocalOnly browse. Repeated calls are idempotent.
    public func start() throws {
        browsingRequested = true
        guard browseOperation == nil, browseRetryTask == nil else { return }
        do {
            try openBrowse()
        } catch {
            scheduleBrowseRetry()
            throw LocalMCPError.producerUnavailable
        }
    }

    /// Stops browsing and resolution while leaving producer registrations alone.
    public func stopBrowsing() async {
        browsingRequested = false
        browseGeneration &+= 1
        browseOperation?.cancel()
        browseOperation = nil
        browseRetryTask?.cancel()
        browseRetryTask = nil
        browseRetryToken = nil
        browseFailureCount = 0
        await clearDiscoveredState()
    }

    /// Releases every browse, resolve, and registration resource idempotently.
    public func stop() async {
        await stopBrowsing()
        let instanceIDs = Set(desiredRegistrations.keys)
            .union(registrations.keys)
            .union(registrationAttempts.keys)
            .union(registrationRetries.keys)
            .union(pendingRegistrationFailures.keys)
        for instanceID in instanceIDs {
            cancelRegistrationWork(instanceID: instanceID, removeDesired: true)
        }
    }

    public func advertise(
        instance: ProducerInstance,
        descriptor: ProducerDescriptor
    ) async throws {
        try validatePublished(instance: instance, descriptor: descriptor)

        let advertisement = DiscoveryAdvertisement(stableProducerID: instance.identity.stableID)
        let txtRecord: Data
        do {
            txtRecord = try BonjourTXTRecordCodec.encode(advertisement)
        } catch {
            throw LocalMCPError.advertisementFailed
        }
        let request = BonjourRegistrationRequest(
            name: registrationName(instanceID: instance.instanceID),
            serviceType: DiscoveryAdvertisement.serviceType,
            interfaceIndex: bonjourLocalOnlyInterfaceIndex,
            port: instance.endpoint.port,
            txtRecord: txtRecord
        )

        if let desired = desiredRegistrations[instance.instanceID], desired.request == request {
            // An active handle, in-flight retry, or scheduled retry already owns
            // this exact desired registration.
            if registrations[instance.instanceID] != nil
                || registrationAttempts[instance.instanceID] != nil
                || registrationRetries[instance.instanceID] != nil
            {
                return
            }
        }

        cancelRegistrationWork(instanceID: instance.instanceID, removeDesired: true)
        let token = UUID()
        desiredRegistrations[instance.instanceID] = DesiredRegistration(
            request: request,
            token: token,
            failureCount: 0
        )
        try await performRegistration(
            instanceID: instance.instanceID,
            request: request,
            desiredToken: token,
            retrying: false
        )
    }

    public func withdraw(instanceID: String) async {
        cancelRegistrationWork(instanceID: instanceID, removeDesired: true)
    }

    public func events() async -> AsyncStream<DiscoveryEvent> {
        try? start()
        return await catalog.events()
    }

    public func snapshot() async -> [ProducerInstance] {
        try? start()
        return await catalog.snapshot()
    }

    func registrationCount() -> Int {
        registrations.count
    }

    func desiredRegistrationCount() -> Int {
        desiredRegistrations.count
    }

    func pendingRegistrationRetryCount() -> Int {
        registrationRetries.count
    }

    func activeResolveCount() -> Int {
        resolveOperations.count
    }

    func isBrowsing() -> Bool {
        browseOperation != nil
    }

    private func receiveBrowseEvent(_ event: BonjourBrowseEvent, generation: UInt64) async {
        guard generation == browseGeneration, browseOperation != nil else { return }
        switch event {
        case let .added(service):
            guard service.interfaceIndex == bonjourLocalOnlyInterfaceIndex else { return }
            browseFailureCount = 0
            presentServices.insert(service)
            serviceFailureCounts[service] = 0
            cancelServiceWork(for: service)
            await beginResolveAttempt(for: service, generation: generation)

        case let .removed(service):
            guard service.interfaceIndex == bonjourLocalOnlyInterfaceIndex else { return }
            browseFailureCount = 0
            presentServices.remove(service)
            cancelServiceWork(for: service)
            await removeAssociation(for: service)

        case .failure:
            await recoverFromBrowseFailure(generation: generation)
        }
    }

    private func openBrowse() throws {
        browseGeneration &+= 1
        let generation = browseGeneration
        let pump = BonjourOrderedEventPump<BonjourBrowseEvent>(
            maximumPendingCount: maximumPendingEvents,
            overflowEvent: .failure(Int32.min)
        ) { [weak self] event in
            await self?.receiveBrowseEvent(event, generation: generation)
        }
        browseOperation = try backend.browse(
            serviceType: DiscoveryAdvertisement.serviceType,
            interfaceIndex: bonjourLocalOnlyInterfaceIndex
        ) { event in
            pump.yield(event)
        }
    }

    private func recoverFromBrowseFailure(generation: UInt64) async {
        guard generation == browseGeneration else { return }
        browseGeneration &+= 1
        browseOperation?.cancel()
        browseOperation = nil
        await clearDiscoveredState()
        guard browsingRequested else { return }
        scheduleBrowseRetry()
    }

    private func scheduleBrowseRetry() {
        guard browsingRequested, browseOperation == nil, browseRetryTask == nil else { return }
        browseFailureCount += 1
        let delay = retryPolicy.delay(afterFailure: browseFailureCount)
        let token = UUID()
        browseRetryToken = token
        browseRetryTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
                try Task.checkCancellation()
                await self?.resumeBrowseRetry(token: token)
            } catch {
                // Explicit stop cancels the sleeper and owns all cleanup.
            }
        }
    }

    private func resumeBrowseRetry(token: UUID) async {
        guard browsingRequested,
              browseOperation == nil,
              browseRetryToken == token
        else { return }
        browseRetryTask = nil
        browseRetryToken = nil
        do {
            try openBrowse()
        } catch {
            scheduleBrowseRetry()
        }
    }

    private func beginResolveAttempt(
        for service: BonjourServiceKey,
        generation: UInt64
    ) async {
        guard generation == browseGeneration,
              browseOperation != nil,
              presentServices.contains(service)
        else { return }

        let token = UUID()
        serviceAttemptTokens[service] = token
        do {
            let pump = BonjourOrderedEventPump<BonjourResolveEvent>(
                maximumPendingCount: maximumPendingEvents,
                overflowEvent: .failure(Int32.min)
            ) { [weak self] event in
                await self?.receiveResolveEvent(
                    event,
                    service: service,
                    generation: generation,
                    token: token
                )
            }
            let operation = try backend.resolve(service) { event in
                pump.yield(event)
            }
            guard serviceAttemptTokens[service] == token,
                  generation == browseGeneration,
                  presentServices.contains(service)
            else {
                operation.cancel()
                return
            }
            resolveOperations[service] = operation
        } catch {
            await transientServiceFailure(
                service: service,
                generation: generation,
                token: token
            )
        }
    }

    private func receiveResolveEvent(
        _ event: BonjourResolveEvent,
        service: BonjourServiceKey,
        generation: UInt64,
        token: UUID
    ) async {
        guard generation == browseGeneration,
              browseOperation != nil,
              presentServices.contains(service),
              serviceAttemptTokens[service] == token
        else { return }

        resolveOperations.removeValue(forKey: service)?.cancel()
        switch event {
        case .failure:
            await transientServiceFailure(
                service: service,
                generation: generation,
                token: token
            )

        case let .resolved(result):
            guard service.interfaceIndex == bonjourLocalOnlyInterfaceIndex,
                  result.interfaceIndex == bonjourLocalOnlyInterfaceIndex,
                  result.port != 0,
                  let advertisement = try? BonjourTXTRecordCodec.decode(result.txtRecord),
                  let endpoint = try? LoopbackEndpoint(
                      port: result.port,
                      path: advertisement.endpointPath
                  ),
                  let descriptorURL = try? LoopbackEndpoint(
                      port: result.port,
                      path: advertisement.descriptorPath
                  )
            else {
                serviceAttemptTokens.removeValue(forKey: service)
                serviceFailureCounts.removeValue(forKey: service)
                await removeAssociation(for: service)
                return
            }

            let loadTask = Task { [descriptorLoader] in
                try await descriptorLoader.loadDescriptor(from: descriptorURL.url)
            }
            descriptorTasks[service] = loadTask
            let descriptorResult: Result<ProducerDescriptor, any Error>
            do {
                descriptorResult = .success(try await loadTask.value)
            } catch {
                descriptorResult = .failure(error)
            }
            guard serviceAttemptTokens[service] == token else { return }
            descriptorTasks.removeValue(forKey: service)
            switch descriptorResult {
            case .failure:
                await transientServiceFailure(
                    service: service,
                    generation: generation,
                    token: token
                )
                return
            case let .success(descriptor):
                guard generation == browseGeneration,
                      browseOperation != nil,
                      presentServices.contains(service)
                else { return }

                await publishResolvedDescriptor(
                    descriptor,
                    advertisement: advertisement,
                    endpoint: endpoint,
                    descriptorURL: descriptorURL,
                    service: service,
                    token: token
                )
            }
        }
    }

    private func publishResolvedDescriptor(
        _ descriptor: ProducerDescriptor,
        advertisement: DiscoveryAdvertisement,
        endpoint: LoopbackEndpoint,
        descriptorURL: LoopbackEndpoint,
        service: BonjourServiceKey,
        token: UUID
    ) async {
        guard serviceAttemptTokens[service] == token else { return }
        serviceAttemptTokens.removeValue(forKey: service)
        serviceFailureCounts.removeValue(forKey: service)

        // Bind the descriptor's presentation fields to the stable ID from TXT.
        // If they disagree, DiscoveryCatalog marks the result incompatible.
        let advertisedIdentity = ProducerIdentity(
            stableID: advertisement.stableProducerID,
            displayName: descriptor.server.displayName,
            version: descriptor.server.version
        )
        let instance = ProducerInstance(
            identity: advertisedIdentity,
            instanceID: descriptor.instanceID,
            endpoint: endpoint,
            descriptorURL: descriptorURL,
            channelBinding: descriptor.channelBinding
        )
        if let previousInstanceID = instanceIDByService[service],
           previousInstanceID != descriptor.instanceID
        {
            await removeAssociation(for: service)
        }
        do {
            try await catalog.advertise(instance: instance, descriptor: descriptor)
            await associate(service: service, with: descriptor.instanceID)
        } catch {
            await removeAssociation(for: service)
        }
    }

    private func transientServiceFailure(
        service: BonjourServiceKey,
        generation: UInt64,
        token: UUID
    ) async {
        guard serviceAttemptTokens[service] == token,
              generation == browseGeneration,
              browseOperation != nil,
              presentServices.contains(service)
        else { return }
        resolveOperations.removeValue(forKey: service)?.cancel()
        descriptorTasks.removeValue(forKey: service)?.cancel()
        await removeAssociation(for: service)

        let failureCount = serviceFailureCounts[service, default: 0] + 1
        serviceFailureCounts[service] = failureCount
        let delay = retryPolicy.delay(afterFailure: failureCount)
        let retryToken = UUID()
        serviceAttemptTokens[service] = retryToken
        let retryTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
                try Task.checkCancellation()
                await self?.resumeServiceRetry(
                    service: service,
                    generation: generation,
                    token: retryToken
                )
            } catch {
                // Removal, browse restart, and stop cancel the sleeper.
            }
        }
        serviceRetryTasks[service] = retryTask
    }

    private func resumeServiceRetry(
        service: BonjourServiceKey,
        generation: UInt64,
        token: UUID
    ) async {
        guard serviceAttemptTokens[service] == token,
              generation == browseGeneration,
              browseOperation != nil,
              presentServices.contains(service)
        else { return }
        serviceRetryTasks.removeValue(forKey: service)
        await beginResolveAttempt(for: service, generation: generation)
    }

    private func cancelServiceWork(for service: BonjourServiceKey) {
        serviceAttemptTokens.removeValue(forKey: service)
        serviceFailureCounts.removeValue(forKey: service)
        resolveOperations.removeValue(forKey: service)?.cancel()
        descriptorTasks.removeValue(forKey: service)?.cancel()
        serviceRetryTasks.removeValue(forKey: service)?.cancel()
    }

    private func clearDiscoveredState() async {
        for operation in resolveOperations.values {
            operation.cancel()
        }
        resolveOperations.removeAll()
        for task in descriptorTasks.values {
            task.cancel()
        }
        descriptorTasks.removeAll()
        for task in serviceRetryTasks.values {
            task.cancel()
        }
        serviceRetryTasks.removeAll()
        serviceAttemptTokens.removeAll()
        serviceFailureCounts.removeAll()
        presentServices.removeAll()

        let instanceIDs = Array(serviceOwnersByInstanceID.keys)
        instanceIDByService.removeAll()
        serviceOwnersByInstanceID.removeAll()
        for instanceID in instanceIDs {
            await catalog.withdraw(instanceID: instanceID)
        }
    }

    private func associate(service: BonjourServiceKey, with instanceID: String) async {
        if let previous = instanceIDByService[service], previous != instanceID {
            await removeOwner(service: service, from: previous)
        }
        instanceIDByService[service] = instanceID
        serviceOwnersByInstanceID[instanceID, default: []].insert(service)
    }

    private func removeAssociation(for service: BonjourServiceKey) async {
        guard let instanceID = instanceIDByService.removeValue(forKey: service) else { return }
        await removeOwner(service: service, from: instanceID)
    }

    private func removeOwner(service: BonjourServiceKey, from instanceID: String) async {
        guard var owners = serviceOwnersByInstanceID[instanceID] else { return }
        owners.remove(service)
        if owners.isEmpty {
            serviceOwnersByInstanceID.removeValue(forKey: instanceID)
            await catalog.withdraw(instanceID: instanceID)
        } else {
            serviceOwnersByInstanceID[instanceID] = owners
        }
    }

    private func performRegistration(
        instanceID: String,
        request: BonjourRegistrationRequest,
        desiredToken: UUID,
        retrying: Bool
    ) async throws {
        guard desiredRegistrations[instanceID]?.token == desiredToken else {
            throw LocalMCPError.cancelled
        }

        let backend = backend
        let attemptToken = UUID()
        let task = Task<any BonjourDNSServiceOperation, any Error> { [weak self] in
            try await backend.register(request) { [weak self] _ in
                Task {
                    await self?.registrationFailed(
                        instanceID: instanceID,
                        desiredToken: desiredToken,
                        attemptToken: attemptToken
                    )
                }
            }
        }
        registrationAttempts[instanceID] = RegistrationAttempt(
            token: attemptToken,
            task: task
        )

        let result: Result<any BonjourDNSServiceOperation, any Error>
        do {
            let operation = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            result = .success(operation)
        } catch {
            result = .failure(error)
        }

        guard desiredRegistrations[instanceID]?.token == desiredToken,
              registrationAttempts[instanceID]?.token == attemptToken
        else {
            if case let .success(operation) = result { operation.cancel() }
            throw LocalMCPError.cancelled
        }
        registrationAttempts.removeValue(forKey: instanceID)
        let failedBeforeInstall = pendingRegistrationFailures[instanceID] == attemptToken
        if failedBeforeInstall {
            pendingRegistrationFailures.removeValue(forKey: instanceID)
        }

        switch result {
        case let .success(operation):
            guard !Task.isCancelled else {
                operation.cancel()
                if retrying {
                    scheduleRegistrationRetry(
                        instanceID: instanceID,
                        desiredToken: desiredToken
                    )
                } else {
                    desiredRegistrations.removeValue(forKey: instanceID)
                }
                throw LocalMCPError.cancelled
            }
            if failedBeforeInstall {
                operation.cancel()
                scheduleRegistrationRetry(
                    instanceID: instanceID,
                    desiredToken: desiredToken
                )
                return
            }
            registrations.removeValue(forKey: instanceID)?.operation.cancel()
            registrations[instanceID] = Registration(
                request: request,
                operation: operation,
                token: attemptToken
            )
            if var desired = desiredRegistrations[instanceID], desired.token == desiredToken {
                desired.failureCount = 0
                desiredRegistrations[instanceID] = desired
            }

        case .failure:
            if retrying {
                scheduleRegistrationRetry(
                    instanceID: instanceID,
                    desiredToken: desiredToken
                )
            } else {
                desiredRegistrations.removeValue(forKey: instanceID)
            }
            if Task.isCancelled { throw LocalMCPError.cancelled }
            throw LocalMCPError.advertisementFailed
        }
    }

    private func registrationFailed(
        instanceID: String,
        desiredToken: UUID,
        attemptToken: UUID
    ) {
        guard desiredRegistrations[instanceID]?.token == desiredToken else { return }
        if registrations[instanceID]?.token == attemptToken {
            registrations.removeValue(forKey: instanceID)?.operation.cancel()
            scheduleRegistrationRetry(instanceID: instanceID, desiredToken: desiredToken)
        } else if registrationAttempts[instanceID]?.token == attemptToken {
            // The backend's successful registration result and a subsequent
            // failure callback can race onto this actor. Preserve that failure
            // until the returned handle is installed so a dead handle never
            // becomes the active registration.
            pendingRegistrationFailures[instanceID] = attemptToken
        }
    }

    private func scheduleRegistrationRetry(instanceID: String, desiredToken: UUID) {
        guard var desired = desiredRegistrations[instanceID],
              desired.token == desiredToken,
              registrationRetries[instanceID] == nil
        else { return }

        desired.failureCount += 1
        desiredRegistrations[instanceID] = desired
        let delay = retryPolicy.delay(afterFailure: desired.failureCount)
        let retryToken = UUID()
        let task = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: delay)
                try Task.checkCancellation()
                await self?.resumeRegistrationRetry(
                    instanceID: instanceID,
                    desiredToken: desiredToken,
                    retryToken: retryToken
                )
            } catch {
                // Replacement, withdrawal, and stop cancel the sleeper.
            }
        }
        registrationRetries[instanceID] = RegistrationRetry(
            desiredToken: desiredToken,
            retryToken: retryToken,
            task: task
        )
    }

    private func resumeRegistrationRetry(
        instanceID: String,
        desiredToken: UUID,
        retryToken: UUID
    ) async {
        guard desiredRegistrations[instanceID]?.token == desiredToken,
              let retry = registrationRetries[instanceID],
              retry.desiredToken == desiredToken,
              retry.retryToken == retryToken
        else { return }
        registrationRetries.removeValue(forKey: instanceID)
        guard let desired = desiredRegistrations[instanceID] else { return }
        _ = try? await performRegistration(
            instanceID: instanceID,
            request: desired.request,
            desiredToken: desiredToken,
            retrying: true
        )
    }

    private func cancelRegistrationWork(instanceID: String, removeDesired: Bool) {
        registrations.removeValue(forKey: instanceID)?.operation.cancel()
        registrationAttempts.removeValue(forKey: instanceID)?.task.cancel()
        registrationRetries.removeValue(forKey: instanceID)?.task.cancel()
        pendingRegistrationFailures.removeValue(forKey: instanceID)
        if removeDesired {
            desiredRegistrations.removeValue(forKey: instanceID)
        }
    }

    private func validatePublished(
        instance: ProducerInstance,
        descriptor: ProducerDescriptor
    ) throws {
        guard instance.identity.isValid,
              LocalMCPValidation.isCanonicalLowercaseUUID(instance.instanceID),
              instance.compatibility == .compatible,
              descriptor.instanceID == instance.instanceID,
              descriptor.server == instance.identity,
              descriptor.mcp.endpoint == instance.endpoint.path,
              descriptor.channelBinding == instance.channelBinding,
              instance.endpoint.path == "/mcp",
              instance.descriptorURL.port == instance.endpoint.port,
              instance.descriptorURL.path == "/local-mcp/v1/descriptor.json"
        else {
            throw LocalMCPError.advertisementFailed
        }
        do {
            _ = try DescriptorCompatibility.validate(descriptor)
        } catch {
            throw LocalMCPError.advertisementFailed
        }
    }

    private func registrationName(instanceID: String) -> String {
        "LocalMCP-\(instanceID.prefix(12))"
    }
}
