import CryptoKit
import Foundation
import LocalMCPContracts

/// Media type for the LocalMCP authenticated-encryption wrapper. The JSON-RPC
/// message and all authorization/session headers are carried only inside this
/// envelope; they are never placed on the outer HTTP request.
package let localMCPSecureMediaType = "application/vnd.localmcp.secure+json"

/// One producer-process X25519 context. The transport creates it before it
/// constructs the descriptor and destroys it as part of every stop path.
public actor MCPProcessSecurityContext {
    public nonisolated let channelBinding: ProducerChannelBinding

    private var privateKey: Curve25519.KeyAgreement.PrivateKey?

    public init() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = privateKey
        channelBinding = ProducerChannelBinding(
            publicKey: try ChannelBindingPublicKey(privateKey.publicKey)
        )
    }

    package init(privateKeyRawRepresentation: [UInt8]) throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(privateKeyRawRepresentation)
        )
        self.privateKey = privateKey
        channelBinding = ProducerChannelBinding(
            publicKey: try ChannelBindingPublicKey(privateKey.publicKey)
        )
    }

    /// Releases the only process-private key retained by the runtime. Calls
    /// after destruction fail closed, and destruction is idempotent.
    public func destroy() {
        privateKey = nil
    }

    package var isUsable: Bool { privateKey != nil }

    package func validatePairingPeerPublicKey(
        _ peerPublicKey: ChannelBindingPublicKey
    ) throws {
        guard let privateKey else { throw SecureChannelError.unavailable }
        _ = try PairingChannelCrypto.sharedSecret(
            privateKeyRawRepresentation: Array(privateKey.rawRepresentation),
            peerPublicKey: peerPublicKey
        )
    }

    package func openMCPRequest(
        _ request: MCPHTTPRequest,
        expectedAuthority: String,
        maximumPlaintextBytes: Int
    ) throws -> SecureOpenedMCPRequest {
        guard let privateKey else { throw SecureChannelError.unavailable }
        return try SecureMCPCodec.openRequest(
            request,
            expectedAuthority: expectedAuthority,
            processPrivateKey: privateKey,
            channelBinding: channelBinding,
            maximumPlaintextBytes: maximumPlaintextBytes
        )
    }

    package func sealPairingResponse(
        plaintext: Data,
        peerPublicKey: ChannelBindingPublicKey,
        transcript: PairingTranscript
    ) throws -> Data {
        guard let privateKey else { throw SecureChannelError.unavailable }
        let key = try PairingChannelCrypto.responseKey(
            privateKeyRawRepresentation: Array(privateKey.rawRepresentation),
            peerPublicKey: peerPublicKey,
            transcript: transcript
        )
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: PairingChannelCrypto.responseAAD(for: transcript)
        )
        return try SecurePairingResponseEnvelope.encode(
            transcript: transcript,
            sealedBytes: sealed.combined
        )
    }
}

package enum SecureChannelError: Error, Sendable, Equatable {
    case invalidEnvelope
    case authenticationFailed
    case replayed
    case unavailable
}

package struct SecureOpenedMCPRequest: @unchecked Sendable {
    package let request: MCPHTTPRequest
    /// Nil is permitted only for initialize and is validated by the server
    /// adapter before the logical request is dispatched.
    package let sequence: UInt64?
    package let messageID: String
    package let responseContext: SecureServerResponseContext
}

package struct SecureServerResponseContext: @unchecked Sendable {
    private let requestID: String
    private let responseKey: SymmetricKey
    private let responseAAD: Data

    fileprivate init(requestID: String, responseKey: SymmetricKey, responseAAD: Data) {
        self.requestID = requestID
        self.responseKey = responseKey
        self.responseAAD = responseAAD
    }

    package func seal(_ response: MCPHTTPResponse) throws -> MCPHTTPResponse {
        let plaintext = try SecureMCPCodec.encodeResponsePayload(response)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: responseKey,
            authenticating: responseAAD
        )
        let body = SecureMCPCodec.encodeResponseEnvelope(
            requestID: requestID,
            sealedBytes: sealed.combined
        )
        return MCPHTTPResponse(
            statusCode: 200,
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": localMCPSecureMediaType,
            ],
            body: body
        )
    }
}

