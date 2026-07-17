import Darwin
import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPMCPAdapter
import LocalMCPProducer
import LocalMCPTesting
import Testing

private struct HTTPMessage: Codable, Sendable, Equatable { let message: String }

private let httpProducerIdentity = ProducerIdentity(
    stableID: "com.example.http-echo",
    displayName: "HTTP Echo",
    version: "1.0.0"
)

private let httpConsumerIdentity = ConsumerIdentity(
    stableID: "com.example.http-client",
    displayName: "HTTP Client",
    version: "1.0.0",
    installationID: "cb434c5d-3982-4b3f-aa45-aa03afa5d45f"
)

private let httpEchoDefinition = CommandDefinition(
    name: "echo",
    title: "Echo",
    description: "Return a bounded message",
    inputSchema: .object([
        "type": .string("object"),
        "required": .array([.string("message")]),
        "additionalProperties": .bool(false),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "minLength": .integer(1),
                "maxLength": .integer(64),
            ]),
        ]),
    ]),
    outputSchema: .object([
        "type": .string("object"),
        "required": .array([.string("message")]),
        "properties": .object(["message": .object(["type": .string("string")])]),
    ]),
    annotations: .init(readOnly: true, idempotent: true)
)

private actor HTTPInvocationRecorder {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    var count: Int { values.count }
}

private struct HTTPFixture: Sendable {
    let producer: LocalMCPProducer
    let transport: LocalMCPHTTPProducerTransport
    let catalog: DiscoveryCatalog
    let store: InMemoryProducerGrantStore
    let recorder: HTTPInvocationRecorder
    let instance: ProducerInstance
}

private func makeHTTPFixture(
    approval: any PairingApproving = RecordingPairingApprover(),
    port: UInt16 = 0,
    handlerTimeout: TimeInterval = 30,
    maximumSessions: Int = 128,
    definition: CommandDefinition = httpEchoDefinition,
    handler: (@Sendable (HTTPMessage, CommandContext) async throws -> CommandResult)? = nil
) async throws -> HTTPFixture {
    let catalog = DiscoveryCatalog()
    let store = InMemoryProducerGrantStore()
    let recorder = HTTPInvocationRecorder()
    let transport = LocalMCPHTTPProducerTransport(
        port: port,
        handlerTimeout: handlerTimeout,
        maximumSessions: maximumSessions
    )
    let producer = LocalMCPProducer(
        identity: httpProducerIdentity,
        instanceID: "8ecf3c61-8471-48dd-88d8-e29d48c9290d",
        transport: transport,
        advertiser: catalog,
        grantStore: store,
        approval: approval
    )
    try await producer.register(definition) { (input: HTTPMessage, context: CommandContext) in
        if let handler { return try await handler(input, context) }
        await recorder.record(input.message)
        return try .structured(input, text: input.message)
    }
    try await producer.start()
    guard let instance = await catalog.snapshot().first else {
        await producer.stop()
        throw LocalMCPError.producerUnavailable
    }
    return HTTPFixture(
        producer: producer,
        transport: transport,
        catalog: catalog,
        store: store,
        recorder: recorder,
        instance: instance
    )
}

private func withHTTPFixture(
    approval: any PairingApproving = RecordingPairingApprover(),
    port: UInt16 = 0,
    handlerTimeout: TimeInterval = 30,
    maximumSessions: Int = 128,
    definition: CommandDefinition = httpEchoDefinition,
    handler: (@Sendable (HTTPMessage, CommandContext) async throws -> CommandResult)? = nil,
    operation: (HTTPFixture) async throws -> Void
) async throws {
    let fixture = try await makeHTTPFixture(
        approval: approval,
        port: port,
        handlerTimeout: handlerTimeout,
        maximumSessions: maximumSessions,
        definition: definition,
        handler: handler
    )
    do {
        try await operation(fixture)
        await fixture.producer.stop()
    } catch {
        await fixture.producer.stop()
        throw error
    }
}

// The raw-socket fixture performs blocking POSIX reads. Running dozens of
// these tests concurrently can exhaust the cooperative executor and deadlock
// the test process before peers are scheduled to answer those reads.
@Suite("Authenticated loopback HTTP and MCP wire", .serialized)
struct HTTPTransportIntegrationTests {
    @Test("pair → initialize → initialized → list → call runs over a real ephemeral socket")
    func completeNetworkLifecycle() async throws {
        try await withHTTPFixture { fixture in
            #expect(fixture.instance.endpoint.port != 0)
            #expect(fixture.instance.endpoint.url.host == "127.0.0.1")

            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            let grant = try await consumer.pair()
            let initialization = try await consumer.initialize(grant: grant)
            #expect(initialization.protocolVersion == MCPProtocolVersion.current.rawValue)
            #expect(initialization.server == httpProducerIdentity)
            #expect(try await consumer.listTools().map(\.name) == ["echo"])
            let result: HTTPMessage = try await consumer.call(
                "echo",
                input: HTTPMessage(message: "hello over HTTP"),
                as: HTTPMessage.self
            )
            #expect(result == HTTPMessage(message: "hello over HTTP"))
            #expect(await fixture.recorder.count == 1)
        }
    }

