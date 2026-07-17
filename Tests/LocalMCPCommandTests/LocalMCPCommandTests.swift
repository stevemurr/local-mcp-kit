import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
@testable import local_mcp
import Testing

@Suite("local-mcp diagnostic CLI")
struct LocalMCPCommandTests {
    @Test("Help and version are deterministic")
    func helpAndVersion() async {
        let help = await LocalMCPCLI.run(arguments: [])
        #expect(help.exitCode == 0)
        #expect(help.standardOutput == LocalMCPCLI.usage)
        #expect(help.standardError.isEmpty)

        let version = await LocalMCPCLI.run(arguments: ["version"])
        #expect(version == .success("local-mcp \(LocalMCPCLI.version)\n"))
    }

    @Test("Discover options parse without order dependence")
    func parsesDiscover() throws {
        #expect(
            try LocalMCPCLIParser.parse(["discover", "--json", "--timeout", "0.25"])
                == .discover(timeout: 0.25, json: true)
        )
        #expect(
            try LocalMCPCLIParser.parse(["discover"])
                == .discover(timeout: 2, json: false)
        )
    }

    @Test("Invalid arguments return sanitized usage errors", arguments: [
        ["unknown"],
        ["discover", "--timeout"],
        ["discover", "--timeout", "-1"],
        ["discover", "--other"],
        ["inspect-descriptor"],
    ])
    func invalidArguments(arguments: [String]) async {
        let execution = await LocalMCPCLI.run(arguments: arguments)
        #expect(execution.exitCode == 2)
        #expect(execution.standardOutput.isEmpty)
        #expect(execution.standardError.hasPrefix("Error: "))
        #expect(execution.standardError.contains("Usage:"))
    }

    @Test("Parse errors escape terminal controls from hostile arguments")
    func parseErrorsEscapeTerminalControls() async {
        let execution = await LocalMCPCLI.run(arguments: [
            "discover", "--timeout", "1\u{1B}[31m\nforged\u{202E}",
        ])

        #expect(execution.exitCode == 2)
        #expect(!execution.standardError.contains("\u{1B}"))
        #expect(!execution.standardError.contains("\u{202E}"))
        #expect(execution.standardError.contains("1\\u{1B}[31m\\u{A}forged\\u{202E}"))
    }

    @Test("Discovery text reports compatibility without authority material")
    func discoveryTextIsRedacted() async throws {
        let producer = try makeInstance()
        let execution = await LocalMCPCLI.discover(
            timeout: 0,
            json: false,
            browser: StaticBrowser(instances: [producer])
        )

        #expect(execution.exitCode == 0)
        #expect(execution.standardOutput.contains("Example Producer (com.example.diagnostic)"))
        #expect(execution.standardOutput.contains("compatibility: compatible"))
        #expect(execution.standardOutput.contains("http://127.0.0.1:49152/mcp"))
        #expect(!execution.standardOutput.localizedCaseInsensitiveContains("token"))
        #expect(!execution.standardOutput.localizedCaseInsensitiveContains("credential"))
        #expect(!execution.standardOutput.localizedCaseInsensitiveContains("authorization"))
    }

    @Test("Discovery JSON is stable and secret-free")
    func discoveryJSON() async throws {
        var instance = try makeInstance()
        instance.identity.displayName = "Direction\u{202E}spoof\u{2066}isolate\u{2028}line"
        let execution = await LocalMCPCLI.discover(
            timeout: 0,
            json: true,
            browser: StaticBrowser(instances: [instance])
        )
        #expect(execution.exitCode == 0)
        #expect(!execution.standardOutput.contains("\u{202E}"))
        #expect(!execution.standardOutput.contains("\u{2066}"))
        #expect(!execution.standardOutput.contains("\u{2028}"))
        #expect(execution.standardOutput.contains("\\u202E"))
        #expect(execution.standardOutput.contains("\\u2066"))
        #expect(execution.standardOutput.contains("\\u2028"))
        let data = Data(execution.standardOutput.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(object.count == 1)
        #expect(object[0]["stableID"] as? String == "com.example.diagnostic")
        #expect(object[0]["displayName"] as? String == instance.identity.displayName)
        #expect(object[0]["compatibility"] as? String == "compatible")
        #expect(object[0]["endpoint"] as? String == "http://127.0.0.1:49152/mcp")
    }

    @Test("Text diagnostics escape terminal controls from untrusted discovery fields")
    func discoveryTextEscapesTerminalControls() async throws {
        var producer = try makeInstance()
        producer.identity.displayName = "Hostile\u{1B}[31m\nInjected\u{202E}"
        producer.identity.version = "1\tspoofed"
        producer.compatibility = .incompatibleDiscoveryProfile("1")

        let execution = await LocalMCPCLI.discover(
            timeout: 0,
            json: false,
            browser: StaticBrowser(instances: [producer])
        )

        #expect(execution.exitCode == 0)
        #expect(!execution.standardOutput.contains("\u{1B}"))
        #expect(!execution.standardOutput.contains("\u{202E}"))
        #expect(!execution.standardOutput.contains("Hostile\u{1B}[31m\nInjected"))
        #expect(execution.standardOutput.contains("Hostile\\u{1B}[31m\\u{A}Injected\\u{202E}"))
        #expect(execution.standardOutput.contains("version: 1\\u{9}spoofed"))
    }

    @Test("Empty discovery is a successful diagnostic result")
    func emptyDiscovery() async {
        let execution = await LocalMCPCLI.discover(
            timeout: 0,
            json: false,
            browser: StaticBrowser(instances: [])
        )
        #expect(execution == .success("No LocalMCPKit producers discovered.\n"))
    }

    @Test("Descriptor inspection distinguishes compatible and incompatible protocol documents")
    func inspectDescriptor() throws {
        let descriptor = ProducerDescriptor(
            instanceID: "11111111-1111-4111-8111-111111111111",
            server: ProducerIdentity(
                stableID: "com.example.diagnostic",
                displayName: "Example Producer",
                version: "1.0.0"
            ),
            channelBinding: try makeChannelBinding()
        )
        let compatibleURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: compatibleURL) }
        try JSONEncoder().encode(descriptor).write(to: compatibleURL)

        let compatible = LocalMCPCLI.inspectDescriptor(
            path: compatibleURL.path,
            json: false
        )
        #expect(compatible.exitCode == 0)
        #expect(compatible.standardOutput.contains("compatibility: compatible"))

        var incompatible = descriptor
        incompatible.mcp.protocolVersions = ["2099-01-01"]
        let incompatibleURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: incompatibleURL) }
        try JSONEncoder().encode(incompatible).write(to: incompatibleURL)

        let inspected = LocalMCPCLI.inspectDescriptor(path: incompatibleURL.path, json: true)
        #expect(inspected.exitCode == 0)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(inspected.standardOutput.utf8)) as? [String: Any]
        )
        #expect(json["compatibility"] as? String == "incompatible-mcp-protocol")
    }

    @Test("Descriptor reads enforce the profile response limit")
    func descriptorSizeLimit() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: 65_537).write(to: url)

        let execution = LocalMCPCLI.inspectDescriptor(path: url.path, json: false)
        #expect(execution.exitCode == 2)
        #expect(execution.standardError.contains("exceeds the 64 KiB"))
    }

    @Test("Descriptor inspection rejects duplicate JSON object keys")
    func descriptorDuplicateKeys() throws {
        let descriptor = ProducerDescriptor(
            instanceID: "11111111-1111-4111-8111-111111111111",
            server: ProducerIdentity(
                stableID: "com.example.diagnostic",
                displayName: "Example Producer",
                version: "1.0.0"
            )
        )
        let encoded = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
        let duplicate = encoded.replacingOccurrences(
            of: #""schemaVersion":"1""#,
            with: #""schemaVersion":"1","schemaVersion":"1""#
        )
        #expect(duplicate != encoded)
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(duplicate.utf8).write(to: url)

        let execution = LocalMCPCLI.inspectDescriptor(path: url.path, json: false)
        #expect(execution.exitCode == 2)
        #expect(execution.standardError.contains("could not be read or decoded"))
    }

    @Test("Descriptor text mode escapes terminal controls while JSON stays valid")
    func descriptorTextEscapesTerminalControls() throws {
        var descriptor = ProducerDescriptor(
            instanceID: "11111111-1111-4111-8111-111111111111",
            server: ProducerIdentity(
                stableID: "com.example.diagnostic",
                displayName: "Bad\u{1B}]0;title\u{7}\nName",
                version: "1.0\rspoofed"
            )
        )
        descriptor.mcp.protocolVersions = ["2025-11-25\u{1B}[2J\u{202E}\u{2029}"]
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(descriptor).write(to: url)

        let text = LocalMCPCLI.inspectDescriptor(path: url.path, json: false)
        #expect(text.exitCode == 0)
        #expect(!text.standardOutput.contains("\u{1B}"))
        #expect(!text.standardOutput.contains("\u{7}"))
        #expect(!text.standardOutput.contains("\r"))
        #expect(text.standardOutput.contains("Bad\\u{1B}]0;title\\u{7}\\u{A}Name"))
        #expect(text.standardOutput.contains("version: 1.0\\u{D}spoofed"))
        #expect(text.standardOutput.contains("2025-11-25\\u{1B}[2J"))

        let json = LocalMCPCLI.inspectDescriptor(path: url.path, json: true)
        #expect(json.exitCode == 0)
        #expect(!json.standardOutput.contains("\u{202E}"))
        #expect(!json.standardOutput.contains("\u{2029}"))
        #expect(json.standardOutput.contains("\\u202E"))
        #expect(json.standardOutput.contains("\\u2029"))
        _ = try JSONSerialization.jsonObject(with: Data(json.standardOutput.utf8))
    }

    private func makeChannelBinding() throws -> ProducerChannelBinding {
        ProducerChannelBinding(
            publicKey: try ChannelBindingPublicKey(
                rawRepresentation: Array(repeating: 0x52, count: 32)
            )
        )
    }

    private func makeInstance() throws -> ProducerInstance {
        ProducerInstance(
            identity: ProducerIdentity(
                stableID: "com.example.diagnostic",
                displayName: "Example Producer",
                version: "1.0.0"
            ),
            instanceID: "11111111-1111-4111-8111-111111111111",
            endpoint: try LoopbackEndpoint(port: 49_152, path: "/mcp"),
            descriptorURL: try LoopbackEndpoint(
                port: 49_152,
                path: "/local-mcp/v1/descriptor.json"
            )
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("local-mcp-cli-\(UUID().uuidString.lowercased())")
    }
}

private actor StaticBrowser: LocalMCPBrowsing {
    let instances: [ProducerInstance]

    init(instances: [ProducerInstance]) {
        self.instances = instances
    }

    func events() -> AsyncStream<DiscoveryEvent> {
        let replay = instances
        return AsyncStream<DiscoveryEvent> { continuation in
            for instance in replay {
                continuation.yield(.added(instance))
            }
        }
    }

    func snapshot() -> [ProducerInstance] { instances }
}
