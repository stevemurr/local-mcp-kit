import Foundation
import LocalMCPContracts
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Network-backed `LocalMCPService` proxy for one discovered loopback endpoint.
/// It implements the complete MCP 2025-11-25 initialize/initialized/list/call
/// lifecycle and the LocalMCPKit V1 pairing extension.
public actor MCPWireClientService: LocalMCPDisconnectingService, LocalMCPPairingCodeReportingService {
    private enum ResponseMediaType: Sendable, Equatable {
        case json
        case eventStream
        case secure
        case none
    }

    private struct WireHTTPResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let mediaType: ResponseMediaType
        let eventValues: [JSONValue]?
    }

    private struct DownloadedResponse: @unchecked Sendable {
        let data: Data
        let response: URLResponse
        let eventValues: [JSONValue]?
    }

    private let instance: ProducerInstance
    private let endpoint: LoopbackEndpoint
    private let channelBinding: ProducerChannelBinding
    private let expectedAuthority: String
    private let pairingURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maximumResponseBytes: Int
    private var sessionID: String?
    private var sessionCredential: CredentialDigest?
    private var nextSessionSequence: UInt64 = 1

    public init(
        instance: ProducerInstance,
        pairingPath: String = "/local-mcp/v1/pairing-requests",
        requestTimeout: TimeInterval = 35,
        maximumResponseBytes: Int = 1_024 * 1_024
    ) throws {
        guard instance.endpoint.path == "/mcp",
              instance.descriptorURL.port == instance.endpoint.port,
              instance.descriptorURL.path == "/local-mcp/v1/descriptor.json",
              LocalMCPValidation.isCanonicalLowercaseUUID(instance.instanceID),
              instance.identity.isValid,
              let channelBinding = instance.channelBinding,
              channelBinding.isSupported,
              LoopbackEndpoint.isValidRelativePath(pairingPath),
              (1...300).contains(requestTimeout),
              (1...1_024 * 1_024).contains(maximumResponseBytes),
              var components = URLComponents(url: instance.endpoint.url, resolvingAgainstBaseURL: false)
        else { throw LocalMCPError.invalidConfiguration }
        components.path = pairingPath
        guard let pairingURL = components.url else { throw LocalMCPError.invalidConfiguration }
        self.instance = instance
        endpoint = instance.endpoint
        self.channelBinding = channelBinding
        expectedAuthority = "127.0.0.1:\(instance.endpoint.port)"
        self.pairingURL = pairingURL
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = max(requestTimeout, 130)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A nil dictionary inherits system/PAC/SOCKS proxy settings. Loopback
        // MCP requests carry bearer credentials and must never leave the host.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": false,
            "HTTPSEnable": false,
            "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false,
            "ProxyAutoDiscoveryEnable": false,
        ]
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        try await requestPairing(request, displayVerificationCode: { _ in })
    }

    public func requestPairing(
        _ request: PairingRequest,
        displayVerificationCode: @Sendable (PairingVerificationCode) -> Void
    ) async throws -> AuthorizationGrant {
        do {
            try request.validateChannelBoundInitiation(expected: instance)
        } catch {
            throw LocalMCPError.pairingDenied
        }
        guard let initiatorPrivateKey = request.initiatorPrivateKeyRawRepresentation,
              let clientSecret = request.localClientSecret
        else { throw LocalMCPError.pairingDenied }
        do {
            _ = try PairingChannelCrypto.sharedSecret(
                privateKeyRawRepresentation: initiatorPrivateKey,
                peerPublicKey: channelBinding.publicKey
            )
        } catch {
            throw LocalMCPError.producerUnavailable
        }

        let value: JSONValue
        do {
            value = try JSONValue.encode(request)
        } catch {
            throw LocalMCPError.pairingDenied
        }
        let challengeResponse = try await sendPlainPairing(
            url: pairingURL,
            method: "POST",
            body: value,
            accept: "application/json"
        )
        guard challengeResponse.statusCode == 201 else {
            throw pairingError(challengeResponse.body)
        }
        guard challengeResponse.mediaType == .json else {
            throw LocalMCPError.producerUnavailable
        }
        guard case let .object(challenge) = try parse(challengeResponse.body),
              Set(challenge.keys) == ["pairingId", "schemaVersion", "serverNonce"],
              challenge["schemaVersion"] == .string(DiscoveryProfileVersion.current.rawValue),
              case let .string(pairingIDString)? = challenge["pairingId"],
              let pairingID = try? PairingIdentifier(encodedValue: pairingIDString),
              case let .string(serverNonceString)? = challenge["serverNonce"],
              let serverNonce = try? PairingNonce(encodedValue: serverNonceString),
              let finalized = try? request.serverFinalized(
                  pairingID: pairingID,
                  serverNonce: serverNonce,
                  revealedClientSecret: clientSecret
              ),
              let transcript = try? PairingTranscript(
                  finalizedRequest: finalized,
                  producerID: instance.identity.stableID,
                  channelBinding: channelBinding
              )
        else { throw LocalMCPError.pairingDenied }

        displayVerificationCode(PairingVerificationCode(transcript: transcript))
        guard !Task.isCancelled else { throw LocalMCPError.cancelled }
        guard let completionValue = try? JSONValue.encode(finalized) else {
            throw LocalMCPError.pairingDenied
        }
        let completionURL = pairingURL.appendingPathComponent(pairingIDString, isDirectory: false)
        let response = try await sendPlainPairing(
            url: completionURL,
            method: "POST",
            body: completionValue,
            accept: localMCPSecureMediaType
        )
        guard response.statusCode == 200 else { throw pairingError(response.body) }
        guard response.mediaType == .secure,
              SecureMCPCodec.isExactSecureContentType(response.headers["content-type"])
        else { throw LocalMCPError.producerUnavailable }
        let plaintext: Data
        do {
            plaintext = try SecurePairingResponseEnvelope.open(
                response.body,
                privateKeyRawRepresentation: initiatorPrivateKey,
                peerPublicKey: channelBinding.publicKey,
                transcript: transcript
            )
            guard plaintext.count <= 64 * 1_024 else {
                throw SecureChannelError.invalidEnvelope
            }
        } catch {
            throw LocalMCPError.unauthorized
        }
        guard case let .object(object) = try parse(plaintext),
              Set(object.keys) == ["accessToken", "endpointBinding", "grant", "schemaVersion"],
              object["schemaVersion"] == .string(DiscoveryProfileVersion.current.rawValue),
              case let .object(grant)? = object["grant"],
              case let .string(grantID)? = grant["id"],
              case let .string(producerID)? = grant["producerId"],
              case let .string(consumerID)? = grant["consumerId"],
              case let .string(installationID)? = grant["consumerInstallationId"],
              consumerID == finalized.consumer.stableID,
              installationID == finalized.consumer.installationID,
              case let .string(issuedString)? = grant["issuedAt"],
              let issuedAt = Self.date(issuedString),
              case let .string(token)? = object["accessToken"],
              let credential = try? AuthorizationCredential(encodedValue: token),
              let endpointBindingValue = object["endpointBinding"],
              let endpointBinding = try? endpointBindingValue.decode(as: AuthorizationEndpointBinding.self),
              endpointBinding == AuthorizationEndpointBinding(
                  instanceID: instance.instanceID,
                  channelBinding: channelBinding
              ),
              producerID == instance.identity.stableID
        else { throw LocalMCPError.unauthorized }

        let expiresAt: Date?
        switch grant["expiresAt"] {
        case .null, nil:
            expiresAt = nil
        case let .string(value):
            guard let parsed = Self.date(value) else { throw LocalMCPError.unauthorized }
            expiresAt = parsed
        default:
            throw LocalMCPError.unauthorized
        }
        return AuthorizationGrant(
            metadata: AuthorizationGrantMetadata(
                grantID: grantID,
                producerID: producerID,
                consumer: finalized.consumer,
                issuedAt: issuedAt,
                expiresAt: expiresAt
            ),
            credential: credential,
            endpointBinding: endpointBinding
        )
    }

    public func authenticate(credential: AuthorizationCredential?) async throws {
        guard credential != nil else { throw LocalMCPError.unauthorized }
        _ = try await listCommands(credential: credential)
    }

    public func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        guard let credential,
              supportedProtocolVersions.contains(MCPProtocolVersion.current.rawValue)
        else { throw LocalMCPError.incompatibleMCPProtocol }

        let id = UUID().uuidString.lowercased()
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(MCPProtocolVersion.current.rawValue),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("LocalMCPKit"),
                    "version": .string("1"),
                ]),
            ]),
        ])
        let response = try await send(
            url: endpoint.url,
            method: "POST",
            body: request,
            credential: credential,
            includeProtocolVersion: false,
            includeSession: false,
            expectedResponseID: .string(id)
        )
        try requireAuthorized(response)
        guard response.statusCode == 200,
              let newSessionID = response.headers["mcp-session-id"],
              Self.isValidSessionID(newSessionID)
        else { throw LocalMCPError.incompatibleMCPProtocol }

        // Once a valid session header has been returned, retain it before
        // validating the result so a hostile/malformed initialize response can
        // still be terminated with DELETE rather than leaking server state.
        sessionID = newSessionID
        sessionCredential = credential.digest
        nextSessionSequence = 1
        do {
            guard case let .object(result) = try rpcResult(response, expectedID: .string(id)),
                  case let .string(protocolVersion)? = result["protocolVersion"],
                  protocolVersion == MCPProtocolVersion.current.rawValue,
                  case let .object(capabilities)? = result["capabilities"],
                  case .object? = capabilities["tools"],
                  case let .object(serverInfo)? = result["serverInfo"],
                  case let .string(stableID)? = serverInfo["name"],
                  case let .string(version)? = serverInfo["version"]
            else { throw LocalMCPError.incompatibleMCPProtocol }
            let displayName: String
            if case let .string(title)? = serverInfo["title"] {
                displayName = title
            } else {
                displayName = stableID
            }
            let server = ProducerIdentity(stableID: stableID, displayName: displayName, version: version)
            guard server.isValid else { throw LocalMCPError.incompatibleMCPProtocol }
            return LocalMCPInitialization(
                protocolVersion: protocolVersion,
                server: server,
                capabilities: ProducerCapabilities(tools: true)
            )
        } catch {
            await disconnect(credential: credential)
            throw LocalMCPError.incompatibleMCPProtocol
        }
    }

    public func initialized(credential: AuthorizationCredential?) async throws {
        let credential = try sessionCredentialValue(credential)
        let response = try await send(
            url: endpoint.url,
            method: "POST",
            body: .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized"),
                "params": .object([:]),
            ]),
            credential: credential,
            includeProtocolVersion: true,
            includeSession: true
        )
        try requireAuthorized(response)
        guard response.statusCode == 202 else { throw LocalMCPError.incompatibleMCPProtocol }
    }

    public func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        let credential = try sessionCredentialValue(credential)
        let id = UUID().uuidString.lowercased()
        let response = try await send(
            url: endpoint.url,
            method: "POST",
            body: .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "method": .string("tools/list"),
                "params": .object([:]),
            ]),
            credential: credential,
            includeProtocolVersion: true,
            includeSession: true,
            expectedResponseID: .string(id)
        )
        try requireAuthorized(response)
        guard response.statusCode == 200,
              case let .object(result) = try rpcResult(response, expectedID: .string(id)),
              case let .array(tools)? = result["tools"]
        else { throw LocalMCPError.commandFailed }
        return try tools.map(Self.commandDefinition)
    }

    public func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        let credential = try sessionCredentialValue(credential)
        let deadlineTimeout: TimeInterval?
        if let deadline = request.deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LocalMCPError.requestTimedOut }
            deadlineTimeout = remaining
        } else {
            deadlineTimeout = nil
        }
        let id = request.requestID
        let response = try await send(
            url: endpoint.url,
            method: "POST",
            body: .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string(request.name),
                    "arguments": request.arguments,
                ]),
            ]),
            credential: credential,
            includeProtocolVersion: true,
            includeSession: true,
            timeoutOverride: deadlineTimeout,
            expectedResponseID: .string(id)
        )
        try requireAuthorized(response)
        guard response.statusCode == 200,
              case let .object(result) = try rpcResult(response, expectedID: .string(id)),
              case let .array(content)? = result["content"]
        else { throw LocalMCPError.commandFailed }

        let isError: Bool
        switch result["isError"] {
        case nil:
            isError = false
        case let .bool(value)?:
            isError = value
        default:
            throw LocalMCPError.commandFailed
        }
        let structured: JSONValue?
        if let value = result["structuredContent"] {
            guard case .object = value else { throw LocalMCPError.commandFailed }
            structured = value
        } else {
            structured = nil
        }
        var text: String?
        for item in content {
            if case let .object(object) = item,
               object["type"] == .string("text"),
               case let .string(value)? = object["text"]
            {
                text = value
                break
            }
        }
        return CommandResult(structuredContent: structured, text: text, isError: isError)
    }

    public func disconnect(credential: AuthorizationCredential?) async {
        guard let credential,
              let disconnectingSessionID = sessionID,
              sessionCredential?.constantTimeEquals(credential.digest) == true
        else { return }
        let disconnectingDigest = credential.digest
        _ = try? await send(
            url: endpoint.url,
            method: "DELETE",
            body: nil,
            credential: credential,
            includeProtocolVersion: true,
            includeSession: true,
            sessionIDOverride: disconnectingSessionID
        )
        guard sessionID == disconnectingSessionID,
              sessionCredential?.constantTimeEquals(disconnectingDigest) == true
        else { return }
        sessionID = nil
        sessionCredential = nil
        nextSessionSequence = 1
    }

    private func sessionCredentialValue(
        _ credential: AuthorizationCredential?
    ) throws -> AuthorizationCredential {
        guard let credential,
              sessionID != nil,
              sessionCredential?.constantTimeEquals(credential.digest) == true
        else { throw LocalMCPError.invalidLifecycleState }
        return credential
    }

    private func send(
        url: URL,
        method: String,
        body: JSONValue?,
        credential: AuthorizationCredential?,
        includeProtocolVersion: Bool,
        includeSession: Bool,
        timeoutOverride: TimeInterval? = nil,
        expectedResponseID: JSONValue? = nil,
        sessionIDOverride: String? = nil
    ) async throws -> WireHTTPResponse {
        guard url == endpoint.url,
              method == "POST" || method == "DELETE",
              let credential
        else { throw LocalMCPError.invalidConfiguration }

        var logicalHeaders: [String: [String]] = [
            "accept": ["application/json, text/event-stream"],
            "authorization": [
                credential.withUnsafeEncodedValue { "Bearer \($0)" },
            ],
        ]
        let logicalBody: Data
        if let body {
            logicalBody = try JSONEncoder.sorted.encode(body)
            logicalHeaders["content-type"] = ["application/json"]
        } else {
            logicalBody = Data()
        }
        if includeProtocolVersion {
            logicalHeaders["mcp-protocol-version"] = [MCPProtocolVersion.current.rawValue]
        }
        if includeSession {
            guard let sessionID = sessionIDOverride ?? sessionID else {
                throw LocalMCPError.invalidLifecycleState
            }
            logicalHeaders["mcp-session-id"] = [sessionID]
        }
        let sequence = includeSession ? try allocateSessionSequence() : nil
        let logicalRequest = MCPHTTPRequest(
            method: method,
            path: endpoint.path,
            headers: logicalHeaders,
            body: logicalBody
        )
        let secureContext: SecureClientResponseContext
        do {
            secureContext = try SecureMCPCodec.sealRequest(
                logicalRequest,
                sequence: sequence,
                expectedAuthority: expectedAuthority,
                channelBinding: channelBinding
            )
        } catch {
            throw LocalMCPError.producerUnavailable
        }

        var outerRequest = URLRequest(url: endpoint.url)
        outerRequest.httpMethod = "POST"
        outerRequest.timeoutInterval = min(timeoutOverride ?? requestTimeout, requestTimeout)
        outerRequest.httpBody = secureContext.requestBody
        outerRequest.setValue(localMCPSecureMediaType, forHTTPHeaderField: "Accept")
        outerRequest.setValue(localMCPSecureMediaType, forHTTPHeaderField: "Content-Type")
        outerRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let outer = try await performURLRequest(
            outerRequest,
            expectedResponseID: nil,
            timeoutError: timeoutOverride == nil ? .producerUnavailable : .requestTimedOut,
            maximumDownloadedBytes: Self.secureEnvelopeLimit(for: maximumResponseBytes)
        )
        let inner: MCPHTTPResponse
        do {
            inner = try secureContext.open(
                outerStatusCode: outer.statusCode,
                outerContentType: outer.headers["content-type"],
                body: outer.body,
                maximumPlaintextBytes: maximumResponseBytes + 64 * 1_024
            )
            guard inner.body.count <= maximumResponseBytes else {
                throw SecureChannelError.invalidEnvelope
            }
        } catch {
            // Plaintext status codes, forged authorization errors, key swaps,
            // and malformed envelopes are identity failures, never evidence
            // that the persisted bearer itself is invalid.
            throw LocalMCPError.producerUnavailable
        }
        let mediaType: ResponseMediaType
        if inner.body.isEmpty {
            mediaType = .none
        } else {
            guard let contentType = inner.headers.first(where: {
                $0.key.lowercased() == "content-type"
            })?.value,
                  let parsed = Self.responseMediaType(contentType),
                  parsed != .secure
            else { throw LocalMCPError.producerUnavailable }
            mediaType = parsed
        }
        var innerHeaders: [String: String] = [:]
        for (key, value) in inner.headers {
            innerHeaders[key.lowercased()] = value
        }
        let eventValues: [JSONValue]?
        if mediaType == .eventStream {
            eventValues = try Self.parseServerSentEvents(inner.body)
        } else {
            eventValues = nil
        }
        return WireHTTPResponse(
            statusCode: inner.statusCode,
            headers: innerHeaders,
            body: inner.body,
            mediaType: mediaType,
            eventValues: eventValues
        )
    }

    private func sendPlainPairing(
        url: URL,
        method: String,
        body: JSONValue,
        accept: String
    ) async throws -> WireHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 130
        request.httpBody = try JSONEncoder.sorted.encode(body)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return try await performURLRequest(
            request,
            expectedResponseID: nil,
            timeoutError: .producerUnavailable,
            maximumDownloadedBytes: Self.secureEnvelopeLimit(for: maximumResponseBytes)
        )
    }

    private func performURLRequest(
        _ request: URLRequest,
        expectedResponseID: JSONValue?,
        timeoutError: LocalMCPError,
        maximumDownloadedBytes: Int
    ) async throws -> WireHTTPResponse {
        guard let url = request.url else { throw LocalMCPError.invalidConfiguration }

        let downloaded: DownloadedResponse
        do {
            let session = session
            let immutableRequest = request
            let transfer = LocalMCPAsyncOperation<DownloadedResponse>(
                timeoutAfter: request.timeoutInterval,
                timeoutError: timeoutError
            ) {
                var data = Data()
                let (bytes, response) = try await session.bytes(for: immutableRequest)
                guard response.expectedContentLength <= Int64(maximumDownloadedBytes) else {
                    throw LocalMCPError.producerUnavailable
                }
                if response.expectedContentLength > 0 {
                    data.reserveCapacity(Int(response.expectedContentLength))
                }
                let responseMediaType = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type")
                    .flatMap(Self.responseMediaType)
                var eventParser = responseMediaType == .eventStream
                    ? IncrementalServerSentEventParser(maximumBytes: maximumDownloadedBytes)
                    : nil
                var eventValues: [JSONValue] = []
                for try await byte in bytes {
                    guard data.count < maximumDownloadedBytes else {
                        throw LocalMCPError.producerUnavailable
                    }
                    data.append(byte)
                    if var parser = eventParser {
                        if let event = try parser.append(byte) {
                            eventValues.append(event)
                            if let expectedResponseID,
                               Self.isJSONRPCResponse(event, id: expectedResponseID)
                            {
                                bytes.task.cancel()
                                return DownloadedResponse(
                                    data: data,
                                    response: response,
                                    eventValues: eventValues
                                )
                            }
                        }
                        eventParser = parser
                    }
                }
                if var parser = eventParser, let event = try parser.finish() {
                    eventValues.append(event)
                }
                return DownloadedResponse(
                    data: data,
                    response: response,
                    eventValues: eventValues.isEmpty ? nil : eventValues
                )
            }
            downloaded = try await transfer.value(cancellationError: LocalMCPError.cancelled)
        } catch is CancellationError {
            throw LocalMCPError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw LocalMCPError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw timeoutError
        } catch let error as LocalMCPError {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
        }
        let data = downloaded.data
        let response = downloaded.response
        guard let http = response as? HTTPURLResponse,
              http.url == url,
              data.count <= maximumDownloadedBytes
        else { throw LocalMCPError.producerUnavailable }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        let mediaType: ResponseMediaType
        if data.isEmpty {
            mediaType = .none
        } else {
            guard let contentType = headers["content-type"],
                  let parsed = Self.responseMediaType(contentType)
            else { throw LocalMCPError.producerUnavailable }
            mediaType = parsed
        }
        return WireHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            mediaType: mediaType,
            eventValues: downloaded.eventValues
        )
    }

    private func allocateSessionSequence() throws -> UInt64 {
        guard nextSessionSequence != 0, nextSessionSequence != UInt64.max else {
            sessionID = nil
            sessionCredential = nil
            throw LocalMCPError.invalidLifecycleState
        }
        let sequence = nextSessionSequence
        nextSessionSequence += 1
        return sequence
    }

    private static func secureEnvelopeLimit(for plaintextLimit: Int) -> Int {
        guard plaintextLimit <= Int.max - 64 * 1_024 else { return Int.max }
        return SecureMCPCodec.maximumEnvelopeBytes(
            forPlaintextBytes: plaintextLimit + 64 * 1_024
        )
    }

    private func requireAuthorized(_ response: WireHTTPResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            sessionID = nil
            sessionCredential = nil
            throw LocalMCPError.unauthorized
        }
        if response.statusCode == 404 {
            sessionID = nil
            sessionCredential = nil
            throw LocalMCPError.invalidLifecycleState
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LocalMCPError.producerUnavailable
        }
    }

    private func rpcResult(_ response: WireHTTPResponse, expectedID: JSONValue) throws -> JSONValue {
        let candidates: [JSONValue]
        switch response.mediaType {
        case .json:
            candidates = [try parse(response.body)]
        case .eventStream:
            candidates = try response.eventValues ?? Self.parseServerSentEvents(response.body)
        case .secure, .none:
            throw LocalMCPError.commandFailed
        }
        let matches = candidates.compactMap { value -> [String: JSONValue]? in
            guard case let .object(object) = value,
                  object["jsonrpc"] == .string("2.0"),
                  object["id"] == expectedID
            else { return nil }
            return object
        }
        guard matches.count == 1, let object = matches.first else {
            throw LocalMCPError.commandFailed
        }
        let result = object["result"]
        let errorValue = object["error"]
        guard (result == nil) != (errorValue == nil) else {
            throw LocalMCPError.commandFailed
        }
        if let errorValue {
            guard case let .object(error) = errorValue else {
                throw LocalMCPError.commandFailed
            }
            throw Self.localError(error)
        }
        return result!
    }

    private static func responseMediaType(_ header: String) -> ResponseMediaType? {
        let pieces = header.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = pieces.first else { return nil }
        switch first.trimmingCharacters(in: .whitespaces).lowercased() {
        case "application/json": return .json
        case "text/event-stream": return .eventStream
        case localMCPSecureMediaType: return .secure
        default: return nil
        }
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (0x21...0x7e).contains(byte)
        }
    }

    /// Parses a bounded, already-size-limited SSE response. Multiple `data:`
    /// lines are joined with newlines as required by the event-stream format.
    private static func parseServerSentEvents(_ data: Data) throws -> [JSONValue] {
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw LocalMCPError.commandFailed
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var events: [JSONValue] = []
        var dataLines: [String] = []

        func appendEvent() throws {
            guard !dataLines.isEmpty else { return }
            let payload = Data(dataLines.joined(separator: "\n").utf8)
            events.append(try StrictJSONParser.parse(payload))
            dataLines.removeAll(keepingCapacity: true)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                try appendEvent()
                continue
            }
            if line.first == ":" { continue }
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = pieces[0]
            var value = pieces.count == 2 ? pieces[1] : Substring("")
            if value.first == " " { value = value.dropFirst() }
            if field == "data" { dataLines.append(String(value)) }
        }
        try appendEvent()
        guard !events.isEmpty else { throw LocalMCPError.commandFailed }
        return events
    }

    private static func isJSONRPCResponse(_ value: JSONValue, id: JSONValue) -> Bool {
        guard case let .object(object) = value else { return false }
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        return object["jsonrpc"] == .string("2.0") &&
            object["id"] == id &&
            hasResult != hasError
    }

    private func parse(_ data: Data) throws -> JSONValue {
        do {
            return try StrictJSONParser.parse(data)
        } catch {
            throw LocalMCPError.commandFailed
        }
    }

    private func pairingError(_ data: Data) -> LocalMCPError {
        guard let value = try? StrictJSONParser.parse(data),
              case let .object(object) = value,
              case let .object(error)? = object["error"],
              case let .string(code)? = error["code"]
        else { return .pairingDenied }
        switch code {
        case "pairing_expired": return .pairingExpired
        case "pairing_replayed": return .pairingReplayed
        case "pairing_rate_limited", "pairing_unavailable": return .producerUnavailable
        default: return .pairingDenied
        }
    }

    private static func localError(_ error: [String: JSONValue]) -> LocalMCPError {
        guard case let .integer(code)? = error["code"] else { return .commandFailed }
        switch code {
        case -32_602: return .invalidCommandInput
        case -32_601: return .commandNotFound
        case -32_004: return .commandNotFound
        case -32_001: return .requestTimedOut
        case -32_800: return .cancelled
        default: return .commandFailed
        }
    }

    private static func commandDefinition(_ value: JSONValue) throws -> CommandDefinition {
        guard case let .object(object) = value,
              case let .string(name)? = object["name"],
              case let .string(description)? = object["description"],
              let inputSchema = object["inputSchema"]
        else { throw LocalMCPError.commandFailed }
        let title: String?
        if case let .string(value)? = object["title"] { title = value } else { title = nil }
        var annotations = CommandAnnotations()
        if let annotationValue = object["annotations"] {
            guard case let .object(hints) = annotationValue else {
                throw LocalMCPError.commandFailed
            }
            if let value = hints["readOnlyHint"] {
                guard case let .bool(value) = value else { throw LocalMCPError.commandFailed }
                annotations.readOnly = value
            }
            if let value = hints["idempotentHint"] {
                guard case let .bool(value) = value else { throw LocalMCPError.commandFailed }
                annotations.idempotent = value
            }
            if let value = hints["destructiveHint"] {
                guard case let .bool(value) = value else { throw LocalMCPError.commandFailed }
                annotations.destructive = value
            }
            if let value = hints["openWorldHint"] {
                guard case let .bool(value) = value else { throw LocalMCPError.commandFailed }
                annotations.openWorld = value
            }
        }
        let definition = CommandDefinition(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: object["outputSchema"],
            annotations: annotations
        )
        guard definition.isValid,
              MCPJSONSchemaValidator.isSupported(schema: definition.inputSchema),
              definition.outputSchema.map(MCPJSONSchemaValidator.isSupported(schema:)) ?? true
        else { throw LocalMCPError.commandFailed }
        return definition
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct IncrementalServerSentEventParser: Sendable {
    private let maximumBytes: Int
    private var consumedBytes = 0
    private var line = Data()
    private var dataLines: [String] = []
    private var ignoreNextLineFeed = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ byte: UInt8) throws -> JSONValue? {
        consumedBytes += 1
        guard consumedBytes <= maximumBytes else { throw LocalMCPError.producerUnavailable }

        if ignoreNextLineFeed {
            ignoreNextLineFeed = false
            if byte == 0x0a { return nil }
        }
        if byte == 0x0d {
            ignoreNextLineFeed = true
            return try finishLine()
        }
        if byte == 0x0a { return try finishLine() }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> JSONValue? {
        if !line.isEmpty {
            if let event = try finishLine() { return event }
        }
        return try finishEvent()
    }

    private mutating func finishLine() throws -> JSONValue? {
        guard let value = String(data: line, encoding: .utf8), !value.contains("\0") else {
            throw LocalMCPError.commandFailed
        }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return try finishEvent() }
        if value.first == ":" { return nil }

        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "data" else { return nil }
        var fieldValue = pieces.count == 2 ? pieces[1] : Substring("")
        if fieldValue.first == " " { fieldValue = fieldValue.dropFirst() }
        dataLines.append(String(fieldValue))
        return nil
    }

    private mutating func finishEvent() throws -> JSONValue? {
        guard !dataLines.isEmpty else { return nil }
        let payload = Data(dataLines.joined(separator: "\n").utf8)
        dataLines.removeAll(keepingCapacity: true)
        return try StrictJSONParser.parse(payload)
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
