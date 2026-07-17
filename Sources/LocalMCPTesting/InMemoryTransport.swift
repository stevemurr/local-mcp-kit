import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPProducer

public typealias InMemoryLocalMCPDiscovery = DiscoveryCatalog

/// Maps synthetic loopback endpoints to live services without bypassing the
/// consumer connection boundary.
public actor InMemoryServiceDirectory: LocalMCPConnecting {
    private var nextPort: UInt16
    private var services: [LoopbackEndpoint: any LocalMCPService] = [:]

    public init(firstPort: UInt16 = 41_000) {
        nextPort = firstPort
    }

    public func register(
        path: String,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint {
        guard nextPort != 0, nextPort < UInt16.max else {
            throw LocalMCPError.bindFailed
        }
        let endpoint = try LoopbackEndpoint(port: nextPort, path: path)
        nextPort &+= 1
        services[endpoint] = service
        return endpoint
    }

    public func unregister(_ endpoint: LoopbackEndpoint) {
        services.removeValue(forKey: endpoint)
    }

    public func connect(to instance: ProducerInstance) async throws -> any LocalMCPService {
        guard let service = services[instance.endpoint] else {
            throw LocalMCPError.producerUnavailable
        }
        return service
    }

    public func serviceCount() -> Int { services.count }
}

public enum InMemoryTransportFailure: Sendable {
    case none
    case beforeRegistration
    case afterRegistration
}

/// A listener test double with an ephemeral synthetic loopback port.
public actor InMemoryProducerTransport: LocalMCPProducerTransport {
    private let directory: InMemoryServiceDirectory
    private var endpoint: LoopbackEndpoint?
    private var failure: InMemoryTransportFailure
    private var startCalls = 0
    private var stopCalls = 0

    public init(
        directory: InMemoryServiceDirectory,
        failure: InMemoryTransportFailure = .none
    ) {
        self.directory = directory
        self.failure = failure
    }

    public func start(
        endpointPath: String,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint {
        startCalls += 1
        if let endpoint { return endpoint }
        if case .beforeRegistration = failure { throw LocalMCPError.bindFailed }
        let registered = try await directory.register(path: endpointPath, service: service)
        endpoint = registered
        if case .afterRegistration = failure { throw LocalMCPError.bindFailed }
        return registered
    }

    public func stop() async {
        stopCalls += 1
        guard let endpoint else { return }
        await directory.unregister(endpoint)
        self.endpoint = nil
    }

    public func setFailure(_ failure: InMemoryTransportFailure) {
        self.failure = failure
    }

    public func isActive() -> Bool { endpoint != nil }
    public func callCounts() -> (start: Int, stop: Int) { (startCalls, stopCalls) }
}

public enum InMemoryAdvertisementFailure: Sendable {
    case none
    case beforePublishing
    case afterPublishing
}

/// Fault-injecting advertiser for lifecycle rollback tests.
public actor InMemoryAdvertiser: LocalMCPAdvertising {
    public let catalog: DiscoveryCatalog
    private var failure: InMemoryAdvertisementFailure
    private var advertiseCalls = 0
    private var withdrawCalls = 0

    public init(
        catalog: DiscoveryCatalog,
        failure: InMemoryAdvertisementFailure = .none
    ) {
        self.catalog = catalog
        self.failure = failure
    }

    public func advertise(instance: ProducerInstance, descriptor: ProducerDescriptor) async throws {
        advertiseCalls += 1
        if case .beforePublishing = failure { throw LocalMCPError.advertisementFailed }
        try await catalog.advertise(instance: instance, descriptor: descriptor)
        if case .afterPublishing = failure { throw LocalMCPError.advertisementFailed }
    }

    public func withdraw(instanceID: String) async {
        withdrawCalls += 1
        await catalog.withdraw(instanceID: instanceID)
    }

    public func setFailure(_ failure: InMemoryAdvertisementFailure) {
        self.failure = failure
    }

    public func callCounts() -> (advertise: Int, withdraw: Int) {
        (advertiseCalls, withdrawCalls)
    }
}

/// Shared boundaries for an in-memory producer/consumer vertical slice.
public final class InMemoryLocalMCPEnvironment: Sendable {
    public let discovery: DiscoveryCatalog
    public let directory: InMemoryServiceDirectory
    public let advertiser: InMemoryAdvertiser

    public init(firstPort: UInt16 = 41_000) {
        discovery = DiscoveryCatalog()
        directory = InMemoryServiceDirectory(firstPort: firstPort)
        advertiser = InMemoryAdvertiser(catalog: discovery)
    }

    public func makeProducerTransport() -> InMemoryProducerTransport {
        InMemoryProducerTransport(directory: directory)
    }
}