package struct SecureClientResponseContext: @unchecked Sendable {
    package let requestBody: Data

    private let requestID: String
    private let responseKey: SymmetricKey
    private let responseAAD: Data

    fileprivate init(
        requestBody: Data,
        requestID: String,
        responseKey: SymmetricKey,
        responseAAD: Data
    ) {
        self.requestBody = requestBody
        self.requestID = requestID
        self.responseKey = responseKey
        self.responseAAD = responseAAD
    }

    package func open(
        outerStatusCode: Int,
        outerContentType: String?,
        body: Data,
        maximumPlaintextBytes: Int
    ) throws -> MCPHTTPResponse {
        guard outerStatusCode == 200,
              SecureMCPCodec.isExactSecureContentType(outerContentType),
              let envelope = try? SecureMCPCodec.parseResponseEnvelope(body),
              envelope.requestID == requestID
        else { throw SecureChannelError.invalidEnvelope }

        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.sealedBytes)
            let plaintext = try ChaChaPoly.open(
                box,
                using: responseKey,
                authenticating: responseAAD
            )
            guard plaintext.count <= maximumPlaintextBytes else {
                throw SecureChannelError.invalidEnvelope
            }
            return try SecureMCPCodec.parseResponsePayload(plaintext)
        } catch let error as SecureChannelError {
            throw error
        } catch {
            throw SecureChannelError.authenticationFailed
        }
    }
}

