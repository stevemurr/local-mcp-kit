import Foundation

/// The release identity shared by all running instances of one producer app.
public struct ProducerIdentity: Codable, Sendable, Hashable {
    public var stableID: String
    public var displayName: String
    public var version: String

    public init(stableID: String, displayName: String, version: String) {
        self.stableID = stableID
        self.displayName = displayName
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case stableID = "id"
        case displayName = "name"
        case version
    }
}

/// The claimed identity of one installed consumer app.
public struct ConsumerIdentity: Codable, Sendable, Hashable {
    public var stableID: String
    public var displayName: String
    public var version: String
    public var installationID: String

    public init(stableID: String, displayName: String, version: String, installationID: String) {
        self.stableID = stableID
        self.displayName = displayName
        self.version = version
        self.installationID = installationID
    }

    private enum CodingKeys: String, CodingKey {
        case stableID = "id"
        case displayName = "name"
        case version
        case installationID = "installationId"
    }
}

/// A resolved IPv4 loopback URL represented without a configurable host.
public struct LoopbackEndpoint: Codable, Sendable, Hashable {
    public let port: UInt16
    public let path: String

    public init(port: UInt16, path: String) throws {
        guard port != 0, Self.isValidRelativePath(path) else {
            throw LocalMCPError.invalidConfiguration
        }
        self.port = port
        self.path = path
    }

    public var url: URL {
        // Construction is guaranteed by validation in init and decode.
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public static func isValidRelativePath(_ value: String) -> Bool {
        guard value.first == "/",
              !value.hasPrefix("//"),
              !value.contains("\\"),
              !value.contains("?"),
              !value.contains("#"),
              !LocalMCPValidation.containsUnsafeTextScalar(value)
        else { return false }

        guard let decoded = value.removingPercentEncoding,
              decoded.first == "/",
              !decoded.hasPrefix("//"),
              !decoded.contains("\\"),
              !decoded.contains("?"),
              !decoded.contains("#"),
              !LocalMCPValidation.containsUnsafeTextScalar(decoded)
        else { return false }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(".") && !components.contains("..")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let port = try container.decode(UInt16.self, forKey: .port)
        let path = try container.decode(String.self, forKey: .path)
        try self.init(port: port, path: path)
    }
}

/// Compatibility state attached to a discovery result.
public enum ProducerCompatibility: Codable, Sendable, Hashable {
    case compatible
    case incompatibleDiscoveryProfile(String)
    case incompatibleMCPProtocol([String])
}

/// One live producer process resolved to loopback endpoints.
public struct ProducerInstance: Codable, Sendable, Hashable {
    public var identity: ProducerIdentity
    public var instanceID: String
    public var endpoint: LoopbackEndpoint
    public var descriptorURL: LoopbackEndpoint
    public var compatibility: ProducerCompatibility
    /// Present for discovered HTTP producers. In-memory transports may omit it.
    public var channelBinding: ProducerChannelBinding?

    public init(
        identity: ProducerIdentity,
        instanceID: String,
        endpoint: LoopbackEndpoint,
        descriptorURL: LoopbackEndpoint,
        compatibility: ProducerCompatibility = .compatible,
        channelBinding: ProducerChannelBinding? = nil
    ) {
        self.identity = identity
        self.instanceID = instanceID
        self.endpoint = endpoint
        self.descriptorURL = descriptorURL
        self.compatibility = compatibility
        self.channelBinding = channelBinding
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case instanceID = "instanceId"
        case endpoint
        case descriptorURL
        case compatibility
        case channelBinding
    }
}

public struct MCPDescriptor: Codable, Sendable, Hashable {
    public var transport: String
    public var endpoint: String
    public var protocolVersions: [String]
    public var authentication: String

    public init(
        transport: String = "localmcp-secure-http",
        endpoint: String = "/mcp",
        protocolVersions: [String] = [MCPProtocolVersion.current.rawValue],
        authentication: String = "pairing-channel"
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.protocolVersions = protocolVersions
        self.authentication = authentication
    }
}

public struct ProducerCapabilities: Codable, Sendable, Hashable {
    public var tools: Bool

    public init(tools: Bool = true) {
        self.tools = tools
    }
}

/// The non-secret, versioned producer descriptor served over loopback.
public struct ProducerDescriptor: Codable, Sendable, Hashable {
    public var schemaVersion: String
    public var instanceID: String
    public var server: ProducerIdentity
    public var mcp: MCPDescriptor
    public var capabilities: ProducerCapabilities
    /// Optional in the model so an old or malformed descriptor can be decoded
    /// and reported as incompatible. V1 compatibility requires this value.
    public var channelBinding: ProducerChannelBinding?

    public init(
        schemaVersion: String = DiscoveryProfileVersion.current.rawValue,
        instanceID: String,
        server: ProducerIdentity,
        mcp: MCPDescriptor = MCPDescriptor(),
        capabilities: ProducerCapabilities = ProducerCapabilities(),
        channelBinding: ProducerChannelBinding? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.instanceID = instanceID
        self.server = server
        self.mcp = mcp
        self.capabilities = capabilities
        self.channelBinding = channelBinding
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case instanceID = "instanceId"
        case server
        case mcp
        case capabilities
        case channelBinding
    }
}

public struct DiscoveryProfileVersion: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let current = DiscoveryProfileVersion(rawValue: "1")
}

