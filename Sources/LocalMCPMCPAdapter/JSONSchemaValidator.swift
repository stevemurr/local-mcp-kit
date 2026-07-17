import Foundation
import LocalMCPContracts

/// Bounded JSON Schema validation for command arguments at the network trust
/// boundary. The implementation covers the assertion vocabulary commonly used
/// by MCP tools and resolves only same-document JSON Pointers. Remote references
/// are deliberately never fetched.
public enum MCPJSONSchemaValidator {
    /// Caps total recursive schema evaluations independently of tree depth. A
    /// small DAG referenced through combinators can otherwise expand into
    /// exponential work even when every individual path is shallow.
    private struct WorkBudget {
        private static let maximumVisits = 4_096
        private var remaining = maximumVisits

        mutating func consume() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    public static func accepts(_ value: JSONValue, schema: JSONValue) -> Bool {
        var budget = WorkBudget()
        return validate(value, schema: schema, root: schema, depth: 0, budget: &budget)
    }

    /// Checks that every assertion this runtime relies on is well formed and
    /// bounded. Unknown annotation/extension keywords remain forward compatible;
    /// external references and malformed known assertions fail registration.
    public static func isSupported(schema: JSONValue) -> Bool {
        var budget = WorkBudget()
        return schemaIsSupported(schema, root: schema, depth: 0, budget: &budget)
    }

    public static func validate(
        _ value: JSONValue,
        against schema: JSONValue,
        maximumEncodedBytes: Int
    ) throws {
        guard maximumEncodedBytes > 0,
              let encoded = try? JSONEncoder().encode(value),
              encoded.count <= maximumEncodedBytes,
              case .object = schema
        else { throw LocalMCPError.invalidCommandInput }

        var budget = WorkBudget()
        guard validate(value, schema: schema, root: schema, depth: 0, budget: &budget) else {
            throw LocalMCPError.invalidCommandInput
        }
    }

    private static func validate(
        _ value: JSONValue,
        schema: JSONValue,
        root: JSONValue,
        depth: Int,
        budget: inout WorkBudget
    ) -> Bool {
        guard depth <= 64, budget.consume() else { return false }

        if case let .bool(allowed) = schema { return allowed }
        guard case let .object(document) = schema else { return false }

        let unsupportedAssertions: Set<String> = [
            "contains", "minContains", "maxContains", "patternProperties",
            "propertyNames", "dependentRequired", "dependentSchemas", "if",
            "then", "else", "unevaluatedProperties", "unevaluatedItems",
            "pattern", "$dynamicRef", "$recursiveRef",
        ]
        guard document.keys.allSatisfy({ !unsupportedAssertions.contains($0) }) else { return false }

        if let reference = document["$ref"] {
            guard case let .string(pointer) = reference,
                  pointer.hasPrefix("#"),
                  let resolved = resolve(pointer: pointer, in: root)
            else { return false }
            guard validate(
                value,
                schema: resolved,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) else {
                return false
            }
        }

        if let constant = document["const"], constant != value { return false }
        if case let .array(values)? = document["enum"], !values.contains(value) { return false }

        if let type = document["type"], !matches(type: type, value: value) { return false }

        if case let .array(schemas)? = document["allOf"] {
            for schema in schemas where !validate(
                value,
                schema: schema,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) {
                return false
            }
        }

        if case let .array(schemas)? = document["anyOf"] {
            var matched = false
            for schema in schemas {
                if validate(
                    value,
                    schema: schema,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) {
                    matched = true
                    break
                }
            }
            if !matched { return false }
        }

        if case let .array(schemas)? = document["oneOf"] {
            var matchCount = 0
            for candidate in schemas {
                if validate(
                    value,
                    schema: candidate,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) {
                    matchCount += 1
                }
            }
            if matchCount != 1 { return false }
        }

        if let negated = document["not"], validate(
            value,
            schema: negated,
            root: root,
            depth: depth + 1,
            budget: &budget
        ) {
            return false
        }

        switch value {
        case let .object(object):
            if !validateObject(
                object,
                document: document,
                root: root,
                depth: depth,
                budget: &budget
            ) { return false }
        case let .array(array):
            if !validateArray(
                array,
                document: document,
                root: root,
                depth: depth,
                budget: &budget
            ) { return false }
        case let .string(string):
            if !validateString(string, document: document) { return false }
        case .integer, .unsignedInteger, .number:
            if !validateNumber(value, document: document) { return false }
        case .null, .bool:
            break
        }

        return true
    }

