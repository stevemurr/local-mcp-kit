import Foundation
import Testing
import LocalMCPContracts

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Every JSON kind round-trips without losing integer precision")
    func allKindsRoundTrip() throws {
        let value = JSONValue.object([
            "array": .array([
                .null,
                .bool(true),
                .string("hello"),
                .integer(.min),
                .unsignedInteger(.max),
                .number(1.25),
            ]),
            "object": .object(["nested": .string("value")]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
        #expect(decoded["object"]?["nested"] == .string("value"))
        #expect(JSONValue.string("not an object")["nested"] == nil)
    }

    @Test("Signed and unsigned integer limits decode as integer cases")
    func integerLimits() throws {
        let signedMinimum = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(String(Int64.min).utf8)
        )
        let signedMaximum = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(String(Int64.max).utf8)
        )
        let unsignedMaximum = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(String(UInt64.max).utf8)
        )

        #expect(signedMinimum == .integer(.min))
        #expect(signedMaximum == .integer(.max))
        #expect(unsignedMaximum == .unsignedInteger(.max))
    }

    @Test("Fractional JSON numbers remain fractional")
    func fractionalNumbers() throws {
        let positive = try JSONDecoder().decode(JSONValue.self, from: Data("1.25".utf8))
        let negative = try JSONDecoder().decode(JSONValue.self, from: Data("-0.5".utf8))

        #expect(positive == .number(1.25))
        #expect(negative == .number(-0.5))
    }

    @Test("Typed values encode to and decode from package-owned JSON")
    func typedBridge() throws {
        struct Payload: Codable, Sendable, Equatable {
            var name: String
            var signed: Int64
            var unsigned: UInt64
            var fraction: Double
            var enabled: Bool
        }

        let payload = Payload(
            name: "fixture",
            signed: .min,
            unsigned: .max,
            fraction: 3.5,
            enabled: true
        )
        let value = try JSONValue.encode(payload)

        #expect(value["name"] == .string("fixture"))
        #expect(value["signed"] == .integer(.min))
        #expect(value["unsigned"] == .unsignedInteger(.max))
        #expect(value["fraction"] == .number(3.5))
        #expect(value["enabled"] == .bool(true))
        #expect(try value.decode(as: Payload.self) == payload)
    }

    @Test("Non-finite numbers are rejected while encoding")
    func rejectsNonFiniteEncoding() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: (any Error).self) {
                try JSONEncoder().encode(JSONValue.number(value))
            }
        }
    }

    @Test("Non-finite numbers are rejected while decoding")
    func rejectsNonFiniteDecoding() {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        for fixture in ["\"NaN\"", "\"Infinity\"", "\"-Infinity\""] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(JSONValue.self, from: Data(fixture.utf8))
            }
        }
    }

    @Test("Ordinary non-finite spellings remain strings with a normal decoder")
    func nonFiniteSpellingIsAString() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("\"NaN\"".utf8))
        #expect(value == .string("NaN"))
    }

    @Test("Integral doubles use canonical integer equality and hashing")
    func canonicalIntegralNumbers() throws {
        let value = JSONValue.number(1.0)
        let decoded = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded == .integer(1))
        #expect(decoded == value)
        #expect(Set([value, .integer(1), .unsignedInteger(1)]).count == 1)
    }

    @Test("Invalid non-finite values remain reflexive but are not valid JSON")
    func nonFiniteValueSemantics() {
        let value = JSONValue.number(.nan)
        #expect(value == value)
        #expect(Set([value, value]).count == 1)
        #expect(value.isValidJSON == false)
        #expect(JSONValue.object(["nested": .array([value])]).isValidJSON == false)
    }
}