public struct MCPProtocolVersion: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let current = MCPProtocolVersion(rawValue: "2025-11-25")
}

/// Validates a descriptor without confusing incompatibility with absence.
public enum DescriptorCompatibility {
    public static func validate(_ descriptor: ProducerDescriptor) throws -> MCPProtocolVersion {
        guard descriptor.schemaVersion == DiscoveryProfileVersion.current.rawValue else {
            throw LocalMCPError.incompatibleDiscoveryProfile
        }
        guard descriptor.mcp.transport == "localmcp-secure-http",
              descriptor.mcp.authentication == "pairing-channel",
              descriptor.mcp.endpoint == "/mcp",
              LocalMCPValidation.isCanonicalLowercaseUUID(descriptor.instanceID),
              descriptor.server.isValid,
              descriptor.capabilities.tools,
              !descriptor.mcp.protocolVersions.isEmpty,
              Set(descriptor.mcp.protocolVersions).count == descriptor.mcp.protocolVersions.count,
              descriptor.mcp.protocolVersions.allSatisfy({ !$0.isEmpty }),
              let channelBinding = descriptor.channelBinding,
              channelBinding.isSupported
        else {
            throw LocalMCPError.incompatibleDiscoveryProfile
        }
        guard descriptor.mcp.protocolVersions.contains(MCPProtocolVersion.current.rawValue) else {
            throw LocalMCPError.incompatibleMCPProtocol
        }
        return .current
    }
}

/// An add/update/remove transition from a long-lived discovery browser.
public enum DiscoveryEvent: Sendable, Hashable {
    case added(ProducerInstance)
    case updated(ProducerInstance)
    case removed(instanceID: String)
}

/// The intentionally small DNS-SD discovery payload.
public struct DiscoveryAdvertisement: Sendable, Hashable {
    public static let serviceType = "_appmcp._tcp"

    public var profileVersion: String
    public var stableProducerID: String
    public var endpointPath: String
    public var descriptorPath: String
    public var authentication: String

    public init(
        profileVersion: String = DiscoveryProfileVersion.current.rawValue,
        stableProducerID: String,
        endpointPath: String = "/mcp",
        descriptorPath: String = "/local-mcp/v1/descriptor.json",
        authentication: String = "pair-channel"
    ) {
        self.profileVersion = profileVersion
        self.stableProducerID = stableProducerID
        self.endpointPath = endpointPath
        self.descriptorPath = descriptorPath
        self.authentication = authentication
    }

    public var txtValues: [String: String] {
        [
            "v": profileVersion,
            "id": stableProducerID,
            "path": endpointPath,
            "desc": descriptorPath,
            "auth": authentication,
        ]
    }

    public init(txtValues: [String: String]) throws {
        guard let version = txtValues["v"],
              let id = txtValues["id"],
              let path = txtValues["path"],
              let descriptorPath = txtValues["desc"],
              let auth = txtValues["auth"],
              version == DiscoveryProfileVersion.current.rawValue,
              auth == "pair-channel",
              LocalMCPValidation.isStableID(id),
              path == "/mcp",
              descriptorPath == "/local-mcp/v1/descriptor.json"
        else {
            throw LocalMCPError.incompatibleDiscoveryProfile
        }
        self.init(
            profileVersion: version,
            stableProducerID: id,
            endpointPath: path,
            descriptorPath: descriptorPath,
            authentication: auth
        )
    }
}

public enum LocalMCPValidation {
    public static func isStableID(_ value: String) -> Bool {
        guard (3...253).contains(value.utf8.count),
              value.contains("."),
              value == value.lowercased()
        else { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.count <= 63 else { return false }
            return label.first != "-" && label.last != "-"
        }
    }

    public static func isDisplayName(_ value: String) -> Bool {
        !value.isEmpty &&
            value.unicodeScalars.count <= 128 &&
            !containsUnsafeTextScalar(value)
    }

    public static func isVersion(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 64 &&
            !containsUnsafeTextScalar(value)
    }

    /// Rejects controls plus the Unicode line/paragraph separators, which are
    /// not members of Foundation's `controlCharacters` set but can still alter
    /// the layout of security-sensitive prompts and diagnostic text.
    static func containsUnsafeTextScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) ||
                scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }

    public static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

public extension ProducerIdentity {
    var isValid: Bool {
        LocalMCPValidation.isStableID(stableID) &&
            LocalMCPValidation.isDisplayName(displayName) &&
            LocalMCPValidation.isVersion(version)
    }
}

public extension ConsumerIdentity {
    var isValid: Bool {
        LocalMCPValidation.isStableID(stableID) &&
            LocalMCPValidation.isDisplayName(displayName) &&
            LocalMCPValidation.isVersion(version) &&
            LocalMCPValidation.isCanonicalLowercaseUUID(installationID)
    }

    /// Authorization identity excludes presentation-only name and version.
    func representsSameInstallation(as other: ConsumerIdentity) -> Bool {
        stableID == other.stableID && installationID == other.installationID
    }
}
