import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
import Testing
@testable import LocalMCPDiscoveryBonjour
import dnssd

@Suite("Bonjour LocalOnly advertising")
struct BonjourLocalOnlyAdvertisingTests {
    @Test("Registration is fixed to LocalOnly with exact V1 metadata")
    func localOnlyRegistration() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader()
        )
        let instance = try bonjourTestInstance()
        let descriptor = bonjourTestDescriptor()

        try await discovery.advertise(instance: instance, descriptor: descriptor)
        try await discovery.advertise(instance: instance, descriptor: descriptor)

        let requests = backend.registrations
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.interfaceIndex == bonjourLocalOnlyInterfaceIndex)
        #expect(request.interfaceIndex == UInt32.max)
        #expect(request.serviceType == "_appmcp._tcp")
        #expect(request.port == instance.endpoint.port)
        #expect(request.name == "LocalMCP-90f3fc7c-b04")
        #expect(
            try BonjourTXTRecordCodec.decode(request.txtRecord) ==
                DiscoveryAdvertisement(stableProducerID: bonjourTestProducer.stableID)
        )

        await discovery.withdraw(instanceID: instance.instanceID)
        await discovery.withdraw(instanceID: instance.instanceID)
        #expect(backend.registrationHandles.first?.cancellationCount == 1)
        #expect(await discovery.registrationCount() == 0)
    }

    @Test("Registration succeeds only for an error-free Add callback")
    func registrationCallbackSemantics() {
        let add = UInt32(kDNSServiceFlagsAdd)
        #expect(!bonjourRegistrationCallbackSucceeded(errorCode: 0, flags: 0))
        #expect(bonjourRegistrationCallbackSucceeded(errorCode: 0, flags: add))
        #expect(bonjourRegistrationCallbackSucceeded(errorCode: 0, flags: add | 1))
        #expect(!bonjourRegistrationCallbackSucceeded(errorCode: -65_537, flags: 0))
        #expect(!bonjourRegistrationCallbackSucceeded(errorCode: -65_537, flags: add))
    }

    @Test("Invalid or oversized advertisements never reach DNS-SD")
    func publicationValidation() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader()
        )
        var invalidDescriptor = bonjourTestDescriptor()
        invalidDescriptor.server.stableID = "com.example.other"
        do {
            try await discovery.advertise(
                instance: try bonjourTestInstance(),
                descriptor: invalidDescriptor
            )
            Issue.record("Expected advertisementFailed.")
        } catch let error as LocalMCPError {
            #expect(error == .advertisementFailed)
        }

        let maximumProfileID = String(repeating: "a", count: 63) + "." +
            String(repeating: "b", count: 63) + "." +
            String(repeating: "c", count: 63) + "." +
            String(repeating: "d", count: 61)
        let identity = ProducerIdentity(
            stableID: maximumProfileID,
            displayName: "Large ID",
            version: "1"
        )
        let descriptor = ProducerDescriptor(instanceID: bonjourTestInstanceID, server: identity)
        let instance = ProducerInstance(
            identity: identity,
            instanceID: bonjourTestInstanceID,
            endpoint: try LoopbackEndpoint(port: 49_152, path: "/mcp"),
            descriptorURL: try LoopbackEndpoint(
                port: 49_152,
                path: "/local-mcp/v1/descriptor.json"
            )
        )
        do {
            try await discovery.advertise(instance: instance, descriptor: descriptor)
            Issue.record("An oversized TXT field reached DNS-SD.")
        } catch let error as LocalMCPError {
            #expect(error == .advertisementFailed)
        }
        #expect(backend.registrations.isEmpty)
    }

    @Test("Immediate registration failure cleans up desired state")
    func immediateFailureCleanup() async throws {
        let failingBackend = FakeBonjourDNSServiceBackend()
        failingBackend.registerFailure = .register
        let failing = BonjourLocalMCPDiscovery(
            backend: failingBackend,
            descriptorLoader: FakeBonjourDescriptorLoader()
        )
        do {
            try await failing.advertise(
                instance: try bonjourTestInstance(),
                descriptor: bonjourTestDescriptor()
            )
            Issue.record("Expected advertisementFailed.")
        } catch let error as LocalMCPError {
            #expect(error == .advertisementFailed)
        }
        #expect(await failing.registrationCount() == 0)
        #expect(await failing.desiredRegistrationCount() == 0)
        #expect(await failing.pendingRegistrationRetryCount() == 0)
    }

    @Test("Asynchronous registration failure retries with capped backoff and recovers")
    func asynchronousFailureRecovery() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let sleeper = ControlledBonjourSleeper()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader(),
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )
        try await discovery.advertise(
            instance: try bonjourTestInstance(),
            descriptor: bonjourTestDescriptor()
        )

        backend.failRegistration()
        #expect(await eventually {
            let activeCount = await discovery.registrationCount()
            let desiredCount = await discovery.desiredRegistrationCount()
            let retryCount = await discovery.pendingRegistrationRetryCount()
            return activeCount == 0
                && desiredCount == 1
                && retryCount == 1
                && sleeper.intervals() == [1]
        })
        #expect(backend.registrationHandles.first?.cancellationCount == 1)

        backend.setRegisterFailure(.register)
        for expectedIntervals: [TimeInterval] in [[1, 2], [1, 2, 4], [1, 2, 4, 4]] {
            #expect(sleeper.resumeNext())
            #expect(await eventually { sleeper.intervals() == expectedIntervals })
            #expect(await discovery.registrationCount() == 0)
            #expect(await discovery.desiredRegistrationCount() == 1)
        }

        backend.setRegisterFailure(nil)
        #expect(sleeper.resumeNext())
        #expect(await eventually {
            let activeCount = await discovery.registrationCount()
            let retryCount = await discovery.pendingRegistrationRetryCount()
            return activeCount == 1 && retryCount == 0
        })
        #expect(backend.registrations.count == 2)
        #expect(await discovery.desiredRegistrationCount() == 1)

        // A delayed callback from the original handle shares the desired
        // registration generation, but not the recovered attempt token.
        backend.failRegistration(at: 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await discovery.registrationCount() == 1)
        #expect(await discovery.pendingRegistrationRetryCount() == 0)
        #expect(sleeper.intervals() == [1, 2, 4, 4])
        await discovery.stop()
    }

    @Test("Withdraw and stop cancel a scheduled registration retry")
    func retryCancellation() async throws {
        for shouldStop in [false, true] {
            let backend = FakeBonjourDNSServiceBackend()
            let sleeper = ControlledBonjourSleeper()
            let discovery = BonjourLocalMCPDiscovery(
                backend: backend,
                descriptorLoader: FakeBonjourDescriptorLoader(),
                sleeper: sleeper,
                retryPolicy: BonjourRetryPolicy(
                    initialDelay: 1,
                    multiplier: 2,
                    maximumDelay: 4
                )
            )
            let instance = try bonjourTestInstance()
            try await discovery.advertise(
                instance: instance,
                descriptor: bonjourTestDescriptor()
            )
            backend.failRegistration()
            #expect(await eventually {
                await discovery.pendingRegistrationRetryCount() == 1
                    && sleeper.pendingCount() == 1
            })

            if shouldStop {
                await discovery.stop()
            } else {
                await discovery.withdraw(instanceID: instance.instanceID)
            }

            #expect(await eventually {
                let activeCount = await discovery.registrationCount()
                let desiredCount = await discovery.desiredRegistrationCount()
                let retryCount = await discovery.pendingRegistrationRetryCount()
                return activeCount == 0
                    && desiredCount == 0
                    && retryCount == 0
                    && sleeper.pendingCount() == 0
            })
            backend.failRegistration()
            try? await Task.sleep(for: .milliseconds(20))
            #expect(sleeper.intervals() == [1])
            #expect(backend.registrations.count == 1)
        }
    }

    @Test("Replacement and withdrawal reject stale failure callbacks")
    func staleRegistrationCallbacks() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let sleeper = ControlledBonjourSleeper()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader(),
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )
        let original = try bonjourTestInstance()
        try await discovery.advertise(
            instance: original,
            descriptor: bonjourTestDescriptor()
        )
        backend.failRegistration(at: 0)
        #expect(await eventually { sleeper.pendingCount() == 1 })

        let replacement = try bonjourTestInstance(port: 49_153)
        try await discovery.advertise(
            instance: replacement,
            descriptor: bonjourTestDescriptor()
        )
        #expect(await eventually { sleeper.pendingCount() == 0 })
        #expect(backend.registrations.map(\.port) == [49_152, 49_153])
        #expect(await discovery.registrationCount() == 1)
        #expect(await discovery.pendingRegistrationRetryCount() == 0)

        backend.failRegistration(at: 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await discovery.registrationCount() == 1)
        #expect(sleeper.intervals() == [1])

        await discovery.withdraw(instanceID: replacement.instanceID)
        backend.failRegistration(at: 1)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await discovery.registrationCount() == 0)
        #expect(await discovery.desiredRegistrationCount() == 0)
        #expect(await discovery.pendingRegistrationRetryCount() == 0)
        #expect(sleeper.intervals() == [1])
    }
}

