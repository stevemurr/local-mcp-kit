import Foundation
import LocalMCPContracts
import Network

/// A real HTTP/1.1 listener whose bind address is not configurable: it always
/// uses the numeric IPv4 loopback address. The implementation accepts one
/// bounded request per connection and closes it after the response.
public final class NumericLoopbackHTTPListener: @unchecked Sendable {
    public typealias Handler = @Sendable (MCPHTTPRequest, String) async -> MCPHTTPResponse

    fileprivate enum ListenerError: Error {
        case invalidRequest
        case requestTooLarge
        case timedOut
        case handlerTimedOut
        case stopped
        case network
    }

    private let requestedPort: UInt16
    private let limits: MCPHTTPServerLimits
    private let handler: Handler
    private let queue = DispatchQueue(label: "localmcp.loopback-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var listenerStopGate: ListenerStopGate?
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(
        requestedPort: UInt16 = 0,
        limits: MCPHTTPServerLimits = .defaults,
        handler: @escaping Handler
    ) {
        self.requestedPort = requestedPort
        self.limits = limits
        self.handler = handler
    }

    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
            throw LocalMCPError.invalidConfiguration
        }
        let requiredEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )
        parameters.requiredLocalEndpoint = requiredEndpoint

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw LocalMCPError.bindFailed
        }
        let startup = StartupGate()
        let stopGate = ListenerStopGate()
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard newListener.parameters.requiredLocalEndpoint == requiredEndpoint,
                      let boundPort = newListener.port?.rawValue,
                      boundPort != 0
                else {
                    startup.fail(LocalMCPError.bindFailed)
                    newListener.cancel()
                    return
                }
                startup.succeed(boundPort)
            case .failed:
                startup.fail(LocalMCPError.bindFailed)
                stopGate.signal()
            case .cancelled:
                startup.fail(LocalMCPError.cancelled)
                stopGate.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        guard install(listener: newListener, stopGate: stopGate) else {
            newListener.cancel()
            throw LocalMCPError.invalidLifecycleState
        }
        newListener.start(queue: queue)

        return try await withTaskCancellationHandler {
            do {
                return try await startup.wait()
            } catch {
                await stop()
                if error is CancellationError { throw LocalMCPError.cancelled }
                if let error = error as? LocalMCPError { throw error }
                throw LocalMCPError.bindFailed
            }
        } onCancel: {
            newListener.cancel()
            startup.fail(LocalMCPError.cancelled)
        }
    }

    public func stop() async {
        let snapshot = takeResources()
        snapshot.listener?.cancel()
        for task in snapshot.tasks { task.cancel() }
        for connection in snapshot.connections { connection.cancel() }
        if let stopGate = snapshot.stopGate {
            let stopped = LocalMCPAsyncOperation<Void>(
                timeoutAfter: 0.25,
                timeoutError: ListenerError.timedOut
            ) {
                await stopGate.wait()
            }
            _ = try? await stopped.value(cancellationError: ListenerError.stopped)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        guard install(connection: connection, id: id) else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancelTask(id: id)
            default:
                break
            }
        }
        connection.start(queue: queue)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(connection, id: id)
            self.removeConnection(id: id)
        }
        install(task: task, id: id)
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        let operationBox = HTTPOperationBox()
        await withTaskCancellationHandler {
            do {
                let request = try await readRequestWithTimeout(from: connection)
                if Task.isCancelled { throw ListenerError.stopped }

                let peerState = PeerState()
                let authority = "127.0.0.1:\(boundPort())"
                let handlerTimeout = request.path == "/local-mcp/v1/pairing-requests"
                    ? 125
                    : limits.handlerTimeout + max(0.05, min(1, limits.handlerTimeout * 0.1))
                let operation = LocalMCPAsyncOperation<MCPHTTPResponse>(
                    timeoutAfter: handlerTimeout,
                    timeoutError: ListenerError.handlerTimedOut
                ) { [handler] in
                    await handler(request, authority)
                }
                operationBox.install(operation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                    data, _, complete, error in
                    if complete || error != nil || data?.isEmpty == false {
                        peerState.markDisconnected()
                        operation.cancel(with: ListenerError.stopped)
                    }
                }

                let response = try await operation.value(cancellationError: ListenerError.stopped)
                guard !peerState.isDisconnected, !Task.isCancelled else {
                    connection.cancel()
                    return
                }
                try await send(response, over: connection)
            } catch ListenerError.handlerTimedOut {
                try? await send(MCPHTTPResponse(statusCode: 503), over: connection)
            } catch ListenerError.requestTooLarge {
                try? await send(MCPHTTPResponse(statusCode: 413), over: connection)
            } catch ListenerError.invalidRequest {
                try? await send(MCPHTTPResponse(statusCode: 400), over: connection)
            } catch {
                connection.cancel()
            }
        } onCancel: {
            operationBox.cancel()
            connection.cancel()
        }
    }

    private func readRequestWithTimeout(from connection: NWConnection) async throws -> MCPHTTPRequest {
        let operation = LocalMCPAsyncOperation<MCPHTTPRequest>(
            timeout: { [limits] in
                let nanoseconds = UInt64(limits.headerTimeout * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                connection.cancel()
            },
            timeoutError: ListenerError.timedOut
        ) { [limits] in
                try await Self.readRequest(from: connection, limits: limits)
        }
        return try await withTaskCancellationHandler {
            try await operation.value(cancellationError: ListenerError.stopped)
        } onCancel: {
            operation.cancel(with: ListenerError.stopped)
            // A pending Network.framework continuation is released by closing
            // the connection even when its surrounding task ignores cancellation.
            connection.cancel()
        }
    }

    private static func readRequest(
        from connection: NWConnection,
        limits: MCPHTTPServerLimits
    ) async throws -> MCPHTTPRequest {
        var bytes = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?

        while headerRange == nil {
            let (chunk, complete) = try await receive(from: connection, maximumLength: 8 * 1_024)
            bytes.append(chunk)
            if bytes.count > limits.maximumHeaderBytes { throw ListenerError.requestTooLarge }
            headerRange = bytes.range(of: delimiter)
            if complete, headerRange == nil { throw ListenerError.invalidRequest }
        }

        let range = headerRange!
        let headerData = bytes[..<range.lowerBound]
        var bodyBuffer = Data(bytes[range.upperBound...])
        let parsed = try parseHeaders(Data(headerData), maximumFields: limits.maximumHeaderFields)
        let bodyLimit: Int
        switch (parsed.method, parsed.path) {
        case ("POST", let path) where path == "/local-mcp/v1/pairing-requests" ||
            path.hasPrefix("/local-mcp/v1/pairing-requests/"):
            bodyLimit = limits.maximumPairingBodyBytes
        case ("POST", "/mcp"):
            bodyLimit = limits.maximumSecureEnvelopeBytes
        default:
            bodyLimit = 0
        }

        let contentLengths = parsed.headers["content-length"] ?? []
        let transferEncodings = parsed.headers["transfer-encoding"] ?? []
        guard !(contentLengths.count > 0 && transferEncodings.count > 0),
              contentLengths.count <= 1,
              transferEncodings.count <= 1
        else { throw ListenerError.invalidRequest }

        let body: Data
        if let rawLength = contentLengths.first {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy(\.isNumber),
                  let length = Int(rawLength),
                  length <= bodyLimit
            else { throw ListenerError.requestTooLarge }
            body = try await readFixedBody(
                length: length,
                initial: &bodyBuffer,
                connection: connection
            )
        } else if let encoding = transferEncodings.first {
            guard encoding.lowercased() == "chunked", bodyLimit > 0 else {
                throw ListenerError.invalidRequest
            }
            let reader = ChunkReader(initial: bodyBuffer, connection: connection)
            body = try await reader.readBody(maximumBytes: bodyLimit)
        } else {
            guard bodyBuffer.isEmpty else { throw ListenerError.invalidRequest }
            body = Data()
        }

        if parsed.method == "POST", contentLengths.isEmpty, transferEncodings.isEmpty {
            throw ListenerError.invalidRequest
        }
        return MCPHTTPRequest(
            method: parsed.method,
            path: parsed.path,
            headers: parsed.headers,
            body: body
        )
    }

    private static func readFixedBody(
        length: Int,
        initial: inout Data,
        connection: NWConnection
    ) async throws -> Data {
        guard initial.count <= length else { throw ListenerError.invalidRequest }
        while initial.count < length {
            let (chunk, complete) = try await receive(
                from: connection,
                maximumLength: min(8 * 1_024, length - initial.count)
            )
            initial.append(chunk)
            if complete, initial.count < length { throw ListenerError.invalidRequest }
        }
        return initial
    }

    private static func parseHeaders(
        _ data: Data,
        maximumFields: Int
    ) throws -> (method: String, path: String, headers: [String: [String]]) {
        guard let string = String(data: data, encoding: .utf8),
              !string.contains("\0")
        else { throw ListenerError.invalidRequest }
        let lines = string.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ListenerError.invalidRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts.contains(where: { $0.isEmpty }),
              parts[2] == "HTTP/1.1"
        else { throw ListenerError.invalidRequest }
        let method = String(parts[0])
        let path = String(parts[1])
        guard ["GET", "POST", "DELETE"].contains(method),
              LoopbackEndpoint.isValidRelativePath(path)
        else { throw ListenerError.invalidRequest }

        let headerLines = lines.dropFirst()
        guard headerLines.count <= maximumFields else { throw ListenerError.requestTooLarge }
        var headers: [String: [String]] = [:]
        for line in headerLines {
            guard !line.isEmpty,
                  line.first != " " && line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { throw ListenerError.invalidRequest }
            let rawName = String(line[..<colon])
            let rawValue = String(line[line.index(after: colon)...])
            guard isHeaderName(rawName) else { throw ListenerError.invalidRequest }
            let name = rawName.lowercased()

            let value: String
            if rawValue.first == " " {
                value = String(rawValue.dropFirst())
            } else {
                guard rawValue.first != "\t" else { throw ListenerError.invalidRequest }
                value = rawValue
            }
            guard !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t")).contains($0)
            })
            else { throw ListenerError.invalidRequest }
            headers[name, default: []].append(value)
        }
        return (method, path, headers)
    }

    private static func isHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func receive(
        from connection: NWConnection,
        maximumLength: Int
    ) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, complete, error in
                if error != nil {
                    continuation.resume(throwing: ListenerError.network)
                } else {
                    continuation.resume(returning: (data ?? Data(), complete))
                }
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, over connection: NWConnection) async throws {
        guard response.body.count <= limits.maximumWireResponseBytes else {
            throw ListenerError.requestTooLarge
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n"
        for key in headers.keys.sorted() {
            guard let value = headers[key], Self.safeResponseHeader(key), Self.safeResponseValue(value) else {
                throw ListenerError.network
            }
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: ListenerError.network)
                } else {
                    continuation.resume()
                }
            })
        }
        connection.cancel()
    }

    private static func safeResponseHeader(_ value: String) -> Bool {
        isHeaderName(value)
    }

    private static func safeResponseValue(_ value: String) -> Bool {
        !value.contains("\r") && !value.contains("\n") && value.utf8.count <= 1_024
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }

    private func install(listener newListener: NWListener, stopGate: ListenerStopGate) -> Bool {
        lock.withLock {
            guard listener == nil else { return false }
            listener = newListener
            listenerStopGate = stopGate
            return true
        }
    }

    private func install(connection: NWConnection, id: UUID) -> Bool {
        lock.withLock {
            guard listener != nil,
                  connections.count < limits.maximumConcurrentConnections
            else { return false }
            connections[id] = connection
            return true
        }
    }

    private func install(task: Task<Void, Never>, id: UUID) {
        lock.withLock {
            if connections[id] != nil { tasks[id] = task } else { task.cancel() }
        }
    }

    private func removeConnection(id: UUID) {
        let connection = lock.withLock { () -> NWConnection? in
            tasks.removeValue(forKey: id)
            return connections.removeValue(forKey: id)
        }
        connection?.cancel()
    }

    private func cancelTask(id: UUID) {
        let task = lock.withLock { tasks[id] }
        task?.cancel()
    }

    private func boundPort() -> UInt16 {
        lock.withLock { listener?.port?.rawValue ?? 0 }
    }

    private func takeResources() -> (
        listener: NWListener?,
        stopGate: ListenerStopGate?,
        connections: [NWConnection],
        tasks: [Task<Void, Never>]
    ) {
        lock.withLock {
            let snapshot = (
                listener,
                listenerStopGate,
                Array(connections.values),
                Array(tasks.values)
            )
            listener = nil
            listenerStopGate = nil
            connections.removeAll()
            tasks.removeAll()
            return snapshot
        }
    }
}

