import Foundation
import LocalMCPContracts

/// Package-internal HTTP request value used between the numeric-loopback
/// listener and the MCP wire adapter. No networking framework type crosses the
/// adapter boundary.
public struct MCPHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: [String]]
    public let body: Data

    public init(
        method: String,
        path: String,
        headers: [String: [String]],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func headerValues(_ name: String) -> [String] {
        headers[name.lowercased()] ?? []
    }

    public func singleHeader(_ name: String) -> String? {
        let values = headerValues(name)
        return values.count == 1 ? values[0] : nil
    }
}

/// Package-internal HTTP response independent of Network.framework.
public struct MCPHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func json(
        statusCode: Int,
        value: JSONValue,
        headers: [String: String] = [:]
    ) -> MCPHTTPResponse {
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data()
        return MCPHTTPResponse(statusCode: statusCode, headers: responseHeaders, body: body)
    }
}

/// Listener and adapter bounds. Values may be lowered by tests, but cannot be
/// raised above the security-model ceilings.
public struct MCPHTTPServerLimits: Sendable, Hashable {
    public let maximumHeaderBytes: Int
    public let maximumHeaderFields: Int
    public let headerTimeout: TimeInterval
    public let maximumMCPBodyBytes: Int
    public let maximumPairingBodyBytes: Int
    public let maximumCommandArgumentBytes: Int
    public let maximumDescriptorBytes: Int
    public let handlerTimeout: TimeInterval
    public let maximumConcurrentConnections: Int
    public let maximumSessions: Int

    public init(
        maximumHeaderBytes: Int = 32 * 1_024,
        maximumHeaderFields: Int = 100,
        headerTimeout: TimeInterval = 10,
        maximumMCPBodyBytes: Int = 1_024 * 1_024,
        maximumPairingBodyBytes: Int = 8 * 1_024,
        maximumCommandArgumentBytes: Int = 256 * 1_024,
        maximumDescriptorBytes: Int = 64 * 1_024,
        handlerTimeout: TimeInterval = 30,
        maximumConcurrentConnections: Int = 64,
        maximumSessions: Int = 128
    ) throws {
        guard (1...32 * 1_024).contains(maximumHeaderBytes),
              (1...100).contains(maximumHeaderFields),
              (0.05...10).contains(headerTimeout),
              (1...1_024 * 1_024).contains(maximumMCPBodyBytes),
              (1...8 * 1_024).contains(maximumPairingBodyBytes),
              (1...256 * 1_024).contains(maximumCommandArgumentBytes),
              (1...64 * 1_024).contains(maximumDescriptorBytes),
              (0.05...300).contains(handlerTimeout),
              (1...256).contains(maximumConcurrentConnections),
              (1...1_024).contains(maximumSessions)
        else { throw LocalMCPError.invalidConfiguration }

        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumHeaderFields = maximumHeaderFields
        self.headerTimeout = headerTimeout
        self.maximumMCPBodyBytes = maximumMCPBodyBytes
        self.maximumPairingBodyBytes = maximumPairingBodyBytes
        self.maximumCommandArgumentBytes = maximumCommandArgumentBytes
        self.maximumDescriptorBytes = maximumDescriptorBytes
        self.handlerTimeout = handlerTimeout
        self.maximumConcurrentConnections = maximumConcurrentConnections
        self.maximumSessions = maximumSessions
    }

    public static var defaults: MCPHTTPServerLimits {
        // The literal defaults above are statically known to be valid.
        try! MCPHTTPServerLimits()
    }

    /// The secure outer JSON base64-encodes one binary AEAD record. The
    /// decrypted record may contain the full MCP body plus the bounded logical
    /// headers; this ceiling accounts for the exact 4/3 expansion, nonce/tag,
    /// and a small fixed JSON envelope allowance.
    package var maximumSecureEnvelopeBytes: Int {
        SecureMCPCodec.maximumEnvelopeBytes(
            forPlaintextBytes: maximumMCPBodyBytes + maximumHeaderBytes + 1_024
        )
    }

    package var maximumWireResponseBytes: Int {
        max(maximumSecureEnvelopeBytes, maximumDescriptorBytes, maximumPairingBodyBytes)
    }
}
