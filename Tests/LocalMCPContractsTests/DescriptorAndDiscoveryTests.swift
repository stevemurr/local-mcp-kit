import Foundation
import Testing
import LocalMCPContracts

@Suite("Producer descriptor")
struct ProducerDescriptorTests {
    private var descriptor: ProducerDescriptor {
        ProducerDescriptor(instanceID: validInstanceID, server: validProducerIdentity)
    }

    @Test("Descriptor encoding matches the V1 golden JSON")
    func goldenJSON() throws {
        let expected = """
        {"capabilities":{"tools":true},"instanceId":"90f3fc7c-b047-4af2-bac1-33b5b0563d16","mcp":{"authentication":"pairing","endpoint":"/mcp","protocolVersions":["2025-11-25"],"transport":"streamable-http"},"schemaVersion":"1","server":{"id":"com.example.notes","name":"Notes","version":"1.0.0"}}
        """

        #expect(try encodedJSON(descriptor) == expected)
        #expect(try JSONDecoder().decode(ProducerDescriptor.self, from: Data(expected.utf8)) == descriptor)
    }

    @Test("Descriptor readers ignore unknown fields at every object level")
    func ignoresUnknownFields() throws {
        let fixture = """
        {
          "schemaVersion": "1",
          "instanceId": "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
          "futureTopLevel": {"enabled": true},
          "server": {
            "id": "com.example.notes",
            "name": "Notes",
            "version": "1.0.0",
            "vendor": "Example"
          },
          "mcp": {
            "transport": "streamable-http",
            "endpoint": "/mcp",
            "protocolVersions": ["2025-11-25"],
            "authentication": "pairing",
            "futureTransportOption": 42
          },
          "capabilities": {
            "tools": true,
            "futureCapability": true
          }
        }
        """

        let decoded = try JSONDecoder().decode(ProducerDescriptor.self, from: Data(fixture.utf8))

        #expect(decoded == descriptor)
        #expect(try DescriptorCompatibility.validate(decoded) == .current)
    }

    @Test("Compatible descriptors select the current protocol from a larger list")
    func selectsCurrentProtocol() throws {
        var descriptor = descriptor
        descriptor.mcp.protocolVersions = ["2099-01-01", MCPProtocolVersion.current.rawValue]

        #expect(try DescriptorCompatibility.validate(descriptor) == .current)
    }

    @Test("Unsupported descriptor schema is a discovery incompatibility")
    func rejectsUnsupportedSchema() {
        var descriptor = descriptor
        descriptor.schemaVersion = "2"

        expectLocalMCPError(.incompatibleDiscoveryProfile) {
            try DescriptorCompatibility.validate(descriptor)
        }
    }

    @Test("Unsupported MCP versions are a protocol incompatibility")
    func rejectsUnsupportedProtocol() {
        var descriptor = descriptor
        descriptor.mcp.protocolVersions = ["2099-01-01"]

        expectLocalMCPError(.incompatibleMCPProtocol) {
            try DescriptorCompatibility.validate(descriptor)
        }
    }

    @Test("Malformed discovery semantics are rejected before MCP negotiation")
    func rejectsMalformedDiscoverySemantics() {
        var invalidDescriptors: [ProducerDescriptor] = []

        var invalid = descriptor
        invalid.mcp.transport = "stdio"
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.mcp.authentication = "none"
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.mcp.endpoint = "/other"
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.instanceID = "not-a-canonical-lowercase-uuid"
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.server.stableID = "Com.Example.Notes"
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.capabilities.tools = false
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.mcp.protocolVersions = []
        invalidDescriptors.append(invalid)

        invalid = descriptor
        invalid.mcp.protocolVersions = [
            MCPProtocolVersion.current.rawValue,
            MCPProtocolVersion.current.rawValue,
        ]
        invalidDescriptors.append(invalid)

        for invalidDescriptor in invalidDescriptors {
            expectLocalMCPError(.incompatibleDiscoveryProfile) {
                try DescriptorCompatibility.validate(invalidDescriptor)
            }
        }
    }
}