@Suite("Bonjour LocalOnly browsing and resolution")
struct BonjourLocalOnlyBrowsingTests {
    private func localService(name: String = "Producer") -> BonjourServiceKey {
        BonjourServiceKey(
            name: name,
            serviceType: "_appmcp._tcp",
            domain: "local.",
            interfaceIndex: bonjourLocalOnlyInterfaceIndex
        )
    }

    private func validResolve(
        port: UInt16 = 49_152,
        interfaceIndex: UInt32 = bonjourLocalOnlyInterfaceIndex
    ) throws -> BonjourResolveEvent {
        .resolved(
            BonjourResolveResult(
                interfaceIndex: interfaceIndex,
                fullName: "Producer._appmcp._tcp.local.",
                hostTarget: "malicious-hostname.example.",
                port: port,
                txtRecord: try BonjourTXTRecordCodec.encode(
                    DiscoveryAdvertisement(stableProducerID: bonjourTestProducer.stableID)
                )
            )
        )
    }

    @Test("Browse and resolve requests and callbacks are all LocalOnly")
    func localOnlyAtEveryBoundary() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let loader = FakeBonjourDescriptorLoader()
        let discovery = BonjourLocalMCPDiscovery(backend: backend, descriptorLoader: loader)
        try await discovery.start()

