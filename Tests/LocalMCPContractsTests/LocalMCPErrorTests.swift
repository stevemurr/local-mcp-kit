import Foundation
import Testing
import LocalMCPContracts

@Suite("LocalMCPError")
struct LocalMCPErrorTests {
    @Test("Every public error has its stable sanitized description")
    func stableDescriptions() {
        let cases: [(LocalMCPError, String)] = [
            (.invalidConfiguration, "The local MCP configuration is invalid."),
            (.invalidLifecycleState, "The operation is not valid in the producer's current state."),
            (.bindFailed, "The local MCP endpoint could not start."),
            (.advertisementFailed, "The local MCP producer could not be advertised."),
            (.incompatibleDiscoveryProfile, "The producer uses an incompatible discovery profile."),
            (.incompatibleMCPProtocol, "The producer does not support a compatible MCP protocol."),
            (.producerUnavailable, "The local MCP producer is unavailable."),
            (.pairingRequired, "Pairing is required before using this producer."),
            (.pairingDenied, "The producer did not approve the pairing request."),
            (.pairingExpired, "The pairing request expired."),
            (.pairingReplayed, "The pairing request cannot be reused."),
            (.unauthorized, "The request is not authorized."),
            (.grantRevoked, "The authorization grant was revoked."),
            (.invalidCommandDefinition, "The command definition is invalid."),
            (.commandAlreadyRegistered, "A command with that name is already registered."),
            (.invalidCommandInput, "The command input is invalid."),
            (.commandNotFound, "The requested command was not found."),
            (.commandFailed, "The command failed."),
            (.requestTimedOut, "The request timed out."),
            (.cancelled, "The operation was cancelled."),
            (.credentialStoreFailed, "The authorization credential store failed."),
        ]

        #expect(cases.count == 21)
        for (error, expectedDescription) in cases {
            #expect(error.description == expectedDescription)
            #expect(error.debugDescription == expectedDescription)
            #expect(error.errorDescription == expectedDescription)
            #expect(String(describing: error) == expectedDescription)
            #expect(String(reflecting: error) == expectedDescription)
        }
    }
}