@Suite("Loopback endpoints")
struct LoopbackEndpointTests {
    @Test("A loopback endpoint always constructs a numeric IPv4 loopback URL")
    func constructsFixedLoopbackURL() throws {
        let endpoint = try LoopbackEndpoint(port: 49_152, path: "/mcp")

        #expect(endpoint.port == 49_152)
        #expect(endpoint.path == "/mcp")
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:49152/mcp")
        #expect(endpoint.url.host == "127.0.0.1")
    }

    @Test("Safe relative paths are accepted")
    func acceptsSafePaths() {
        for path in ["/", "/mcp", "/nested/resource", "/caf%C3%A9", "/a//b"] {
            #expect(LoopbackEndpoint.isValidRelativePath(path))
        }
    }

    @Test("Paths that can escape or alter the request target are rejected")
    func rejectsUnsafePaths() {
        let paths = [
            "",
            "mcp",
            "//example.invalid/mcp",
            "/back\\slash",
            "/mcp?token=value",
            "/mcp#fragment",
            "/line\nfeed",
            "/./mcp",
            "/mcp/../secret",
            "/%2e/mcp",
            "/%2E%2E/secret",
            "/%2e%2e%2fsecret",
            "/%5C..%5Csecret",
            "/mcp%3Fquery=value",
            "/mcp%23fragment",
            "/encoded%00control",
            "/malformed%ZZescape",
        ]

        for path in paths {
            #expect(!LoopbackEndpoint.isValidRelativePath(path))
        }
    }

    @Test("Zero ports and unsafe paths cannot initialize")
    func rejectsInvalidInitialization() {
        expectLocalMCPError(.invalidConfiguration) {
            try LoopbackEndpoint(port: 0, path: "/mcp")
        }
        expectLocalMCPError(.invalidConfiguration) {
            try LoopbackEndpoint(port: 8_080, path: "//example.invalid/mcp")
        }
    }

