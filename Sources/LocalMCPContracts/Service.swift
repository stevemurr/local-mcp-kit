import Foundation

/// The package-level initialize response before MCP wire adaptation.
public struct LocalMCPInitialization: Codable, Sendable, Hashable {
    public var protocolVersion: String
    public var server: ProducerIdentity
    public var capabilities: ProducerCapabilities

    public init(
        protocolVersion: String,
        server: ProducerIdentity,
        capabilities: ProducerCapabilities
    ) {
        self.protocolVersion = protocolVersion
        self.server = server
        self.capabilities = capabilities
    }
}

/// A transport-neutral service implemented by a producer and adapted to MCP at
/// the in-memory or production HTTP boundary.
public protocol LocalMCPService: Sendable {
    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant

    /// Validates one bearer credential without decoding or dispatching an MCP
    /// message. Network transports use this gate after request-context checks
    /// and before parsing an attacker-controlled JSON-RPC body.
    func authenticate(credential: AuthorizationCredential?) async throws

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization

    /// The 2025-11-25 lifecycle notification sent after successful initialize.
    func initialized(credential: AuthorizationCredential?) async throws

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition]

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult
}

/// Pairing transports whose human-verification code is available only after a
/// server challenge implement this additive capability. The callback runs
/// after that challenge has been validated and before the consumer reveals its
/// committed pairing secret.
public protocol LocalMCPPairingCodeReportingService: LocalMCPService {
    func requestPairing(
        _ request: PairingRequest,
        displayVerificationCode: @Sendable (PairingVerificationCode) -> Void
    ) async throws -> AuthorizationGrant
}

/// An optional connection-lifecycle extension implemented by stateful
/// transports. Consumers use it to terminate a negotiated MCP session when a
/// producer disappears, its routing changes, or the consumer is explicitly
/// closed.
public protocol LocalMCPDisconnectingService: LocalMCPService {
    func disconnect(credential: AuthorizationCredential?) async
}

public extension LocalMCPService {
    /// Compatibility implementation for custom services. Implementations may
    /// override this with a cheaper authorization-only lookup.
    func authenticate(credential: AuthorizationCredential?) async throws {
        _ = try await listCommands(credential: credential)
    }
}

/// Resolves a discovered instance to an injected in-memory or network connection.
public protocol LocalMCPConnecting: Sendable {
    func connect(to instance: ProducerInstance) async throws -> any LocalMCPService
}