private final class StartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?
    private var result: Result<UInt16, any Error>?

    func wait() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<UInt16, any Error>? in
                if let existing = self.result { return existing }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func succeed(_ port: UInt16) { finish(.success(port)) }
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<UInt16, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ListenerStopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyCompleted = lock.withLock { () -> Bool in
                if completed { return true }
                self.continuation = continuation
                return false
            }
            if alreadyCompleted { continuation.resume() }
        }
    }

    func signal() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !completed else { return nil }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class PeerState: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnected = false

    var isDisconnected: Bool { lock.withLock { disconnected } }
    func markDisconnected() { lock.withLock { disconnected = true } }
}

private final class HTTPOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: LocalMCPAsyncOperation<MCPHTTPResponse>?
    private var cancelled = false

    func install(_ operation: LocalMCPAsyncOperation<MCPHTTPResponse>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            self.operation = operation
            return cancelled
        }
        if cancelImmediately { operation.cancel(with: NumericLoopbackHTTPListener.ListenerError.stopped) }
    }

    func cancel() {
        let operation = lock.withLock { () -> LocalMCPAsyncOperation<MCPHTTPResponse>? in
            cancelled = true
            return self.operation
        }
        operation?.cancel(with: NumericLoopbackHTTPListener.ListenerError.stopped)
    }
}

