import Darwin
import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPMCPAdapter
import Testing

// These mock servers intentionally exercise partial and long-lived responses
// with blocking POSIX sockets; serialize them to avoid starving peer tasks in
// the cooperative executor when the wider integration target runs in parallel.
//
// Every mock owns a real MCPProcessSecurityContext: it decrypts the client's
// sealed envelope and returns a request-bound sealed inner response, so the
// hostile shapes below exercise the client's logical-response validation, not
// its outer-envelope rejection path.
@Suite("Wire client response conformance", .serialized)
struct WireClientResponseTests {
    @Test("SSE responses are bounded and matched by JSON-RPC ID")
    func serverSentEventResponse() async throws {
        let server = try MockLoopbackHTTPServer(responseCount: 1) { _, opened in
            let id = try requestID(opened)
            let body = ": keepalive\n\n"
                + "event: message\n"
                + "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n"
                + "event: message\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"com.example.mock-producer\",\"title\":\"Mock Producer\",\"version\":\"1.0.0\"}}}\n\n"
            return MockHTTPReply(
                headers: [
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Mcp-Session-Id": "sse-session-1",
                ],
                body: Data(body.utf8),
                holdOpenMicroseconds: 500_000
            )
        }
        let service = try await mockService(server: server)
        let clock = ContinuousClock()
        let started = clock.now
        let initialization = try await service.initialize(
            supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
            credential: mockCredential
        )
        #expect(initialization.server == mockProducerIdentity)
        #expect(initialization.capabilities.tools)
        #expect(started.duration(to: clock.now) < .milliseconds(300))
        try await server.wait()
    }

    @Test("JSON lookalike Content-Type and hostile initialize fields are rejected")
    func hostileInitializeResponses() async throws {
        let cases: [(String, String, Bool, Bool, LocalMCPError)] = [
            ("application/jsonp", "valid-session", true, false, .producerUnavailable),
            ("application/json", "bad session", true, false, .incompatibleMCPProtocol),
            ("application/json", "valid-session", false, true, .incompatibleMCPProtocol),
        ]
        for (contentType, sessionID, includeCapabilities, expectsDelete, expected) in cases {
            let server = try MockLoopbackHTTPServer(responseCount: expectsDelete ? 2 : 1) { index, opened in
                if index == 1 {
                    #expect(opened.request.method == "DELETE")
                    #expect(opened.request.singleHeader("mcp-session-id") == sessionID)
                    return MockHTTPReply(statusCode: 204)
                }
                let id = try requestID(opened)
                let capabilities = includeCapabilities ? ",\"capabilities\":{\"tools\":{}}" : ""
                let body = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25"\#(capabilities),"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#
                return MockHTTPReply(
                    headers: ["Content-Type": contentType, "Mcp-Session-Id": sessionID],
                    body: Data(body.utf8)
                )
            }
            let service = try await mockService(server: server)
            await expectWireError(expected) {
                _ = try await service.initialize(
                    supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                    credential: mockCredential
                )
            }
            try await server.wait()
        }

        let server = try MockLoopbackHTTPServer(responseCount: 2) { index, opened in
            if index == 1 {
                #expect(opened.request.method == "DELETE")
                #expect(opened.request.singleHeader("mcp-session-id") == "valid-session")
                return MockHTTPReply(statusCode: 204)
            }
            let id = try requestID(opened)
            let body = #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock\u0007Producer","version":"1.0.0"}}}"#
            return MockHTTPReply(
                headers: ["Content-Type": "application/json", "Mcp-Session-Id": "valid-session"],
                body: Data(body.utf8)
            )
        }
        let service = try await mockService(server: server)
        await expectWireError(.incompatibleMCPProtocol) {
            _ = try await service.initialize(
                supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                credential: mockCredential
            )
        }
        try await server.wait()
    }