        #expect(backend.browses == [
            .init(serviceType: "_appmcp._tcp", interfaceIndex: bonjourLocalOnlyInterfaceIndex)
        ])
        backend.emitBrowse(
            .added(
                BonjourServiceKey(
                    name: "LAN record",
                    serviceType: "_appmcp._tcp",
                    domain: "local.",
                    interfaceIndex: 4
                )
            )
        )
        try? await Task.sleep(for: .milliseconds(20))
        #expect(backend.resolutions.isEmpty)

        let service = localService()
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions == [service] })
        #expect(backend.resolutions.first?.interfaceIndex == bonjourLocalOnlyInterfaceIndex)

        backend.emitResolve(try validResolve(interfaceIndex: 4), for: service)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await loader.urls().isEmpty)
        #expect(await discovery.snapshot().isEmpty)
    }

    @Test("Resolved hostnames are ignored and descriptor fetches use numeric loopback")
    func numericLoopbackDescriptorFetch() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let loader = FakeBonjourDescriptorLoader()
        let discovery = BonjourLocalMCPDiscovery(backend: backend, descriptorLoader: loader)
        try await discovery.start()
        let service = localService()

        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions == [service] })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().count == 1 })

        let instance = try #require(await discovery.snapshot().first)
        let expectedInstance = try bonjourTestInstance()
        #expect(instance == expectedInstance)
        let requestedURL = try #require(await loader.urls().first)
        #expect(requestedURL.absoluteString ==
            "http://127.0.0.1:49152/local-mcp/v1/descriptor.json")
        #expect(!requestedURL.absoluteString.contains("malicious-hostname"))
    }

    @Test("Rapid browse callbacks preserve delivery order and cannot leave a phantom service")
    func rapidAddRemoveOrdering() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader()
        )
        try await discovery.start()
        let service = localService()

        backend.emitBrowse(.added(service))
        backend.emitBrowse(.removed(service))

        #expect(await eventually {
            guard backend.resolutions.count == 1 else { return false }
            return await discovery.activeResolveCount() == 0
        })
        #expect(backend.resolveHandle(for: service)?.cancellationCount == 1)

        // A callback already queued by DNS-SD after removal belongs to the old
        // attempt token and must not resurrect the service.
        backend.emitResolve(try validResolve(), for: service)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await discovery.snapshot().isEmpty)
        await discovery.stop()
    }

    @Test("Descriptor identity, path, authentication, capability, and version mismatches stay incompatible")
    func descriptorCompatibility() async throws {
        let cases: [(String, ProducerDescriptor, ProducerCompatibility)] = {
            var identityMismatch = bonjourTestDescriptor()
            identityMismatch.server.stableID = "com.example.impostor"

            var pathMismatch = bonjourTestDescriptor()
            pathMismatch.mcp.endpoint = "/other"

            var authMismatch = bonjourTestDescriptor()
            authMismatch.mcp.authentication = "none"

            var capabilityMismatch = bonjourTestDescriptor()
            capabilityMismatch.capabilities.tools = false

            var versionMismatch = bonjourTestDescriptor()
            versionMismatch.mcp.protocolVersions = ["2099-01-01"]

            return [
                ("identity", identityMismatch, .incompatibleDiscoveryProfile("1")),
                ("path", pathMismatch, .incompatibleDiscoveryProfile("1")),
                ("auth", authMismatch, .incompatibleDiscoveryProfile("1")),
                ("capability", capabilityMismatch, .incompatibleDiscoveryProfile("1")),
                ("version", versionMismatch, .incompatibleMCPProtocol(["2099-01-01"])),
            ]
        }()

        for (name, descriptor, expectedCompatibility) in cases {
            let backend = FakeBonjourDNSServiceBackend()
            let loader = FakeBonjourDescriptorLoader(descriptor: descriptor)
            let discovery = BonjourLocalMCPDiscovery(backend: backend, descriptorLoader: loader)
            try await discovery.start()
            let service = localService(name: name)
            backend.emitBrowse(.added(service))
            #expect(await eventually { backend.resolutions == [service] })
            backend.emitResolve(try validResolve(), for: service)
            #expect(await eventually { await discovery.snapshot().count == 1 })
            #expect(await discovery.snapshot().first?.compatibility == expectedCompatibility)
            await discovery.stop()
        }
    }

    @Test("Removal, descriptor failure, restart, and stop converge with full cleanup")
    func lifecycleCleanupAndRestart() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let loader = FakeBonjourDescriptorLoader()
        let discovery = BonjourLocalMCPDiscovery(backend: backend, descriptorLoader: loader)
        try await discovery.start()
        let service = localService()

        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 1 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().count == 1 })

        let replacementID = "95a519b9-d823-4b84-913f-27211ef70773"
        await loader.setDescriptor(bonjourTestDescriptor(instanceID: replacementID))
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 2 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually {
            await discovery.snapshot().map(\.instanceID) == [replacementID]
        })

        await loader.setFailure()
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 3 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().isEmpty })

        backend.emitBrowse(.removed(service))
        await discovery.stop()
        await discovery.stop()
        let browsing = await discovery.isBrowsing()
        #expect(!browsing)
        #expect(await discovery.activeResolveCount() == 0)
        #expect(backend.browseHandles.first?.cancellationCount == 1)
    }

    @Test("Resolve failures retry with capped backoff and removal cancels the retry")
    func resolveRetryBackoffAndCancellation() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let sleeper = ControlledBonjourSleeper()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader(),
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )
        try await discovery.start()
        let service = localService()
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 1 })

        for attempt in 1 ... 4 {
            backend.emitResolve(.failure(-65_537), for: service)
            #expect(await eventually { sleeper.intervals().count == attempt })
            if attempt < 4 {
                #expect(sleeper.resumeNext())
                #expect(await eventually { backend.resolutions.count == attempt + 1 })
            }
        }

        #expect(sleeper.intervals() == [1, 2, 4, 4])
        #expect(sleeper.pendingCount() == 1)
        backend.emitBrowse(.removed(service))
        #expect(await eventually { sleeper.pendingCount() == 0 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(backend.resolutions.count == 4)
        #expect(await discovery.snapshot().isEmpty)
        await discovery.stop()
    }

    @Test("Descriptor fetch failures retry while the service remains present")
    func descriptorRetry() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let loader = FakeBonjourDescriptorLoader()
        await loader.setFailure()
        let sleeper = ControlledBonjourSleeper()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: loader,
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )
        try await discovery.start()
        let service = localService()

        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 1 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { sleeper.intervals() == [1] })
        #expect(await discovery.snapshot().isEmpty)

        await loader.setDescriptor(bonjourTestDescriptor())
        #expect(sleeper.resumeNext())
        #expect(await eventually { backend.resolutions.count == 2 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().count == 1 })
        #expect(await loader.urls().count == 2)
        await discovery.stop()
    }

    @Test("Browse creation failure recovers without closing the discovery stream")
    func initialBrowseFailureRecovery() async {
        let backend = FakeBonjourDNSServiceBackend()
        backend.browseFailure = .browse
        let sleeper = ControlledBonjourSleeper()
        let catalog = DiscoveryCatalog()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader(),
            catalog: catalog,
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )

        let stream = await discovery.events()
        _ = stream
        #expect(await eventually { sleeper.intervals() == [1] })
        #expect(await catalog.subscriberCount() == 1)
        backend.browseFailure = nil
        #expect(sleeper.resumeNext())
        #expect(await eventually { await discovery.isBrowsing() })
        #expect(backend.browses.count == 1)
        #expect(backend.browses.first?.interfaceIndex == bonjourLocalOnlyInterfaceIndex)
        await discovery.stop()
    }

    @Test("Browse failure removes stale state and the same stream observes recovery")
    func browseFailureRecovery() async throws {
        let backend = FakeBonjourDNSServiceBackend()
        let sleeper = ControlledBonjourSleeper()
        let catalog = DiscoveryCatalog()
        let discovery = BonjourLocalMCPDiscovery(
            backend: backend,
            descriptorLoader: FakeBonjourDescriptorLoader(),
            catalog: catalog,
            sleeper: sleeper,
            retryPolicy: BonjourRetryPolicy(
                initialDelay: 1,
                multiplier: 2,
                maximumDelay: 4
            )
        )
        let stream = await discovery.events()
        let recorder = DiscoveryEventRecorder()
        let observation = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        let service = localService()
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 1 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().count == 1 })
        #expect(await eventually { await recorder.events().count == 1 })

        backend.emitBrowse(.failure(-65_537))
        #expect(await eventually { await discovery.snapshot().isEmpty })
        #expect(await eventually { sleeper.intervals() == [1] })
        #expect(await eventually { await recorder.events().count == 2 })
        #expect(await catalog.subscriberCount() == 1)

        #expect(sleeper.resumeNext())
        #expect(await eventually { backend.browses.count == 2 })
        backend.emitBrowse(.added(service))
        #expect(await eventually { backend.resolutions.count == 2 })
        backend.emitResolve(try validResolve(), for: service)
        #expect(await eventually { await discovery.snapshot().count == 1 })
        #expect(await eventually { await recorder.events().count == 3 })
        let events = await recorder.events()
        let expectedInstance = try bonjourTestInstance()
        #expect(events[0] == .added(expectedInstance))
        #expect(events[1] == .removed(instanceID: bonjourTestInstanceID))
        #expect(events[2] == .added(expectedInstance))

        await discovery.stop()
        observation.cancel()
    }
}

@Suite("Bonjour ordered callback pump")
struct BonjourOrderedEventPumpTests {
    @Test("Overflow is bounded and replaced by one terminal recovery event")
    func overflow() async {
        let recorder = BlockingOrderedPumpRecorder()
        let pump = BonjourOrderedEventPump<Int>(
            maximumPendingCount: 2,
            overflowEvent: -1
        ) { value in
            await recorder.receive(value)
        }

        pump.yield(1)
        #expect(await eventually { await recorder.events() == [1] })

        pump.yield(2)
        pump.yield(3)
        pump.yield(4)
        pump.yield(5)
        await recorder.release()

        #expect(await eventually { await recorder.events() == [1, -1] })
    }
}
