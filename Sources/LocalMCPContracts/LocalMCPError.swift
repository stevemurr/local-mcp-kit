import Foundation

/// Stable failures surfaced by LocalMCPKit public APIs.
///
/// Cases deliberately avoid retaining framework errors, credentials, payloads,
/// pairing values, or other attacker-controlled text.
public enum LocalMCPError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidLifecycleState
    case bindFailed
    case advertisementFailed
    case incompatibleDiscoveryProfile
    case incompatibleMCPProtocol
    case producerUnavailable
    case pairingRequired
    case pairingDenied
    case pairingExpired
    case pairingReplayed
    case unauthorized
    case grantRevoked
    case invalidCommandDefinition
    case commandAlreadyRegistered
    case invalidCommandInput
    case commandNotFound
    case commandFailed
    case requestTimedOut
    case cancelled
    case credentialStoreFailed
}

extension LocalMCPError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidConfiguration: "The local MCP configuration is invalid."
        case .invalidLifecycleState: "The operation is not valid in the producer's current state."
        case .bindFailed: "The local MCP endpoint could not start."
        case .advertisementFailed: "The local MCP producer could not be advertised."
        case .incompatibleDiscoveryProfile: "The producer uses an incompatible discovery profile."
        case .incompatibleMCPProtocol: "The producer does not support a compatible MCP protocol."
        case .producerUnavailable: "The local MCP producer is unavailable."
        case .pairingRequired: "Pairing is required before using this producer."
        case .pairingDenied: "The producer did not approve the pairing request."
        case .pairingExpired: "The pairing request expired."
        case .pairingReplayed: "The pairing request cannot be reused."
        case .unauthorized: "The request is not authorized."
        case .grantRevoked: "The authorization grant was revoked."
        case .invalidCommandDefinition: "The command definition is invalid."
        case .commandAlreadyRegistered: "A command with that name is already registered."
        case .invalidCommandInput: "The command input is invalid."
        case .commandNotFound: "The requested command was not found."
        case .commandFailed: "The command failed."
        case .requestTimedOut: "The request timed out."
        case .cancelled: "The operation was cancelled."
        case .credentialStoreFailed: "The authorization credential store failed."
        }
    }

    public var debugDescription: String { description }
}
