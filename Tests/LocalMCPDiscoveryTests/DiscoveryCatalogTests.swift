import LocalMCPContracts
import Testing
@testable import LocalMCPDiscovery

@Suite("Discovery catalog")
struct DiscoveryCatalogTests {
    @Test("advertising, updating, and withdrawing work through the discovery protocols")
    func protocolBoundariesExposeCatalogTransitions() async throws {
        let catalog = DiscoveryCatalog()
        let advertiser: any LocalMCPAdvertising = catalog
        let browser: any LocalMCPBrowsing = catalog
        let stream = await browser.events()
        var iterator = stream.makeAsyncIterator()

        let original = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000001",
            stableID: "com.example.alpha",
            port: 41_001
        )
        try await advertiser.advertise(
            instance: original,
            descriptor: DiscoveryFixture.descriptor(for: original)
        )

        let added = await iterator.next()
        #expect(added == .some(.added(original)))
        #expect(await browser.snapshot() == [original])

        let updated = try DiscoveryFixture.updated(
            original,
            displayName: "Alpha Next",
            version: "2.0.0",
            port: 41_002
        )
        try await advertiser.advertise(
            instance: updated,
            descriptor: DiscoveryFixture.descriptor(for: updated)
        )

        let update = await iterator.next()
        #expect(update == .some(.updated(updated)))
        #expect(await browser.snapshot() == [updated])

        await advertiser.withdraw(instanceID: original.instanceID)