    @Test("descriptor is served without secrets and stop releases the fixed port")
    func descriptorAndPortRelease() async throws {
        try await withHTTPFixture { fixture in
            let (data, response) = try await URLSession.shared.data(from: fixture.instance.descriptorURL.url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data.count < 64 * 1_024)
            let descriptor = try JSONDecoder().decode(ProducerDescriptor.self, from: data)
            #expect(descriptor.instanceID == fixture.instance.instanceID)
            #expect(descriptor.mcp.endpoint == "/mcp")
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.localizedCaseInsensitiveContains("token"))
            #expect(!text.localizedCaseInsensitiveContains("authorization"))
        }
    }

    @Test("stop releases the bound port for an immediate real-listener restart")
    func portReleaseAndRestart() async throws {
        let first = try await makeHTTPFixture()
        let port = first.instance.endpoint.port
        await first.producer.stop()
        let second = try await makeHTTPFixture(port: port)
        #expect(second.instance.endpoint.port == port)
        await second.producer.stop()
    }

    @Test("revoked and wrong credentials are rejected before command dispatch")
    func authenticationPrecedesDispatch() async throws {
        try await withHTTPFixture { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            let grant = try await consumer.pair()
            _ = try await consumer.initialize(grant: grant)
            try await fixture.producer.revokeGrant(grant.metadata.grantID)
            await expectHTTPError(.unauthorized) {
                _ = try await consumer.call("echo", arguments: .object(["message": .string("blocked")]))
            }
            #expect(await fixture.recorder.count == 0)

            let wire = try SecureWire(instance: fixture.instance)
            let body = #"{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}"#

            // The bearer travels only inside the sealed envelope; omitting it
            // is an authenticated-envelope 401, never an outer failure.
            let missing = try await wire.send(token: nil, body: body).inner()
            #expect(missing.statusCode == 401)

            let wrongCredential = try AuthorizationCredential(bytes: [UInt8](repeating: 77, count: 32))
            let wrongToken = wrongCredential.withUnsafeEncodedValue { $0 }
            let wrong = try await wire.send(token: wrongToken, body: body)
            let wrongInner = try wrong.inner()
            #expect(wrongInner.statusCode == 401)
            #expect(!String(decoding: wrong.raw, as: UTF8.self).contains(wrongToken))
            #expect(!String(decoding: wrongInner.body, as: UTF8.self).contains(wrongToken))

            // A plaintext outer bearer invalidates the whole envelope before
            // any authorization interpretation.
            let plaintextBearer = try await wire.send(
                token: wrongToken,
                extraOuterHeaders: ["Authorization": "Bearer \(wrongToken)"],
                body: body
            )
            #expect(plaintextBearer.outerStatus == 400)

            let expiredCredential = try AuthorizationCredential(bytes: [UInt8](repeating: 78, count: 32))
            try await fixture.store.saveReplacingActiveGrant(
                ProducerGrantRecord(
                    metadata: AuthorizationGrantMetadata(
                        grantID: "expired-grant",
                        producerID: httpProducerIdentity.stableID,
                        consumer: httpConsumerIdentity,
                        issuedAt: Date(timeIntervalSince1970: 1),
                        expiresAt: Date(timeIntervalSince1970: 2)
                    ),
                    credentialDigest: expiredCredential.digest
                )
            )
            let expiredToken = expiredCredential.withUnsafeEncodedValue { $0 }
            let expired = try await wire.send(token: expiredToken, body: body).inner()
            #expect(expired.statusCode == 401)
            #expect(await fixture.recorder.count == 0)
        }
    }

    @Test("credential-store outage is 503 before parsing and never masquerades as bad bearer")
    func authenticationStoreOutage() async throws {
        let catalog = DiscoveryCatalog()
        let store = ToggleAuthenticationFailureStore()
        let transport = LocalMCPHTTPProducerTransport()
        let producer = LocalMCPProducer(
            identity: httpProducerIdentity,
            instanceID: "1919b45d-19b2-44d0-aeaf-49ed60467a10",
            transport: transport,
            advertiser: catalog,
            grantStore: store,
            approval: RecordingPairingApprover()
        )
        try await producer.register(httpEchoDefinition) {
            (input: HTTPMessage, _: CommandContext) in
            try .structured(input)
        }
        try await producer.start()
        do {
            guard let instance = await catalog.snapshot().first else {
                throw LocalMCPError.producerUnavailable
            }
            let token = try await pairRaw(instance: instance, nonceByte: 58)
            await store.failAuthenticationReads()
            let wire = try SecureWire(instance: instance)
            let response = try await wire.send(token: token, body: #"{"jsonrpc":"#).inner()
            #expect(response.statusCode == 503)
            let responseBody = String(decoding: response.body, as: UTF8.self)
            #expect(responseBody.contains("producer_unavailable"))
            #expect(!responseBody.contains("Parse error"))
            #expect(!responseBody.contains(token))
            await producer.stop()
        } catch {
            await producer.stop()
            throw error
        }
    }

    @Test("Host, Origin, and MCP Accept policies fail closed")
    func requestContextPolicy() async throws {
        try await withHTTPFixture { fixture in
            let port = fixture.instance.endpoint.port
            let hostileHost = try await rawHTTPExchange(
                port: port,
                request: "GET /local-mcp/v1/descriptor.json HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n"
            )
            #expect(rawStatus(hostileHost) == 403)

            let hostileOrigin = try await rawHTTPExchange(
                port: port,
                request: "GET /local-mcp/v1/descriptor.json HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: null\r\n\r\n"
            )
            #expect(rawStatus(hostileOrigin) == 403)

            let token = try await pairRaw(fixture: fixture)
            let wire = try SecureWire(instance: fixture.instance)
            let initializeBody = #"{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}"#
            let jsonOnly = try await wire.send(
                token: token,
                accept: "application/json",
                body: initializeBody
            ).inner()
            #expect(jsonOnly.statusCode == 406)
        }
    }

    @Test("declared and chunked oversized bodies are rejected before JSON parsing")
    func bodyLimits() async throws {
        try await withHTTPFixture { fixture in
            let port = fixture.instance.endpoint.port
            let outerLimit = try MCPHTTPServerLimits().maximumSecureEnvelopeBytes

            // Beyond the encrypted outer envelope limit the listener answers
            // 413 from the declared length alone, before any body arrives.
            let declared = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(outerLimit + 1)\r\nContent-Type: \(localMCPSecureMediaType)\r\nAccept: \(localMCPSecureMediaType)\r\n\r\n"
            let declaredResponse = try await rawHTTPExchange(port: port, request: declared)
            #expect(rawStatus(declaredResponse) == 413)

            // At exactly the outer limit the body is read completely and then
            // rejected as an invalid secure envelope.
            let atOuterLimit = httpRequest(
                method: "POST",
                path: "/mcp",
                port: port,
                headers: [
                    "Accept": localMCPSecureMediaType,
                    "Content-Type": localMCPSecureMediaType,
                ],
                body: String(repeating: "x", count: outerLimit)
            )
            let atOuterLimitResponse = try await rawHTTPExchange(port: port, request: atOuterLimit)
            #expect(rawStatus(atOuterLimitResponse) == 400)

            let chunked = "POST /local-mcp/v1/pairing-requests HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\nAccept: application/json\r\n\r\n2001\r\n"
            let chunkedResponse = try await rawHTTPExchange(port: port, request: chunked)
            #expect(rawStatus(chunkedResponse) == 413)

            // The pairing body limit is exact: one byte past 8 KiB is refused
            // from the declared length, while exactly 8 KiB is read and then
            // rejected as an invalid pairing document.
            let pairingHeaders = ["Accept": "application/json", "Content-Type": "application/json"]
            let overPairingLimit = "POST /local-mcp/v1/pairing-requests HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 8193\r\nContent-Type: application/json\r\nAccept: application/json\r\n\r\n"
            let overPairingResponse = try await rawHTTPExchange(port: port, request: overPairingLimit)
            #expect(rawStatus(overPairingResponse) == 413)

            let atPairingLimit = httpRequest(
                method: "POST",
                path: "/local-mcp/v1/pairing-requests",
                port: port,
                headers: pairingHeaders,
                body: String(repeating: "x", count: 8_192)
            )
            let atPairingLimitResponse = try await rawHTTPExchange(port: port, request: atPairingLimit)
            #expect(rawStatus(atPairingLimitResponse) == 400)

            // The decrypted logical body keeps its own exact 1 MiB bound
            // regardless of how much fits inside a valid envelope.
            let token = try await pairRaw(fixture: fixture, nonceByte: 57)
            let wire = try SecureWire(instance: fixture.instance)
            let oversizedInner = try await wire.send(
                token: token,
                body: String(repeating: "x", count: 1_024 * 1_024 + 1)
            ).inner()
            #expect(oversizedInner.statusCode == 413)
            #expect(oversizedInner.body.isEmpty)

            let atInnerLimit = try await wire.send(
                token: token,
                body: String(repeating: "x", count: 1_024 * 1_024)
            ).inner()
            #expect(String(decoding: atInnerLimit.body, as: UTF8.self).contains("-32700"))
        }
    }

    @Test("schema constraints reject arguments before the typed handler")
    func schemaConstraints() async throws {
        try await withHTTPFixture { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
            await expectHTTPError(.invalidCommandInput) {
                _ = try await consumer.call("echo", arguments: .object(["message": .string("")]))
            }
            await expectHTTPError(.invalidCommandInput) {
                _ = try await consumer.call(
                    "echo",
                    arguments: .object([
                        "message": .string("valid"),
                        "unexpected": .bool(true),
                    ])
                )
            }
            #expect(await fixture.recorder.count == 0)
        }
    }

    @Test("unknown tools retain commandNotFound across JSON-RPC adaptation")
    func unknownToolMapping() async throws {
        try await withHTTPFixture { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
            await expectHTTPError(.commandNotFound) {
                _ = try await consumer.call("missing.tool", arguments: .object([:]))
            }
        }
    }

    @Test("pairing uses its 120-second exchange budget instead of the shorter MCP timeout")
    func pairingTimeoutBudget() async throws {
        let approver = ClosurePairingApprover { _ in
            try await Task.sleep(nanoseconds: 1_200_000_000)
            return .approve
        }
        try await withHTTPFixture(approval: approver) { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(requestTimeout: 1),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
        }
    }

    @Test("pairing subsystem failure is unavailable rather than user denial")
    func pairingSubsystemFailure() async throws {
        struct ApprovalFailure: Error {}
        let approval = ClosurePairingApprover { _ in throw ApprovalFailure() }
        try await withHTTPFixture(approval: approval) { fixture in
            let response = try await pairRawCompletionResponse(fixture: fixture, nonceByte: 59)
            #expect(rawStatus(response) == 503)
            #expect(rawBodyString(response).contains("pairing_unavailable"))
            #expect(await fixture.store.count() == 0)
        }
    }

    @Test("client rejects an oversized declared response before accepting it")
    func boundedClientResponse() async throws {
        try await withHTTPFixture(handler: { _, _ in
            let message = HTTPMessage(message: String(repeating: "x", count: 2_048))
            return try .structured(message, text: message.message)
        }) { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(maximumResponseBytes: 1_024),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
            await expectHTTPError(.producerUnavailable) {
                _ = try await consumer.call(
                    "echo",
                    input: HTTPMessage(message: "large"),
                    as: HTTPMessage.self
                )
            }
        }
    }

    @Test("MCP session sequencing and protocol-version headers are enforced")
    func sessionSequencing() async throws {
        try await withHTTPFixture { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 11)
            let wire = try SecureWire(instance: fixture.instance)
            let noSession = try await wire.send(
                token: token,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"list-0","method":"tools/list","params":{}}"#
            ).inner()
            #expect(noSession.statusCode == 400)
            #expect(noSession.body.isEmpty)

            let sessionID = try await initializeRaw(wire: wire, token: token)
            let beforeInitialized = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"list-1","method":"tools/list","params":{}}"#
            ).inner()
            #expect(String(decoding: beforeInitialized.body, as: UTF8.self).contains("Client not initialized"))

            #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)
            let wrongVersion = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: "2025-06-18",
                body: #"{"jsonrpc":"2.0","id":"list-2","method":"tools/list","params":{}}"#
            ).inner()
            #expect(wrongVersion.statusCode == 400)
            #expect(wrongVersion.body.isEmpty)

            let listed = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"list-3","method":"tools/list","params":{}}"#
            ).inner()
            #expect(String(decoding: listed.body, as: UTF8.self).contains("\"name\":\"echo\""))
        }
    }

    @Test("deadline cancels a suspended handler and never publishes success")
    func handlerDeadline() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 0.1,
            handler: { _, _ in
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
            await expectHTTPError(.requestTimedOut) {
                _ = try await consumer.call(
                    "echo",
                    input: HTTPMessage(message: "wait"),
                    as: HTTPMessage.self
                )
            }
            await entered.wait()
            await cancelled.wait()
        }
    }

    @Test("notifications/cancelled cancels the matching in-flight call")
    func explicitCancellation() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            handler: { _, _ in
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 12)
            let wire = try SecureWire(instance: fixture.instance)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)

            let call = Task {
                try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":"call-1","method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
                ).inner()
            }
            await entered.wait()
            let cancellationResponse = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call-1","reason":"test"}}"#
            ).inner()
            #expect(cancellationResponse.statusCode == 202)
            let callResponse = try await call.value
            let callBody = String(decoding: callResponse.body, as: UTF8.self)
            #expect(callBody.contains("Request cancelled"))
            #expect(!callBody.contains("must not succeed"))
            await cancelled.wait()
        }
    }

    @Test("fractional request IDs cancel exactly and initialized params are optional")
    func fractionalRequestIDAndOptionalInitializedParams() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            handler: { _, context in
                #expect(context.requestID == "1.5")
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 73)
            let wire = try SecureWire(instance: fixture.instance)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            let initialized = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ).inner()
            #expect(initialized.statusCode == 202)

            let listed = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}"#
            ).inner()
            #expect(listed.statusCode == 200)
            let listedBody = String(decoding: listed.body, as: UTF8.self)
            #expect(listedBody.contains("\"destructiveHint\":true"))
            #expect(listedBody.contains("\"openWorldHint\":true"))

            let call = Task {
                try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":1.5,"method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
                ).inner()
            }
            await entered.wait()
            let cancellation = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1.5}}"#
            ).inner()
            #expect(cancellation.statusCode == 202)
            let response = try await call.value
            let responseBody = String(decoding: response.body, as: UTF8.self)
            #expect(responseBody.contains("\"id\":1.5"))
            #expect(responseBody.contains("Request cancelled"))
            await cancelled.wait()
        }
    }

    @Test("closing a call socket promptly cancels the suspended handler")
    func clientDisconnectCancellation() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            handler: { _, _ in
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let port = fixture.instance.endpoint.port
            let token = try await pairRaw(fixture: fixture, nonceByte: 13)
            let wire = try SecureWire(instance: fixture.instance)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)

            let sealed = try wire.seal(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"drop-1","method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
            )
            let socket = try openLoopbackSocket(port: port)
            try writeAll(Data(sealed.outerRequest().utf8), to: socket)
            await entered.wait()
            Darwin.close(socket)
            await cancelled.wait()
        }
    }

    @Test("DELETE terminates the session and cancels every active call in it")
    func deleteSessionCancelsCalls() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            handler: { _, _ in
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 14)
            let wire = try SecureWire(instance: fixture.instance)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)
            let call = Task {
                try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":"delete-call","method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
                ).inner()
            }
            await entered.wait()
            let deleted = try await deleteSession(wire: wire, token: token, sessionID: sessionID)
            #expect(deleted == 204)
            let callResponse = try await call.value
            #expect(String(decoding: callResponse.body, as: UTF8.self).contains("Request cancelled"))
            await cancelled.wait()
        }
    }

    @Test("session-cap eviction cancels calls owned by the evicted session")
    func sessionEvictionCancelsCalls() async throws {
        let entered = HTTPTestSignal()
        let cancelled = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            maximumSessions: 1,
            handler: { _, _ in
                await entered.signal()
                do {
                    try await Task.sleep(nanoseconds: UInt64.max)
                    return .text("must not succeed")
                } catch {
                    await cancelled.signal()
                    throw LocalMCPError.cancelled
                }
            }
        ) { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 15)
            let wire = try SecureWire(instance: fixture.instance)
            let firstSession = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(wire: wire, token: token, sessionID: firstSession) == 202)
            let call = Task {
                try await wire.send(
                    token: token,
                    sessionID: firstSession,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":"evicted-call","method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
                ).inner()
            }
            await entered.wait()
            let secondSession = try await initializeRaw(wire: wire, token: token)
            #expect(secondSession != firstSession)
            let callResponse = try await call.value
            #expect(String(decoding: callResponse.body, as: UTF8.self).contains("Request cancelled"))
            await cancelled.wait()
        }
    }

    @Test("JSON-RPC parse, invalid-request, and notification responses are distinct")
    func jsonRPCEnvelopeSemantics() async throws {
        try await withHTTPFixture { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 60)
            let wire = try SecureWire(instance: fixture.instance)

            let malformed = try await wire.send(token: token, body: #"{"jsonrpc":"#).inner()
            #expect(String(decoding: malformed.body, as: UTF8.self).contains("-32700"))
            let invalid = try await wire.send(token: token, body: "[]").inner()
            #expect(String(decoding: invalid.body, as: UTF8.self).contains("-32600"))

            for invalidNotification in [
                #"{"method":"notifications/initialized"}"#,
                #"{"jsonrpc":"1.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","method":42}"#,
            ] {
                let response = try await wire.send(token: token, body: invalidNotification).inner()
                #expect(response.statusCode == 400)
                #expect(response.body.isEmpty)
            }

            let sessionID = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)
            let notifications = [
                #"{"jsonrpc":"2.0","method":"notifications/unknown","params":{}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized","params":[]}"#,
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#,
                #"{"jsonrpc":"2.0","method":"tools/list","params":{}}"#,
            ]
            for body in notifications {
                let response = try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: body
                ).inner()
                #expect(response.statusCode == 202)
                #expect(response.body.isEmpty)
            }

            let unknownRequest = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"unknown","method":"tools/unknown","params":{}}"#
            ).inner()
            #expect(String(decoding: unknownRequest.body, as: UTF8.self).contains("-32601"))

            let extensionRequest = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"extension","method":"vendor/custom@v1","params":{}}"#
            ).inner()
            let extensionBody = String(decoding: extensionRequest.body, as: UTF8.self)
            #expect(extensionBody.contains("-32601"))
            #expect(!extensionBody.contains("-32600"))

            for malformedList in [
                #"{"jsonrpc":"2.0","id":"bad-list-1","method":"tools/list","params":[]}"#,
                #"{"jsonrpc":"2.0","id":"bad-list-2","method":"tools/list","params":{"cursor":42}}"#,
            ] {
                let response = try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: malformedList
                ).inner()
                let responseBody = String(decoding: response.body, as: UTF8.self)
                #expect(responseBody.contains("-32602"))
                #expect(!responseBody.contains("\"tools\""))
            }

            let absentListParameters = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"list-no-params","method":"tools/list"}"#
            ).inner()
            #expect(String(decoding: absentListParameters.body, as: UTF8.self).contains("\"tools\""))
        }
    }

    @Test("integral JSON tokens are lossless at the 64-bit boundaries")
    func integralJSONBoundaries() async throws {
        try await withHTTPFixture { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 75)
            let wire = try SecureWire(instance: fixture.instance)
            func initializeBody(id: String) -> String {
                #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"boundary","version":"1"}}}"#
            }

            let maximum = String(UInt64.max)
            let accepted = try await wire.send(
                token: token,
                body: initializeBody(id: maximum)
            ).inner()
            #expect(accepted.statusCode == 200)
            #expect(String(decoding: accepted.body, as: UTF8.self).contains("\"id\":\(maximum)"))

            for rejected in ["18446744073709551616", "-9223372036854775809"] {
                let response = try await wire.send(
                    token: token,
                    body: initializeBody(id: rejected)
                ).inner()
                let responseBody = String(decoding: response.body, as: UTF8.self)
                #expect(responseBody.contains("-32700"))
                #expect(!responseBody.contains(rejected))
            }
        }
    }

    @Test("session and protocol-version transport failures use HTTP status codes")
    func sessionTransportStatuses() async throws {
        try await withHTTPFixture { fixture in
            let token = try await pairRaw(fixture: fixture, nonceByte: 61)
            let wire = try SecureWire(instance: fixture.instance)
            let body = #"{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}"#
            let missingSession = try await wire.send(
                token: token,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: body
            ).inner()
            #expect(missingSession.statusCode == 400)

            let unknownSession = try await wire.send(
                token: token,
                sessionID: "unknown",
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: body
            ).inner()
            #expect(unknownSession.statusCode == 404)

            let sessionID = try await initializeRaw(wire: wire, token: token)
            let badVersion = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: "2025-06-18",
                body: body
            ).inner()
            #expect(badVersion.statusCode == 400)

            #expect(try await deleteSession(wire: wire, token: token, sessionID: sessionID) == 204)
            let afterDelete = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: body
            ).inner()
            #expect(afterDelete.statusCode == 404)
        }
    }

    @Test("a rotated credential may terminate only its own retired session")
    func rotatedCredentialSessionTermination() async throws {
        try await withHTTPFixture { fixture in
            let wire = try SecureWire(instance: fixture.instance)
            let oldToken = try await pairRaw(fixture: fixture, nonceByte: 65)
            let oldSession = try await initializeRaw(wire: wire, token: oldToken)
            let newToken = try await pairRaw(fixture: fixture, nonceByte: 66)
            let newSession = try await initializeRaw(wire: wire, token: newToken)

            let oldInvocation = try await wire.send(
                token: oldToken,
                sessionID: oldSession,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"old","method":"tools/list","params":{}}"#
            ).inner()
            #expect(oldInvocation.statusCode == 401)

            let crossSessionDelete = try await deleteSession(
                wire: wire,
                token: oldToken,
                sessionID: newSession
            )
            #expect(crossSessionDelete == 404)

            let retiredDelete = try await deleteSession(
                wire: wire,
                token: oldToken,
                sessionID: oldSession
            )
            #expect(retiredDelete == 204)

            let activeDelete = try await deleteSession(
                wire: wire,
                token: newToken,
                sessionID: newSession
            )
            #expect(activeDelete == 204)
        }
    }

    @Test("Accept media ranges reject lookalikes and zero quality")
    func strictAcceptMediaTypes() async throws {
        let approval = RecordingPairingApprover()
        try await withHTTPFixture(approval: approval) { fixture in
            let port = fixture.instance.endpoint.port
            let pairingBody = try RawChannelPairing(
                instance: fixture.instance,
                nonceByte: 62
            ).initiationBody()
            for accept in ["application/jsonp", "application/json;q=0"] {
                let response = try await rawHTTPExchange(
                    port: port,
                    request: httpRequest(
                        method: "POST",
                        path: "/local-mcp/v1/pairing-requests",
                        port: port,
                        headers: ["Accept": accept, "Content-Type": "application/json"],
                        body: pairingBody
                    )
                )
                #expect(rawStatus(response) == 400)
            }
            #expect(await approval.challenges().isEmpty)

            let token = try await pairRaw(fixture: fixture, nonceByte: 63)
            let wire = try SecureWire(instance: fixture.instance)
            let initialize = #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"accept-test","version":"1"}}}"#
            for accept in [
                "application/jsonp, text/event-stream",
                "application/json;q=0, text/event-stream",
                "application/json, text/event-stream;q=0",
            ] {
                let response = try await wire.send(
                    token: token,
                    accept: accept,
                    body: initialize
                ).inner()
                #expect(response.statusCode == 406)
            }
        }
    }

    @Test("HTTP deadlines and caller cancellation do not join a noncooperative handler")
    func nonCooperativeHTTPCallCancellation() async throws {
        let entered = HTTPTestSignal()
        let release = HTTPTestSignal()
        try await withHTTPFixture(
            handlerTimeout: 5,
            handler: { _, _ in
                await entered.signal()
                await release.wait()
                return .text("late success")
            }
        ) { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await consumer.pair()
            let timed = Task {
                try await consumer.call(
                    "echo",
                    input: HTTPMessage(message: "timed"),
                    as: HTTPMessage.self,
                    deadline: Date().addingTimeInterval(0.05)
                )
            }
            await entered.wait()
            let clock = ContinuousClock()
            let started = clock.now
            await expectHTTPError(.requestTimedOut) { _ = try await timed.value }
            #expect(started.duration(to: clock.now) < .seconds(1))

            let cancelledEntered = HTTPTestSignal()
            let cancelledRelease = HTTPTestSignal()
            let secondFixture = try await makeHTTPFixture(
                handlerTimeout: 5,
                handler: { _, _ in
                    await cancelledEntered.signal()
                    await cancelledRelease.wait()
                    return .text("late cancellation success")
                }
            )
            let secondConsumer = LocalMCPConsumer(
                instance: secondFixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            _ = try await secondConsumer.pair()
            let cancelled = Task {
                try await secondConsumer.call(
                    "echo",
                    input: HTTPMessage(message: "cancel"),
                    as: HTTPMessage.self
                )
            }
            await cancelledEntered.wait()
            cancelled.cancel()
            await expectHTTPError(.cancelled) { _ = try await cancelled.value }
            await cancelledRelease.signal()
            await secondFixture.producer.stop()

            await release.signal()
        }
    }

    @Test("outer handler budgets bound noncooperative authentication and listing")
    func outerHandlerBudgets() async throws {
        let credential = try AuthorizationCredential(bytes: [UInt8](repeating: 76, count: 32))
        let token = credential.withUnsafeEncodedValue { $0 }

        let authEntered = HTTPTestSignal()
        let authRelease = HTTPTestSignal()
        let authTransport = LocalMCPHTTPProducerTransport(handlerTimeout: 0.05)
        let authBinding = try await authTransport.prepareProcessChannelBinding()
        let authEndpoint = try await authTransport.start(
            endpointPath: "/mcp",
            descriptorPath: "/local-mcp/v1/descriptor.json",
            descriptor: ProducerDescriptor(
                instanceID: "c755d360-0fbe-42e7-bf95-0820d25b77af",
                server: httpProducerIdentity,
                channelBinding: authBinding
            ),
            service: BlockingAuthenticationHTTPService(
                entered: authEntered,
                release: authRelease
            )
        )
        do {
            let authWire = SecureWire(port: authEndpoint.port, binding: authBinding)
            let initialize = #"{"jsonrpc":"2.0","id":"blocked-auth","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"timeout","version":"1"}}}"#
            let clock = ContinuousClock()
            let started = clock.now
            let request = Task {
                try await authWire.send(token: token, body: initialize)
            }
            await authEntered.wait()
            let response = try await request.value
            #expect(response.outerStatus == 503)
            #expect(started.duration(to: clock.now) < .seconds(1))
            await authRelease.signal()
            await authTransport.stop()
        } catch {
            await authRelease.signal()
            await authTransport.stop()
            throw error
        }

        let listEntered = HTTPTestSignal()
        let listRelease = HTTPTestSignal()
        let listTransport = LocalMCPHTTPProducerTransport(handlerTimeout: 0.05)
        let listBinding = try await listTransport.prepareProcessChannelBinding()
        let listEndpoint = try await listTransport.start(
            endpointPath: "/mcp",
            descriptorPath: "/local-mcp/v1/descriptor.json",
            descriptor: ProducerDescriptor(
                instanceID: "4c7abfe7-b9de-4718-8ef4-43c6c0b3be87",
                server: httpProducerIdentity,
                channelBinding: listBinding
            ),
            service: BlockingListHTTPService(entered: listEntered, release: listRelease)
        )
        do {
            let listWire = SecureWire(port: listEndpoint.port, binding: listBinding)
            let sessionID = try await initializeRaw(wire: listWire, token: token)
            #expect(try await initializedRaw(
                wire: listWire,
                token: token,
                sessionID: sessionID
            ) == 202)
            let clock = ContinuousClock()
            let started = clock.now
            let request = Task {
                try await listWire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":"blocked-list","method":"tools/list"}"#
                )
            }
            await listEntered.wait()
            let response = try await request.value
            #expect(response.outerStatus == 503)
            #expect(started.duration(to: clock.now) < .seconds(1))
            await listRelease.signal()
            await listTransport.stop()
        } catch {
            await listRelease.signal()
            await listTransport.stop()
            throw error
        }
    }

    @Test("Listener stop releases its port while a handler still ignores cancellation")
    func listenerStopWithNonCooperativeHandler() async throws {
        let entered = HTTPTestSignal()
        let release = HTTPTestSignal()
        let first = try await makeHTTPFixture(
            handlerTimeout: 5,
            handler: { _, _ in
                await entered.signal()
                await release.wait()
                return .text("late success")
            }
        )
        let port = first.instance.endpoint.port
        let token = try await pairRaw(fixture: first, nonceByte: 64)
        let wire = try SecureWire(instance: first.instance)
        let sessionID = try await initializeRaw(wire: wire, token: token)
        #expect(try await initializedRaw(wire: wire, token: token, sessionID: sessionID) == 202)
        let call = Task {
            try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","id":"stop-call","method":"tools/call","params":{"name":"echo","arguments":{"message":"wait"}}}"#
            )
        }
        await entered.wait()

        let clock = ContinuousClock()
        let started = clock.now
        await first.producer.stop()
        #expect(started.duration(to: clock.now) < .seconds(1))
        let second = try await makeHTTPFixture(port: port)
        #expect(second.instance.endpoint.port == port)
        await release.signal()
        _ = try? await call.value
        await second.producer.stop()
    }

    @Test("initialized notification failures are HTTP failures, never false acceptance")
    func initializedFailureStatus() async throws {
        let transport = LocalMCPHTTPProducerTransport()
        let binding = try await transport.prepareProcessChannelBinding()
        let descriptor = ProducerDescriptor(
            instanceID: "77d0be07-3c46-407a-bb32-b2698b3fb7bb",
            server: httpProducerIdentity,
            channelBinding: binding
        )
        let endpoint = try await transport.start(
            endpointPath: "/mcp",
            descriptorPath: "/local-mcp/v1/descriptor.json",
            descriptor: descriptor,
            service: FailingInitializedHTTPService()
        )
        do {
            let credential = try AuthorizationCredential(bytes: [UInt8](repeating: 72, count: 32))
            let token = credential.withUnsafeEncodedValue { $0 }
            let wire = SecureWire(port: endpoint.port, binding: binding)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            let response = try await wire.send(
                token: token,
                sessionID: sessionID,
                protocolVersion: MCPProtocolVersion.current.rawValue,
                body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            ).inner()
            #expect(response.statusCode == 503)
            #expect(response.body.isEmpty)
            await transport.stop()
        } catch {
            await transport.stop()
            throw error
        }
    }

    @Test("tools/list cannot publish success after its session is deleted")
    func listSessionRecheck() async throws {
        let entered = HTTPTestSignal()
        let release = HTTPTestSignal()
        let service = BlockingListHTTPService(entered: entered, release: release)
        let transport = LocalMCPHTTPProducerTransport()
        let binding = try await transport.prepareProcessChannelBinding()
        let descriptor = ProducerDescriptor(
            instanceID: "06d75c4b-34cc-42a7-a787-c4e59479b52f",
            server: httpProducerIdentity,
            channelBinding: binding
        )
        let endpoint = try await transport.start(
            endpointPath: "/mcp",
            descriptorPath: "/local-mcp/v1/descriptor.json",
            descriptor: descriptor,
            service: service
        )
        do {
            let credential = try AuthorizationCredential(bytes: [UInt8](repeating: 74, count: 32))
            let token = credential.withUnsafeEncodedValue { $0 }
            let wire = SecureWire(port: endpoint.port, binding: binding)
            let sessionID = try await initializeRaw(wire: wire, token: token)
            #expect(try await initializedRaw(
                wire: wire,
                token: token,
                sessionID: sessionID
            ) == 202)
            let list = Task {
                try await wire.send(
                    token: token,
                    sessionID: sessionID,
                    protocolVersion: MCPProtocolVersion.current.rawValue,
                    body: #"{"jsonrpc":"2.0","id":"list-race","method":"tools/list","params":{}}"#
                ).inner()
            }
            await entered.wait()
            let deleted = try await deleteSession(wire: wire, token: token, sessionID: sessionID)
            #expect(deleted == 204)
            await release.signal()
            let response = try await list.value
            let responseBody = String(decoding: response.body, as: UTF8.self)
            #expect(responseBody.contains("Request cancelled"))
            #expect(!responseBody.contains("\"name\":\"echo\""))
            await transport.stop()
        } catch {
            await release.signal()
            await transport.stop()
            throw error
        }
    }

    @Test("server refuses non-object structured tool results even without an output schema")
    func structuredResultWireShape() async throws {
        var definition = httpEchoDefinition
        definition.outputSchema = nil
        try await withHTTPFixture(
            definition: definition,
            handler: { _, _ in CommandResult(structuredContent: .string("invalid")) }
        ) { fixture in
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: httpConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: InMemoryConsumerGrantStore()
            )
            let grant = try await consumer.pair()
            _ = try await consumer.initialize(grant: grant)
            await expectHTTPError(.commandFailed) {
                _ = try await consumer.call(
                    "echo",
                    input: HTTPMessage(message: "invalid result"),
                    as: HTTPMessage.self
                )
            }
        }
    }

    @Test("pairing rejects duplicate JSON members, nonce replay, and the sixth rolling start")
    func pairingAbuseLimits() async throws {
        try await withHTTPFixture { fixture in
            let port = fixture.instance.endpoint.port
            let validBody = try RawChannelPairing(
                instance: fixture.instance,
                nonceByte: 19
            ).initiationBody()
            let duplicateBody = validBody.replacingOccurrences(
                of: #""schemaVersion":"1""#,
                with: #""schemaVersion":"1","schemaVersion":"1""#
            )
            #expect(duplicateBody != validBody)
            let duplicate = try await rawHTTPExchange(
                port: port,
                request: httpRequest(
                    method: "POST",
                    path: "/local-mcp/v1/pairing-requests",
                    port: port,
                    headers: ["Accept": "application/json", "Content-Type": "application/json"],
                    body: duplicateBody
                )
            )
            #expect(rawStatus(duplicate) == 400)

            _ = try await pairRaw(fixture: fixture, nonceByte: 20)
            let replay = try await pairRawResponse(fixture: fixture, nonceByte: 20)
            #expect(rawStatus(replay) == 409)

            // A replayed initiation is rejected before the rolling-start
            // budget, so four more approvals fill the five-start window and
            // the next initiation is rate-limited.
            _ = try await pairRaw(fixture: fixture, nonceByte: 21)
            _ = try await pairRaw(fixture: fixture, nonceByte: 22)
            _ = try await pairRaw(fixture: fixture, nonceByte: 23)
            _ = try await pairRaw(fixture: fixture, nonceByte: 24)
            let limited = try await pairRawResponse(fixture: fixture, nonceByte: 25)
            #expect(rawStatus(limited) == 429)
            #expect(rawBodyString(limited).contains("pairing_rate_limited"))
        }
    }
}

