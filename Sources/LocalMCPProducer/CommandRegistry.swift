import Foundation
import LocalMCPContracts
import LocalMCPMCPAdapter

/// A concurrency-safe, deterministic registry for typed app-owned commands.
public actor CommandRegistry {
    public typealias DynamicHandler = @Sendable (JSONValue, CommandContext) async throws -> CommandResult

    private struct Entry: Sendable {
        let definition: CommandDefinition
        let handler: DynamicHandler
    }

    private var entries: [String: Entry] = [:]
    private var sealed = false
    private let clock: any LocalMCPClock
    private let sleeper: any LocalMCPSleeping

    public init(
        clock: any LocalMCPClock = SystemLocalMCPClock(),
        sleeper: any LocalMCPSleeping = SystemLocalMCPSleeper()
    ) {
        self.clock = clock
        self.sleeper = sleeper
    }

    public func register<Input: Decodable & Sendable>(
        _ definition: CommandDefinition,
        handler: @escaping @Sendable (Input, CommandContext) async throws -> CommandResult
    ) throws {
        try registerDynamic(definition) { arguments, context in
            let input: Input
            do {
                input = try arguments.decode(as: Input.self)
            } catch {
                throw LocalMCPError.invalidCommandInput
            }
            return try await handler(input, context)
        }
    }

    public func registerDynamic(
        _ definition: CommandDefinition,
        handler: @escaping DynamicHandler
    ) throws {
        guard !sealed else { throw LocalMCPError.invalidLifecycleState }
        guard definition.isValid,
              MCPJSONSchemaValidator.isSupported(schema: definition.inputSchema),
              definition.outputSchema.map({ MCPJSONSchemaValidator.isSupported(schema: $0) }) ?? true
        else { throw LocalMCPError.invalidCommandDefinition }
        guard entries[definition.name] == nil else {
            throw LocalMCPError.commandAlreadyRegistered
        }
        entries[definition.name] = Entry(definition: definition, handler: handler)
    }

    public func definitions() -> [CommandDefinition] {
        entries.values.map(\.definition).sorted { $0.name < $1.name }
    }

    public func seal() {
        sealed = true
    }

    public func unseal() {
        sealed = false
    }

    public func invoke(
        _ request: CommandCallRequest,
        context: CommandContext
    ) async throws -> CommandResult {
        guard let entry = entries[request.name] else {
            throw LocalMCPError.commandNotFound
        }

        guard MCPJSONSchemaValidator.accepts(
            request.arguments,
            schema: entry.definition.inputSchema
        ) else {
            throw LocalMCPError.invalidCommandInput
        }

        try await checkCancellationAndDeadline(context.deadline)

        do {
            // The sendable closure is copied out of actor state before suspension.
            // Actor reentrancy therefore permits listing and unrelated calls while
            // a host handler is suspended.
            let operation: LocalMCPAsyncOperation<CommandResult>
            if let deadline = context.deadline {
                let remaining = deadline.timeIntervalSince(await clock.now())
                guard remaining > 0 else { throw LocalMCPError.requestTimedOut }
                operation = LocalMCPAsyncOperation(
                    timeout: { [sleeper] in
                        try await sleeper.sleep(for: remaining)
                    },
                    timeoutError: LocalMCPError.requestTimedOut
                ) {
                    try await entry.handler(request.arguments, context)
                }
            } else {
                operation = LocalMCPAsyncOperation {
                    try await entry.handler(request.arguments, context)
                }
            }
            let result = try await operation.value(cancellationError: LocalMCPError.cancelled)
            try await checkCancellationAndDeadline(context.deadline)
            if let content = result.structuredContent {
                // MCP CallToolResult.structuredContent is an object whenever it
                // is present, for successful and error results alike.
                guard case .object = content else {
                    throw LocalMCPError.commandFailed
                }
            }
            if !result.isError, let outputSchema = entry.definition.outputSchema {
                guard let content = result.structuredContent,
                      MCPJSONSchemaValidator.accepts(content, schema: outputSchema)
                else { throw LocalMCPError.commandFailed }
            }
            return result
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as LocalMCPError {
            switch error {
            case .invalidCommandInput, .cancelled, .requestTimedOut:
                throw error
            default:
                throw LocalMCPError.commandFailed
            }
        } catch {
            throw LocalMCPError.commandFailed
        }
    }

    private func checkCancellationAndDeadline(_ deadline: Date?) async throws {
        if Task.isCancelled { throw LocalMCPError.cancelled }
        if let deadline, await clock.now() >= deadline {
            throw LocalMCPError.requestTimedOut
        }
    }
}