package enum SecureMCPCodec {
    private static let profile = "localmcp-secure-v1"
    private static let requestKeyInfo = Data("LocalMCPKit secure request key v1".utf8)
    private static let responseKeyInfo = Data("LocalMCPKit secure response key v1".utf8)
    private static let requestAADDomain = Array("LocalMCPKit secure request aad v1".utf8)
    private static let requestDigestDomain = Array("LocalMCPKit secure request digest v1".utf8)
    private static let responseAADDomain = Array("LocalMCPKit secure response aad v1".utf8)

    package static func sealRequest(
        _ logicalRequest: MCPHTTPRequest,
        sequence: UInt64?,
        expectedAuthority: String,
        channelBinding: ProducerChannelBinding
    ) throws -> SecureClientResponseContext {
        guard channelBinding.isSupported,
              logicalRequest.path == "/mcp",
              logicalRequest.method == "POST" || logicalRequest.method == "DELETE"
        else { throw SecureChannelError.invalidEnvelope }

        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = try ChannelBindingPublicKey(ephemeralPrivateKey.publicKey)
        let messageIDBytes = randomBytes(count: 32)
        let messageID = SecureBase64URL.encode(messageIDBytes)
        let requestAAD = try makeRequestAAD(
            requestID: messageID,
            ephemeralPublicKey: ephemeralPublicKey,
            channelBinding: channelBinding,
            method: "POST",
            path: logicalRequest.path,
            authority: expectedAuthority,
            contentType: localMCPSecureMediaType
        )
        let sharedSecret = try sharedSecret(
            privateKey: ephemeralPrivateKey,
            peerPublicKey: channelBinding.publicKey
        )
        let requestKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: requestAAD)),
            sharedInfo: requestKeyInfo,
            outputByteCount: 32
        )
        let plaintext = try encodeRequestPayload(logicalRequest, sequence: sequence)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: requestKey,
            authenticating: requestAAD
        )
        let body = encodeRequestEnvelope(
            requestID: messageID,
            ephemeralPublicKey: ephemeralPublicKey,
            sealedBytes: sealed.combined
        )
        let requestDigest = makeRequestDigest(
            method: "POST",
            path: logicalRequest.path,
            authority: expectedAuthority,
            contentType: localMCPSecureMediaType,
            body: body
        )
        let responseKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestDigest,
            sharedInfo: responseKeyInfo,
            outputByteCount: 32
        )
        return SecureClientResponseContext(
            requestBody: body,
            requestID: messageID,
            responseKey: responseKey,
            responseAAD: makeResponseAAD(requestID: messageID, requestDigest: requestDigest)
        )
    }

    fileprivate static func openRequest(
        _ outerRequest: MCPHTTPRequest,
        expectedAuthority: String,
        processPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        channelBinding: ProducerChannelBinding,
        maximumPlaintextBytes: Int
    ) throws -> SecureOpenedMCPRequest {
        guard outerRequest.method == "POST",
              outerRequest.path == "/mcp",
              outerRequest.body.count <= maximumEnvelopeBytes(
                  forPlaintextBytes: maximumPlaintextBytes
              ),
              outerRequest.headerValues("authorization").isEmpty,
              outerRequest.headerValues("mcp-protocol-version").isEmpty,
              outerRequest.headerValues("mcp-session-id").isEmpty,
              outerRequest.singleHeader("content-type") == localMCPSecureMediaType,
              outerRequest.singleHeader("accept") == localMCPSecureMediaType
        else { throw SecureChannelError.invalidEnvelope }

        let envelope = try parseRequestEnvelope(outerRequest.body)
        let requestAAD = try makeRequestAAD(
            requestID: envelope.requestID,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            channelBinding: channelBinding,
            method: outerRequest.method,
            path: outerRequest.path,
            authority: expectedAuthority,
            contentType: localMCPSecureMediaType
        )
        let sharedSecret = try sharedSecret(
            privateKey: processPrivateKey,
            peerPublicKey: envelope.ephemeralPublicKey
        )
        let requestKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: requestAAD)),
            sharedInfo: requestKeyInfo,
            outputByteCount: 32
        )
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.sealedBytes)
            plaintext = try ChaChaPoly.open(box, using: requestKey, authenticating: requestAAD)
        } catch {
            throw SecureChannelError.authenticationFailed
        }
        guard plaintext.count <= maximumPlaintextBytes else {
            throw SecureChannelError.invalidEnvelope
        }
        let decoded = try parseRequestPayload(plaintext)
        let requestDigest = makeRequestDigest(
            method: outerRequest.method,
            path: outerRequest.path,
            authority: expectedAuthority,
            contentType: localMCPSecureMediaType,
            body: outerRequest.body
        )
        let responseKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestDigest,
            sharedInfo: responseKeyInfo,
            outputByteCount: 32
        )
        return SecureOpenedMCPRequest(
            request: decoded.request,
            sequence: decoded.sequence,
            messageID: envelope.requestID,
            responseContext: SecureServerResponseContext(
                requestID: envelope.requestID,
                responseKey: responseKey,
                responseAAD: makeResponseAAD(
                    requestID: envelope.requestID,
                    requestDigest: requestDigest
                )
            )
        )
    }

    package static func isExactSecureContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespaces).lowercased() == localMCPSecureMediaType
    }

    package static func maximumEnvelopeBytes(forPlaintextBytes plaintextBytes: Int) -> Int {
        guard plaintextBytes >= 0, plaintextBytes <= Int.max - 64 * 1_024 else { return Int.max }
        let sealedBytes = plaintextBytes + 12 + 16
        let encodedBytes = ((sealedBytes + 2) / 3) * 4
        guard encodedBytes <= Int.max - 4 * 1_024 else { return Int.max }
        return encodedBytes + 4 * 1_024
    }

    private static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: ChannelBindingPublicKey
    ) throws -> SharedSecret {
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(peerPublicKey.rawRepresentation)
            )
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            var aggregate: UInt8 = 0
            secret.withUnsafeBytes { bytes in
                for byte in bytes { aggregate |= byte }
            }
            guard aggregate != 0 else { throw SecureChannelError.authenticationFailed }
            return secret
        } catch let error as SecureChannelError {
            throw error
        } catch {
            throw SecureChannelError.authenticationFailed
        }
    }

    private struct RequestEnvelope {
        let requestID: String
        let ephemeralPublicKey: ChannelBindingPublicKey
        let sealedBytes: Data
    }

    fileprivate struct ResponseEnvelope {
        let requestID: String
        let sealedBytes: Data
    }

    private struct DecodedRequestPayload {
        let request: MCPHTTPRequest
        let sequence: UInt64?
    }

    private static func encodeRequestEnvelope(
        requestID: String,
        ephemeralPublicKey: ChannelBindingPublicKey,
        sealedBytes: Data
    ) -> Data {
        encodeJSON(.object([
            "ephemeralPublicKey": .string(ephemeralPublicKey.canonicalEncodedValue),
            "profile": .string(profile),
            "requestId": .string(requestID),
            "sealed": .string(SecureBase64URL.encode([UInt8](sealedBytes))),
            "suite": .string(ProducerChannelBinding.supportedSuite),
        ]))
    }

    private static func parseRequestEnvelope(_ data: Data) throws -> RequestEnvelope {
        guard case let .object(object) = try StrictJSONParser.parse(data),
              Set(object.keys) == ["ephemeralPublicKey", "profile", "requestId", "sealed", "suite"],
              object["profile"] == .string(profile),
              object["suite"] == .string(ProducerChannelBinding.supportedSuite),
              case let .string(requestID)? = object["requestId"],
              SecureBase64URL.decode(requestID)?.count == 32,
              case let .string(publicKeyString)? = object["ephemeralPublicKey"],
              let publicKey = try? ChannelBindingPublicKey(encodedValue: publicKeyString),
              case let .string(sealedString)? = object["sealed"],
              let sealed = SecureBase64URL.decode(sealedString),
              sealed.count >= 12 + 16
        else { throw SecureChannelError.invalidEnvelope }
        return RequestEnvelope(
            requestID: requestID,
            ephemeralPublicKey: publicKey,
            sealedBytes: Data(sealed)
        )
    }

    fileprivate static func encodeResponseEnvelope(requestID: String, sealedBytes: Data) -> Data {
        encodeJSON(.object([
            "profile": .string(profile),
            "requestId": .string(requestID),
            "sealed": .string(SecureBase64URL.encode([UInt8](sealedBytes))),
            "suite": .string(ProducerChannelBinding.supportedSuite),
        ]))
    }

    fileprivate static func parseResponseEnvelope(_ data: Data) throws -> ResponseEnvelope {
        guard case let .object(object) = try StrictJSONParser.parse(data),
              Set(object.keys) == ["profile", "requestId", "sealed", "suite"],
              object["profile"] == .string(profile),
              object["suite"] == .string(ProducerChannelBinding.supportedSuite),
              case let .string(requestID)? = object["requestId"],
              SecureBase64URL.decode(requestID)?.count == 32,
              case let .string(sealedString)? = object["sealed"],
              let sealed = SecureBase64URL.decode(sealedString),
              sealed.count >= 12 + 16
        else { throw SecureChannelError.invalidEnvelope }
        return ResponseEnvelope(requestID: requestID, sealedBytes: Data(sealed))
    }

    private static func encodeRequestPayload(
        _ request: MCPHTTPRequest,
        sequence: UInt64?
    ) throws -> Data {
        guard request.path == "/mcp",
              request.body.count <= Int(UInt32.max),
              request.headers.count <= Int(UInt16.max)
        else { throw SecureChannelError.invalidEnvelope }
        var writer = SecureBinaryWriter()
        writer.appendBytes(Array("LMCPREQ".utf8) + [1])
        switch request.method {
        case "POST": writer.appendByte(1)
        case "DELETE": writer.appendByte(2)
        default: throw SecureChannelError.invalidEnvelope
        }
        if let sequence {
            guard sequence != 0 else { throw SecureChannelError.invalidEnvelope }
            writer.appendByte(1)
            writer.appendUInt64(sequence)
        } else {
            writer.appendByte(0)
        }
        writer.appendUInt16(UInt16(request.headers.count))
        for (name, values) in request.headers.sorted(by: { $0.key < $1.key }) {
            guard isValidHeaderName(name),
                  values.count == 1,
                  isValidHeaderValue(values[0])
            else { throw SecureChannelError.invalidEnvelope }
            try writer.appendShortString(name)
            try writer.appendData(Data(values[0].utf8))
        }
        try writer.appendData(request.body)
        return writer.data
    }

    private static func parseRequestPayload(_ data: Data) throws -> DecodedRequestPayload {
        var reader = SecureBinaryReader(data: data)
        guard try reader.readBytes(count: 8) == Array("LMCPREQ".utf8) + [1] else {
            throw SecureChannelError.invalidEnvelope
        }
        let method: String
        switch try reader.readByte() {
        case 1: method = "POST"
        case 2: method = "DELETE"
        default: throw SecureChannelError.invalidEnvelope
        }
        let sequence: UInt64?
        switch try reader.readByte() {
        case 0:
            sequence = nil
        case 1:
            let value = try reader.readUInt64()
            guard value != 0 else { throw SecureChannelError.invalidEnvelope }
            sequence = value
        default:
            throw SecureChannelError.invalidEnvelope
        }
        let headerCount = Int(try reader.readUInt16())
        var headers: [String: [String]] = [:]
        var previousName: String?
        for _ in 0..<headerCount {
            let name = try reader.readShortString()
            let valueData = try reader.readData()
            guard isValidHeaderName(name),
                  headers[name] == nil,
                  previousName.map({ $0 < name }) ?? true,
                  let headerValue = String(data: valueData, encoding: .utf8),
                  isValidHeaderValue(headerValue)
            else { throw SecureChannelError.invalidEnvelope }
            headers[name] = [headerValue]
            previousName = name
        }
        let body = try reader.readData()
        guard reader.isAtEnd else { throw SecureChannelError.invalidEnvelope }
        return DecodedRequestPayload(
            request: MCPHTTPRequest(
                method: method,
                path: "/mcp",
                headers: headers,
                body: body
            ),
            sequence: sequence
        )
    }

    fileprivate static func encodeResponsePayload(_ response: MCPHTTPResponse) throws -> Data {
        guard (100...599).contains(response.statusCode),
              response.headers.count <= Int(UInt16.max),
              response.body.count <= Int(UInt32.max)
        else {
            throw SecureChannelError.invalidEnvelope
        }
        var writer = SecureBinaryWriter()
        writer.appendBytes(Array("LMCPRES".utf8) + [1])
        writer.appendUInt16(UInt16(response.statusCode))
        writer.appendUInt16(UInt16(response.headers.count))
        var seen: Set<String> = []
        for (name, value) in response.headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let canonicalName = name.lowercased()
            guard isValidHeaderName(canonicalName),
                  seen.insert(canonicalName).inserted,
                  isValidHeaderValue(value)
            else { throw SecureChannelError.invalidEnvelope }
            try writer.appendShortString(canonicalName)
            try writer.appendData(Data(value.utf8))
        }
        try writer.appendData(response.body)
        return writer.data
    }

    fileprivate static func parseResponsePayload(_ data: Data) throws -> MCPHTTPResponse {
        var reader = SecureBinaryReader(data: data)
        guard try reader.readBytes(count: 8) == Array("LMCPRES".utf8) + [1] else {
            throw SecureChannelError.invalidEnvelope
        }
        let status = try reader.readUInt16()
        guard (100...599).contains(status) else { throw SecureChannelError.invalidEnvelope }
        let headerCount = Int(try reader.readUInt16())
        var headers: [String: String] = [:]
        var previousName: String?
        for _ in 0..<headerCount {
            let name = try reader.readShortString()
            let valueData = try reader.readData()
            guard isValidHeaderName(name),
                  headers[name] == nil,
                  previousName.map({ $0 < name }) ?? true,
                  let headerValue = String(data: valueData, encoding: .utf8),
                  isValidHeaderValue(headerValue)
            else { throw SecureChannelError.invalidEnvelope }
            headers[name] = headerValue
            previousName = name
        }
        let body = try reader.readData()
        guard reader.isAtEnd else { throw SecureChannelError.invalidEnvelope }
        return MCPHTTPResponse(
            statusCode: Int(status),
            headers: headers,
            body: body
        )
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count), value == value.lowercased() else { return false }
        return value.utf8.allSatisfy { byte in
            (0x61...0x7a).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2d
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        (0...8_192).contains(value.utf8.count) &&
            !value.unicodeScalars.contains { scalar in
                scalar.value == 0 || scalar.value == 0x0a || scalar.value == 0x0d
            }
    }

    private static func makeRequestAAD(
        requestID: String,
        ephemeralPublicKey: ChannelBindingPublicKey,
        channelBinding: ProducerChannelBinding,
        method: String,
        path: String,
        authority: String,
        contentType: String
    ) throws -> Data {
        guard channelBinding.isSupported else { throw SecureChannelError.invalidEnvelope }
        return lengthPrefixed([
            requestAADDomain,
            Array(profile.utf8),
            Array(channelBinding.suite.utf8),
            channelBinding.publicKey.rawRepresentation,
            ephemeralPublicKey.rawRepresentation,
            SecureBase64URL.decode(requestID) ?? [],
            Array(method.utf8),
            Array(path.utf8),
            Array(authority.utf8),
            Array(contentType.utf8),
        ])
    }

    private static func makeRequestDigest(
        method: String,
        path: String,
        authority: String,
        contentType: String,
        body: Data
    ) -> Data {
        Data(SHA256.hash(data: lengthPrefixed([
            requestDigestDomain,
            Array(method.utf8),
            Array(path.utf8),
            Array(authority.utf8),
            Array(contentType.utf8),
            [UInt8](body),
        ])))
    }

    private static func makeResponseAAD(requestID: String, requestDigest: Data) -> Data {
        lengthPrefixed([
            responseAADDomain,
            SecureBase64URL.decode(requestID) ?? [],
            [UInt8](requestDigest),
            Array(localMCPSecureMediaType.utf8),
        ])
    }

    private static func lengthPrefixed(_ fields: [[UInt8]]) -> Data {
        var bytes: [UInt8] = []
        for field in fields {
            precondition(field.count <= Int(UInt32.max))
            let count = UInt32(field.count)
            bytes.append(UInt8(truncatingIfNeeded: count >> 24))
            bytes.append(UInt8(truncatingIfNeeded: count >> 16))
            bytes.append(UInt8(truncatingIfNeeded: count >> 8))
            bytes.append(UInt8(truncatingIfNeeded: count))
            bytes.append(contentsOf: field)
        }
        return Data(bytes)
    }

    private static func encodeJSON(_ value: JSONValue) -> Data {
        // Every value built above consists only of JSON-representable data.
        (try? JSONEncoder.secureSorted.encode(value)) ?? Data()
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

package enum SecurePairingResponseEnvelope {
    private static let profile = "localmcp-pairing-response-v1"

    package static func encode(transcript: PairingTranscript, sealedBytes: Data) throws -> Data {
        let digest = transcript.withDigestBytes { SecureBase64URL.encode($0) }
        return try JSONEncoder.secureSorted.encode(JSONValue.object([
            "profile": .string(profile),
            "sealed": .string(SecureBase64URL.encode([UInt8](sealedBytes))),
            "transcriptDigest": .string(digest),
        ]))
    }

    package static func open(
        _ data: Data,
        privateKeyRawRepresentation: [UInt8],
        peerPublicKey: ChannelBindingPublicKey,
        transcript: PairingTranscript
    ) throws -> Data {
        guard case let .object(object) = try StrictJSONParser.parse(data),
              Set(object.keys) == ["profile", "sealed", "transcriptDigest"],
              object["profile"] == .string(profile),
              case let .string(digest)? = object["transcriptDigest"],
              digest == transcript.withDigestBytes({ SecureBase64URL.encode($0) }),
              case let .string(sealedValue)? = object["sealed"],
              let sealed = SecureBase64URL.decode(sealedValue)
        else { throw SecureChannelError.invalidEnvelope }
        do {
            let key = try PairingChannelCrypto.responseKey(
                privateKeyRawRepresentation: privateKeyRawRepresentation,
                peerPublicKey: peerPublicKey,
                transcript: transcript
            )
            let box = try ChaChaPoly.SealedBox(combined: Data(sealed))
            return try ChaChaPoly.open(
                box,
                using: key,
                authenticating: PairingChannelCrypto.responseAAD(for: transcript)
            )
        } catch let error as SecureChannelError {
            throw error
        } catch {
            throw SecureChannelError.authenticationFailed
        }
    }
}

private enum SecureBase64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> [UInt8]? {
        guard !value.contains("="),
              value.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
                  ).contains($0)
              })
        else { return nil }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](data)
        return encode(bytes) == value ? bytes : nil
    }
}