private actor HTTPTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct FailingInitializedHTTPService: LocalMCPService {
    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        throw LocalMCPError.producerUnavailable
    }

    func authenticate(credential: AuthorizationCredential?) async throws {
        guard credential != nil else { throw LocalMCPError.unauthorized }
    }

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        try await authenticate(credential: credential)
        guard supportedProtocolVersions.contains(MCPProtocolVersion.current.rawValue) else {
            throw LocalMCPError.incompatibleMCPProtocol
        }
        return LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: httpProducerIdentity,
            capabilities: ProducerCapabilities()
        )
    }

    func initialized(credential: AuthorizationCredential?) async throws {
        try await authenticate(credential: credential)
        throw LocalMCPError.producerUnavailable
    }

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        try await authenticate(credential: credential)
        return [httpEchoDefinition]
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        try await authenticate(credential: credential)
        throw LocalMCPError.commandNotFound
    }
}

private actor BlockingAuthenticationHTTPService: LocalMCPService {
    private let entered: HTTPTestSignal
    private let release: HTTPTestSignal

    init(entered: HTTPTestSignal, release: HTTPTestSignal) {
        self.entered = entered
        self.release = release
    }

    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        throw LocalMCPError.producerUnavailable
    }

    func authenticate(credential: AuthorizationCredential?) async throws {
        guard credential != nil else { throw LocalMCPError.unauthorized }
        await entered.signal()
        await release.wait()
    }

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: httpProducerIdentity,
            capabilities: ProducerCapabilities()
        )
    }

    func initialized(credential: AuthorizationCredential?) async throws {}

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        [httpEchoDefinition]
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        throw LocalMCPError.commandNotFound
    }
}