    @Test("Decoding re-applies endpoint validation")
    func decodingValidates() throws {
        let valid = try LoopbackEndpoint(port: 8_080, path: "/mcp")
        let roundTrip = try JSONDecoder().decode(
            LoopbackEndpoint.self,
            from: JSONEncoder().encode(valid)
        )
        #expect(roundTrip == valid)

        let invalid = Data(#"{"port":0,"path":"/mcp"}"#.utf8)
        expectLocalMCPError(.invalidConfiguration) {
            try JSONDecoder().decode(LoopbackEndpoint.self, from: invalid)
        }
    }
}

@Suite("Identities and discovery advertisements")
struct IdentityAndAdvertisementTests {
    @Test("Identity coding uses the stable V1 field names")
    func identityCodingKeys() throws {
        #expect(
            try encodedJSON(validProducerIdentity) ==
                #"{"id":"com.example.notes","name":"Notes","version":"1.0.0"}"#
        )
        #expect(
            try encodedJSON(validConsumerIdentity) ==
                #"{"id":"com.example.assistant","installationId":"3e260e1c-bb58-4247-9733-47352fbc6c98","name":"Example Assistant","version":"2.0.0"}"#
        )
    }

    @Test("Valid producer and consumer identities are accepted")
    func validIdentities() {
        #expect(validProducerIdentity.isValid)
        #expect(validConsumerIdentity.isValid)

        let maximumStableID = String(repeating: "a", count: 63) + "." +
            String(repeating: "b", count: 63) + "." +
            String(repeating: "c", count: 63) + "." +
            String(repeating: "d", count: 61)
        #expect(maximumStableID.utf8.count == 253)
        #expect(LocalMCPValidation.isStableID(maximumStableID))

        #expect(LocalMCPValidation.isDisplayName(String(repeating: "é", count: 128)))
        #expect(LocalMCPValidation.isVersion(String(repeating: "界", count: 64)))
    }

    @Test("Invalid producer identity fields are rejected")
    func invalidProducerIdentity() {
        let invalidStableIDs = [
            "ab",
            "localhost",
            "Com.example.notes",
            ".com.example.notes",
            "com..notes",
            "com.-example.notes",
            "com.example-.notes",
            "com.example_notes",
            " com.example.notes",
            String(repeating: "a", count: 64) + ".example",
            String(repeating: "a", count: 63) + "." +
                String(repeating: "b", count: 63) + "." +
                String(repeating: "c", count: 63) + "." +
                String(repeating: "d", count: 63),
        ]

        for stableID in invalidStableIDs {
            #expect(!LocalMCPValidation.isStableID(stableID))
        }
        #expect(!LocalMCPValidation.isDisplayName(""))
        #expect(!LocalMCPValidation.isDisplayName("Notes\n"))
        #expect(!LocalMCPValidation.isDisplayName(String(repeating: "a", count: 129)))
        #expect(!LocalMCPValidation.isVersion(""))
        #expect(!LocalMCPValidation.isVersion("1.0.0\n"))
        #expect(!LocalMCPValidation.isVersion(String(repeating: "1", count: 65)))
    }

    @Test("Consumer installation IDs must be canonical lowercase UUIDs")
    func installationIDValidation() {
        #expect(LocalMCPValidation.isCanonicalLowercaseUUID(validConsumerIdentity.installationID))
        #expect(!LocalMCPValidation.isCanonicalLowercaseUUID(validConsumerIdentity.installationID.uppercased()))
        #expect(!LocalMCPValidation.isCanonicalLowercaseUUID("not-a-uuid"))

        var consumer = validConsumerIdentity
        consumer.installationID = consumer.installationID.uppercased()
        #expect(!consumer.isValid)
    }

    @Test("Advertisement encoding is the exact small V1 TXT payload")
    func advertisementTXTValues() {
        let advertisement = DiscoveryAdvertisement(stableProducerID: validProducerIdentity.stableID)

        #expect(DiscoveryAdvertisement.serviceType == "_appmcp._tcp")
        #expect(advertisement.txtValues == [
            "v": "1",
            "id": "com.example.notes",
            "path": "/mcp",
            "desc": "/local-mcp/v1/descriptor.json",
            "auth": "pair",
        ])
    }

    @Test("Advertisement readers ignore unknown additive TXT keys")
    func advertisementIgnoresUnknownKeys() throws {
        var values = DiscoveryAdvertisement(stableProducerID: validProducerIdentity.stableID).txtValues
        values["future"] = "additive-metadata"

        let advertisement = try DiscoveryAdvertisement(txtValues: values)

        #expect(advertisement.stableProducerID == validProducerIdentity.stableID)
        #expect(advertisement.endpointPath == "/mcp")
        #expect(advertisement.descriptorPath == "/local-mcp/v1/descriptor.json")
        #expect(advertisement.authentication == "pair")
        #expect(advertisement.txtValues["future"] == nil)
    }

    @Test("Missing or altered required TXT values are incompatible")
    func advertisementRejectsInvalidValues() {
        let valid = DiscoveryAdvertisement(stableProducerID: validProducerIdentity.stableID).txtValues

        for key in ["v", "id", "path", "desc", "auth"] {
            var missing = valid
            missing.removeValue(forKey: key)
            expectLocalMCPError(.incompatibleDiscoveryProfile) {
                try DiscoveryAdvertisement(txtValues: missing)
            }
        }

        let replacements = [
            ("v", "2"),
            ("id", "Com.Example.Notes"),
            ("path", "/other"),
            ("path", "//example.invalid/mcp"),
            ("desc", "/other.json"),
            ("desc", "/discovery/v1/server.json"),
            ("auth", "none"),
        ]
        for (key, value) in replacements {
            var altered = valid
            altered[key] = value
            expectLocalMCPError(.incompatibleDiscoveryProfile) {
                try DiscoveryAdvertisement(txtValues: altered)
            }
        }

        var legacyServerCard = valid
        let legacyDescriptorPath = legacyServerCard.removeValue(forKey: "desc")
        legacyServerCard["card"] = legacyDescriptorPath
        expectLocalMCPError(.incompatibleDiscoveryProfile) {
            try DiscoveryAdvertisement(txtValues: legacyServerCard)
        }
    }
}
