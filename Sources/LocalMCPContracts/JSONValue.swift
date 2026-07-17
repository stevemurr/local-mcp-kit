import Foundation

/// A lossless representation of the JSON value kinds used at package boundaries.
///
/// Signed and unsigned integers are kept separate from fractional values so large
/// identifiers and sizes are not silently rounded through `Double`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Encodes an application value and converts it to package-owned JSON.
    public static func encode<Value: Encodable & Sendable>(_ value: Value) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// Decodes package-owned JSON as an application value.
    public func decode<Value: Decodable & Sendable>(as type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(self))
    }

    /// Returns the named member when this is an object.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    /// Whether this value can be represented by standards-compliant JSON.
    public var isValidJSON: Bool {
        switch self {
        case .null, .bool, .string, .integer, .unsignedInteger:
            true
        case let .number(value):
            value.isFinite
        case let .array(values):
            values.allSatisfy(\.isValidJSON)
        case let .object(values):
            values.values.allSatisfy(\.isValidJSON)
        }
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(lhs), .bool(rhs)): lhs == rhs
        case let (.string(lhs), .string(rhs)): lhs == rhs
        case let (.integer(lhs), .integer(rhs)): lhs == rhs
        case let (.unsignedInteger(lhs), .unsignedInteger(rhs)): lhs == rhs
        case let (.integer(lhs), .unsignedInteger(rhs)),
             let (.unsignedInteger(rhs), .integer(lhs)):
            lhs >= 0 && UInt64(lhs) == rhs
        case let (.number(lhs), .number(rhs)):
            lhs == rhs || lhs.bitPattern == rhs.bitPattern
        case let (.number(value), .integer(integer)),
             let (.integer(integer), .number(value)):
            Int64(exactly: value) == integer
        case let (.number(value), .unsignedInteger(integer)),
             let (.unsignedInteger(integer), .number(value)):
            UInt64(exactly: value) == integer
        case let (.array(lhs), .array(rhs)): lhs == rhs
        case let (.object(lhs), .object(rhs)): lhs == rhs
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case let .bool(value):
            hasher.combine(1)
            hasher.combine(value)
        case let .string(value):
            hasher.combine(2)
            hasher.combine(value)
        case let .integer(value):
            hashInteger(value, into: &hasher)
        case let .unsignedInteger(value):
            hashUnsignedInteger(value, into: &hasher)
        case let .number(value):
            if let integer = Int64(exactly: value) {
                hashInteger(integer, into: &hasher)
            } else if let integer = UInt64(exactly: value) {
                hashUnsignedInteger(integer, into: &hasher)
            } else {
                hasher.combine(5)
                hasher.combine(value == 0 ? Double(0).bitPattern : value.bitPattern)
            }
        case let .array(values):
            hasher.combine(6)
            hasher.combine(values.count)
            for value in values { hasher.combine(value) }
        case let .object(values):
            hasher.combine(7)
            hasher.combine(values.count)
            for key in values.keys.sorted() {
                hasher.combine(key)
                hasher.combine(values[key])
            }
        }
    }

    private func hashInteger(_ value: Int64, into hasher: inout Hasher) {
        if value >= 0 {
            hashUnsignedInteger(UInt64(value), into: &hasher)
        } else {
            hasher.combine(3)
            hasher.combine(value)
        }
    }

    private func hashUnsignedInteger(_ value: UInt64, into hasher: inout Hasher) {
        hasher.combine(4)
        hasher.combine(value)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite."
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The value is not valid JSON."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .unsignedInteger(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite.")
                )
            }
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