private actor BlockingListHTTPService: LocalMCPService {
    private let entered: HTTPTestSignal
    private let release: HTTPTestSignal

    init(entered: HTTPTestSignal, release: HTTPTestSignal) {
        self.entered = entered
        self.release = release
    }

    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        throw LocalMCPError.producerUnavailable
    }

    func authenticate(credential: AuthorizationCredential?) async throws {
        guard credential != nil else { throw LocalMCPError.unauthorized }
    }

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        try await authenticate(credential: credential)
        return LocalMCPInitialization(
            protocolVersion: MCPProtocolVersion.current.rawValue,
            server: httpProducerIdentity,
            capabilities: ProducerCapabilities()
        )
    }

    func initialized(credential: AuthorizationCredential?) async throws {
        try await authenticate(credential: credential)
    }

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        try await authenticate(credential: credential)
        await entered.signal()
        await release.wait()
        return [httpEchoDefinition]
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        throw LocalMCPError.commandNotFound
    }
}

private actor ToggleAuthenticationFailureStore: ProducerGrantStoring {
    struct Outage: Error {}
    private let backing = InMemoryProducerGrantStore()
    private var authenticationReadsFail = false

    func failAuthenticationReads() {
        authenticationReadsFail = true
    }

    func stagePendingGrant(_ record: ProducerGrantRecord) async throws {
        try await backing.stagePendingGrant(record)
    }

    func activatePendingGrant(
        matching digest: CredentialDigest,
        binding: AuthorizationEndpointBinding?
    ) async throws -> ProducerGrantRecord? {
        if authenticationReadsFail { throw Outage() }
        return try await backing.activatePendingGrant(matching: digest, binding: binding)
    }

    func saveReplacingActiveGrant(_ record: ProducerGrantRecord) async throws {
        try await backing.saveReplacingActiveGrant(record)
    }

    func record(matching digest: CredentialDigest) async throws -> ProducerGrantRecord? {
        if authenticationReadsFail { throw Outage() }
        return try await backing.record(matching: digest)
    }

    func record(grantID: String) async throws -> ProducerGrantRecord? {
        try await backing.record(grantID: grantID)
    }

    func records() async throws -> [ProducerGrantRecord] {
        try await backing.records()
    }

    func remove(grantID: String) async throws {
        try await backing.remove(grantID: grantID)
    }
}