    private static func schemaIsSupported(
        _ schema: JSONValue,
        root: JSONValue,
        depth: Int,
        budget: inout WorkBudget
    ) -> Bool {
        guard depth <= 64, budget.consume() else { return false }
        if case .bool = schema { return true }
        guard case let .object(document) = schema else { return false }

        let unsupportedAssertions: Set<String> = [
            "contains", "minContains", "maxContains", "patternProperties",
            "propertyNames", "dependentRequired", "dependentSchemas", "if",
            "then", "else", "unevaluatedProperties", "unevaluatedItems",
            "pattern", "$dynamicRef", "$recursiveRef",
        ]
        guard document.keys.allSatisfy({ !unsupportedAssertions.contains($0) }) else { return false }

        if let reference = document["$ref"] {
            guard case let .string(pointer) = reference,
                  pointer.hasPrefix("#"),
                  let resolved = resolve(pointer: pointer, in: root)
            else { return false }
            guard schemaIsSupported(
                resolved,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) else {
                return false
            }
        }

        if let type = document["type"] {
            let validNames: Set<String> = ["null", "boolean", "object", "array", "number", "integer", "string"]
            switch type {
            case let .string(name):
                guard validNames.contains(name) else { return false }
            case let .array(names):
                var seen: Set<String> = []
                for nameValue in names {
                    guard case let .string(name) = nameValue,
                          validNames.contains(name),
                          seen.insert(name).inserted
                    else { return false }
                }
                guard !seen.isEmpty else { return false }
            default:
                return false
            }
        }

        if case let .array(values)? = document["enum"], values.isEmpty { return false }
        if let value = document["enum"], case .array = value {} else if document["enum"] != nil { return false }

        for keyword in ["allOf", "anyOf", "oneOf"] {
            if let value = document[keyword] {
                guard case let .array(schemas) = value, !schemas.isEmpty else { return false }
                for schema in schemas where !schemaIsSupported(
                    schema,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) {
                    return false
                }
            }
        }
        if let negated = document["not"], !schemaIsSupported(
            negated,
            root: root,
            depth: depth + 1,
            budget: &budget
        ) { return false }

        if let properties = document["properties"] {
            guard case let .object(schemas) = properties else { return false }
            for schema in schemas.values where !schemaIsSupported(
                schema,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) {
                return false
            }
        }
        if let additional = document["additionalProperties"] {
            guard schemaIsSupported(
                additional,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) else { return false }
        }
        if let required = document["required"] {
            guard case let .array(names) = required else { return false }
            let strings = names.compactMap { value -> String? in
                if case let .string(name) = value { return name }
                return nil
            }
            guard strings.count == names.count, Set(strings).count == strings.count else { return false }
        }

        if let prefixItems = document["prefixItems"] {
            guard case let .array(schemas) = prefixItems else { return false }
            for schema in schemas where !schemaIsSupported(
                schema,
                root: root,
                depth: depth + 1,
                budget: &budget
            ) {
                return false
            }
        }
        if let items = document["items"], !schemaIsSupported(
            items,
            root: root,
            depth: depth + 1,
            budget: &budget
        ) { return false }

        for keyword in ["minProperties", "maxProperties", "minItems", "maxItems", "minLength", "maxLength"] {
            if document[keyword] != nil, integer(document[keyword]) == nil { return false }
        }
        if let minimum = integer(document["minProperties"]),
           let maximum = integer(document["maxProperties"]), minimum > maximum { return false }
        if let minimum = integer(document["minItems"]),
           let maximum = integer(document["maxItems"]), minimum > maximum { return false }
        if let minimum = integer(document["minLength"]),
           let maximum = integer(document["maxLength"]), minimum > maximum { return false }

        if let unique = document["uniqueItems"], case .bool = unique {} else if document["uniqueItems"] != nil {
            return false
        }
        for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
            if document[keyword] != nil, decimal(document[keyword]) == nil { return false }
        }
        if let multiple = document["multipleOf"] {
            guard let value = decimal(multiple), value > 0 else { return false }
        }
        return true
    }

    private static func validateObject(
        _ value: [String: JSONValue],
        document: [String: JSONValue],
        root: JSONValue,
        depth: Int,
        budget: inout WorkBudget
    ) -> Bool {
        if let minimum = integer(document["minProperties"]), value.count < minimum { return false }
        if let maximum = integer(document["maxProperties"]), value.count > maximum { return false }

        if case let .array(required)? = document["required"] {
            for member in required {
                guard case let .string(name) = member, value[name] != nil else { return false }
            }
        }

        let properties: [String: JSONValue]
        if case let .object(schemas)? = document["properties"] {
            properties = schemas
        } else {
            properties = [:]
        }

        for (name, propertyValue) in value {
            if let propertySchema = properties[name] {
                guard validate(
                    propertyValue,
                    schema: propertySchema,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) else { return false }
                continue
            }

            if let additional = document["additionalProperties"] {
                if case let .bool(allowed) = additional {
                    if !allowed { return false }
                } else if !validate(
                    propertyValue,
                    schema: additional,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) {
                    return false
                }
            }
        }
        return true
    }

