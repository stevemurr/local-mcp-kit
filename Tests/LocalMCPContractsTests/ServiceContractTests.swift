import Foundation
import Testing
import LocalMCPContracts

@Suite("Discovery and service value contracts")
struct ServiceContractTests {
    @Test("Published discovery and MCP version constants are stable")
    func versionConstants() {
        #expect(DiscoveryProfileVersion.current.rawValue == "1")
        #expect(MCPProtocolVersion.current.rawValue == "2025-11-25")
        #expect(DiscoveryProfileVersion(rawValue: "2").rawValue == "2")
        #expect(MCPProtocolVersion(rawValue: "future").rawValue == "future")
    }

    @Test("Producer instances preserve endpoints and all compatibility states through Codable")
    func producerInstanceCoding() throws {
        let endpoint = try LoopbackEndpoint(port: 49_152, path: "/mcp")
        let descriptorURL = try LoopbackEndpoint(
            port: 49_152,
            path: "/local-mcp/v1/descriptor.json"
        )
        let compatibilityStates: [ProducerCompatibility] = [
            .compatible,
            .incompatibleDiscoveryProfile("2"),
            .incompatibleMCPProtocol(["2099-01-01"]),
        ]

        for compatibility in compatibilityStates {
            let instance = ProducerInstance(
                identity: validProducerIdentity,
                instanceID: validInstanceID,
                endpoint: endpoint,
                descriptorURL: descriptorURL,
                compatibility: compatibility
            )
            let data = try JSONEncoder().encode(instance)
            let decoded = try JSONDecoder().decode(ProducerInstance.self, from: data)

            #expect(decoded == instance)
            #expect(String(decoding: data, as: UTF8.self).contains("\"instanceId\""))
            #expect(!String(decoding: data, as: UTF8.self).contains("\"instanceID\""))
        }
    }

    @Test("Discovery events retain exact transition payloads")
    func discoveryEvents() throws {
        let endpoint = try LoopbackEndpoint(port: 49_152, path: "/mcp")
        let descriptorURL = try LoopbackEndpoint(
            port: 49_152,
            path: "/local-mcp/v1/descriptor.json"
        )
        let instance = ProducerInstance(
            identity: validProducerIdentity,
            instanceID: validInstanceID,
            endpoint: endpoint,
            descriptorURL: descriptorURL
        )

        #expect(DiscoveryEvent.added(instance) == .added(instance))
        #expect(DiscoveryEvent.updated(instance) == .updated(instance))
        #expect(DiscoveryEvent.removed(instanceID: validInstanceID) ==
            .removed(instanceID: validInstanceID))
        #expect(DiscoveryEvent.added(instance) != .updated(instance))
    }

    @Test("Installation identity ignores presentation-only name and version")
    func sameConsumerInstallation() {
        var renamed = validConsumerIdentity
        renamed.displayName = "Renamed Assistant"
        renamed.version = "99.0"
        #expect(validConsumerIdentity.representsSameInstallation(as: renamed))

        var differentStableID = renamed
        differentStableID.stableID = "com.example.other-assistant"
        #expect(!validConsumerIdentity.representsSameInstallation(as: differentStableID))

        var differentInstallation = renamed
        differentInstallation.installationID = "c938fa58-8998-4ef1-a125-8b7b26a51b35"
        #expect(!validConsumerIdentity.representsSameInstallation(as: differentInstallation))
    }

    @Test("Initialization values round-trip without exposing an adapter type")
    func initializationCoding() throws {
        let initialization = LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: validProducerIdentity,
            capabilities: ProducerCapabilities(tools: true)
        )

        let data = try JSONEncoder().encode(initialization)
        #expect(
            try JSONDecoder().decode(LocalMCPInitialization.self, from: data) == initialization
        )
    }
}

@Suite("System contract dependencies")
struct SystemContractDependencyTests {
    @Test("System random bytes enforce public count bounds")
    func randomByteBounds() async throws {
        let generator = SystemRandomBytesGenerator()

        #expect(try await generator.randomBytes(count: 1).count == 1)
        #expect(try await generator.randomBytes(count: 4_096).count == 4_096)

        for invalidCount in [Int.min, -1, 0, 4_097, Int.max] {
            do {
                _ = try await generator.randomBytes(count: invalidCount)
                Issue.record("Expected invalidConfiguration for count \(invalidCount).")
            } catch let error as LocalMCPError {
                #expect(error == .invalidConfiguration)
            } catch {
                Issue.record("Unexpected error: \(String(reflecting: error))")
            }
        }
    }

    @Test("System clock returns the current wall-clock interval")
    func systemClock() async {
        let before = Date()
        let observed = await SystemLocalMCPClock().now()
        let after = Date()

        #expect(observed.timeIntervalSince(before) >= -1)
        #expect(observed.timeIntervalSince(after) <= 1)
    }
}
