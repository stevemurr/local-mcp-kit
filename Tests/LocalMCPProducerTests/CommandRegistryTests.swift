import Foundation
import LocalMCPContracts
import LocalMCPProducer
import LocalMCPTesting
import Testing

private struct RegistryInput: Codable, Sendable, Equatable {
    let message: String
}

private struct RegistryOutput: Codable, Sendable, Equatable {
    let echoed: String
}

private let objectSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([:]),
])

private func definition(_ name: String) -> CommandDefinition {
    CommandDefinition(
        name: name,
        description: "Test command",
        inputSchema: objectSchema,
        outputSchema: objectSchema,
        annotations: .init(readOnly: true, idempotent: true)
    )
}

private let testConsumer = ConsumerIdentity(
    stableID: "com.example.consumer",
    displayName: "Consumer",
    version: "1.0.0",
    installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
)

private func testContext(deadline: Date? = nil) -> CommandContext {
    CommandContext(
        consumer: testConsumer,
        grantID: "grant-1",
        requestID: "request-1",
        deadline: deadline
    )
}

func expectLocalError(
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

@Suite("Command registry")
struct CommandRegistryTests {
    @Test("Registration is validated, unique, and lexically ordered")
    func registrationAndListing() async throws {
        let registry = CommandRegistry()
        try await registry.register(definition("z.last")) { (_: RegistryInput, _: CommandContext) in
            .text("z")
        }
        try await registry.register(definition("a.first")) { (_: RegistryInput, _: CommandContext) in
            .text("a")
        }

        #expect(await registry.definitions().map(\.name) == ["a.first", "z.last"])
        await expectLocalError(.commandAlreadyRegistered) {
            try await registry.register(definition("a.first")) { (_: RegistryInput, _: CommandContext) in
                .text("replacement")
            }
        }
        #expect(await registry.definitions().count == 2)

        let invalid = CommandDefinition(
            name: "bad name",
            description: "Bad",
            inputSchema: objectSchema
        )
        await expectLocalError(.invalidCommandDefinition) {
            try await registry.registerDynamic(invalid) { _, _ in .text("bad") }
        }
        #expect(await registry.definitions().count == 2)
    }

    @Test("Concurrent duplicate registration has one winner")
    func concurrentDuplicate() async {
        let registry = CommandRegistry()
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        try await registry.registerDynamic(definition("race")) { _, _ in .text("\(index)") }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var total = 0
            for await succeeded in group where succeeded { total += 1 }
            return total
        }
        #expect(successes == 1)
        #expect(await registry.definitions().count == 1)
    }

    @Test("Typed dispatch decodes input and receives complete context")
    func typedDispatch() async throws {
        let registry = CommandRegistry()
        try await registry.register(definition("echo")) { (input: RegistryInput, context: CommandContext) in
            #expect(context == testContext())
            return try .structured(RegistryOutput(echoed: input.message), text: input.message)
        }

        let result = try await registry.invoke(
            CommandCallRequest(
                name: "echo",
                arguments: try JSONValue.encode(RegistryInput(message: "hello")),
                requestID: "request-1"
            ),
            context: testContext()
        )
        #expect(try result.decode(as: RegistryOutput.self) == RegistryOutput(echoed: "hello"))
        #expect(result.text == "hello")
    }

    @Test("Invalid input and unknown commands never enter a handler")
    func dispatchGuards() async throws {
        let registry = CommandRegistry()
        let counter = InvocationCounter()
        try await registry.register(definition("echo")) { (_: RegistryInput, _: CommandContext) in
            await counter.increment()
            return .text("entered")
        }

        await expectLocalError(.invalidCommandInput) {
            _ = try await registry.invoke(
                CommandCallRequest(name: "echo", arguments: .object([:]), requestID: "r"),
                context: testContext()
            )
        }
        await expectLocalError(.commandNotFound) {
            _ = try await registry.invoke(
                CommandCallRequest(name: "absent", arguments: .object([:]), requestID: "r"),
                context: testContext()
            )
        }
        #expect(await counter.value == 0)
    }

    @Test("Handler failures are sanitized and cancellation stays distinct")
    func errorMapping() async throws {
        struct SecretError: Error {}
        let registry = CommandRegistry()
        try await registry.registerDynamic(definition("fails")) { _, _ in throw SecretError() }
        try await registry.registerDynamic(definition("cancels")) { _, _ in throw CancellationError() }

        await expectLocalError(.commandFailed) {
            _ = try await registry.invoke(
                .init(name: "fails", arguments: .object([:]), requestID: "r"),
                context: testContext()
            )
        }
        await expectLocalError(.cancelled) {
            _ = try await registry.invoke(
                .init(name: "cancels", arguments: .object([:]), requestID: "r"),
                context: testContext()
            )
        }
    }

    @Test("Deadlines are checked before and after execution")
    func deadlines() async throws {
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 100))
        let registry = CommandRegistry(clock: clock)
        let counter = InvocationCounter()
        try await registry.registerDynamic(definition("deadline")) { _, _ in
            await counter.increment()
            await clock.advance(by: 10)
            return .text("late")
        }

        await expectLocalError(.requestTimedOut) {
            _ = try await registry.invoke(
                .init(name: "deadline", arguments: .object([:]), requestID: "r"),
                context: testContext(deadline: Date(timeIntervalSince1970: 100))
            )
        }
        #expect(await counter.value == 0)

        await clock.set(Date(timeIntervalSince1970: 100))
        await expectLocalError(.requestTimedOut) {
            _ = try await registry.invoke(
                .init(name: "deadline", arguments: .object([:]), requestID: "r"),
                context: testContext(deadline: Date(timeIntervalSince1970: 105))
            )
        }
        #expect(await counter.value == 1)
    }

    @Test("A deadline actively cancels a suspended handler")
    func activeDeadline() async throws {
        let clock = ManualLocalMCPClock(now: Date(timeIntervalSince1970: 100))
        let registry = CommandRegistry(clock: clock, sleeper: ImmediateLocalMCPSleeper())
        let entered = InvocationCounter()
        try await registry.registerDynamic(definition("suspended")) { _, _ in
            await entered.increment()
            try await Task.sleep(nanoseconds: UInt64.max)
            return .text("unexpected")
        }
        await expectLocalError(.requestTimedOut) {
            _ = try await registry.invoke(
                .init(name: "suspended", arguments: .object([:]), requestID: "r"),
                context: testContext(deadline: Date(timeIntervalSince1970: 200))
            )
        }
        #expect(await entered.value <= 1)
    }

    @Test("Sealing freezes mutation without affecting calls")
    func sealing() async throws {
        let registry = CommandRegistry()
        try await registry.registerDynamic(definition("existing")) { _, _ in .text("ok") }
        await registry.seal()
        await expectLocalError(.invalidLifecycleState) {
            try await registry.registerDynamic(definition("new")) { _, _ in .text("new") }
        }
        #expect(await registry.definitions().map(\.name) == ["existing"])
        await registry.unseal()
        try await registry.registerDynamic(definition("new")) { _, _ in .text("new") }
        #expect(await registry.definitions().map(\.name) == ["existing", "new"])
    }
}

private actor InvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