private func expectHTTPError(
    _ expected: LocalMCPError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(type(of: error))")
    }
}

// MARK: - Secure wire helpers

/// Allocates strictly increasing sequence numbers for sealed session requests.
private final class SecureWireSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 1

    func allocate() -> UInt64 {
        lock.withLock {
            defer { next += 1 }
            return next
        }
    }
}

/// A sealed logical request plus the context needed to open its response.
private struct SealedSecureRequest: @unchecked Sendable {
    let port: UInt16
    let context: SecureClientResponseContext

    func outerRequest(extraHeaders: [String: String] = [:]) -> String {
        var headers = [
            "Accept": localMCPSecureMediaType,
            "Content-Type": localMCPSecureMediaType,
        ]
        for (name, value) in extraHeaders { headers[name] = value }
        return httpRequest(
            method: "POST",
            path: "/mcp",
            port: port,
            headers: headers,
            body: String(decoding: context.requestBody, as: UTF8.self)
        )
    }
}

/// One raw outer HTTP exchange plus the opener for the sealed inner response.
private struct SecureWireExchange: @unchecked Sendable {
    let raw: Data
    let context: SecureClientResponseContext

    var outerStatus: Int? { rawStatus(raw) }

    func inner() throws -> MCPHTTPResponse {
        try context.open(
            outerStatusCode: rawStatus(raw) ?? 0,
            outerContentType: rawHeaders(raw)["content-type"],
            body: rawBody(raw) ?? Data(),
            maximumPlaintextBytes: 4 * 1_024 * 1_024
        )
    }
}

