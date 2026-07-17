import Darwin
import Foundation
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPDiscoveryBonjour

@main
struct LocalMCPCommand {
    static func main() async {
        let execution = await LocalMCPCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        write(execution.standardOutput, to: .standardOutput)
        write(execution.standardError, to: .standardError)
        if execution.exitCode != 0 {
            exit(execution.exitCode)
        }
    }

    private static func write(_ value: String, to handle: FileHandle) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        handle.write(data)
    }
}

struct LocalMCPCLIExecution: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    static func success(_ output: String) -> Self {
        Self(exitCode: 0, standardOutput: output, standardError: "")
    }

    static func failure(_ error: String) -> Self {
        Self(exitCode: 2, standardOutput: "", standardError: "Error: \(error)\n\n\(LocalMCPCLI.usage)")
    }
}

enum LocalMCPCLICommand: Sendable, Equatable {
    case help
    case version
    case discover(timeout: TimeInterval, json: Bool)
    case inspectDescriptor(path: String, json: Bool)
}

enum LocalMCPCLIParseError: Error, Sendable, Equatable {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidTimeout(String)
    case missingDescriptorPath

    var message: String {
        switch self {
        case let .unknownCommand(value):
            "Unknown command '\(terminalSafe(value))'."
        case let .unknownOption(value):
            "Unknown option '\(terminalSafe(value))'."
        case let .missingValue(option):
            "Option '\(terminalSafe(option))' requires a value."
        case let .invalidTimeout(value):
            "Timeout '\(terminalSafe(value))' must be a number from 0 through 60 seconds."
        case .missingDescriptorPath:
            "inspect-descriptor requires a file path or '-' for standard input."
        }
    }
}

enum LocalMCPCLIParser {
    static func parse(_ arguments: [String]) throws -> LocalMCPCLICommand {
        guard let command = arguments.first else { return .help }
        switch command {
        case "help", "--help", "-h":
            guard arguments.count == 1 else {
                throw LocalMCPCLIParseError.unknownOption(arguments[1])
            }
            return .help
        case "version", "--version":
            guard arguments.count == 1 else {
                throw LocalMCPCLIParseError.unknownOption(arguments[1])
            }
            return .version
        case "discover":
            return try parseDiscover(Array(arguments.dropFirst()))
        case "inspect-descriptor":
            return try parseDescriptor(Array(arguments.dropFirst()))
        default:
            throw LocalMCPCLIParseError.unknownCommand(command)
        }
    }

    private static func parseDiscover(_ arguments: [String]) throws -> LocalMCPCLICommand {
        var timeout: TimeInterval = 2
        var json = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                json = true
                index += 1
            case "--timeout":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw LocalMCPCLIParseError.missingValue("--timeout")
                }
                let value = arguments[valueIndex]
                guard let parsed = TimeInterval(value), parsed.isFinite, parsed >= 0, parsed <= 60 else {
                    throw LocalMCPCLIParseError.invalidTimeout(value)
                }
                timeout = parsed
                index += 2
            default:
                throw LocalMCPCLIParseError.unknownOption(arguments[index])
            }
        }
        return .discover(timeout: timeout, json: json)
    }

    private static func parseDescriptor(_ arguments: [String]) throws -> LocalMCPCLICommand {
        var path: String?
        var json = false
        for argument in arguments {
            if argument == "--json" {
                json = true
            } else if argument.hasPrefix("-") && argument != "-" {
                throw LocalMCPCLIParseError.unknownOption(argument)
            } else if path == nil {
                path = argument
            } else {
                throw LocalMCPCLIParseError.unknownOption(argument)
            }
        }
        guard let path else { throw LocalMCPCLIParseError.missingDescriptorPath }
        return .inspectDescriptor(path: path, json: json)
    }
}

enum LocalMCPCLI {
    // SwiftPM does not expose the enclosing package's release tag at runtime.
    // Keep this honest until the release process injects a version explicitly.
    static let version = "development"

