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

    @Test("JSON Schema object, string, numeric, and array assertions run before handlers")
    func schemaAssertionsGuardHandlers() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("query"), .string("limit"), .string("scopes")]),
            "additionalProperties": .bool(false),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "minLength": .integer(3),
                    "maxLength": .integer(12),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                    "maximum": .integer(100),
                    "multipleOf": .integer(5),
                ]),
                "scopes": .object([
                    "type": .string("array"),
                    "minItems": .integer(1),
                    "maxItems": .integer(2),
                    "uniqueItems": .bool(true),
                    "items": .object([
                        "enum": .array([.string("home"), .string("icloud")]),
                    ]),
                ]),
            ]),
        ])
        let registry = CommandRegistry()
        let counter = InvocationCounter()
        try await registry.registerDynamic(
            CommandDefinition(name: "search", description: "Search", inputSchema: schema)
        ) { _, _ in
            await counter.increment()
            return .text("ok")
        }

        let valid: JSONValue = .object([
            "query": .string("road map"),
            "limit": .integer(25),
            "scopes": .array([.string("home"), .string("icloud")]),
        ])
        _ = try await registry.invoke(
            .init(name: "search", arguments: valid, requestID: "valid"),
            context: testContext()
        )

        let invalidValues: [JSONValue] = [
            .object(["query": .string("ab"), "limit": .integer(25), "scopes": .array([.string("home")])]),
            .object(["query": .string("a query that is too long"), "limit": .integer(25), "scopes": .array([.string("home")])]),
            .object(["query": .string("roadmap"), "limit": .integer(24), "scopes": .array([.string("home")])]),
            .object(["query": .string("roadmap"), "limit": .integer(25), "scopes": .array([.string("home"), .string("home")])]),
            .object(["query": .string("roadmap"), "limit": .integer(25), "scopes": .array([.string("all")])]),
            .object(["query": .string("roadmap"), "limit": .integer(25), "scopes": .array([.string("home")]), "extra": .bool(true)]),
        ]
        for (index, value) in invalidValues.enumerated() {
            await expectLocalError(.invalidCommandInput) {
                _ = try await registry.invoke(
                    .init(name: "search", arguments: value, requestID: "invalid-\(index)"),
                    context: testContext()
                )
            }
        }
        #expect(await counter.value == 1)
    }

    @Test("JSON Schema combinators, nullable types, const, and tuple prefixes are enforced")
    func schemaCombinators() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("mode"), .string("value"), .string("tuple")]),
            "properties": .object([
                "mode": .object(["const": .string("exact")]),
                "value": .object([
                    "anyOf": .array([
                        .object(["type": .string("null")]),
                        .object([
                            "type": .string("string"),
                            "not": .object(["enum": .array([.string("forbidden")])]),
                        ]),
                    ]),
                ]),
                "tuple": .object([
                    "type": .string("array"),
                    "prefixItems": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("integer")]),
                    ]),
                    "items": .bool(false),
                ]),
            ]),
        ])
        let registry = CommandRegistry()
        try await registry.registerDynamic(
            CommandDefinition(name: "combined", description: "Combined", inputSchema: schema)
        ) { _, _ in .text("ok") }

        _ = try await registry.invoke(
            .init(
                name: "combined",
                arguments: .object([
                    "mode": .string("exact"),
                    "value": .null,
                    "tuple": .array([.string("item"), .integer(2)]),
                ]),
                requestID: "valid"
            ),
            context: testContext()
        )
        await expectLocalError(.invalidCommandInput) {
            _ = try await registry.invoke(
                .init(
                    name: "combined",
                    arguments: .object([
                        "mode": .string("exact"),
                        "value": .string("forbidden"),
                        "tuple": .array([.string("item"), .integer(2), .integer(3)]),
                    ]),
                    requestID: "invalid"
                ),
                context: testContext()
            )
        }
    }

    @Test("Unsupported or malformed assertion schemas fail registration")
    func malformedSchemasFailRegistration() async {
        let invalidSchemas: [JSONValue] = [
            .object(["type": .string("mystery")]),
            .object(["required": .array([.string("value"), .string("value")])]),
            .object(["pattern": .string("^[a-z]+$")]),
            .object(["$dynamicRef": .string("#/$defs/value")]),
            .object(["minimum": .string("zero")]),
            .object(["minItems": .integer(2), "maxItems": .integer(1)]),
            .object(["$ref": .string("#/$defs/value")]),
        ]
        for (index, schema) in invalidSchemas.enumerated() {
            let registry = CommandRegistry()
            await expectLocalError(.invalidCommandDefinition) {
                try await registry.registerDynamic(
                    CommandDefinition(name: "invalid-\(index)", description: "Invalid", inputSchema: schema)
                ) { _, _ in .text("unreachable") }
            }
        }
    }

    @Test("Schema registration has a total work budget for branching local references")
    func schemaWorkBudget() async {
        var definitions: [String: JSONValue] = [
            "level0": .object(["type": .string("object")]),
        ]
        for level in 1 ... 13 {
            let reference = JSONValue.object([
                "$ref": .string("#/$defs/level\(level - 1)"),
            ])
            definitions["level\(level)"] = .object([
                "allOf": .array([reference, reference]),
            ])
        }
        let branchingSchema: JSONValue = .object([
            "$defs": .object(definitions),
            "$ref": .string("#/$defs/level13"),
        ])
        let registry = CommandRegistry()

        await expectLocalError(.invalidCommandDefinition) {
            try await registry.registerDynamic(
                CommandDefinition(
                    name: "budgeted",
                    description: "Must not expand a schema DAG without a bound.",
                    inputSchema: branchingSchema
                )
            ) { _, _ in .text("unreachable") }
        }
    }

    @Test("Local references evaluate sibling assertions and reject malformed pointer escapes")
    func localReferenceSemantics() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "$defs": .object([
                "base": .object([
                    "type": .string("object"),
                    "required": .array([.string("value")]),
                    "properties": .object([
                        "value": .object(["type": .string("string")]),
                    ]),
                ]),
            ]),
            "$ref": .string("#/$defs/base"),
            "maxProperties": .integer(1),
        ])
        let registry = CommandRegistry()
        try await registry.registerDynamic(
            CommandDefinition(name: "referenced", description: "Referenced", inputSchema: schema)
        ) { _, _ in .text("ok") }

        _ = try await registry.invoke(
            .init(
                name: "referenced",
                arguments: .object(["value": .string("accepted")]),
                requestID: "valid-reference"
            ),
            context: testContext()
        )
        await expectLocalError(.invalidCommandInput) {
            _ = try await registry.invoke(
                .init(
                    name: "referenced",
                    arguments: .object([
                        "value": .string("rejected"),
                        "extra": .bool(true),
                    ]),
                    requestID: "sibling-assertion"
                ),
                context: testContext()
            )
        }

        let malformedPointer: JSONValue = .object([
            "$defs": .object([
                "value": .object(["type": .string("string")]),
            ]),
            "$ref": .string("#/$defs/~2value"),
        ])
        await expectLocalError(.invalidCommandDefinition) {
            try await CommandRegistry().registerDynamic(
                CommandDefinition(
                    name: "malformed-reference",
                    description: "Malformed reference",
                    inputSchema: malformedPointer
                )
            ) { _, _ in .text("unreachable") }
        }
    }

    @Test("Structured results must satisfy their declared output schema")
    func outputSchemaIsEnforced() async throws {
        let outputSchema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("count")]),
            "properties": .object([
                "count": .object(["type": .string("integer"), "minimum": .integer(0)]),
            ]),
        ])
        let registry = CommandRegistry()
        try await registry.registerDynamic(
            CommandDefinition(
                name: "bad-output",
                description: "Bad output",
                inputSchema: objectSchema,
                outputSchema: outputSchema
            )
        ) { _, _ in
            CommandResult(structuredContent: .object(["count": .integer(-1)]))
        }

        await expectLocalError(.commandFailed) {
            _ = try await registry.invoke(
                .init(name: "bad-output", arguments: .object([:]), requestID: "r"),
                context: testContext()
            )
        }
    }

    @Test("Structured content is always an object, even without an output schema")
    func structuredContentWireShapeIsEnforced() async throws {
        let registry = CommandRegistry()
        try await registry.registerDynamic(
            CommandDefinition(
                name: "scalar-success",
                description: "Invalid scalar result",
                inputSchema: objectSchema
            )
        ) { _, _ in
            CommandResult(structuredContent: .string("not an object"))
        }
        try await registry.registerDynamic(
            CommandDefinition(
                name: "scalar-error",
                description: "Invalid scalar error result",
                inputSchema: objectSchema
            )
        ) { _, _ in
            CommandResult(structuredContent: .array([]), isError: true)
        }

        for name in ["scalar-success", "scalar-error"] {
            await expectLocalError(.commandFailed) {
                _ = try await registry.invoke(
                    .init(name: name, arguments: .object([:]), requestID: name),
                    context: testContext()
                )
            }
        }
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

    @Test("A deadline does not join a handler that ignores cancellation")
    func nonCooperativeDeadline() async throws {
        let registry = CommandRegistry()
        let gate = NonCooperativeCommandGate()
        try await registry.registerDynamic(definition("noncooperative")) { _, _ in
            await gate.run()
        }
        let call = Task {
            try await registry.invoke(
                .init(name: "noncooperative", arguments: .object([:]), requestID: "bounded"),
                context: testContext(deadline: Date().addingTimeInterval(0.05))
            )
        }
        await gate.waitUntilEntered()

        let clock = ContinuousClock()
        let started = clock.now
        await expectLocalError(.requestTimedOut) { _ = try await call.value }
        #expect(started.duration(to: clock.now) < .seconds(1))
        #expect(await !gate.didFinish)

        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await gate.didFinish)
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

private actor NonCooperativeCommandGate {
    private var entered = false
    private var finished = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var didFinish: Bool { finished }

    func run() async -> CommandResult {
        entered = true
        let currentEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in currentEntryWaiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        finished = true
        return .text("late success")
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}