/// Test-side implementation of the LocalMCP secure MCP profile: it seals the
/// logical request (bearer, session, protocol, JSON-RPC body) to the
/// producer's process channel binding and opens the request-bound sealed
/// response. Only initialize-shaped requests (no session) may omit a sequence.
private struct SecureWire: Sendable {
    let port: UInt16
    let binding: ProducerChannelBinding
    private let sequences = SecureWireSequence()

    init(instance: ProducerInstance) throws {
        guard let binding = instance.channelBinding else {
            throw LocalMCPError.invalidConfiguration
        }
        self.init(port: instance.endpoint.port, binding: binding)
    }

    init(port: UInt16, binding: ProducerChannelBinding) {
        self.port = port
        self.binding = binding
    }

    func seal(
        method: String = "POST",
        token: String?,
        sessionID: String? = nil,
        protocolVersion: String? = nil,
        accept: String? = "application/json, text/event-stream",
        contentType: String? = "application/json",
        body: String = ""
    ) throws -> SealedSecureRequest {
        var headers: [String: [String]] = [:]
        if let accept { headers["accept"] = [accept] }
        if let contentType { headers["content-type"] = [contentType] }
        if let token { headers["authorization"] = ["Bearer \(token)"] }
        if let protocolVersion { headers["mcp-protocol-version"] = [protocolVersion] }
        if let sessionID { headers["mcp-session-id"] = [sessionID] }
        let context = try SecureMCPCodec.sealRequest(
            MCPHTTPRequest(
                method: method,
                path: "/mcp",
                headers: headers,
                body: Data(body.utf8)
            ),
            sequence: sessionID == nil ? nil : sequences.allocate(),
            expectedAuthority: "127.0.0.1:\(port)",
            channelBinding: binding
        )
        return SealedSecureRequest(port: port, context: context)
    }