private final class ChunkReader: @unchecked Sendable {
    private var buffer: Data
    private let connection: NWConnection

    init(initial: Data, connection: NWConnection) {
        buffer = initial
        self.connection = connection
    }

    func readBody(maximumBytes: Int) async throws -> Data {
        var body = Data()
        while true {
            let line = try await readLine(maximumBytes: 128)
            guard !line.isEmpty,
                  !line.contains(";"),
                  line.allSatisfy({ $0.isHexDigit }),
                  let size = Int(line, radix: 16)
            else { throw NumericLoopbackHTTPListener.ListenerError.invalidRequest }
            if size == 0 {
                guard try await readLine(maximumBytes: 2).isEmpty else {
                    throw NumericLoopbackHTTPListener.ListenerError.invalidRequest
                }
                return body
            }
            guard size <= maximumBytes - body.count else {
                throw NumericLoopbackHTTPListener.ListenerError.requestTooLarge
            }
            body.append(try await read(count: size))
            guard try await read(count: 2) == Data("\r\n".utf8) else {
                throw NumericLoopbackHTTPListener.ListenerError.invalidRequest
            }
        }
    }

    private func readLine(maximumBytes: Int) async throws -> String {
        let delimiter = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: delimiter) {
                guard range.lowerBound <= maximumBytes,
                      let line = String(data: buffer[..<range.lowerBound], encoding: .utf8)
                else { throw NumericLoopbackHTTPListener.ListenerError.invalidRequest }
                buffer.removeSubrange(..<range.upperBound)
                return line
            }
            guard buffer.count <= maximumBytes else {
                throw NumericLoopbackHTTPListener.ListenerError.invalidRequest
            }
            let (chunk, complete) = try await receiveChunk(maximumLength: 8 * 1_024)
            buffer.append(chunk)
            if complete { throw NumericLoopbackHTTPListener.ListenerError.invalidRequest }
        }
    }

    private func read(count: Int) async throws -> Data {
        while buffer.count < count {
            let (chunk, complete) = try await receiveChunk(maximumLength: count - buffer.count)
            buffer.append(chunk)
            if complete, buffer.count < count {
                throw NumericLoopbackHTTPListener.ListenerError.invalidRequest
            }
        }
        let value = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return value
    }

    private func receiveChunk(maximumLength: Int) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                data, _, complete, error in
                if error != nil {
                    continuation.resume(throwing: LocalMCPError.producerUnavailable)
                } else {
                    continuation.resume(returning: (data ?? Data(), complete))
                }
            }
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
