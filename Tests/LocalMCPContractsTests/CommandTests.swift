import Foundation
import Testing
import LocalMCPContracts

@Suite("Command annotations and definitions")
struct CommandDefinitionTests {
    private var objectSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    }

    @Test("Annotation defaults are conservative and coding is stable")
    func annotationDefaultsAndCoding() throws {
        let defaults = CommandAnnotations()
        #expect(!defaults.readOnly)
        #expect(!defaults.idempotent)
        #expect(defaults.destructive)
        #expect(defaults.openWorld)

        let annotations = CommandAnnotations(
            readOnly: true,
            idempotent: true,
            destructive: false,
            openWorld: true
        )
        #expect(
            try encodedJSON(annotations) ==
                #"{"destructive":false,"idempotent":true,"openWorld":true,"readOnly":true}"#
        )
        #expect(
            try JSONDecoder().decode(
                CommandAnnotations.self,
                from: JSONEncoder().encode(annotations)
            ) == annotations
        )
    }

    @Test("A complete schema-first command definition is valid and Codable")
    func validDefinition() throws {
        let definition = CommandDefinition(
            name: "notes.search-v1",
            title: "Search Notes",
            description: "Search note metadata.",
            inputSchema: objectSchema,
            outputSchema: .object(["type": .string("object")]),
            annotations: CommandAnnotations(
                readOnly: true,
                idempotent: true,
                destructive: false,
                openWorld: false
            )
        )

        #expect(definition.isValid)
        #expect(
            try JSONDecoder().decode(
                CommandDefinition.self,
                from: JSONEncoder().encode(definition)
            ) == definition
        )
    }

    @Test("Command names enforce the public MCP-safe character and byte limits")
    func nameValidation() {
        #expect(CommandDefinition.isValidName("a"))
        #expect(CommandDefinition.isValidName("A-Z_0.9"))
        #expect(CommandDefinition.isValidName(String(repeating: "a", count: 128)))

        for name in [
            "",
            "contains space",
            "contains/slash",
            "naïve",
            String(repeating: "a", count: 129),
        ] {
            #expect(!CommandDefinition.isValidName(name))
        }
    }

    @Test("Definition validation rejects blank and oversized human-readable fields")
    func humanReadableFieldValidation() {
        let validDescription = CommandDefinition(
            name: "valid",
            title: String(repeating: "t", count: 256),
            description: String(repeating: "d", count: 1_024),
            inputSchema: objectSchema
        )
        #expect(validDescription.isValid)

        for description in [
            "",
            " \n\t ",
            "Safe\u{2028}spoofed",
            "Safe\u{2029}spoofed",
            String(repeating: "d", count: 1_025),
        ] {
            let definition = CommandDefinition(
                name: "invalid-description",
                description: description,
                inputSchema: objectSchema
            )
            #expect(!definition.isValid)
        }

        for title in [
            "",
            " \n\t ",
            "Safe\u{2028}spoofed",
            "Safe\u{2029}spoofed",
            String(repeating: "t", count: 257),
        ] {
            let definition = CommandDefinition(
                name: "invalid-title",
                title: title,
                description: "Description",
                inputSchema: objectSchema
            )
            #expect(!definition.isValid)
        }
    }

    @Test("Input and output schemas must be top-level JSON objects")
    func schemaValidation() {
        for invalidInput in [
            JSONValue.null,
            .array([]),
            .string("object"),
            .bool(true),
        ] {
            let definition = CommandDefinition(
                name: "invalid-input",
                description: "Description",
                inputSchema: invalidInput
            )
            #expect(!definition.isValid)
        }

        let noOutput = CommandDefinition(
            name: "no-output",
            description: "Description",
            inputSchema: objectSchema
        )
        #expect(noOutput.isValid)

        let objectOutput = CommandDefinition(
            name: "object-output",
            description: "Description",
            inputSchema: objectSchema,
            outputSchema: .object(["type": .string("object")])
        )
        #expect(objectOutput.isValid)

        for schemaWithoutObjectType in [
            JSONValue.object([:]),
            .object(["type": .string("array")]),
        ] {
            #expect(!CommandDefinition(
                name: "invalid-input-root-type",
                description: "Description",
                inputSchema: schemaWithoutObjectType
            ).isValid)
            #expect(!CommandDefinition(
                name: "invalid-output-root-type",
                description: "Description",
                inputSchema: objectSchema,
                outputSchema: schemaWithoutObjectType
            ).isValid)
        }

        for invalidOutput in [
            JSONValue.null,
            .array([]),
            .string("object"),
            .bool(false),
        ] {
            let definition = CommandDefinition(
                name: "invalid-output",
                description: "Description",
                inputSchema: objectSchema,
                outputSchema: invalidOutput
            )
            #expect(!definition.isValid)
        }
    }

    @Test("Schemas containing non-finite JSON numbers are rejected")
    func nonFiniteSchema() {
        let invalid = CommandDefinition(
            name: "invalid.schema",
            description: "Invalid schema",
            inputSchema: .object(["minimum": .number(.nan)])
        )
        #expect(invalid.isValid == false)
    }
}