    func send(
        method: String = "POST",
        token: String?,
        sessionID: String? = nil,
        protocolVersion: String? = nil,
        accept: String? = "application/json, text/event-stream",
        contentType: String? = "application/json",
        extraOuterHeaders: [String: String] = [:],
        body: String = ""
    ) async throws -> SecureWireExchange {
        let sealed = try seal(
            method: method,
            token: token,
            sessionID: sessionID,
            protocolVersion: protocolVersion,
            accept: accept,
            contentType: contentType,
            body: body
        )
        let raw = try await rawHTTPExchange(
            port: port,
            request: sealed.outerRequest(extraHeaders: extraOuterHeaders)
        )
        return SecureWireExchange(raw: raw, context: sealed.context)
    }
}

private func initializeRaw(wire: SecureWire, token: String) async throws -> String {
    let response = try await wire.send(
        token: token,
        body: #"{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"raw-test","version":"1"}}}"#
    ).inner()
    guard response.statusCode == 200,
          let sessionID = response.headers["mcp-session-id"]
    else { throw LocalMCPError.incompatibleMCPProtocol }
    return sessionID
}

private func initializedRaw(
    wire: SecureWire,
    token: String,
    sessionID: String
) async throws -> Int? {
    try await wire.send(
        token: token,
        sessionID: sessionID,
        protocolVersion: MCPProtocolVersion.current.rawValue,
        body: #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#
    ).inner().statusCode
}

