import Foundation
import LocalMCPContracts
import Testing
@testable import LocalMCPDiscoveryBonjour

@Suite("Bonjour TXT record codec")
struct BonjourTXTRecordTests {
    @Test("V1 encoding has an exact deterministic wire representation")
    func exactEncoding() throws {
        let advertisement = DiscoveryAdvertisement(
            stableProducerID: "com.example.bonjour-producer"
        )
        let encoded = try BonjourTXTRecordCodec.encode(advertisement)
        let expected = rawTXTRecord([
            "v=1",
            "id=com.example.bonjour-producer",
            "path=/mcp",
            "desc=/local-mcp/v1/descriptor.json",
            "auth=pair-channel",
        ])

        #expect(encoded == expected)
        #expect(encoded.count <= BonjourTXTRecordCodec.maximumEncodedLength)
        #expect(try BonjourTXTRecordCodec.decode(encoded) == advertisement)
    }

    @Test("Unknown lowercase keys are ignored without weakening required values")
    func unknownKeys() throws {
        let encoded = rawTXTRecord([
            "v=1",
            "id=com.example.bonjour-producer",
            "path=/mcp",
            "desc=/local-mcp/v1/descriptor.json",
            "auth=pair-channel",
            "future=metadata",
        ])
        let advertisement = try BonjourTXTRecordCodec.decode(encoded)

        #expect(advertisement.stableProducerID == "com.example.bonjour-producer")
        #expect(advertisement.txtValues["future"] == nil)
    }

    @Test("Duplicate, missing, uppercase, malformed, and unsupported fields fail closed")
    func malformedRecords() {
        let base = [
            "v=1",
            "id=com.example.bonjour-producer",
            "path=/mcp",
            "desc=/local-mcp/v1/descriptor.json",
            "auth=pair-channel",
        ]
        var fixtures: [Data] = []
        fixtures.append(rawTXTRecord(base + ["id=com.example.other"]))
        fixtures.append(rawTXTRecord(Array(base.dropLast())))
        fixtures.append(rawTXTRecord(base + ["Future=value"]))
        fixtures.append(rawTXTRecord(base.map { $0 == "v=1" ? "v=2" : $0 }))
        fixtures.append(rawTXTRecord(base.map { $0.hasPrefix("path=") ? "path=/other" : $0 }))
        fixtures.append(rawTXTRecord(base.map { $0.hasPrefix("desc=") ? "desc=/server.json" : $0 }))
        fixtures.append(rawTXTRecord(base.map { $0 == "auth=pair-channel" ? "auth=none" : $0 }))
        fixtures.append(Data([0]))
        fixtures.append(Data([5, UInt8(ascii: "v"), UInt8(ascii: "="), UInt8(ascii: "1")]))
        fixtures.append(Data([2, 0xff, 0xfe]))

        for fixture in fixtures {
            #expect(throws: (any Error).self) {
                try BonjourTXTRecordCodec.decode(fixture)
            }
        }
    }

    @Test("The complete record is bounded before parsing")
    func sizeLimit() {
        #expect(throws: BonjourTXTRecordError.self) {
            try BonjourTXTRecordCodec.decode(
                Data(repeating: 0, count: BonjourTXTRecordCodec.maximumEncodedLength + 1)
            )
        }

        let maximumProfileID = String(repeating: "a", count: 63) + "." +
            String(repeating: "b", count: 63) + "." +
            String(repeating: "c", count: 63) + "." +
            String(repeating: "d", count: 61)
        #expect(LocalMCPValidation.isStableID(maximumProfileID))
        #expect(throws: BonjourTXTRecordError.recordTooLarge) {
            try BonjourTXTRecordCodec.encode(
                DiscoveryAdvertisement(stableProducerID: maximumProfileID)
            )
        }
    }

    @Test("Discovery TXT contains no authorization or pairing material")
    func containsNoSecrets() throws {
        let seededSecret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let encoded = try BonjourTXTRecordCodec.encode(
            DiscoveryAdvertisement(stableProducerID: "com.example.bonjour-producer")
        )
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains(seededSecret))
        #expect(!text.lowercased().contains("token"))
        #expect(!text.lowercased().contains("nonce"))
        #expect(!text.lowercased().contains("credential"))
        #expect(!text.lowercased().contains("command"))
    }
}