        let removed = await iterator.next()
        #expect(removed == .some(.removed(instanceID: original.instanceID)))
        #expect(await browser.snapshot().isEmpty)
    }

    @Test("an identical advertisement is silent")
    func identicalAdvertisementIsNoOp() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let original = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000002",
            stableID: "com.example.noop",
            port: 41_010
        )
        let descriptor = DiscoveryFixture.descriptor(for: original)

        try await catalog.advertise(instance: original, descriptor: descriptor)
        _ = await iterator.next()

        try await catalog.advertise(instance: original, descriptor: descriptor)

        // The update is a marker: if the repeated advertisement emitted anything,
        // that stale event would be observed here instead.
        let updated = try DiscoveryFixture.updated(
            original,
            displayName: "No-op Producer Updated",
            version: "1.1.0",
            port: 41_011
        )
        try await catalog.advertise(
            instance: updated,
            descriptor: DiscoveryFixture.descriptor(for: updated)
        )

        let next = await iterator.next()
        #expect(next == .some(.updated(updated)))
        #expect(await catalog.snapshot() == [updated])
    }

    @Test("withdrawing an unknown instance is silent")
    func unknownWithdrawalIsNoOp() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let known = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000003",
            stableID: "com.example.known",
            port: 41_020
        )

        try await catalog.advertise(
            instance: known,
            descriptor: DiscoveryFixture.descriptor(for: known)
        )
        _ = await iterator.next()

        await catalog.withdraw(instanceID: "missing-instance")
        await catalog.withdraw(instanceID: known.instanceID)

        // The known removal is a marker proving that the unknown ID emitted no event.
        let next = await iterator.next()
        #expect(next == .some(.removed(instanceID: known.instanceID)))
        #expect(await catalog.snapshot().isEmpty)
    }

    @Test("a withdrawn instance can be advertised again")
    func readdingWithdrawnInstanceEmitsAddedAgain() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let instance = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000004",
            stableID: "com.example.returning",
            port: 41_030
        )
        let descriptor = DiscoveryFixture.descriptor(for: instance)

        try await catalog.advertise(instance: instance, descriptor: descriptor)
        let firstAdd = await iterator.next()
        #expect(firstAdd == .some(.added(instance)))

        await catalog.withdraw(instanceID: instance.instanceID)
        let removal = await iterator.next()
        #expect(removal == .some(.removed(instanceID: instance.instanceID)))

        try await catalog.advertise(instance: instance, descriptor: descriptor)
        let secondAdd = await iterator.next()
        #expect(secondAdd == .some(.added(instance)))
        #expect(await catalog.snapshot() == [instance])
    }

    @Test("two processes with one stable producer ID remain distinct")
    func sameStableIDDoesNotDeduplicateDistinctInstances() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let second = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000006",
            stableID: "com.example.shared",
            port: 41_041
        )
        let first = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000005",
            stableID: "com.example.shared",
            port: 41_040
        )

        try await catalog.advertise(
            instance: second,
            descriptor: DiscoveryFixture.descriptor(for: second)
        )
        try await catalog.advertise(
            instance: first,
            descriptor: DiscoveryFixture.descriptor(for: first)
        )

        let firstEvent = await iterator.next()
        let secondEvent = await iterator.next()
        #expect(firstEvent == .some(.added(second)))
        #expect(secondEvent == .some(.added(first)))
        #expect(await catalog.snapshot() == [first, second])
    }

    @Test("changing a stable ID for one instance is removal followed by addition")
    func stableIDMutationIsIdentityReplacement() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let original = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000007",
            stableID: "com.example.original",
            port: 41_050
        )

        try await catalog.advertise(
            instance: original,
            descriptor: DiscoveryFixture.descriptor(for: original)
        )
        _ = await iterator.next()

        let replacement = try DiscoveryFixture.instance(
            instanceID: original.instanceID,
            stableID: "com.example.replacement",
            displayName: "Replacement",
            version: "1.0.0",
            port: 41_051
        )
        try await catalog.advertise(
            instance: replacement,
            descriptor: DiscoveryFixture.descriptor(for: replacement)
        )

        let removal = await iterator.next()
        let addition = await iterator.next()
        #expect(removal == .some(.removed(instanceID: original.instanceID)))
        #expect(addition == .some(.added(replacement)))
        #expect(await catalog.snapshot() == [replacement])
    }

    @Test("incompatible descriptors stay visible with their incompatibility reason")
    func descriptorIncompatibilitiesRemainVisible() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()

        let profileInstance = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000010",
            stableID: "com.example.profile",
            port: 41_060
        )
        var profileDescriptor = DiscoveryFixture.descriptor(for: profileInstance)
        profileDescriptor.schemaVersion = "2"

        let protocolInstance = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000011",
            stableID: "com.example.protocol",
            port: 41_061
        )
        var protocolDescriptor = DiscoveryFixture.descriptor(for: protocolInstance)
        let unsupportedVersions = ["2024-11-05", "2025-03-26"]
        protocolDescriptor.mcp.protocolVersions = unsupportedVersions

        let instanceMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000012",
            stableID: "com.example.instanceowner",
            port: 41_062
        )
        var mismatchedInstanceDescriptor = DiscoveryFixture.descriptor(for: instanceMismatch)
        mismatchedInstanceDescriptor.instanceID = "00000000-0000-0000-0000-000000000099"

        let identityMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000013",
            stableID: "com.example.identityowner",
            port: 41_063
        )
        var mismatchedIdentityDescriptor = DiscoveryFixture.descriptor(for: identityMismatch)
        mismatchedIdentityDescriptor.server = DiscoveryFixture.identity(
            stableID: "com.example.differentidentity",
            displayName: "Different Identity"
        )

        let presentationMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000014",
            stableID: "com.example.presentationowner",
            port: 41_064
        )
        var mismatchedPresentationDescriptor = DiscoveryFixture.descriptor(for: presentationMismatch)
        mismatchedPresentationDescriptor.server.displayName = "Spoofed Name"

        let endpointMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000015",
            stableID: "com.example.endpointowner",
            port: 41_065
        )
        var mismatchedEndpointDescriptor = DiscoveryFixture.descriptor(for: endpointMismatch)
        mismatchedEndpointDescriptor.mcp.endpoint = "/different-mcp"

        var descriptorPathMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000016",
            stableID: "com.example.descriptorpath",
            port: 41_066
        )
        descriptorPathMismatch.descriptorURL = try LoopbackEndpoint(
            port: 41_066,
            path: "/unexpected-descriptor.json"
        )

        var descriptorPortMismatch = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000017",
            stableID: "com.example.descriptorport",
            port: 41_067
        )
        descriptorPortMismatch.descriptorURL = try LoopbackEndpoint(
            port: 41_068,
            path: "/local-mcp/v1/descriptor.json"
        )

        let cases: [(
            instance: ProducerInstance,
            descriptor: ProducerDescriptor,
            expectedCompatibility: ProducerCompatibility
        )] = [
            (
                profileInstance,
                profileDescriptor,
                .incompatibleDiscoveryProfile("2")
            ),
            (
                protocolInstance,
                protocolDescriptor,
                .incompatibleMCPProtocol(unsupportedVersions)
            ),
            (
                instanceMismatch,
                mismatchedInstanceDescriptor,
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
            (
                identityMismatch,
                mismatchedIdentityDescriptor,
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
            (
                presentationMismatch,
                mismatchedPresentationDescriptor,
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
            (
                endpointMismatch,
                mismatchedEndpointDescriptor,
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
            (
                descriptorPathMismatch,
                DiscoveryFixture.descriptor(for: descriptorPathMismatch),
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
            (
                descriptorPortMismatch,
                DiscoveryFixture.descriptor(for: descriptorPortMismatch),
                .incompatibleDiscoveryProfile(DiscoveryProfileVersion.current.rawValue)
            ),
        ]

        for testCase in cases {
            try await catalog.advertise(
                instance: testCase.instance,
                descriptor: testCase.descriptor
            )

            guard let event = await iterator.next() else {
                Issue.record("Expected an added event for an incompatible descriptor")
                return
            }
            guard case let .added(discovered) = event else {
                Issue.record("Expected added, received \(event)")
                continue
            }
            #expect(discovered.instanceID == testCase.instance.instanceID)
            #expect(discovered.compatibility == testCase.expectedCompatibility)
        }

        let snapshot = await catalog.snapshot()
        #expect(snapshot.count == cases.count)
        #expect(snapshot.allSatisfy { $0.compatibility != .compatible })
    }

    @Test("late subscribers receive a deterministic replay before live events")
    func lateSubscriberReplayIsSortedAndPrecedesLiveEvents() async throws {
        let catalog = DiscoveryCatalog()
        let zeta = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000023",
            stableID: "com.example.zeta",
            port: 41_070
        )
        let alpha = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000021",
            stableID: "com.example.alpha",
            port: 41_071
        )
        let middle = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000022",
            stableID: "com.example.middle",
            port: 41_072
        )

        for instance in [zeta, alpha, middle] {
            try await catalog.advertise(
                instance: instance,
                descriptor: DiscoveryFixture.descriptor(for: instance)
            )
        }

        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        let replayOne = await iterator.next()
        let replayTwo = await iterator.next()
        let replayThree = await iterator.next()
        #expect(replayOne == .some(.added(alpha)))
        #expect(replayTwo == .some(.added(middle)))
        #expect(replayThree == .some(.added(zeta)))

        let secondLateStream = await catalog.events()
        var secondLateIterator = secondLateStream.makeAsyncIterator()
        let secondReplayOne = await secondLateIterator.next()
        let secondReplayTwo = await secondLateIterator.next()
        let secondReplayThree = await secondLateIterator.next()
        #expect(secondReplayOne == replayOne)
        #expect(secondReplayTwo == replayTwo)
        #expect(secondReplayThree == replayThree)

        let live = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000024",
            stableID: "com.example.live",
            port: 41_073
        )
        try await catalog.advertise(
            instance: live,
            descriptor: DiscoveryFixture.descriptor(for: live)
        )

        let liveEvent = await iterator.next()
        let secondLiveEvent = await secondLateIterator.next()
        #expect(liveEvent == .some(.added(live)))
        #expect(secondLiveEvent == .some(.added(live)))
    }

    @Test("subscribers have independent streams")
    func multipleSubscribersReceiveEveryTransitionIndependently() async throws {
        let catalog = DiscoveryCatalog()
        let firstStream = await catalog.events()
        let secondStream = await catalog.events()
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        #expect(await catalog.subscriberCount() == 2)

        let original = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000030",
            stableID: "com.example.multicast",
            port: 41_080
        )
        try await catalog.advertise(
            instance: original,
            descriptor: DiscoveryFixture.descriptor(for: original)
        )

        let firstAdd = await firstIterator.next()
        let secondAdd = await secondIterator.next()
        #expect(firstAdd == .some(.added(original)))
        #expect(secondAdd == .some(.added(original)))

        let updated = try DiscoveryFixture.updated(
            original,
            displayName: "Multicast Updated",
            version: "1.2.0",
            port: 41_081
        )
        try await catalog.advertise(
            instance: updated,
            descriptor: DiscoveryFixture.descriptor(for: updated)
        )

        let firstUpdate = await firstIterator.next()
        let secondUpdate = await secondIterator.next()
        #expect(firstUpdate == .some(.updated(updated)))
        #expect(secondUpdate == .some(.updated(updated)))
    }

    @Test("snapshot order is stable regardless of advertisement order")
    func snapshotOrderingIsDeterministic() async throws {
        let catalog = DiscoveryCatalog()
        let zeta = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000043",
            stableID: "com.example.one",
            port: 41_090
        )
        let alpha = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000041",
            stableID: "com.example.three",
            port: 41_091
        )
        let middle = try DiscoveryFixture.instance(
            instanceID: "00000000-0000-0000-0000-000000000042",
            stableID: "com.example.two",
            port: 41_092
        )

        for instance in [middle, zeta, alpha] {
            try await catalog.advertise(
                instance: instance,
                descriptor: DiscoveryFixture.descriptor(for: instance)
            )
        }

        let firstSnapshot = await catalog.snapshot()
        let secondSnapshot = await catalog.snapshot()
        #expect(firstSnapshot == [alpha, middle, zeta])
        #expect(secondSnapshot == firstSnapshot)
    }

    @Test("a slow subscriber does not silently lose an advertisement burst")
    func subscriberBurstPreservesEarliestTransition() async throws {
        let catalog = DiscoveryCatalog()
        let stream = await catalog.events()
        var iterator = stream.makeAsyncIterator()
        var advertised: [ProducerInstance] = []

        // Deliberately exceed the catalog's original 256-event implementation
        // buffer. Losing the oldest additions leaves a subscriber permanently out
        // of sync because no overflow/resnapshot signal exists in the protocol.
        for index in 0..<300 {
            let instance = try DiscoveryFixture.instance(
                instanceID: DiscoveryFixture.instanceID(index + 1_000),
                stableID: "com.example.burst\(index)",
                port: UInt16(42_000 + index)
            )
            advertised.append(instance)
            try await catalog.advertise(
                instance: instance,
                descriptor: DiscoveryFixture.descriptor(for: instance)
            )
        }

        let earliestTransition = await iterator.next()
        #expect(earliestTransition == .some(.added(advertised[0])))
        #expect(await catalog.snapshot().count == advertised.count)
    }

    @Test("cancelling consumers removes their subscriber continuations")
    func cancellationCleansUpSubscribers() async {
        let catalog = DiscoveryCatalog()
        let firstStream = await catalog.events()
        let secondStream = await catalog.events()
        #expect(await catalog.subscriberCount() == 2)

        let firstResult = await cancelledIterationResult(of: firstStream)
        #expect(firstResult == nil)

        let countAfterFirstCancellation = await subscriberCount(
            1,
            eventuallyIn: catalog
        )
        #expect(countAfterFirstCancellation == 1)

        let secondResult = await cancelledIterationResult(of: secondStream)
        #expect(secondResult == nil)

        let finalCount = await subscriberCount(0, eventuallyIn: catalog)
        #expect(finalCount == 0)
    }

    /// Cancels a consumer only after it has begun iterating, and bounds the
    /// join so a stream that ignores cancellation fails the test instead of
    /// wedging the whole run.
    private func cancelledIterationResult(
        of stream: AsyncStream<DiscoveryEvent>
    ) async -> DiscoveryEvent? {
        struct IterationTimeout: Error {}
        let gate = IterationStartGate()
        let consumer = Task { () -> DiscoveryEvent? in
            var iterator = stream.makeAsyncIterator()
            await gate.markStarted()
            return await iterator.next()
        }
        await gate.waitUntilStarted()
        await Task.yield()
        consumer.cancel()

        let join = LocalMCPAsyncOperation<DiscoveryEvent?>(
            timeoutAfter: 10,
            timeoutError: IterationTimeout()
        ) {
            await consumer.value
        }
        do {
            return try await join.value(cancellationError: IterationTimeout())
        } catch {
            Issue.record("A cancelled subscriber iteration never returned.")
            return nil
        }
    }

    private func subscriberCount(
        _ expectedCount: Int,
        eventuallyIn catalog: DiscoveryCatalog
    ) async -> Int {
        for _ in 0..<100 {
            let count = await catalog.subscriberCount()
            if count == expectedCount {
                return count
            }
            await Task.yield()
        }
        return await catalog.subscriberCount()
    }
}