@Suite("Command results and requests")
struct CommandResultTests {
    private struct EchoPayload: Codable, Sendable, Equatable {
        var message: String
        var count: UInt64
    }

    @Test("Structured results bridge typed payloads and retain optional text")
    func structuredResult() throws {
        let payload = EchoPayload(message: "hello", count: .max)
        let result = try CommandResult.structured(payload, text: "Human-readable summary")

        #expect(!result.isError)
        #expect(result.text == "Human-readable summary")
        #expect(result.structuredContent?["message"] == .string("hello"))
        #expect(result.structuredContent?["count"] == .unsignedInteger(.max))
        #expect(try result.decode(as: EchoPayload.self) == payload)

        let roundTrip = try JSONDecoder().decode(
            CommandResult.self,
            from: JSONEncoder().encode(result)
        )
        #expect(roundTrip == result)

        expectLocalMCPError(.commandFailed) {
            _ = try CommandResult.structured(42)
        }
        expectLocalMCPError(.commandFailed) {
            _ = try CommandResult.structured(["not", "an", "object"])
        }
    }

    @Test("Text and failure factories set only their intended fields")
    func textAndFailureFactories() {
        let text = CommandResult.text("done")
        #expect(text.text == "done")
        #expect(text.structuredContent == nil)
        #expect(!text.isError)

        let failure = CommandResult.failure(text: "safe failure")
        #expect(failure.text == "safe failure")
        #expect(failure.structuredContent == nil)
        #expect(failure.isError)
    }

    @Test("Missing, failed, and type-mismatched structured content maps to commandFailed")
    func structuredDecodeFailures() {
        expectLocalMCPError(.commandFailed) {
            try CommandResult.text("not structured").decode(as: EchoPayload.self)
        }
        expectLocalMCPError(.commandFailed) {
            try CommandResult(
                structuredContent: .object([
                    "message": .string("hello"),
                    "count": .integer(1),
                ]),
                isError: true
            ).decode(as: EchoPayload.self)
        }
        expectLocalMCPError(.commandFailed) {
            try CommandResult(
                structuredContent: .object(["unexpected": .bool(true)])
            ).decode(as: EchoPayload.self)
        }
    }

    @Test("Command call requests retain package-level invocation metadata")
    func callRequest() {
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let request = CommandCallRequest(
            name: "echo",
            arguments: .object(["message": .string("hello")]),
            requestID: "request-123",
            deadline: deadline
        )

        #expect(request.name == "echo")
        #expect(request.arguments["message"] == .string("hello"))
        #expect(request.requestID == "request-123")
        #expect(request.deadline == deadline)
    }

    @Test("Command context translates task cancellation to the stable package error")
    func contextCancellation() async throws {
        let context = CommandContext(
            consumer: validConsumerIdentity,
            grantID: "grant-123",
            requestID: "request-123",
            deadline: nil
        )

        #expect(context.consumer == validConsumerIdentity)
        #expect(context.grantID == "grant-123")
        #expect(context.requestID == "request-123")
        #expect(context.deadline == nil)
        try context.checkCancellation()

        let task = Task { () -> LocalMCPError? in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation is asserted through the package boundary below.
            }
            do {
                try context.checkCancellation()
                return nil
            } catch let error as LocalMCPError {
                return error
            } catch {
                return nil
            }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }
}
