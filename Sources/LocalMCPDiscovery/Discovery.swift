import Foundation
import LocalMCPContracts

/// A local-only discovery advertiser. Implementations own their registration cleanup.
public protocol LocalMCPAdvertising: Sendable {
    func advertise(instance: ProducerInstance, descriptor: ProducerDescriptor) async throws
    /// Idempotently releases registration resources and must converge without failure.
    func withdraw(instanceID: String) async
}

/// A long-lived, cancellation-aware source of discovery transitions.
public protocol LocalMCPBrowsing: Sendable {
    func events() async -> AsyncStream<DiscoveryEvent>
    func snapshot() async -> [ProducerInstance]
}

/// A deterministic replaying discovery state machine used by backends and tests.
public actor DiscoveryCatalog: LocalMCPAdvertising, LocalMCPBrowsing {
    private struct Entry: Sendable, Equatable {
        var instance: ProducerInstance
        var descriptor: ProducerDescriptor
    }

    private var entries: [String: Entry] = [:]
    private var subscribers: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]

    public init() {}

    public func advertise(instance: ProducerInstance, descriptor: ProducerDescriptor) async throws {
        try advertise(instance: instance, descriptor: descriptor, permitsUnboundInProcess: false)
    }

    /// Publishes a directly injected, same-process test service. This bypass is
    /// intentionally separate from `LocalMCPAdvertising`: network discovery
    /// backends can never use it to make a missing channel binding compatible.
    public func advertiseInProcess(
        instance: ProducerInstance,
        descriptor: ProducerDescriptor
    ) async throws {
        guard instance.channelBinding == nil, descriptor.channelBinding == nil else {
            throw LocalMCPError.invalidConfiguration
        }
        try advertise(instance: instance, descriptor: descriptor, permitsUnboundInProcess: true)
    }

    private func advertise(
        instance: ProducerInstance,
        descriptor: ProducerDescriptor,
        permitsUnboundInProcess: Bool
    ) throws {
        var resolved = instance
        if descriptor.instanceID != instance.instanceID ||
            descriptor.server != instance.identity ||
            descriptor.mcp.endpoint != instance.endpoint.path ||
            descriptor.channelBinding != instance.channelBinding ||
            instance.endpoint.port != instance.descriptorURL.port ||
            instance.descriptorURL.path != "/local-mcp/v1/descriptor.json"
        {
            resolved.compatibility = .incompatibleDiscoveryProfile(descriptor.schemaVersion)
        } else {
            do {
                var validatedDescriptor = descriptor
                if permitsUnboundInProcess {
                    validatedDescriptor.channelBinding = Self.inProcessValidationBinding
                }
                _ = try DescriptorCompatibility.validate(validatedDescriptor)
                resolved.compatibility = .compatible
            } catch LocalMCPError.incompatibleMCPProtocol {
                resolved.compatibility = .incompatibleMCPProtocol(descriptor.mcp.protocolVersions)
            } catch {
                resolved.compatibility = .incompatibleDiscoveryProfile(descriptor.schemaVersion)
            }
        }

        let next = Entry(instance: resolved, descriptor: descriptor)
        if let previous = entries[instance.instanceID] {
            guard previous != next else { return }
            entries[instance.instanceID] = next

            if previous.instance.identity.stableID != resolved.identity.stableID {
                broadcast(.removed(instanceID: instance.instanceID))
                broadcast(.added(resolved))
            } else {
                broadcast(.updated(resolved))
            }
        } else {
            entries[instance.instanceID] = next
            broadcast(.added(resolved))
        }
    }

    private static let inProcessValidationBinding = ProducerChannelBinding(
        publicKey: try! ChannelBindingPublicKey(rawRepresentation: Array(repeating: 0x42, count: 32))
    )

    public func withdraw(instanceID: String) async {
        guard entries.removeValue(forKey: instanceID) != nil else { return }
        broadcast(.removed(instanceID: instanceID))
    }

    public func events() async -> AsyncStream<DiscoveryEvent> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024)
        )
        subscribers[subscriberID] = continuation

        for instance in entries.values.map(\.instance).sorted(by: Self.instanceOrder) {
            if case .dropped = continuation.yield(.added(instance)) {
                continuation.finish()
                subscribers.removeValue(forKey: subscriberID)
                break
            }
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        return stream
    }

    public func snapshot() async -> [ProducerInstance] {
        entries.values.map(\.instance).sorted(by: Self.instanceOrder)
    }

    /// Diagnostic state used by deterministic cleanup tests.
    public func subscriberCount() -> Int {
        subscribers.count
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func broadcast(_ event: DiscoveryEvent) {
        var terminated: [UUID] = []
        for (id, continuation) in subscribers {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                // Ending the stream forces a consumer to resubscribe and replay a
                // fresh snapshot instead of silently continuing from a gap.
                continuation.finish()
                terminated.append(id)
            @unknown default:
                continuation.finish()
                terminated.append(id)
            }
        }
        for id in terminated {
            subscribers.removeValue(forKey: id)
        }
    }

    private nonisolated static func instanceOrder(_ lhs: ProducerInstance, _ rhs: ProducerInstance) -> Bool {
        if lhs.instanceID != rhs.instanceID { return lhs.instanceID < rhs.instanceID }
        return lhs.identity.stableID < rhs.identity.stableID
    }
}