private enum DiscoveryFixture {
    static let channelBinding = ProducerChannelBinding(
        publicKey: try! ChannelBindingPublicKey(
            rawRepresentation: Array(repeating: 0x31, count: 32)
        )
    )

    static func instanceID(_ value: Int) -> String {
        let suffix = String(value, radix: 16)
        return "00000000-0000-0000-0000-" +
            String(repeating: "0", count: 12 - suffix.count) + suffix
    }

    static func identity(
        stableID: String,
        displayName: String = "Test Producer",
        version: String = "1.0.0"
    ) -> ProducerIdentity {
        ProducerIdentity(
            stableID: stableID,
            displayName: displayName,
            version: version
        )
    }

    static func instance(
        instanceID: String,
        stableID: String,
        displayName: String = "Test Producer",
        version: String = "1.0.0",
        port: UInt16
    ) throws -> ProducerInstance {
        ProducerInstance(
            identity: identity(
                stableID: stableID,
                displayName: displayName,
                version: version
            ),
            instanceID: instanceID,
            endpoint: try LoopbackEndpoint(port: port, path: "/mcp"),
            descriptorURL: try LoopbackEndpoint(
                port: port,
                path: "/local-mcp/v1/descriptor.json"
            ),
            channelBinding: channelBinding
        )
    }

    static func descriptor(for instance: ProducerInstance) -> ProducerDescriptor {
        ProducerDescriptor(
            instanceID: instance.instanceID,
            server: instance.identity,
            mcp: MCPDescriptor(endpoint: instance.endpoint.path),
            channelBinding: instance.channelBinding
        )
    }

    static func updated(
        _ instance: ProducerInstance,
        displayName: String,
        version: String,
        port: UInt16
    ) throws -> ProducerInstance {
        try self.instance(
            instanceID: instance.instanceID,
            stableID: instance.identity.stableID,
            displayName: displayName,
            version: version,
            port: port
        )
    }
}

private actor IterationStartGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
