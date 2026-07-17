import Foundation
import Testing
import LocalMCPContracts

func expectLocalMCPError<Result>(
    _ expected: LocalMCPError,
    _ operation: () throws -> Result,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try operation()
        Issue.record(
            "Expected \(expected), but the operation succeeded.",
            sourceLocation: sourceLocation
        )
    } catch let error as LocalMCPError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record(
            "Expected \(expected), but caught \(String(reflecting: error)).",
            sourceLocation: sourceLocation
        )
    }
}

func encodedJSON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

let validProducerIdentity = ProducerIdentity(
    stableID: "com.example.notes",
    displayName: "Notes",
    version: "1.0.0"
)

let validConsumerIdentity = ConsumerIdentity(
    stableID: "com.example.assistant",
    displayName: "Example Assistant",
    version: "2.0.0",
    installationID: "3e260e1c-bb58-4247-9733-47352fbc6c98"
)

let validInstanceID = "90f3fc7c-b047-4af2-bac1-33b5b0563d16"