private func deleteSession(
    wire: SecureWire,
    token: String,
    sessionID: String
) async throws -> Int? {
    try await wire.send(
        method: "DELETE",
        token: token,
        sessionID: sessionID,
        protocolVersion: MCPProtocolVersion.current.rawValue,
        accept: nil,
        contentType: nil
    ).inner().statusCode
}

// MARK: - Raw commitment → challenge → reveal pairing

/// A deterministic channel-bound pairing driven over the raw wire. All key
/// material derives from `nonceByte`, so resending the same initiation is a
/// byte-identical replay for the producer's replay defenses.
private struct RawChannelPairing {
    struct Challenge {
        let pairingID: String
        let serverNonce: String
    }

    let instance: ProducerInstance
    let binding: ProducerChannelBinding
    let privateKeyBytes: [UInt8]
    let secret: PairingSecret
    let initiation: PairingRequest

    init(instance: ProducerInstance, nonceByte: UInt8) throws {
        guard let binding = instance.channelBinding else {
            throw LocalMCPError.invalidConfiguration
        }
        self.instance = instance
        self.binding = binding
        privateKeyBytes = [UInt8](repeating: nonceByte ^ 0xa5, count: 32)
        secret = try PairingSecret(bytes: [UInt8](repeating: nonceByte ^ 0x5a, count: 32))
        initiation = try PairingRequest(
            consumer: httpConsumerIdentity,
            requestNonce: PairingNonce(bytes: [UInt8](repeating: nonceByte, count: 32)),
            expectedProducerPublicKey: binding.publicKey,
            expectedInstanceID: instance.instanceID,
            expectedEndpoint: instance.endpoint.url.absoluteString,
            initiatorPrivateKeyRawRepresentation: privateKeyBytes,
            clientSecret: secret
        )
    }

    func initiationBody() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(initiation), as: UTF8.self)
    }

    func initiationResponse() async throws -> Data {
        try await rawHTTPExchange(
            port: instance.endpoint.port,
            request: httpRequest(
                method: "POST",
                path: "/local-mcp/v1/pairing-requests",
                port: instance.endpoint.port,
                headers: ["Accept": "application/json", "Content-Type": "application/json"],
                body: try initiationBody()
            )
        )
    }

    func begin() async throws -> Challenge {
        let response = try await initiationResponse()
        guard rawStatus(response) == 201,
              let body = rawBody(response),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pairingID = object["pairingId"] as? String,
              let serverNonce = object["serverNonce"] as? String
        else { throw LocalMCPError.pairingDenied }
        return Challenge(pairingID: pairingID, serverNonce: serverNonce)
    }

    func completionResponse(challenge: Challenge) async throws -> Data {
        guard var object = try JSONSerialization.jsonObject(
            with: Data(try initiationBody().utf8)
        ) as? [String: Any]
        else { throw LocalMCPError.pairingDenied }
        object["pairingId"] = challenge.pairingID
        object["serverNonce"] = challenge.serverNonce
        object["revealedClientSecret"] = secret.canonicalEncodedValue
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try await rawHTTPExchange(
            port: instance.endpoint.port,
            request: httpRequest(
                method: "POST",
                path: "/local-mcp/v1/pairing-requests/\(challenge.pairingID)",
                port: instance.endpoint.port,
                headers: [
                    "Accept": localMCPSecureMediaType,
                    "Content-Type": "application/json",
                ],
                body: String(decoding: body, as: UTF8.self)
            )
        )
    }

    func accessToken(from completion: Data, challenge: Challenge) throws -> String {
        guard rawStatus(completion) == 200, let body = rawBody(completion) else {
            throw LocalMCPError.pairingDenied
        }
        let finalized = try initiation.serverFinalized(
            pairingID: PairingIdentifier(encodedValue: challenge.pairingID),
            serverNonce: PairingNonce(encodedValue: challenge.serverNonce),
            revealedClientSecret: secret
        )
        let transcript = try PairingTranscript(
            finalizedRequest: finalized,
            producerID: instance.identity.stableID,
            channelBinding: binding
        )
        let plaintext = try SecurePairingResponseEnvelope.open(
            body,
            privateKeyRawRepresentation: privateKeyBytes,
            peerPublicKey: binding.publicKey,
            transcript: transcript
        )
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let token = object["accessToken"] as? String
        else { throw LocalMCPError.pairingDenied }
        return token
    }
}

private func pairRaw(fixture: HTTPFixture, nonceByte: UInt8 = 9) async throws -> String {
    try await pairRaw(instance: fixture.instance, nonceByte: nonceByte)
}

private func pairRaw(instance: ProducerInstance, nonceByte: UInt8) async throws -> String {
    let pairing = try RawChannelPairing(instance: instance, nonceByte: nonceByte)
    let challenge = try await pairing.begin()
    let completion = try await pairing.completionResponse(challenge: challenge)
    return try pairing.accessToken(from: completion, challenge: challenge)
}

private func pairRawResponse(fixture: HTTPFixture, nonceByte: UInt8) async throws -> Data {
    try await RawChannelPairing(
        instance: fixture.instance,
        nonceByte: nonceByte
    ).initiationResponse()
}

private func pairRawCompletionResponse(
    fixture: HTTPFixture,
    nonceByte: UInt8
) async throws -> Data {
    let pairing = try RawChannelPairing(instance: fixture.instance, nonceByte: nonceByte)
    let challenge = try await pairing.begin()
    return try await pairing.completionResponse(challenge: challenge)
}

// MARK: - Raw HTTP plumbing

private func httpRequest(
    method: String,
    path: String,
    port: UInt16,
    headers: [String: String],
    body: String
) -> String {
    var result = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
    for key in headers.keys.sorted() { result += "\(key): \(headers[key]!)\r\n" }
    result += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    return result
}

private func rawStatus(_ data: Data) -> Int? {
    guard let first = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first else {
        return nil
    }
    let pieces = first.split(separator: " ")
    return pieces.count >= 2 ? Int(pieces[1]) : nil
}

private func rawHeaders(_ data: Data) -> [String: String] {
    guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
    let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
    var headers: [String: String] = [:]
    for line in head.components(separatedBy: "\r\n").dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
    }
    return headers
}

private func rawBodyString(_ data: Data) -> String {
    rawBody(data).map { String(decoding: $0, as: UTF8.self) } ?? ""
}

private func rawBody(_ data: Data) -> Data? {
    guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    return Data(data[range.upperBound...])
}

private func rawHTTPExchange(port: UInt16, request: String) async throws -> Data {
    try await Task.detached {
        let descriptor = try openLoopbackSocket(port: port)
        defer { Darwin.close(descriptor) }
        try writeAll(Data(request.utf8), to: descriptor)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw LocalMCPError.producerUnavailable }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 4 * 1_024 * 1_024 else { throw LocalMCPError.producerUnavailable }
        }
        return response
    }.value
}

private func openLoopbackSocket(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LocalMCPError.producerUnavailable }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw LocalMCPError.producerUnavailable
    }
    return descriptor
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), data.count - sent, 0)
            guard count > 0 else { throw LocalMCPError.producerUnavailable }
            sent += count
        }
    }
}
