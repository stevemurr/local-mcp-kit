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

/// A transport-neutral service implemented by a producer and adapted to MCP later.
public protocol LocalMCPService: Sendable {
    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant

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

/// Resolves a discovered instance to an injected in-memory or network connection.
public protocol LocalMCPConnecting: Sendable {
    func connect(to instance: ProducerInstance) async throws -> any LocalMCPService
}
