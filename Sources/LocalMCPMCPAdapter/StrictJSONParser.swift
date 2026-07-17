import Foundation
import LocalMCPContracts

/// Small, bounded JSON parser that rejects duplicate object members. Foundation
/// decoders intentionally accept duplicates, which is unsuitable for pairing,
/// authorization, and JSON-RPC envelopes at a security boundary.
enum StrictJSONParser {
    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw LocalMCPError.invalidCommandInput }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth <= 64 else { throw LocalMCPError.invalidCommandInput }
            skipWhitespace()
            guard index < bytes.count else { throw LocalMCPError.invalidCommandInput }
            switch bytes[index] {
            case 0x6e:
                try consume("null")
                return .null
            case 0x74:
                try consume("true")
                return .bool(true)
            case 0x66:
                try consume("false")
                return .bool(false)
            case 0x22:
                return .string(try parseString())
            case 0x5b:
                return try parseArray(depth: depth)
            case 0x7b:
                return try parseObject(depth: depth)
            case 0x2d, 0x30...0x39:
                return try parseNumber()
            default:
                throw LocalMCPError.invalidCommandInput
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            index += 1
            skipWhitespace()
            if consumeIf(0x5d) { return .array([]) }
            var values: [JSONValue] = []
            while true {
                values.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                if consumeIf(0x5d) { break }
                guard consumeIf(0x2c) else { throw LocalMCPError.invalidCommandInput }
            }
            return .array(values)
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            index += 1
            skipWhitespace()
            if consumeIf(0x7d) { return .object([:]) }
            var values: [String: JSONValue] = [:]
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw LocalMCPError.invalidCommandInput
                }
                let key = try parseString()
                guard values[key] == nil else { throw LocalMCPError.invalidCommandInput }
                skipWhitespace()
                guard consumeIf(0x3a) else { throw LocalMCPError.invalidCommandInput }
                values[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x7d) { break }
                guard consumeIf(0x2c) else { throw LocalMCPError.invalidCommandInput }
            }
            return .object(values)
        }

        mutating func parseString() throws -> String {
            guard consumeIf(0x22) else { throw LocalMCPError.invalidCommandInput }
            var scalars: [UnicodeScalar] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 { return String(String.UnicodeScalarView(scalars)) }
                if byte == 0x5c {
                    guard index < bytes.count else { throw LocalMCPError.invalidCommandInput }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: scalars.append("\"".unicodeScalars.first!)
                    case 0x5c: scalars.append("\\".unicodeScalars.first!)
                    case 0x2f: scalars.append("/".unicodeScalars.first!)
                    case 0x62: scalars.append(UnicodeScalar(0x08)!)
                    case 0x66: scalars.append(UnicodeScalar(0x0c)!)
                    case 0x6e: scalars.append("\n".unicodeScalars.first!)
                    case 0x72: scalars.append("\r".unicodeScalars.first!)
                    case 0x74: scalars.append("\t".unicodeScalars.first!)
                    case 0x75:
                        let first = try parseHexScalar()
                        if (0xd800...0xdbff).contains(first) {
                            guard index + 1 < bytes.count,
                                  bytes[index] == 0x5c,
                                  bytes[index + 1] == 0x75
                            else { throw LocalMCPError.invalidCommandInput }
                            index += 2
                            let second = try parseHexScalar()
                            guard (0xdc00...0xdfff).contains(second) else {
                                throw LocalMCPError.invalidCommandInput
                            }
                            let combined = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                            guard let scalar = UnicodeScalar(combined) else {
                                throw LocalMCPError.invalidCommandInput
                            }
                            scalars.append(scalar)
                        } else {
                            guard !(0xdc00...0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
                                throw LocalMCPError.invalidCommandInput
                            }
                            scalars.append(scalar)
                        }
                    default:
                        throw LocalMCPError.invalidCommandInput
                    }
                } else if byte < 0x20 {
                    throw LocalMCPError.invalidCommandInput
                } else if byte < 0x80 {
                    scalars.append(UnicodeScalar(byte))
                } else {
                    index -= 1
                    let start = index
                    let length: Int
                    switch byte {
                    case 0xc2...0xdf: length = 2
                    case 0xe0...0xef: length = 3
                    case 0xf0...0xf4: length = 4
                    default: throw LocalMCPError.invalidCommandInput
                    }
                    guard start + length <= bytes.count,
                          let text = String(bytes: bytes[start..<(start + length)], encoding: .utf8),
                          text.utf8.count == length,
                          text.unicodeScalars.count == 1,
                          let scalar = text.unicodeScalars.first
                    else { throw LocalMCPError.invalidCommandInput }
                    scalars.append(scalar)
                    index = start + length
                }
            }
            throw LocalMCPError.invalidCommandInput
        }

        mutating func parseHexScalar() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw LocalMCPError.invalidCommandInput }
            var result: UInt32 = 0
            for byte in bytes[index..<(index + 4)] {
                result <<= 4
                switch byte {
                case 0x30...0x39: result += UInt32(byte - 0x30)
                case 0x41...0x46: result += UInt32(byte - 0x41 + 10)
                case 0x61...0x66: result += UInt32(byte - 0x61 + 10)
                default: throw LocalMCPError.invalidCommandInput
                }
            }
            index += 4
            return result
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            _ = consumeIf(0x2d)
            guard index < bytes.count else { throw LocalMCPError.invalidCommandInput }
            if consumeIf(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw LocalMCPError.invalidCommandInput
                }
            } else {
                guard consumeDigits(requireOne: true) else { throw LocalMCPError.invalidCommandInput }
            }

            var fractional = false
            if consumeIf(0x2e) {
                fractional = true
                guard consumeDigits(requireOne: true) else { throw LocalMCPError.invalidCommandInput }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                fractional = true
                index += 1
                if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d { index += 1 }
                guard consumeDigits(requireOne: true) else { throw LocalMCPError.invalidCommandInput }
            }

            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if !fractional {
                if token.first == "-", let signed = Int64(token) { return .integer(signed) }
                if let signed = Int64(token) { return .integer(signed) }
                if let unsigned = UInt64(token) { return .unsignedInteger(unsigned) }
                // An integral lexical token must remain lossless. Falling
                // through to Double here would silently round identifiers and
                // other security-relevant values outside the 64-bit domains.
                throw LocalMCPError.invalidCommandInput
            }
            guard let number = Double(token), number.isFinite else {
                throw LocalMCPError.invalidCommandInput
            }
            return .number(number)
        }

        mutating func consumeDigits(requireOne: Bool) -> Bool {
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return !requireOne || index > start
        }

        mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected
            else { throw LocalMCPError.invalidCommandInput }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
