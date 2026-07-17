import CryptoKit
import Foundation
import LocalMCPContracts

/// Authenticated MCP 2025-11-25 request/response adapter. It intentionally owns
/// all JSON-RPC and Streamable HTTP version/session behavior so no wire or SDK
/// type escapes into the public producer API.
public actor MCPWireServerAdapter {
    private struct Session: Sendable {
        let credentialDigest: CredentialDigest
        let createdAt: Date
        var initialized: Bool
        var replayWindow = SequenceReplayWindow()
    }

    /// A fixed 64-message anti-replay window. Advancing the highest sequence
    /// shifts a bitmap; duplicates and values older than highest-63 can never
    /// be accepted again. This permits the listener's bounded concurrency to
    /// deliver valid requests out of order without serializing MCP calls.
    private struct SequenceReplayWindow: Sendable {
        private var highest: UInt64 = 0
        private var received: UInt64 = 0

        mutating func accept(_ sequence: UInt64) -> Bool {
            guard sequence != 0 else { return false }
            if highest == 0 {
                highest = sequence
                received = 1
                return true
            }
            if sequence > highest {
                let distance = sequence - highest
                received = distance >= 64 ? 1 : (received << distance) | 1
                highest = sequence
                return true
            }
            let distance = highest - sequence
            guard distance < 64 else { return false }
            let bit = UInt64(1) << distance
            guard received & bit == 0 else { return false }
            received |= bit
            return true
        }
    }

    private struct PendingPairing: Sendable {
        let initiation: PairingRequest
        let identifier: PairingIdentifier
        let serverNonce: PairingNonce
        let expiresAt: Date
    }

    private struct ActiveCallKey: Hashable, Sendable {
        let sessionID: String
        let requestID: JSONValue
    }

    private let service: any LocalMCPService
    private let descriptor: ProducerDescriptor
    private let descriptorPath: String
    private let pairingPath: String
    private let limits: MCPHTTPServerLimits
    private let processSecurityContext: MCPProcessSecurityContext
    private var sessions: [String: Session] = [:]
    private var activeCalls: [ActiveCallKey: LocalMCPAsyncOperation<CommandResult>] = [:]
    private var activePairings: [UUID: LocalMCPAsyncOperation<AuthorizationGrant>] = [:]
    private var pendingPairings: [String: PendingPairing] = [:]
    private var terminalPairingIDs: Set<String> = []
    private var retainedPairingInitiations: [Data: Date] = [:]
    private var pairingStarts: [Date] = []
    private var initializeReplayIDs: Set<String> = []
    private var initializeReplayCapacityExhausted = false
    private var stopped = false

    public init(
        service: any LocalMCPService,
        descriptor: ProducerDescriptor,
        processSecurityContext: MCPProcessSecurityContext,
        descriptorPath: String = "/local-mcp/v1/descriptor.json",
        pairingPath: String = "/local-mcp/v1/pairing-requests",
        limits: MCPHTTPServerLimits = .defaults
    ) throws {
        guard (try? DescriptorCompatibility.validate(descriptor)) != nil,
              descriptor.channelBinding == processSecurityContext.channelBinding,
              descriptor.channelBinding?.isSupported == true,
              descriptor.mcp.endpoint == "/mcp",
              descriptorPath == "/local-mcp/v1/descriptor.json",
              pairingPath == "/local-mcp/v1/pairing-requests"
        else { throw LocalMCPError.invalidConfiguration }
        self.service = service
        self.descriptor = descriptor
        self.processSecurityContext = processSecurityContext
        self.descriptorPath = descriptorPath
        self.pairingPath = pairingPath
        self.limits = limits
    }

    public func stop() async {
        stopped = true
        for operation in activeCalls.values {
            operation.cancel(with: LocalMCPError.cancelled)
        }
        for operation in activePairings.values {
            operation.cancel(with: LocalMCPError.cancelled)
        }
        activeCalls.removeAll(keepingCapacity: false)
        activePairings.removeAll(keepingCapacity: false)
        pendingPairings.removeAll(keepingCapacity: false)
        terminalPairingIDs.removeAll(keepingCapacity: false)
        retainedPairingInitiations.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
        initializeReplayIDs.removeAll(keepingCapacity: false)
        initializeReplayCapacityExhausted = true
        await processSecurityContext.destroy()
    }

    public func handle(_ request: MCPHTTPRequest, expectedAuthority: String) async -> MCPHTTPResponse {
        guard !stopped else { return smallError(status: 503, code: "producer_unavailable") }

        let hostValues = request.headerValues("host")
        guard hostValues.count == 1, hostValues[0] == expectedAuthority,
              request.headerValues("origin").isEmpty
        else {
            return smallError(status: 403, code: "forbidden_request_context")
        }

        if request.method == "GET", request.path == descriptorPath {
            guard request.body.isEmpty else { return smallError(status: 400, code: "invalid_request") }
            return descriptorResponse()
        }

        if request.method == "POST", request.path == pairingPath {
            guard acceptsJSON(request), hasJSONContentType(request) else {
                return smallError(status: 400, code: "invalid_pairing_request")
            }
            return await handlePairingInitiation(request, expectedAuthority: expectedAuthority)
        }

        if request.method == "POST", request.path.hasPrefix(pairingPath + "/") {
            guard request.singleHeader("accept") == localMCPSecureMediaType,
                  hasJSONContentType(request)
            else { return smallError(status: 400, code: "invalid_pairing_request") }
            return await handlePairingCompletion(request, expectedAuthority: expectedAuthority)
        }

        guard request.path == descriptor.mcp.endpoint else {
            return smallError(status: 404, code: "not_found")
        }

        if request.method == "GET" || request.method == "DELETE" {
            return MCPHTTPResponse(statusCode: 405, headers: ["Allow": "POST"])
        }

        guard request.method == "POST" else {
            return MCPHTTPResponse(statusCode: 405, headers: ["Allow": "POST"])
        }

        guard request.singleHeader("accept") == localMCPSecureMediaType,
              request.singleHeader("content-type") == localMCPSecureMediaType
        else {
            return MCPHTTPResponse(statusCode: 415)
        }
        let opened: SecureOpenedMCPRequest
        do {
            opened = try await processSecurityContext.openMCPRequest(
                request,
                expectedAuthority: expectedAuthority,
                maximumPlaintextBytes: limits.maximumMCPBodyBytes + limits.maximumHeaderBytes
            )
        } catch {
            // An unsigned/undecryptable outer failure contains no credential
            // information and must never be confused with an authenticated
            // authorization rejection.
            return MCPHTTPResponse(statusCode: 400, headers: ["Cache-Control": "no-store"])
        }

        let innerResponse = await handleSecuredMCP(opened)
        do {
            return try opened.responseContext.seal(innerResponse)
        } catch {
            return MCPHTTPResponse(statusCode: 503, headers: ["Cache-Control": "no-store"])
        }
    }

    private func descriptorResponse() -> MCPHTTPResponse {
        guard let value = try? JSONValue.encode(descriptor),
              let data = try? JSONEncoder.sorted.encode(value),
              data.count <= limits.maximumDescriptorBytes
        else { return smallError(status: 500, code: "descriptor_unavailable") }
        return MCPHTTPResponse(
            statusCode: 200,
            headers: [
                "Cache-Control": "no-store",
                "Content-Type": "application/json",
            ],
            body: data
        )
    }

    private func handlePairingInitiation(
        _ request: MCPHTTPRequest,
        expectedAuthority: String
    ) async -> MCPHTTPResponse {
        guard request.body.count <= limits.maximumPairingBodyBytes else {
            return smallError(status: 413, code: "invalid_pairing_request")
        }

        let now = Date()
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > now }
        pairingStarts.removeAll { now.timeIntervalSince($0) >= 60 }
        guard pendingPairings.count + activePairings.count < 3,
              pairingStarts.count < 5
        else {
            return smallError(
                status: 429,
                code: "pairing_rate_limited",
                headers: ["Retry-After": "60"]
            )
        }

        let pairingRequest: PairingRequest
        let initiationFingerprint: Data
        do {
            let value = try StrictJSONParser.parse(request.body)
            guard case let .object(object) = value,
                  Set(object.keys) == [
                      "clientSecretCommitment",
                      "consumer",
                      "consumerEphemeralPublicKey",
                      "expectedEndpoint",
                      "expectedInstanceId",
                      "expectedProducerPublicKey",
                      "requestNonce",
                      "schemaVersion",
                  ]
            else { throw LocalMCPError.invalidCommandInput }
            pairingRequest = try value.decode(as: PairingRequest.self)
            let expectedInstance = try pairingInstance(authority: expectedAuthority)
            try pairingRequest.validateChannelBoundInitiation(expected: expectedInstance)
            guard let peerPublicKey = pairingRequest.consumerEphemeralPublicKey else {
                throw LocalMCPError.invalidConfiguration
            }
            try await processSecurityContext.validatePairingPeerPublicKey(peerPublicKey)
            let canonical = try JSONEncoder.sorted.encode(JSONValue.encode(pairingRequest))
            initiationFingerprint = Data(SHA256.hash(data: canonical))
        } catch {
            return smallError(status: 400, code: "invalid_pairing_request")
        }

        // Peer-key validation crosses an actor boundary. Recheck every
        // allocation limit after that suspension so concurrent starts cannot
        // overbook pending slots or the rolling-rate budget.
        let reservationTime = Date()
        pendingPairings = pendingPairings.filter { $0.value.expiresAt > reservationTime }
        pairingStarts.removeAll { reservationTime.timeIntervalSince($0) >= 60 }
        retainedPairingInitiations = retainedPairingInitiations.filter {
            $0.value > reservationTime
        }
        guard pendingPairings.count + activePairings.count < 3,
              pairingStarts.count < 5,
              retainedPairingInitiations.count < 64
        else {
            return smallError(
                status: 429,
                code: "pairing_rate_limited",
                headers: ["Retry-After": "60"]
            )
        }
        guard retainedPairingInitiations[initiationFingerprint] == nil else {
            return smallError(status: 409, code: "pairing_replayed")
        }
        retainedPairingInitiations[initiationFingerprint] = reservationTime.addingTimeInterval(600)

        let identifier: PairingIdentifier
        let serverNonce: PairingNonce
        do {
            var candidate: PairingIdentifier
            repeat {
                candidate = try PairingIdentifier(bytes: Self.randomBytes(count: 32))
            } while pendingPairings[candidate.canonicalEncodedValue] != nil ||
                terminalPairingIDs.contains(candidate.canonicalEncodedValue)
            identifier = candidate
            serverNonce = try PairingNonce(bytes: Self.randomBytes(count: 32))
        } catch {
            return smallError(status: 503, code: "pairing_unavailable")
        }
        let identifierString = identifier.canonicalEncodedValue
        pendingPairings[identifierString] = PendingPairing(
            initiation: pairingRequest,
            identifier: identifier,
            serverNonce: serverNonce,
            expiresAt: reservationTime.addingTimeInterval(120)
        )
        pairingStarts.append(reservationTime)
        return .json(
            statusCode: 201,
            value: .object([
                "pairingId": .string(identifierString),
                "schemaVersion": .string(DiscoveryProfileVersion.current.rawValue),
                "serverNonce": serverNonce.withUnsafeBytes {
                    .string(Self.base64URLEncode($0))
                },
            ]),
            headers: ["Cache-Control": "no-store"]
        )
    }

    private func handlePairingCompletion(
        _ request: MCPHTTPRequest,
        expectedAuthority: String
    ) async -> MCPHTTPResponse {
        guard request.body.count <= limits.maximumPairingBodyBytes else {
            return smallError(status: 413, code: "invalid_pairing_request")
        }
        let suffix = String(request.path.dropFirst(pairingPath.count + 1))
        guard !suffix.isEmpty,
              !suffix.contains("/"),
              (try? PairingIdentifier(encodedValue: suffix)) != nil
        else { return smallError(status: 400, code: "invalid_pairing_request") }
        if terminalPairingIDs.contains(suffix) {
            return smallError(status: 409, code: "pairing_replayed")
        }
        guard let pending = pendingPairings[suffix] else {
            return smallError(status: 409, code: "pairing_replayed")
        }
        guard pending.expiresAt > Date() else {
            pendingPairings.removeValue(forKey: suffix)
            rememberTerminalPairingID(suffix)
            return smallError(status: 408, code: "pairing_expired")
        }

        let finalized: PairingRequest
        let transcript: PairingTranscript
        do {
            let value = try StrictJSONParser.parse(request.body)
            guard case let .object(object) = value,
                  Set(object.keys) == [
                      "clientSecretCommitment",
                      "consumer",
                      "consumerEphemeralPublicKey",
                      "expectedEndpoint",
                      "expectedInstanceId",
                      "expectedProducerPublicKey",
                      "pairingId",
                      "requestNonce",
                      "revealedClientSecret",
                      "schemaVersion",
                      "serverNonce",
                  ]
            else { throw LocalMCPError.invalidConfiguration }
            let decoded = try value.decode(as: PairingRequest.self)
            guard decoded.pairingID == pending.identifier,
                  decoded.serverNonce == pending.serverNonce,
                  let revealedSecret = decoded.revealedClientSecret
            else { throw LocalMCPError.invalidConfiguration }
            let expected = try pending.initiation.serverFinalized(
                pairingID: pending.identifier,
                serverNonce: pending.serverNonce,
                revealedClientSecret: revealedSecret
            )
            guard decoded == expected else { throw LocalMCPError.invalidConfiguration }
            let expectedInstance = try pairingInstance(authority: expectedAuthority)
            try pending.initiation.validateChannelBoundInitiation(expected: expectedInstance)
            guard let channelBinding = descriptor.channelBinding else {
                throw LocalMCPError.invalidConfiguration
            }
            try decoded.validateServerFinalized(
                producerID: descriptor.server.stableID,
                channelBinding: channelBinding
            )
            finalized = decoded
            transcript = try PairingTranscript(
                finalizedRequest: decoded,
                producerID: descriptor.server.stableID,
                channelBinding: channelBinding
            )
        } catch {
            return smallError(status: 400, code: "invalid_pairing_request")
        }

        // Completion is one-shot before approval work begins. A retry cannot
        // mint or retrieve another bearer, even if the approval callback is
        // cancelled or its response is lost.
        pendingPairings.removeValue(forKey: suffix)
        rememberTerminalPairingID(suffix)
        let remainingPairingLifetime = pending.expiresAt.timeIntervalSince(Date())
        guard remainingPairingLifetime > 0 else {
            return smallError(status: 408, code: "pairing_expired")
        }
        let operationID = UUID()
        let operation = LocalMCPAsyncOperation<AuthorizationGrant>(
            timeoutAfter: remainingPairingLifetime,
            timeoutError: LocalMCPError.pairingExpired
        ) { [service] in
            try await service.requestPairing(finalized)
        }
        activePairings[operationID] = operation
        let result: Result<AuthorizationGrant, any Error>
        do {
            result = .success(
                try await operation.value(cancellationError: LocalMCPError.cancelled)
            )
        } catch {
            result = .failure(error)
        }
        activePairings.removeValue(forKey: operationID)

        switch result {
        case let .success(grant):
            do {
                let plaintext = try pairingSuccessPayload(grant, request: finalized)
                guard let peerPublicKey = finalized.consumerEphemeralPublicKey else {
                    throw LocalMCPError.invalidConfiguration
                }
                let sealed = try await processSecurityContext.sealPairingResponse(
                    plaintext: plaintext,
                    peerPublicKey: peerPublicKey,
                    transcript: transcript
                )
                return MCPHTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Cache-Control": "no-store",
                        "Content-Type": localMCPSecureMediaType,
                    ],
                    body: sealed
                )
            } catch {
                return pairingFailure(error)
            }
        case let .failure(error):
            return pairingFailure(error)
        }
    }

    private func pairingSuccessPayload(
        _ grant: AuthorizationGrant,
        request: PairingRequest
    ) throws -> Data {
        let token = grant.credential.withUnsafeEncodedValue { $0 }
        let metadata = grant.metadata
        guard metadata.producerID == descriptor.server.stableID,
              metadata.consumer.representsSameInstallation(as: request.consumer),
              metadata.revokedAt == nil,
              let channelBinding = descriptor.channelBinding,
              grant.endpointBinding == AuthorizationEndpointBinding(
                  instanceID: descriptor.instanceID,
                  channelBinding: channelBinding
              )
        else { throw LocalMCPError.unauthorized }
        let grantObject: [String: JSONValue] = [
            "id": .string(metadata.grantID),
            "producerId": .string(metadata.producerID),
            "consumerId": .string(metadata.consumer.stableID),
            "consumerInstallationId": .string(metadata.consumer.installationID),
            "issuedAt": .string(Self.timestamp(metadata.issuedAt)),
            "expiresAt": metadata.expiresAt.map { .string(Self.timestamp($0)) } ?? .null,
        ]
        let payload: JSONValue = .object([
                "schemaVersion": .string(DiscoveryProfileVersion.current.rawValue),
                "grant": .object(grantObject),
                "accessToken": .string(token),
                "endpointBinding": try JSONValue.encode(grant.endpointBinding!),
            ])
        return try JSONEncoder.sorted.encode(payload)
    }

    private func pairingFailure(_ error: any Error) -> MCPHTTPResponse {
        switch error as? LocalMCPError {
        case .pairingDenied:
            smallError(status: 403, code: "pairing_denied")
        case .pairingExpired:
            smallError(status: 408, code: "pairing_expired")
        case .pairingReplayed:
            smallError(status: 409, code: "pairing_replayed")
        case .cancelled:
            smallError(status: 503, code: "pairing_unavailable")
        default:
            smallError(status: 503, code: "pairing_unavailable")
        }
    }

    private func handleSecuredMCP(_ opened: SecureOpenedMCPRequest) async -> MCPHTTPResponse {
        let request = opened.request
        guard request.path == descriptor.mcp.endpoint,
              request.method == "POST" || request.method == "DELETE"
        else { return smallError(status: 400, code: "invalid_request") }

        let allowedHeaders: Set<String> = [
            "accept",
            "authorization",
            "content-type",
            "mcp-protocol-version",
            "mcp-session-id",
        ]
        guard Set(request.headers.keys).isSubset(of: allowedHeaders),
              let credential = bearerCredential(request)
        else { return unauthorizedResponse() }

        // A rotated credential may terminate only the session that was opened
        // with that exact credential. All POST operations reauthenticate on
        // every request so pending grants can be promoted and revocations take
        // effect immediately.
        if request.method == "DELETE" {
            guard sessionMatches(request, credential: credential) else {
                return MCPHTTPResponse(statusCode: 404)
            }
            guard let sequence = opened.sequence,
                  reserveSessionSequence(request, credential: credential, sequence: sequence)
            else { return smallError(status: 409, code: "secure_replay_rejected") }
            return terminateSession(request, credential: credential)
        }

        // A valid AEAD record consumes its replay coordinate before any
        // potentially suspended authorization lookup or MCP parsing. Retrying
        // after an outage therefore requires a fresh message ID/sequence and a
        // captured record can never become dispatchable later.
        if request.singleHeader("mcp-session-id") != nil {
            guard sessionMatches(request, credential: credential) else {
                return MCPHTTPResponse(statusCode: 404)
            }
            guard let sequence = opened.sequence,
                  reserveSessionSequence(request, credential: credential, sequence: sequence)
            else { return smallError(status: 409, code: "secure_replay_rejected") }
        } else {
            guard opened.sequence == nil,
                  !initializeReplayCapacityExhausted,
                  !initializeReplayIDs.contains(opened.messageID)
            else { return smallError(status: 409, code: "secure_replay_rejected") }
            if initializeReplayIDs.count >= 65_536 {
                initializeReplayCapacityExhausted = true
                return smallError(status: 503, code: "producer_unavailable")
            }
            initializeReplayIDs.insert(opened.messageID)
        }

        guard acceptsMCP(request), hasJSONContentType(request) else {
            return MCPHTTPResponse(statusCode: hasJSONContentType(request) ? 406 : 415)
        }

        do {
            try await service.authenticate(credential: credential)
        } catch let error as LocalMCPError where Self.isAuthenticationRejection(error) {
            return unauthorizedResponse()
        } catch {
            return smallError(status: 503, code: "producer_unavailable")
        }
        if Task.isCancelled {
            return jsonRPCError(id: nil, code: -32_800, message: "Request cancelled")
        }

        return await handleMCP(request, credential: credential)
    }

    private func reserveSessionSequence(
        _ request: MCPHTTPRequest,
        credential: AuthorizationCredential,
        sequence: UInt64
    ) -> Bool {
        guard let sessionID = request.singleHeader("mcp-session-id"),
              var session = sessions[sessionID],
              session.credentialDigest.constantTimeEquals(credential.digest),
              session.replayWindow.accept(sequence)
        else { return false }
        sessions[sessionID] = session
        return true
    }

    private func sessionMatches(
        _ request: MCPHTTPRequest,
        credential: AuthorizationCredential
    ) -> Bool {
        guard let sessionID = request.singleHeader("mcp-session-id"),
              let session = sessions[sessionID]
        else { return false }
        return session.credentialDigest.constantTimeEquals(credential.digest)
    }

    private func handleMCP(
        _ request: MCPHTTPRequest,
        credential: AuthorizationCredential
    ) async -> MCPHTTPResponse {
        guard request.body.count <= limits.maximumMCPBodyBytes else {
            return MCPHTTPResponse(statusCode: 413)
        }

        let value: JSONValue
        do {
            value = try StrictJSONParser.parse(request.body)
        } catch {
            return jsonRPCError(id: nil, code: -32_700, message: "Parse error")
        }
        guard case let .object(envelope) = value else {
            return jsonRPCError(id: nil, code: -32_600, message: "Invalid Request")
        }

        let id = envelope["id"]
        guard validJSONRPCID(id) else {
            return jsonRPCError(id: nil, code: -32_600, message: "Invalid Request")
        }
        guard envelope["jsonrpc"] == .string("2.0"),
              case let .string(method)? = envelope["method"]
        else { return invalidEnvelopeResponse(id: id) }
        guard Self.validMethod(method) else {
            return invalidEnvelopeResponse(id: id)
        }

        if method == "initialize" {
            guard request.headerValues("mcp-protocol-version").isEmpty,
                  request.headerValues("mcp-session-id").isEmpty,
                  id != nil
            else { return id == nil ? MCPHTTPResponse(statusCode: 202) : invalidEnvelopeResponse(id: id) }
            return await initialize(envelope, id: id!, credential: credential)
        }

        guard request.singleHeader("mcp-protocol-version") == MCPProtocolVersion.current.rawValue else {
            return MCPHTTPResponse(statusCode: 400)
        }
        guard let sessionID = request.singleHeader("mcp-session-id") else {
            return MCPHTTPResponse(statusCode: 400)
        }
        guard let session = sessions[sessionID],
              session.credentialDigest.constantTimeEquals(credential.digest)
        else {
            return MCPHTTPResponse(statusCode: 404)
        }

        switch method {
        case "notifications/initialized":
            guard id == nil else { return jsonRPCError(id: id, code: -32_600, message: "Invalid Request") }
            if let params = envelope["params"], case .object = params {
                // Optional object parameters are accepted by MCP 2025-11-25.
            } else if envelope["params"] != nil {
                return MCPHTTPResponse(statusCode: 202)
            }
            do {
                try await service.initialized(credential: credential)
                guard !Task.isCancelled else {
                    return MCPHTTPResponse(statusCode: 503)
                }
                guard sessions[sessionID] != nil else {
                    return MCPHTTPResponse(statusCode: 404)
                }
                sessions[sessionID]?.initialized = true
                return MCPHTTPResponse(statusCode: 202)
            } catch let error as LocalMCPError where Self.isAuthenticationRejection(error) {
                return MCPHTTPResponse(
                    statusCode: 401,
                    headers: ["WWW-Authenticate": "Bearer"]
                )
            } catch {
                return MCPHTTPResponse(statusCode: 503)
            }

        case "notifications/cancelled":
            guard id == nil,
                  session.initialized,
                  case let .object(params)? = envelope["params"],
                  let requestIDValue = params["requestId"],
                  validJSONRPCID(requestIDValue),
                  requestIDValue != .null,
                  Self.validCancellationReason(params["reason"])
            else {
                return id == nil
                    ? MCPHTTPResponse(statusCode: 202)
                    : jsonRPCError(id: id, code: -32_600, message: "Invalid Request")
            }
            let key = ActiveCallKey(
                sessionID: sessionID,
                requestID: requestIDValue
            )
            activeCalls[key]?.cancel(with: LocalMCPError.cancelled)
            return MCPHTTPResponse(statusCode: 202)

        case "tools/list":
            guard let id else { return MCPHTTPResponse(statusCode: 202) }
            guard session.initialized else {
                return jsonRPCError(id: id, code: -32_600, message: "Client not initialized")
            }
            guard Self.validListParameters(envelope["params"]) else {
                return jsonRPCError(id: id, code: -32_602, message: "Invalid params")
            }
            do {
                let commands = try await service.listCommands(credential: credential)
                guard !Task.isCancelled,
                      !stopped,
                      let currentSession = sessions[sessionID],
                      currentSession.initialized,
                      currentSession.credentialDigest.constantTimeEquals(credential.digest)
                else { throw LocalMCPError.cancelled }
                let tools = try commands.map(Self.toolValue)
                return jsonRPCResult(id: id, result: .object(["tools": .array(tools)]))
            } catch {
                return mappedError(error, id: id)
            }

        case "tools/call":
            guard let id else { return MCPHTTPResponse(statusCode: 202) }
            guard session.initialized else {
                return jsonRPCError(id: id, code: -32_600, message: "Client not initialized")
            }
            return await callTool(
                envelope,
                id: id,
                sessionID: sessionID,
                credential: credential
            )

        default:
            return id == nil
                ? MCPHTTPResponse(statusCode: 202)
                : jsonRPCError(id: id, code: -32_601, message: "Method not found")
        }
    }

    private func initialize(
        _ envelope: [String: JSONValue],
        id: JSONValue,
        credential: AuthorizationCredential
    ) async -> MCPHTTPResponse {
        guard case let .object(params)? = envelope["params"],
              case let .string(protocolVersion)? = params["protocolVersion"],
              case .object? = params["capabilities"],
              case let .object(clientInfo)? = params["clientInfo"],
              case .string? = clientInfo["name"],
              case .string? = clientInfo["version"]
        else { return jsonRPCError(id: id, code: -32_602, message: "Invalid params") }

        do {
            let initialized = try await service.initialize(
                supportedProtocolVersions: [protocolVersion],
                credential: credential
            )
            guard initialized.protocolVersion == MCPProtocolVersion.current.rawValue else {
                return jsonRPCError(id: id, code: -32_602, message: "Unsupported protocol version")
            }
            guard !Task.isCancelled, !stopped else { throw LocalMCPError.cancelled }

            if sessions.count >= limits.maximumSessions,
               let oldest = sessions.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
            {
                cancelCalls(sessionID: oldest)
                sessions.removeValue(forKey: oldest)
            }
            let sessionID = UUID().uuidString.lowercased()
            sessions[sessionID] = Session(
                credentialDigest: credential.digest,
                createdAt: Date(),
                initialized: false
            )
            let response = jsonRPCResult(
                id: id,
                result: .object([
                    "protocolVersion": .string(initialized.protocolVersion),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(false)]),
                    ]),
                    "serverInfo": .object([
                        "name": .string(initialized.server.stableID),
                        "title": .string(initialized.server.displayName),
                        "version": .string(initialized.server.version),
                    ]),
                ]),
                headers: ["Mcp-Session-Id": sessionID]
            )
            return response
        } catch {
            return mappedError(error, id: id)
        }
    }

    private func callTool(
        _ envelope: [String: JSONValue],
        id: JSONValue,
        sessionID: String,
        credential: AuthorizationCredential
    ) async -> MCPHTTPResponse {
        guard case let .object(params)? = envelope["params"],
              case let .string(name)? = params["name"],
              CommandDefinition.isValidName(name)
        else { return jsonRPCError(id: id, code: -32_602, message: "Invalid params") }
        let arguments = params["arguments"] ?? .object([:])
        guard case .object = arguments,
              let argumentData = try? JSONEncoder.sorted.encode(arguments),
              argumentData.count <= limits.maximumCommandArgumentBytes
        else { return jsonRPCError(id: id, code: -32_602, message: "Invalid params") }

        do {
            let request = CommandCallRequest(
                name: name,
                arguments: arguments,
                requestID: Self.requestID(id),
                deadline: Date().addingTimeInterval(limits.handlerTimeout)
            )
            let key = ActiveCallKey(sessionID: sessionID, requestID: id)
            guard activeCalls[key] == nil else {
                return jsonRPCError(id: id, code: -32_600, message: "Duplicate request ID")
            }
            let maximumCommandArgumentBytes = limits.maximumCommandArgumentBytes
            let operation = LocalMCPAsyncOperation<CommandResult>(
                timeoutAfter: limits.handlerTimeout,
                timeoutError: LocalMCPError.requestTimedOut
            ) { [service] in
                let commands = try await service.listCommands(credential: credential)
                guard let definition = commands.first(where: { $0.name == name }) else {
                    throw LocalMCPError.commandNotFound
                }
                guard definition.isValid,
                      MCPJSONSchemaValidator.isSupported(schema: definition.inputSchema),
                      definition.outputSchema.map(MCPJSONSchemaValidator.isSupported(schema:)) ?? true
                else { throw LocalMCPError.commandFailed }
                try MCPJSONSchemaValidator.validate(
                    arguments,
                    against: definition.inputSchema,
                    maximumEncodedBytes: maximumCommandArgumentBytes
                )
                return try await service.callCommand(request, credential: credential)
            }
            activeCalls[key] = operation
            let result: CommandResult
            do {
                result = try await operation.value(cancellationError: LocalMCPError.cancelled)
                activeCalls.removeValue(forKey: key)
            } catch {
                activeCalls.removeValue(forKey: key)
                throw error
            }
            guard !stopped, sessions[sessionID] != nil else {
                throw LocalMCPError.cancelled
            }
            var resultObject: [String: JSONValue] = ["isError": .bool(result.isError)]
            if let text = result.text {
                resultObject["content"] = .array([
                    .object(["type": .string("text"), "text": .string(text)]),
                ])
            } else {
                resultObject["content"] = .array([])
            }
            if let structured = result.structuredContent {
                guard case .object = structured else { throw LocalMCPError.commandFailed }
                resultObject["structuredContent"] = structured
            }
            return jsonRPCResult(id: id, result: .object(resultObject))
        } catch {
            return mappedError(error, id: id)
        }
    }

    private func terminateSession(
        _ request: MCPHTTPRequest,
        credential: AuthorizationCredential
    ) -> MCPHTTPResponse {
        guard request.body.isEmpty,
              request.singleHeader("mcp-protocol-version") == MCPProtocolVersion.current.rawValue,
              let sessionID = request.singleHeader("mcp-session-id")
        else { return MCPHTTPResponse(statusCode: 400) }
        guard let session = sessions[sessionID],
              session.credentialDigest.constantTimeEquals(credential.digest)
        else { return MCPHTTPResponse(statusCode: 404) }
        sessions.removeValue(forKey: sessionID)
        cancelCalls(sessionID: sessionID)
        return MCPHTTPResponse(statusCode: 204)
    }

    private func bearerCredential(_ request: MCPHTTPRequest) -> AuthorizationCredential? {
        let values = request.headerValues("authorization")
        guard values.count == 1,
              !values[0].contains(","),
              values[0].hasPrefix("Bearer "),
              values[0].dropFirst(7).allSatisfy({ !$0.isWhitespace }),
              !values[0].dropFirst(7).isEmpty
        else { return nil }
        return try? AuthorizationCredential(encodedValue: String(values[0].dropFirst(7)))
    }

    private func acceptsJSON(_ request: MCPHTTPRequest) -> Bool {
        guard let accept = request.singleHeader("accept") else { return false }
        return Self.acceptsMediaType("application/json", in: accept)
    }

    private func acceptsMCP(_ request: MCPHTTPRequest) -> Bool {
        guard let accept = request.singleHeader("accept") else { return false }
        return Self.acceptsMediaType("application/json", in: accept)
            && Self.acceptsMediaType("text/event-stream", in: accept)
    }

    private static func acceptsMediaType(_ expected: String, in header: String) -> Bool {
        header.split(separator: ",", omittingEmptySubsequences: false).contains { item in
            let components = item.split(separator: ";", omittingEmptySubsequences: false)
            guard let rawType = components.first,
                  rawType.trimmingCharacters(in: .whitespaces).lowercased() == expected
            else { return false }
            var quality = 1.0
            var sawQuality = false
            for parameter in components.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return false }
                let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "q" {
                    guard !sawQuality,
                          let parsed = Double(pair[1].trimmingCharacters(in: .whitespaces)),
                          (0...1).contains(parsed)
                    else { return false }
                    sawQuality = true
                    quality = parsed
                }
            }
            return quality > 0
        }
    }

    private func hasJSONContentType(_ request: MCPHTTPRequest) -> Bool {
        guard let contentType = request.singleHeader("content-type") else { return false }
        return contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    private func validJSONRPCID(_ id: JSONValue?) -> Bool {
        switch id {
        case nil, .string, .integer, .unsignedInteger:
            true
        case let .number(value):
            value.isFinite
        default:
            false
        }
    }

    private func mappedError(_ error: any Error, id: JSONValue?) -> MCPHTTPResponse {
        switch error as? LocalMCPError {
        case .incompatibleMCPProtocol:
            jsonRPCError(id: id, code: -32_602, message: "Unsupported protocol version")
        case .invalidCommandInput:
            jsonRPCError(id: id, code: -32_602, message: "Invalid params")
        case .commandNotFound:
            jsonRPCError(id: id, code: -32_004, message: "Unknown tool")
        case .requestTimedOut:
            jsonRPCError(id: id, code: -32_001, message: "Request timed out")
        case .cancelled:
            jsonRPCError(id: id, code: -32_800, message: "Request cancelled")
        default:
            jsonRPCError(id: id, code: -32_603, message: "Internal error")
        }
    }

    private func unauthorizedResponse() -> MCPHTTPResponse {
        smallError(
            status: 401,
            code: "unauthorized",
            headers: [
                "Cache-Control": "no-store",
                "WWW-Authenticate": "Bearer",
            ]
        )
    }

    private static func isAuthenticationRejection(_ error: LocalMCPError) -> Bool {
        switch error {
        case .pairingRequired, .unauthorized, .grantRevoked:
            true
        default:
            false
        }
    }

    private func jsonRPCResult(
        id: JSONValue,
        result: JSONValue,
        headers: [String: String] = [:]
    ) -> MCPHTTPResponse {
        .json(
            statusCode: 200,
            value: .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": result,
            ]),
            headers: headers
        )
    }

    private func jsonRPCError(
        id: JSONValue?,
        code: Int64,
        message: String
    ) -> MCPHTTPResponse {
        .json(
            statusCode: 200,
            value: .object([
                "jsonrpc": .string("2.0"),
                "id": id ?? .null,
                "error": .object([
                    "code": .integer(code),
                    "message": .string(message),
                ]),
            ])
        )
    }

    private func invalidEnvelopeResponse(id: JSONValue?) -> MCPHTTPResponse {
        id == nil
            ? MCPHTTPResponse(statusCode: 400)
            : jsonRPCError(id: id, code: -32_600, message: "Invalid Request")
    }

    private func smallError(
        status: Int,
        code: String,
        headers: [String: String] = [:]
    ) -> MCPHTTPResponse {
        .json(
            statusCode: status,
            value: .object([
                "schemaVersion": .string(DiscoveryProfileVersion.current.rawValue),
                "error": .object([
                    "code": .string(code),
                    "message": .string(Self.safeMessage(for: code)),
                ]),
            ]),
            headers: headers
        )
    }

    private static func toolValue(_ definition: CommandDefinition) throws -> JSONValue {
        guard definition.isValid,
              MCPJSONSchemaValidator.isSupported(schema: definition.inputSchema),
              definition.outputSchema.map(MCPJSONSchemaValidator.isSupported(schema:)) ?? true
        else { throw LocalMCPError.commandFailed }
        var object: [String: JSONValue] = [
            "name": .string(definition.name),
            "description": .string(definition.description),
            "inputSchema": definition.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(definition.annotations.readOnly),
                "idempotentHint": .bool(definition.annotations.idempotent),
                "destructiveHint": .bool(definition.annotations.destructive),
                "openWorldHint": .bool(definition.annotations.openWorld),
            ]),
        ]
        if let title = definition.title { object["title"] = .string(title) }
        if let outputSchema = definition.outputSchema { object["outputSchema"] = outputSchema }
        return .object(object)
    }

    private static func requestID(_ id: JSONValue) -> String {
        switch id {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .unsignedInteger(value): String(value)
        case let .number(value): String(value)
        default: UUID().uuidString.lowercased()
        }
    }

    private static func validCancellationReason(_ value: JSONValue?) -> Bool {
        if value == nil { return true }
        if case .string = value { return true }
        return false
    }

    private static func validListParameters(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard case let .object(parameters) = value else { return false }
        if let cursor = parameters["cursor"], case .string = cursor { return true }
        return parameters["cursor"] == nil
    }

    private static func validMethod(_ value: String) -> Bool {
        guard (1...1_024).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) ||
                scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(
            .iso8601
                .year()
                .month()
                .day()
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .omitted)
        )
    }

    private static func safeMessage(for code: String) -> String {
        switch code {
        case "forbidden_request_context": "The request context is not allowed."
        case "invalid_pairing_request": "The pairing request is invalid."
        case "pairing_denied": "The producer did not approve this pairing request."
        case "pairing_expired": "The pairing request expired."
        case "pairing_replayed": "The pairing request cannot be reused."
        case "pairing_rate_limited": "Too many pairing requests."
        case "pairing_unavailable": "Pairing is temporarily unavailable."
        case "unauthorized": "The request is not authorized."
        case "not_found": "The requested route was not found."
        case "producer_unavailable": "The producer is unavailable."
        case "secure_replay_rejected": "The secure request cannot be reused."
        default: "The request could not be completed."
        }
    }

    private func pairingInstance(authority: String) throws -> ProducerInstance {
        let prefix = "127.0.0.1:"
        guard authority.hasPrefix(prefix),
              let port = UInt16(authority.dropFirst(prefix.count)),
              port != 0,
              let channelBinding = descriptor.channelBinding,
              channelBinding.isSupported
        else { throw LocalMCPError.invalidConfiguration }
        return ProducerInstance(
            identity: descriptor.server,
            instanceID: descriptor.instanceID,
            endpoint: try LoopbackEndpoint(port: port, path: descriptor.mcp.endpoint),
            descriptorURL: try LoopbackEndpoint(port: port, path: descriptorPath),
            channelBinding: channelBinding
        )
    }

    private func rememberTerminalPairingID(_ value: String) {
        if terminalPairingIDs.count >= 256, let oldestArbitrary = terminalPairingIDs.first {
            terminalPairingIDs.remove(oldestArbitrary)
        }
        terminalPairingIDs.insert(value)
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func cancelCalls(sessionID: String) {
        let keys = activeCalls.keys.filter { $0.sessionID == sessionID }
        for key in keys {
            activeCalls.removeValue(forKey: key)?.cancel(with: LocalMCPError.cancelled)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