    @Test("Unsupported schemas and control-bearing tool text are rejected")
    func hostileToolDefinitions() async throws {
        for hostileTool in [
            #"{"name":"hostile","description":"unsafe\u0007text","inputSchema":{"type":"object"},"annotations":{}}"#,
            #"{"name":"hostile","description":"Unsupported schema","inputSchema":{"type":"object","patternProperties":{}},"annotations":{}}"#,
            #"{"name":"hostile","description":"Missing root type","inputSchema":{"properties":{}},"annotations":{}}"#,
            #"{"name":"hostile","description":"Wrong root type","inputSchema":{"type":"array"},"annotations":{}}"#,
            #"{"name":"hostile","description":"Missing output root type","inputSchema":{"type":"object"},"outputSchema":{},"annotations":{}}"#,
            #"{"name":"hostile","description":"Malformed annotations","inputSchema":{"type":"object"},"annotations":{"destructiveHint":"false"}}"#,
        ] {
            let server = try MockLoopbackHTTPServer(responseCount: 3) { index, opened in
                switch index {
                case 0:
                    let id = try requestID(opened)
                    return jsonReply(
                        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                        sessionID: "tool-session"
                    )
                case 1:
                    return MockHTTPReply(statusCode: 202)
                default:
                    let id = try requestID(opened)
                    return jsonReply(
                        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"tools":[\#(hostileTool)]}}"#
                    )
                }
            }
            let service = try await mockService(server: server)
            _ = try await service.initialize(
                supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                credential: mockCredential
            )
            try await service.initialized(credential: mockCredential)
            await expectWireError(.commandFailed) {
                _ = try await service.listCommands(credential: mockCredential)
            }
            try await server.wait()
        }
    }

    @Test("omitted MCP safety hints retain the conservative protocol defaults")
    func annotationDefaults() async throws {
        let server = try MockLoopbackHTTPServer(responseCount: 3) { index, opened in
            switch index {
            case 0:
                let id = try requestID(opened)
                return jsonReply(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                    sessionID: "annotation-session"
                )
            case 1:
                return MockHTTPReply(statusCode: 202)
            default:
                let id = try requestID(opened)
                return jsonReply(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"tools":[{"name":"safe-defaults","description":"Default hints","inputSchema":{"type":"object"},"annotations":{}}]}}"#
                )
            }
        }
        let service = try await mockService(server: server)
        _ = try await service.initialize(
            supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
            credential: mockCredential
        )
        try await service.initialized(credential: mockCredential)
        let command = try #require(try await service.listCommands(credential: mockCredential).first)
        #expect(!command.annotations.readOnly)
        #expect(!command.annotations.idempotent)
        #expect(command.annotations.destructive)
        #expect(command.annotations.openWorld)
        try await server.wait()
    }

    @Test("call results require MCP content and typed optional fields")
    func callResultShape() async throws {
        let cases: [(String, String, Bool)] = [
            (#"{"content":[],"structuredContent":{"ok":true}}"#, "", true),
            (#"{"isError":false}"#, "", false),
            (#"{"content":{}}"#, "", false),
            (#"{"content":[],"structuredContent":"not-an-object"}"#, "", false),
            (#"{"content":[],"isError":"false"}"#, "", false),
            (
                #"{"content":[]}"#,
                #", "error":{"code":-32603,"message":"ambiguous"}"#,
                false
            ),
        ]
        for (result, extraEnvelopeMembers, succeeds) in cases {
            let server = try MockLoopbackHTTPServer(responseCount: 3) { index, opened in
                switch index {
                case 0:
                    let id = try requestID(opened)
                    return jsonReply(
                        #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                        sessionID: "result-session"
                    )
                case 1:
                    return MockHTTPReply(statusCode: 202)
                default:
                    let id = try requestID(opened)
                    return jsonReply(
                        #"{"jsonrpc":"2.0","id":"\#(id)","result":\#(result)\#(extraEnvelopeMembers)}"#
                    )
                }
            }
            let service = try await mockService(server: server)
            _ = try await service.initialize(
                supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
                credential: mockCredential
            )
            try await service.initialized(credential: mockCredential)
            let request = CommandCallRequest(
                name: "echo",
                arguments: .object([:]),
                requestID: "shape"
            )
            if succeeds {
                let response = try await service.callCommand(request, credential: mockCredential)
                #expect(response.structuredContent == .object(["ok": .bool(true)]))
                #expect(!response.isError)
            } else {
                await expectWireError(.commandFailed) {
                    _ = try await service.callCommand(request, credential: mockCredential)
                }
            }
            try await server.wait()
        }
    }

    @Test("A command deadline is a hard total deadline for a drip response")
    func hardDripDeadline() async throws {
        let server = try MockLoopbackHTTPServer(responseCount: 3) { index, opened in
            switch index {
            case 0:
                let id = try requestID(opened)
                return jsonReply(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                    sessionID: "deadline-session"
                )
            case 1:
                return MockHTTPReply(statusCode: 202)
            default:
                let id = try requestID(opened)
                return MockHTTPReply(
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"content":[],"isError":false}}"#.utf8),
                    bodyChunkDelayMicroseconds: 20_000
                )
            }
        }
        let service = try await mockService(server: server)
        _ = try await service.initialize(
            supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
            credential: mockCredential
        )
        try await service.initialized(credential: mockCredential)

        let clock = ContinuousClock()
        let started = clock.now
        await expectWireError(.requestTimedOut) {
            _ = try await service.callCommand(
                CommandCallRequest(
                    name: "echo",
                    arguments: .object([:]),
                    requestID: "drip",
                    deadline: Date().addingTimeInterval(0.1)
                ),
                credential: mockCredential
            )
        }
        #expect(started.duration(to: clock.now) < .seconds(1))
        try await server.wait()
    }

    @Test("a late old-session disconnect cannot clear a newly initialized session")
    func disconnectReentrancy() async throws {
        let deleteReceived = WireClientTestSignal()
        let server = try MockLoopbackHTTPServer(responseCount: 4) { index, opened in
            switch index {
            case 0:
                let id = try requestID(opened)
                return jsonReply(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                    sessionID: "old-session"
                )
            case 1:
                await deleteReceived.signal()
                return MockHTTPReply(statusCode: 204, headerDelayMicroseconds: 300_000)
            case 2:
                let id = try requestID(opened)
                return jsonReply(
                    #"{"jsonrpc":"2.0","id":"\#(id)","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"com.example.mock-producer","title":"Mock Producer","version":"1.0.0"}}}"#,
                    sessionID: "new-session"
                )
            default:
                return MockHTTPReply(statusCode: 202)
            }
        }
        let service = try await mockService(server: server)
        _ = try await service.initialize(
            supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
            credential: mockCredential
        )
        let disconnecting = Task {
            guard let disconnecting = service as? any LocalMCPDisconnectingService else {
                Issue.record("Wire service did not expose disconnect")
                return
            }
            await disconnecting.disconnect(credential: mockCredential)
        }
        await deleteReceived.wait()
        _ = try await service.initialize(
            supportedProtocolVersions: [MCPProtocolVersion.current.rawValue],
            credential: mockCredential
        )
        await disconnecting.value
        try await service.initialized(credential: mockCredential)
        try await server.wait()
    }
}

private let mockProducerIdentity = ProducerIdentity(
    stableID: "com.example.mock-producer",
    displayName: "Mock Producer",
    version: "1.0.0"
)

private let mockCredential = try! AuthorizationCredential(bytes: [UInt8](repeating: 91, count: 32))

private func mockService(server: MockLoopbackHTTPServer) async throws -> any LocalMCPService {
    let endpoint = try LoopbackEndpoint(port: server.port, path: "/mcp")
    let instance = ProducerInstance(
        identity: mockProducerIdentity,
        instanceID: "e704e84e-a6f5-4b8f-8f18-2959a079722b",
        endpoint: endpoint,
        descriptorURL: try LoopbackEndpoint(
            port: server.port,
            path: "/local-mcp/v1/descriptor.json"
        ),
        channelBinding: server.channelBinding
    )
    return try await LocalMCPHTTPConnector(requestTimeout: 1).connect(to: instance)
}

private func expectWireError(
    _ expected: LocalMCPError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

/// The logical (inner) reply a mock returns. It is sealed to the client's
/// request before it leaves the socket; the timing fields shape the outer
/// transfer to exercise deadlines and slow peers.
private struct MockHTTPReply: Sendable {
    var statusCode = 200
    var headers: [String: String] = [:]
    var body = Data()
    var bodyChunkDelayMicroseconds: useconds_t = 0
    var holdOpenMicroseconds: useconds_t = 0
    var headerDelayMicroseconds: useconds_t = 0
}

private func jsonReply(_ body: String, sessionID: String? = nil) -> MockHTTPReply {
    var headers = ["Content-Type": "application/json"]
    if let sessionID { headers["Mcp-Session-Id"] = sessionID }
    return MockHTTPReply(headers: headers, body: Data(body.utf8))
}

private func requestID(_ opened: SecureOpenedMCPRequest) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: opened.request.body) as? [String: Any],
          let id = object["id"] as? String
    else { throw LocalMCPError.commandFailed }
    return id
}

private final class MockLoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    let channelBinding: ProducerChannelBinding
    private let listener: Int32
    private let task: Task<Void, any Error>

    init(
        responseCount: Int,
        responder: @escaping @Sendable (Int, SecureOpenedMCPRequest) async throws -> MockHTTPReply
    ) throws {
        let securityContext = try MCPProcessSecurityContext()
        channelBinding = securityContext.channelBinding
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LocalMCPError.bindFailed }
        var reusable: Int32 = 1
        let reusableSize = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafePointer(to: &reusable) {
            Darwin.setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, $0, reusableSize)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, Int32(responseCount)) == 0 else {
            Darwin.close(listener)
            throw LocalMCPError.bindFailed
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(listener)
            throw LocalMCPError.bindFailed
        }
        self.listener = listener
        let port = UInt16(bigEndian: resolved.sin_port)
        self.port = port
        let authority = "127.0.0.1:\(port)"
        task = Task.detached {
            defer { Darwin.close(listener) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<responseCount {
                    let connection = Darwin.accept(listener, nil, nil)
                    guard connection >= 0 else { throw LocalMCPError.producerUnavailable }
                    group.addTask {
                        defer { Darwin.close(connection) }
                        let raw = try readMockRequest(connection)
                        let outerRequest = try parseMockOuterRequest(raw)
                        let opened = try await securityContext.openMCPRequest(
                            outerRequest,
                            expectedAuthority: authority,
                            maximumPlaintextBytes: 2 * 1_024 * 1_024
                        )
                        let reply = try await responder(index, opened)
                        let sealed = try opened.responseContext.seal(
                            MCPHTTPResponse(
                                statusCode: reply.statusCode,
                                headers: reply.headers,
                                body: reply.body
                            )
                        )
                        try sendMockReply(
                            sealed,
                            timing: reply,
                            connection: connection
                        )
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    func wait() async throws {
        try await task.value
    }

    deinit {
        Darwin.shutdown(listener, SHUT_RDWR)
    }
}

private func readMockRequest(_ connection: Int32) throws -> Data {
    var data = Data()
    var expectedLength: Int?
    var bodyStart: Data.Index?
    var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
    while true {
        if let bodyStart, let expectedLength, data.count - bodyStart >= expectedLength {
            return Data(data.prefix(bodyStart + expectedLength))
        }
        let count = Darwin.recv(connection, &buffer, buffer.count, 0)
        guard count > 0 else { throw LocalMCPError.producerUnavailable }
        data.append(contentsOf: buffer.prefix(count))
        guard data.count <= 2 * 1_024 * 1_024 else { throw LocalMCPError.producerUnavailable }
        if bodyStart == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
            bodyStart = range.upperBound
            let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
            expectedLength = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
        }
    }
}

private func parseMockOuterRequest(_ raw: Data) throws -> MCPHTTPRequest {
    guard let range = raw.range(of: Data("\r\n\r\n".utf8)) else {
        throw LocalMCPError.producerUnavailable
    }
    let head = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw LocalMCPError.producerUnavailable }
    let pieces = requestLine.split(separator: " ")
    guard pieces.count >= 2 else { throw LocalMCPError.producerUnavailable }
    var headers: [String: [String]] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[name, default: []].append(value)
    }
    return MCPHTTPRequest(
        method: String(pieces[0]),
        path: String(pieces[1]),
        headers: headers,
        body: Data(raw[range.upperBound...])
    )
}

