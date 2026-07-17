import Darwin
import Foundation
import LocalMCPContracts
import LocalMCPDiscoveryBonjour
import LocalMCPProducer
import LocalMCPTesting

@main
struct LocalMCPSeparateProcessProducer {
    static func main() async {
        do {
            let options = try ProducerOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options: options)
        } catch let error as ExampleProcessError {
            writeError(error.message)
            exit(2)
        } catch let error as LocalMCPError {
            writeError(error.description)
            exit(1)
        } catch {
            writeError("The example producer failed.")
            exit(1)
        }
    }

    private static func run(options: ProducerOptions) async throws {
        let consumer = ConsumerIdentity(
            stableID: "com.example.localmcp.separate-consumer",
            displayName: "Separate Process Example Consumer",
            version: "1.0.0",
            installationID: "33333333-3333-4333-8333-333333333333"
        )
        let random = SystemRandomBytesGenerator()
        let credential = try await AuthorizationCredential(bytes: random.randomBytes(count: 32))
        let metadata = AuthorizationGrantMetadata(
            grantID: UUID().uuidString.lowercased(),
            producerID: "com.example.localmcp.separate-producer",
            consumer: consumer,
            issuedAt: Date()
        )

        let grantStore = InMemoryProducerGrantStore()
        let discovery = BonjourLocalMCPDiscovery()
        let producer = LocalMCPProducer(
            identity: ProducerIdentity(
                stableID: metadata.producerID,
                displayName: "Separate Process Example Producer",
                version: "1.0.0"
            ),
            transport: LocalMCPHTTPProducerTransport(),
            advertiser: discovery,
            grantStore: grantStore,
            approval: DenyNetworkPairingApprover()
        )

        try await producer.register(Self.echoDefinition) {
            (input: EchoInput, context: CommandContext) in
            try context.checkCancellation()
            guard !input.message.isEmpty, input.message.utf8.count <= 256 else {
                throw LocalMCPError.invalidCommandInput
            }
            let output = EchoOutput(message: input.message)
            return try .structured(output, text: output.message)
        }

        do {
            try await producer.start()
            guard case let .running(instance) = await producer.state else {
                throw LocalMCPError.invalidLifecycleState
            }
            guard let channelBinding = instance.channelBinding else {
                throw LocalMCPError.invalidConfiguration
            }

            // The pre-issued development grant is only usable against this
            // exact running instance: staging it as pending with the live
            // endpoint binding makes activation enforce instance identity and
            // channel binding, exactly like a freshly paired grant.
            let endpointBinding = AuthorizationEndpointBinding(
                instanceID: instance.instanceID,
                channelBinding: channelBinding
            )
            try await grantStore.stagePendingGrant(
                ProducerGrantRecord(
                    metadata: metadata,
                    credentialDigest: credential.digest,
                    state: .pending(endpointBinding)
                )
            )
            let rendezvous = DevGrantRendezvous(
                instance: instance,
                grant: metadata,
                accessToken: credential.withUnsafeEncodedValue { $0 }
            )
            try writeExclusiveSecretFile(
                try JSONEncoder().encode(rendezvous),
                path: options.rendezvousPath
            )

            print("ready \(instance.identity.stableID) \(instance.endpoint.url.absoluteString)")
            print("Press Return to stop the producer.")
            _ = readLine()
            try? FileManager.default.removeItem(atPath: options.rendezvousPath)
            await producer.stop()
        } catch {
            try? FileManager.default.removeItem(atPath: options.rendezvousPath)
            await producer.stop()
            throw error
        }
    }

    private static let echoDefinition = CommandDefinition(
        name: "example.echo",
        title: "Echo a message",
        description: "Returns the supplied development-fixture message.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(256),
                ]),
            ]),
            "required": .array([.string("message")]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("message")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .init(readOnly: true, idempotent: true)
    )

    private static func writeError(_ message: String) {
        let value = "Error: \(message)\n"
        FileHandle.standardError.write(Data(value.utf8))
    }
}

private struct ProducerOptions: Sendable {
    let rendezvousPath: String

    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.count == 3,
              arguments[0] == "--preissued-dev-grant",
              arguments[1] == "--rendezvous",
              !arguments[2].isEmpty
        else {
            throw ExampleProcessError(
                "Usage: local-mcp-example-producer --preissued-dev-grant --rendezvous <private-file>"
            )
        }
        return Self(rendezvousPath: arguments[2])
    }
}

private struct EchoInput: Codable, Sendable {
    let message: String
}

private struct EchoOutput: Codable, Sendable {
    let message: String
}

private struct DevGrantRendezvous: Codable, Sendable {
    let instance: ProducerInstance
    let grant: AuthorizationGrantMetadata
    let accessToken: String
}

private struct ExampleProcessError: Error, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct DenyNetworkPairingApprover: PairingApproving {
    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        .deny
    }
}

private func writeExclusiveSecretFile(_ data: Data, path: String) throws {
    let descriptor = open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
        throw ExampleProcessError("The private rendezvous file could not be created.")
    }
    var shouldRemove = true
    defer {
        close(descriptor)
        if shouldRemove { unlink(path) }
    }

    try data.withUnsafeBytes { buffer in
        guard var address = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let count = Darwin.write(descriptor, address, remaining)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ExampleProcessError("The private rendezvous file could not be written.")
            }
            address = address.advanced(by: count)
            remaining -= count
        }
    }
    guard fsync(descriptor) == 0 else {
        throw ExampleProcessError("The private rendezvous file could not be synchronized.")
    }
    shouldRemove = false
}