    static let usage = """
    Usage:
      local-mcp discover [--timeout SECONDS] [--json]
      local-mcp inspect-descriptor <PATH|-> [--json]
      local-mcp version
      local-mcp help

    Commands:
      discover            Browse LocalOnly Bonjour and report untrusted producer state.
      inspect-descriptor  Decode and check a bounded LocalMCPKit descriptor document.

    Discovery never pairs, sends credentials, lists tools, or invokes commands.
    """ + "\n"

    static func run(arguments: [String]) async -> LocalMCPCLIExecution {
        let command: LocalMCPCLICommand
        do {
            command = try LocalMCPCLIParser.parse(arguments)
        } catch let error as LocalMCPCLIParseError {
            return .failure(error.message)
        } catch {
            return .failure("The command line could not be parsed.")
        }

        switch command {
        case .help:
            return .success(usage)
        case .version:
            return .success("local-mcp \(version)\n")
        case let .discover(timeout, json):
            return await discover(
                timeout: timeout,
                json: json,
                browser: BonjourLocalMCPDiscovery()
            )
        case let .inspectDescriptor(path, json):
            return inspectDescriptor(path: path, json: json)
        }
    }

    static func discover(
        timeout: TimeInterval,
        json: Bool,
        browser: any LocalMCPBrowsing
    ) async -> LocalMCPCLIExecution {
        let stream = await browser.events()
        let drain = Task {
            for await _ in stream {
                if Task.isCancelled { break }
            }
        }
        if timeout > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                drain.cancel()
                await drain.value
                return .failure("Discovery was cancelled.")
            }
        }
        drain.cancel()
        await drain.value

        let instances = await browser.snapshot().sorted(by: diagnosticOrder)
        do {
            return .success(try render(instances: instances, json: json))
        } catch {
            return .failure("Discovery results could not be encoded.")
        }
    }

    static func inspectDescriptor(path: String, json: Bool) -> LocalMCPCLIExecution {
        do {
            let data = try readBoundedDescriptor(path: path)
            try StrictJSONDuplicateKeyValidator.validate(data)
            let descriptor = try JSONDecoder().decode(ProducerDescriptor.self, from: data)
            let compatibility: String
            do {
                _ = try DescriptorCompatibility.validate(descriptor)
                compatibility = "compatible"
            } catch LocalMCPError.incompatibleMCPProtocol {
                compatibility = "incompatible-mcp-protocol"
            } catch {
                compatibility = "incompatible-discovery-profile"
            }
            let diagnostic = DescriptorDiagnostic(descriptor: descriptor, compatibility: compatibility)
            if json {
                return .success(try encodeJSON(diagnostic))
            }
            return .success(diagnostic.text)
        } catch DescriptorReadError.tooLarge {
            return .failure("The descriptor exceeds the 64 KiB diagnostic limit.")
        } catch {
            return .failure("The descriptor could not be read or decoded.")
        }
    }

    private static func render(instances: [ProducerInstance], json: Bool) throws -> String {
        let diagnostics = instances.map(ProducerDiagnostic.init)
        if json { return try encodeJSON(diagnostics) }
        guard !diagnostics.isEmpty else {
            return "No LocalMCPKit producers discovered.\n"
        }
        return diagnostics.map(\.text).joined(separator: "\n")
    }

    private static func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return escapeJSONPresentationControls(String(decoding: data, as: UTF8.self)) + "\n"
    }

    private static func diagnosticOrder(_ lhs: ProducerInstance, _ rhs: ProducerInstance) -> Bool {
        if lhs.identity.stableID != rhs.identity.stableID {
            return lhs.identity.stableID < rhs.identity.stableID
        }
        return lhs.instanceID < rhs.instanceID
    }

    private static func readBoundedDescriptor(path: String) throws -> Data {
        let handle: FileHandle
        let shouldClose: Bool
        if path == "-" {
            handle = .standardInput
            shouldClose = false
        } else {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            shouldClose = true
        }
        defer {
            if shouldClose { try? handle.close() }
        }
        var result = Data()
        while true {
            let chunk = try handle.read(upToCount: min(8_192, 65_537 - result.count)) ?? Data()
            if chunk.isEmpty { return result }
            result.append(chunk)
            guard result.count <= 65_536 else { throw DescriptorReadError.tooLarge }
        }
    }
}