private func sendMockReply(
    _ sealed: MCPHTTPResponse,
    timing: MockHTTPReply,
    connection: Int32
) throws {
    if timing.headerDelayMicroseconds > 0 { usleep(timing.headerDelayMicroseconds) }
    var headers = sealed.headers
    headers["Content-Length"] = String(sealed.body.count)
    headers["Connection"] = "close"
    var head = "HTTP/1.1 \(sealed.statusCode) OK\r\n"
    for key in headers.keys.sorted() {
        head += "\(key): \(headers[key]!)\r\n"
    }
    head += "\r\n"
    try sendMockBytes(Data(head.utf8), connection: connection)
    if timing.bodyChunkDelayMicroseconds == 0 {
        try sendMockBytes(sealed.body, connection: connection)
    } else {
        for byte in sealed.body {
            usleep(timing.bodyChunkDelayMicroseconds)
            do {
                try sendMockBytes(Data([byte]), connection: connection)
            } catch {
                return
            }
        }
    }
    if timing.holdOpenMicroseconds > 0 { usleep(timing.holdOpenMicroseconds) }
}

private actor WireClientTestSignal {
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
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func sendMockBytes(_ data: Data, connection: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = Darwin.send(
                connection,
                base.advanced(by: sent),
                data.count - sent,
                MSG_NOSIGNAL
            )
            guard count > 0 else { throw LocalMCPError.producerUnavailable }
            sent += count
        }
    }
}
