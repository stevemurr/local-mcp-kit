import Foundation

/// Consumer-facing safety hints for one command.
public struct CommandAnnotations: Codable, Sendable, Hashable {
    public var readOnly: Bool
    public var idempotent: Bool
    public var destructive: Bool
    public var openWorld: Bool

    public init(
        readOnly: Bool = false,
        idempotent: Bool = false,
        destructive: Bool = true,
        openWorld: Bool = true
    ) {
        self.readOnly = readOnly
        self.idempotent = idempotent
        self.destructive = destructive
        self.openWorld = openWorld
    }
}

/// The stable, schema-first description of an app-owned command.
public struct CommandDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: CommandAnnotations

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: CommandAnnotations = CommandAnnotations()
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    public var isValid: Bool {
        guard Self.isValidName(name),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.utf8.count <= 1_024,
              !LocalMCPValidation.containsUnsafeTextScalar(description),
              title.map({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      $0.utf8.count <= 256 &&
                      !LocalMCPValidation.containsUnsafeTextScalar($0)
              }) ?? true,
              case .object = inputSchema,
              inputSchema["type"] == .string("object"),
              inputSchema.isValidJSON
        else { return false }

        if let outputSchema, case .object = outputSchema {
            return outputSchema["type"] == .string("object") && outputSchema.isValidJSON
        }
        return outputSchema == nil
    }

    public static func isValidName(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Sanitized identity and scheduling metadata supplied to a command handler.
public struct CommandContext: Sendable, Hashable {
    public let consumer: ConsumerIdentity
    public let grantID: String
    public let requestID: String
    public let deadline: Date?

    public init(consumer: ConsumerIdentity, grantID: String, requestID: String, deadline: Date?) {
        self.consumer = consumer
        self.grantID = grantID
        self.requestID = requestID
        self.deadline = deadline
    }

    public func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw LocalMCPError.cancelled
        }
    }
}

/// Package-owned command content independent of an MCP SDK.
public struct CommandResult: Codable, Sendable, Hashable {
    public var structuredContent: JSONValue?
    public var text: String?
    public var isError: Bool

    public init(structuredContent: JSONValue? = nil, text: String? = nil, isError: Bool = false) {
        self.structuredContent = structuredContent
        self.text = text
        self.isError = isError
    }

    public static func structured<Value: Encodable & Sendable>(
        _ value: Value,
        text: String? = nil
    ) throws -> CommandResult {
        let content = try JSONValue.encode(value)
        guard case .object = content else { throw LocalMCPError.commandFailed }
        return CommandResult(structuredContent: content, text: text)
    }

    public static func text(_ value: String) -> CommandResult {
        CommandResult(text: value)
    }

    public static func failure(text: String) -> CommandResult {
        CommandResult(text: text, isError: true)
    }

    public func decode<Value: Decodable & Sendable>(as type: Value.Type = Value.self) throws -> Value {
        guard !isError, let structuredContent else {
            throw LocalMCPError.commandFailed
        }
        do {
            return try structuredContent.decode(as: type)
        } catch {
            throw LocalMCPError.commandFailed
        }
    }
}

/// One package-level tool invocation before MCP wire adaptation.
public struct CommandCallRequest: Sendable, Hashable {
    public var name: String
    public var arguments: JSONValue
    public var requestID: String
    public var deadline: Date?

    public init(name: String, arguments: JSONValue, requestID: String, deadline: Date? = nil) {
        self.name = name
        self.arguments = arguments
        self.requestID = requestID
        self.deadline = deadline
    }
}