private enum DescriptorReadError: Error {
    case tooLarge
}

private struct ProducerDiagnostic: Codable, Sendable {
    let stableID: String
    let displayName: String
    let version: String
    let instanceID: String
    let endpoint: String
    let descriptorURL: String
    let compatibility: String

    init(_ instance: ProducerInstance) {
        stableID = instance.identity.stableID
        displayName = instance.identity.displayName
        version = instance.identity.version
        instanceID = instance.instanceID
        endpoint = instance.endpoint.url.absoluteString
        descriptorURL = instance.descriptorURL.url.absoluteString
        switch instance.compatibility {
        case .compatible:
            compatibility = "compatible"
        case .incompatibleDiscoveryProfile:
            compatibility = "incompatible-discovery-profile"
        case .incompatibleMCPProtocol:
            compatibility = "incompatible-mcp-protocol"
        }
    }

    var text: String {
        """
        \(terminalSafe(displayName)) (\(terminalSafe(stableID)))
          compatibility: \(compatibility)
          instance: \(terminalSafe(instanceID))
          version: \(terminalSafe(version))
          endpoint: \(terminalSafe(endpoint))
          descriptor: \(terminalSafe(descriptorURL))
        """ + "\n"
    }
}

private struct DescriptorDiagnostic: Codable, Sendable {
    let schemaVersion: String
    let instanceID: String
    let stableID: String
    let displayName: String
    let version: String
    let transport: String
    let endpoint: String
    let protocolVersions: [String]
    let authentication: String
    let tools: Bool
    let compatibility: String

    init(descriptor: ProducerDescriptor, compatibility: String) {
        schemaVersion = descriptor.schemaVersion
        instanceID = descriptor.instanceID
        stableID = descriptor.server.stableID
        displayName = descriptor.server.displayName
        version = descriptor.server.version
        transport = descriptor.mcp.transport
        endpoint = descriptor.mcp.endpoint
        protocolVersions = descriptor.mcp.protocolVersions
        authentication = descriptor.mcp.authentication
        tools = descriptor.capabilities.tools
        self.compatibility = compatibility
    }

    var text: String {
        """
        \(terminalSafe(displayName)) (\(terminalSafe(stableID)))
          compatibility: \(compatibility)
          schema: \(terminalSafe(schemaVersion))
          instance: \(terminalSafe(instanceID))
          version: \(terminalSafe(version))
          transport: \(terminalSafe(transport))
          endpoint: \(terminalSafe(endpoint))
          protocols: \(protocolVersions.map(terminalSafe).joined(separator: ", "))
          authentication: \(terminalSafe(authentication))
          tools: \(tools)
        """ + "\n"
    }
}

/// Makes attacker-controlled diagnostic fields inert in a terminal while
/// preserving ordinary Unicode text. JSON mode relies on JSONEncoder escaping.
private func terminalSafe(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
        let codePoint = scalar.value
        let isDirectionalControl = (0x202A...0x202E).contains(codePoint)
            || (0x2066...0x2069).contains(codePoint)
        let isLineSeparator = codePoint == 0x2028 || codePoint == 0x2029
        if CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.illegalCharacters.contains(scalar)
            || isDirectionalControl
            || isLineSeparator
        {
            output += "\\u{\(String(codePoint, radix: 16, uppercase: true))}"
        } else {
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}

/// JSON escapes C0 controls itself, but it may emit bidi and Unicode line
/// separators literally. Escaping those scalars keeps raw diagnostic output
/// inert in terminals while preserving the decoded JSON string exactly.
private func escapeJSONPresentationControls(_ value: String) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
        let codePoint = scalar.value
        let requiresEscape = (0x2028...0x202E).contains(codePoint)
            || (0x2066...0x2069).contains(codePoint)
        if requiresEscape {
            output += "\\u" + String(format: "%04X", codePoint)
        } else {
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}