    private static func validateArray(
        _ value: [JSONValue],
        document: [String: JSONValue],
        root: JSONValue,
        depth: Int,
        budget: inout WorkBudget
    ) -> Bool {
        if let minimum = integer(document["minItems"]), value.count < minimum { return false }
        if let maximum = integer(document["maxItems"]), value.count > maximum { return false }
        if case .bool(true)? = document["uniqueItems"], Set(value).count != value.count { return false }

        if case let .array(prefix)? = document["prefixItems"] {
            for (index, itemSchema) in prefix.enumerated() where index < value.count {
                guard validate(
                    value[index],
                    schema: itemSchema,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) else {
                    return false
                }
            }
        }

        if let itemSchema = document["items"] {
            let startIndex: Int
            if case let .array(prefix)? = document["prefixItems"] {
                startIndex = min(prefix.count, value.count)
            } else {
                startIndex = 0
            }
            if case let .bool(allowed) = itemSchema {
                if !allowed, startIndex < value.count { return false }
            } else {
                for item in value.dropFirst(startIndex) where !validate(
                    item,
                    schema: itemSchema,
                    root: root,
                    depth: depth + 1,
                    budget: &budget
                ) {
                    return false
                }
            }
        }
        return true
    }

    private static func validateString(
        _ value: String,
        document: [String: JSONValue]
    ) -> Bool {
        let scalarCount = value.unicodeScalars.count
        if let minimum = integer(document["minLength"]), scalarCount < minimum { return false }
        if let maximum = integer(document["maxLength"]), scalarCount > maximum { return false }
        return true
    }

    private static func validateNumber(
        _ value: JSONValue,
        document: [String: JSONValue]
    ) -> Bool {
        guard let number = decimal(value) else { return false }
        if let minimum = decimal(document["minimum"]), number < minimum { return false }
        if let maximum = decimal(document["maximum"]), number > maximum { return false }
        if let minimum = decimal(document["exclusiveMinimum"]), number <= minimum { return false }
        if let maximum = decimal(document["exclusiveMaximum"]), number >= maximum { return false }
        if let divisor = decimal(document["multipleOf"]) {
            guard divisor > 0 else { return false }
            var quotient = number / divisor
            var rounded = Decimal()
            NSDecimalRound(&rounded, &quotient, 0, .plain)
            if quotient != rounded { return false }
        }
        return true
    }

    private static func matches(type: JSONValue, value: JSONValue) -> Bool {
        switch type {
        case let .string(name):
            return matches(typeName: name, value: value)
        case let .array(names):
            return names.contains {
                if case let .string(name) = $0 { return matches(typeName: name, value: value) }
                return false
            }
        default:
            return false
        }
    }

    private static func matches(typeName: String, value: JSONValue) -> Bool {
        switch (typeName, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string),
             ("array", .array), ("object", .object),
             ("integer", .integer), ("integer", .unsignedInteger),
             ("number", .integer), ("number", .unsignedInteger), ("number", .number):
            true
        case ("integer", .number(let number)):
            number.isFinite && number.rounded(.towardZero) == number
        default:
            false
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case let .integer(number) where number >= 0:
            Int(exactly: number)
        case let .unsignedInteger(number):
            Int(exactly: number)
        default:
            nil
        }
    }

    private static func decimal(_ value: JSONValue?) -> Decimal? {
        switch value {
        case let .integer(number):
            Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        case let .unsignedInteger(number):
            Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        case let .number(number) where number.isFinite:
            Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
        default:
            nil
        }
    }

    private static func resolve(pointer: String, in root: JSONValue) -> JSONValue? {
        guard pointer.first == "#" else { return nil }
        let fragment = String(pointer.dropFirst())
        if fragment.isEmpty { return root }
        guard fragment.first == "/", fragment.utf8.count <= 2_048 else { return nil }

        var current = root
        for rawToken in fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let token = decodePointerToken(String(rawToken)) else { return nil }
            switch current {
            case let .object(object):
                guard let next = object[token] else { return nil }
                current = next
            case let .array(array):
                guard let index = Int(token), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func decodePointerToken(_ raw: String) -> String? {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] != "~" {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let escape = raw.index(after: index)
            guard escape < raw.endIndex else { return nil }
            switch raw[escape] {
            case "0": output.append("~")
            case "1": output.append("/")
            default: return nil
            }
            index = raw.index(after: escape)
        }
        return output
    }
}