private struct SecureBinaryWriter {
    private(set) var data = Data()

    mutating func appendByte(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendBytes(_ value: [UInt8]) {
        data.append(contentsOf: value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        appendByte(UInt8(truncatingIfNeeded: value >> 8))
        appendByte(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendByte(UInt8(truncatingIfNeeded: value >> 24))
        appendByte(UInt8(truncatingIfNeeded: value >> 16))
        appendByte(UInt8(truncatingIfNeeded: value >> 8))
        appendByte(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            appendByte(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendShortString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw SecureChannelError.invalidEnvelope }
        appendUInt16(UInt16(bytes.count))
        data.append(bytes)
    }

    mutating func appendData(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw SecureChannelError.invalidEnvelope }
        appendUInt32(UInt32(value.count))
        data.append(value)
    }
}

private struct SecureBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw SecureChannelError.invalidEnvelope }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw SecureChannelError.invalidEnvelope
        }
        let range = offset..<(offset + count)
        offset += count
        return Array(data[range])
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readByte()) << 8 | UInt16(try readByte())
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readByte()) << 24 |
            UInt32(try readByte()) << 16 |
            UInt32(try readByte()) << 8 |
            UInt32(try readByte())
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = value << 8 | UInt64(try readByte())
        }
        return value
    }

    mutating func readShortString() throws -> String {
        let count = Int(try readUInt16())
        let bytes = try readBytes(count: count)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw SecureChannelError.invalidEnvelope
        }
        return value
    }

    mutating func readData() throws -> Data {
        let count = Int(try readUInt32())
        return Data(try readBytes(count: count))
    }
}

private extension JSONEncoder {
    static var secureSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
