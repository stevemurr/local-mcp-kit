import Darwin
import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPTesting

@main
struct LocalMCPSeparateProcessConsumer {
    static func main() async {
        do {
            let options = try ConsumerOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let output = try await run(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
        } catch let error as ExampleProcessError {
            writeError(error.message)
            exit(2)
        } catch let error as LocalMCPError {
            writeError(error.description)
            exit(1)
        } catch {
            writeError("The example consumer failed.")
            exit(1)
        }
    }

    private static func run(options: ConsumerOptions) async throws -> ConsumerOutput {
        let data = try readPrivateRendezvous(path: options.rendezvousPath)
        let rendezvous: DevGrantRendezvous
        do {
            rendezvous = try JSONDecoder().decode(DevGrantRendezvous.self, from: data)
        } catch {
            throw ExampleProcessError("The private rendezvous file is invalid.")
        }

        guard rendezvous.grant.producerID == rendezvous.instance.identity.stableID,
              rendezvous.grant.consumer == Self.consumerIdentity,
              rendezvous.grant.revokedAt == nil,
              !rendezvous.grant.isExpired(at: Date()),
              rendezvous.instance.compatibility == .compatible
        else {
            throw ExampleProcessError("The pre-issued development grant does not match the producer.")
        }

        let credential: AuthorizationCredential
        do {
            credential = try AuthorizationCredential(encodedValue: rendezvous.accessToken)
        } catch {
            throw ExampleProcessError("The pre-issued development grant is malformed.")
        }
        guard let channelBinding = rendezvous.instance.channelBinding else {
            throw ExampleProcessError("The producer instance does not declare a channel binding.")
        }

        // The grant is bound to the producer's running instance and channel
        // binding; an unbound grant is rejected as unauthorized.
        let grant = AuthorizationGrant(
            metadata: rendezvous.grant,
            credential: credential,
            endpointBinding: AuthorizationEndpointBinding(
                instanceID: rendezvous.instance.instanceID,
                channelBinding: channelBinding
            )
        )
        try FileManager.default.removeItem(atPath: options.rendezvousPath)

        let store = InMemoryConsumerGrantStore()
        try await store.save(grant)
        let consumer = LocalMCPConsumer(
            instance: rendezvous.instance,
            identity: Self.consumerIdentity,
            connector: LocalMCPHTTPConnector(),
            grantStore: store
        )

        do {
            let initialization = try await consumer.initialize(grant: grant)
            let tools = try await consumer.listTools(grant: grant)
            let result: EchoOutput = try await consumer.call(
                "example.echo",
                input: EchoInput(message: "hello across processes"),
                as: EchoOutput.self,
                grant: grant
            )
            let output = ConsumerOutput(
                producerID: initialization.server.stableID,
                protocolVersion: initialization.protocolVersion,
                tools: tools.map(\.name),
                result: result.message
            )
            await consumer.close()
            return output
        } catch {
            await consumer.close()
            throw error
        }
    }

    private static let consumerIdentity = ConsumerIdentity(
        stableID: "com.example.localmcp.separate-consumer",
        displayName: "Separate Process Example Consumer",
        version: "1.0.0",
        installationID: "33333333-3333-4333-8333-333333333333"
    )

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }
}

private struct ConsumerOptions: Sendable {
    let rendezvousPath: String

    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.count == 3,
              arguments[0] == "--preissued-dev-grant",
              arguments[1] == "--rendezvous",
              !arguments[2].isEmpty
        else {
            throw ExampleProcessError(
                "Usage: local-mcp-example-consumer --preissued-dev-grant --rendezvous <private-file>"
            )
        }
        return Self(rendezvousPath: arguments[2])
    }
}

private struct DevGrantRendezvous: Codable, Sendable {
    let instance: ProducerInstance
    let grant: AuthorizationGrantMetadata
    let accessToken: String
}

private struct EchoInput: Codable, Sendable {
    let message: String
}

private struct EchoOutput: Codable, Sendable {
    let message: String
}

private struct ConsumerOutput: Codable, Sendable {
    let producerID: String
    let protocolVersion: String
    let tools: [String]
    let result: String
}

private struct ExampleProcessError: Error, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private func readPrivateRendezvous(path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw ExampleProcessError("The private rendezvous file could not be opened.")
    }
    defer { close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_uid == geteuid(),
          (status.st_mode & 0o077) == 0,
          status.st_size >= 0,
          status.st_size <= 65_536
    else {
        throw ExampleProcessError(
            "The rendezvous path must be a private, owner-only regular file no larger than 64 KiB."
        )
    }

    var result = Data()
    result.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
            throw ExampleProcessError("The private rendezvous file could not be read.")
        }
        if count == 0 { break }
        guard result.count + count <= 65_536 else {
            throw ExampleProcessError("The private rendezvous file exceeds 64 KiB.")
        }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}
