import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPProducer
import LocalMCPTesting
import Testing

private struct EchoInput: Codable, Sendable, Equatable { let message: String }
private struct EchoOutput: Codable, Sendable, Equatable { let message: String }

private let integrationProducerIdentity = ProducerIdentity(
    stableID: "com.example.echo",
    displayName: "Echo",
    version: "1.0.0"
)

private func integrationConsumer(_ number: Int) -> ConsumerIdentity {
    ConsumerIdentity(
        stableID: "com.example.assistant.\(number)",
        displayName: "Assistant \(number)",
        version: "1.0.0",
        installationID: number == 1
            ? "3e260e1c-bb58-4247-9733-47352fbc6c98"
            : "95a519b9-d823-4b84-913f-27211ef70773"
    )
}

private let echoDefinition = CommandDefinition(
    name: "echo",
    title: "Echo",
    description: "Return the supplied text",
    inputSchema: .object([
        "type": .string("object"),
        "required": .array([.string("message")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    annotations: .init(readOnly: true, idempotent: true)
)

private func expectIntegrationError(
    _ expected: LocalMCPError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
    }
}

@Suite("In-memory vertical slice")
struct InMemoryVerticalSliceTests {
    @Test("discover → pair → initialize → list → call → revoke → remove")
    func completeFlow() async throws {
        let environment = InMemoryLocalMCPEnvironment()
        let transport = environment.makeProducerTransport()
        let producerStore = InMemoryProducerGrantStore()
        let recorder = InvocationRecorder()
        let producer = LocalMCPProducer(
            identity: integrationProducerIdentity,
            instanceID: "02b04cec-c3c5-4d20-b0f0-194f77a349ee",
            transport: transport,
            advertiser: environment.advertiser,
            grantStore: producerStore,
            approval: RecordingPairingApprover(),
            clock: ManualLocalMCPClock(),
            random: SequenceRandomBytesGenerator()
        )
        try await producer.register(echoDefinition) { (input: EchoInput, context: CommandContext) in
            await recorder.record(context)
            return try .structured(EchoOutput(message: input.message), text: input.message)
        }

        let eventStream = await environment.discovery.events()
        var events = eventStream.makeAsyncIterator()
        try await producer.start()

        guard case let .added(discovered)? = await events.next() else {
            Issue.record("Expected a discovered producer")
            return
        }
        #expect(discovered.identity == integrationProducerIdentity)
        #expect(discovered.compatibility == .compatible)

        let consumerStore = InMemoryConsumerGrantStore()
        let consumer = LocalMCPConsumer(
            instance: discovered,
            identity: integrationConsumer(1),
            connector: environment.directory,
            grantStore: consumerStore,
            clock: ManualLocalMCPClock(),
            random: SequenceRandomBytesGenerator()
        )

        await expectIntegrationError(.pairingRequired) {
            _ = try await consumer.listTools()
        }
        await expectIntegrationError(.pairingRequired) {
            let _: EchoOutput = try await consumer.call(
                "echo",
                input: EchoInput(message: "blocked"),
                as: EchoOutput.self
            )
        }
        #expect(await recorder.count == 0)

        let grant = try await consumer.pair()
        let initialization = try await consumer.initialize(grant: grant)
        #expect(initialization.protocolVersion == MCPProtocolVersion.current.rawValue)
        #expect(try await consumer.listTools(grant: grant) == [echoDefinition])
        let output: EchoOutput = try await consumer.call(
            "echo",
            input: EchoInput(message: "hello"),
            as: EchoOutput.self,
            grant: grant
        )
        #expect(output == EchoOutput(message: "hello"))
        #expect(await recorder.count == 1)
        #expect(await recorder.contexts.first?.consumer == integrationConsumer(1))
        #expect(await recorder.contexts.first?.grantID == grant.metadata.grantID)

        try await producer.revokeGrant(grant.metadata.grantID)
        await expectIntegrationError(.grantRevoked) {
            _ = try await consumer.call("echo", arguments: .object(["message": .string("again")]))
        }
        #expect(await recorder.count == 1)
        await expectIntegrationError(.pairingRequired) { _ = try await consumer.listTools() }

        await producer.stop()
        guard case let .removed(instanceID)? = await events.next() else {
            Issue.record("Expected producer removal")
            return
        }
        #expect(instanceID == discovered.instanceID)
        #expect(await environment.discovery.snapshot().isEmpty)
        #expect(await environment.directory.serviceCount() == 0)
        #expect(await transport.isActive() == false)
        #expect(await consumerStore.count() == 0)
    }

    @Test("Each consumer receives an independent grant")
    func twoConsumerIsolation() async throws {
        let environment = InMemoryLocalMCPEnvironment(firstPort: 43_000)
        let producer = LocalMCPProducer(
            identity: integrationProducerIdentity,
            instanceID: "20208e3d-f872-46d7-8847-f5a446d12299",
            transport: environment.makeProducerTransport(),
            advertiser: environment.advertiser,
            grantStore: InMemoryProducerGrantStore(),
            approval: RecordingPairingApprover(),
            clock: ManualLocalMCPClock(),
            random: SequenceRandomBytesGenerator()
        )
        let recorder = InvocationRecorder()
        try await producer.register(echoDefinition) { (input: EchoInput, context: CommandContext) in
            await recorder.record(context)
            return try .structured(EchoOutput(message: input.message))
        }
        try await producer.start()
        guard let discovered = await environment.discovery.snapshot().first else {
            Issue.record("Expected producer")
            return
        }

        let first = LocalMCPConsumer(
            instance: discovered,
            identity: integrationConsumer(1),
            connector: environment.directory,
            grantStore: InMemoryConsumerGrantStore(),
            random: SequenceRandomBytesGenerator(fallback: 20)
        )
        let second = LocalMCPConsumer(
            instance: discovered,
            identity: integrationConsumer(2),
            connector: environment.directory,
            grantStore: InMemoryConsumerGrantStore(),
            random: SequenceRandomBytesGenerator(fallback: 40)
        )

        let firstGrant = try await first.pair()
        let secondGrant = try await second.pair()
        #expect(firstGrant.credential != secondGrant.credential)
        let firstOutput: EchoOutput = try await first.call(
            "echo",
            input: EchoInput(message: "one"),
            as: EchoOutput.self
        )
        let secondOutput: EchoOutput = try await second.call(
            "echo",
            input: EchoInput(message: "two"),
            as: EchoOutput.self
        )
        #expect(firstOutput.message == "one")
        #expect(secondOutput.message == "two")

        try await producer.revokeGrant(firstGrant.metadata.grantID)
        await expectIntegrationError(.grantRevoked) { _ = try await first.listTools() }
        #expect(try await second.listTools().map(\.name) == ["echo"])
        #expect(await recorder.count == 2)
        await producer.stop()
    }
}

private actor InvocationRecorder {
    private(set) var contexts: [CommandContext] = []
    var count: Int { contexts.count }
    func record(_ context: CommandContext) { contexts.append(context) }
}
