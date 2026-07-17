import Darwin
import Foundation
import LocalMCPContracts
import Testing
@testable import LocalMCPDiscoveryBonjour

let bonjourTestProducer = ProducerIdentity(
    stableID: "com.example.bonjour-producer",
    displayName: "Bonjour Producer",
    version: "1.0.0"
)

let bonjourTestInstanceID = "90f3fc7c-b047-4af2-bac1-33b5b0563d16"
let bonjourTestChannelBinding = ProducerChannelBinding(
    publicKey: try! ChannelBindingPublicKey(
        rawRepresentation: Array(repeating: 0x52, count: 32)
    )
)

func bonjourTestDescriptor(
    instanceID: String = bonjourTestInstanceID,
    server: ProducerIdentity = bonjourTestProducer,
    mcp: MCPDescriptor = MCPDescriptor()
) -> ProducerDescriptor {
    ProducerDescriptor(
        instanceID: instanceID,
        server: server,
        mcp: mcp,
        channelBinding: bonjourTestChannelBinding
    )
}

func bonjourTestInstance(
    instanceID: String = bonjourTestInstanceID,
    port: UInt16 = 49_152
) throws -> ProducerInstance {
    ProducerInstance(
        identity: bonjourTestProducer,
        instanceID: instanceID,
        endpoint: try LoopbackEndpoint(port: port, path: "/mcp"),
        descriptorURL: try LoopbackEndpoint(
            port: port,
            path: "/local-mcp/v1/descriptor.json"
        ),
        channelBinding: bonjourTestChannelBinding
    )
}

func rawTXTRecord(_ entries: [String]) -> Data {
    var data = Data()
    for entry in entries {
        let bytes = Data(entry.utf8)
        precondition(bytes.count <= Int(UInt8.max))
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }
    return data
}

func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

final class FakeBonjourOperation: BonjourDNSServiceOperation, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    func cancel() {
        lock.withLock { cancellations += 1 }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }
}

final class FakeBonjourDNSServiceBackend: BonjourDNSServiceBackend, @unchecked Sendable {
    enum Failure: Error { case register; case browse; case resolve }

    struct BrowseCall: Sendable, Equatable {
        var serviceType: String
        var interfaceIndex: UInt32
    }

    private let lock = NSLock()
    private var registrationRequests: [BonjourRegistrationRequest] = []
    private var registrationFailureHandlers: [@Sendable (Int32) -> Void] = []
    private var registrationOperations: [FakeBonjourOperation] = []
    private var browseCalls: [BrowseCall] = []
    private var browseHandlers: [@Sendable (BonjourBrowseEvent) -> Void] = []
    private var browseOperations: [FakeBonjourOperation] = []
    private var resolveServices: [BonjourServiceKey] = []
    private var resolveHandlers: [BonjourServiceKey: @Sendable (BonjourResolveEvent) -> Void] = [:]
    private var resolveOperations: [BonjourServiceKey: FakeBonjourOperation] = [:]
    var registerFailure: Failure?
    var browseFailure: Failure?
    var resolveFailure: Failure?

    func register(
        _ request: BonjourRegistrationRequest,
        failureHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> any BonjourDNSServiceOperation {
        try lock.withLock {
            if registerFailure != nil { throw Failure.register }
            let operation = FakeBonjourOperation()
            registrationRequests.append(request)
            registrationFailureHandlers.append(failureHandler)
            registrationOperations.append(operation)
            return operation
        }
    }

    func browse(
        serviceType: String,
        interfaceIndex: UInt32,
        handler: @escaping @Sendable (BonjourBrowseEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation {
        try lock.withLock {
            if browseFailure != nil { throw Failure.browse }
            let operation = FakeBonjourOperation()
            browseCalls.append(BrowseCall(serviceType: serviceType, interfaceIndex: interfaceIndex))
            browseHandlers.append(handler)
            browseOperations.append(operation)
            return operation
        }
    }

    func resolve(
        _ service: BonjourServiceKey,
        handler: @escaping @Sendable (BonjourResolveEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation {
        try lock.withLock {
            if resolveFailure != nil { throw Failure.resolve }
            let operation = FakeBonjourOperation()
            resolveServices.append(service)
            resolveHandlers[service] = handler
            resolveOperations[service] = operation
            return operation
        }
    }

    func emitBrowse(_ event: BonjourBrowseEvent) {
        let handlers = lock.withLock { browseHandlers }
        handlers.forEach { $0(event) }
    }

    func emitResolve(_ event: BonjourResolveEvent, for service: BonjourServiceKey) {
        let handler = lock.withLock { resolveHandlers[service] }
        handler?(event)
    }

    func failRegistration(at index: Int = 0, errorCode: Int32 = -65_537) {
        let handler = lock.withLock {
            registrationFailureHandlers.indices.contains(index)
                ? registrationFailureHandlers[index]
                : nil
        }
        handler?(errorCode)
    }

    func setRegisterFailure(_ failure: Failure?) {
        lock.withLock { registerFailure = failure }
    }

    var registrations: [BonjourRegistrationRequest] {
        lock.withLock { registrationRequests }
    }

    var registrationHandles: [FakeBonjourOperation] {
        lock.withLock { registrationOperations }
    }

    var browses: [BrowseCall] {
        lock.withLock { browseCalls }
    }

    var browseHandles: [FakeBonjourOperation] {
        lock.withLock { browseOperations }
    }

    var resolutions: [BonjourServiceKey] {
        lock.withLock { resolveServices }
    }

    func resolveHandle(for service: BonjourServiceKey) -> FakeBonjourOperation? {
        lock.withLock { resolveOperations[service] }
    }
}

actor FakeBonjourDescriptorLoader: BonjourDescriptorLoading {
    enum Failure: Error { case injected }

    private var result: Result<ProducerDescriptor, Failure>
    private var requestedURLs: [URL] = []

    init(descriptor: ProducerDescriptor = bonjourTestDescriptor()) {
        result = .success(descriptor)
    }

    func loadDescriptor(from url: URL) async throws -> ProducerDescriptor {
        requestedURLs.append(url)
        return try result.get()
    }

    func setDescriptor(_ descriptor: ProducerDescriptor) {
        result = .success(descriptor)
    }

    func setFailure() {
        result = .failure(.injected)
    }

    func urls() -> [URL] {
        requestedURLs
    }
}

actor BonjourEventRecorder {
    private var values: [BonjourBrowseEvent] = []

    func append(_ value: BonjourBrowseEvent) {
        values.append(value)
    }

    func events() -> [BonjourBrowseEvent] {
        values
    }
}

actor DiscoveryEventRecorder {
    private var values: [DiscoveryEvent] = []

    func append(_ value: DiscoveryEvent) {
        values.append(value)
    }

    func events() -> [DiscoveryEvent] {
        values
    }
}

actor BlockingOrderedPumpRecorder {
    private var values: [Int] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func receive(_ value: Int) async {
        values.append(value)
        guard value == 1 else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func events() -> [Int] {
        values
    }
}

final class ControlledBonjourSleeper: LocalMCPSleeping, @unchecked Sendable {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var recordedIntervals: [TimeInterval] = []
    private var waiters: [Waiter] = []
    private var cancelledIDs: Set<UUID> = []

    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if cancelledIDs.remove(id) != nil || Task.isCancelled {
                        return true
                    }
                    recordedIntervals.append(interval)
                    waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: { cancel(id: id) })
    }

    @discardableResult
    func resumeNext() -> Bool {
        let waiter = lock.withLock { () -> Waiter? in
            guard !waiters.isEmpty else { return nil }
            return waiters.removeFirst()
        }
        guard let waiter else { return false }
        waiter.continuation.resume()
        return true
    }

    func intervals() -> [TimeInterval] {
        lock.withLock { recordedIntervals }
    }

    func pendingCount() -> Int {
        lock.withLock { waiters.count }
    }

    private func cancel(id: UUID) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                cancelledIDs.insert(id)
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }
}

enum SlowDripLoopbackServerError: Error {
    case socket
}

final class SlowDripLoopbackServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var connected = false
        private var disconnected = false
        private var stopping = false

        func markConnected() {
            lock.withLock { connected = true }
        }

        func markDisconnected() {
            lock.withLock { disconnected = true }
        }

        func beginStop() -> Bool {
            lock.withLock {
                guard !stopping else { return false }
                stopping = true
                return true
            }
        }

        var isConnected: Bool {
            lock.withLock { connected }
        }

        var isDisconnected: Bool {
            lock.withLock { disconnected }
        }

        var isStopping: Bool {
            lock.withLock { stopping }
        }
    }

    let port: UInt16

    private let listenerDescriptor: Int32
    private let state = State()
    private let serverTask: Task<Void, Never>

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SlowDripLoopbackServerError.socket }

        var enabled: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw SlowDripLoopbackServerError.socket
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0, boundAddress.sin_port != 0 else {
            Darwin.close(descriptor)
            throw SlowDripLoopbackServerError.socket
        }

        listenerDescriptor = descriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
        let state = self.state
        serverTask = Task.detached {
            Self.serve(listenerDescriptor: descriptor, state: state)
        }
    }

    deinit {
        guard state.beginStop() else { return }
        serverTask.cancel()
        Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
        Darwin.close(listenerDescriptor)
    }

    var clientConnected: Bool { state.isConnected }
    var clientDisconnected: Bool { state.isDisconnected }

    func stop() async {
        guard state.beginStop() else { return }
        serverTask.cancel()
        Darwin.shutdown(listenerDescriptor, SHUT_RDWR)
        Darwin.close(listenerDescriptor)
        await serverTask.value
    }

    private static func serve(listenerDescriptor: Int32, state: State) {
        let connection = Darwin.accept(listenerDescriptor, nil, nil)
        guard connection >= 0 else { return }
        state.markConnected()
        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2 * 1_024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil, !state.isStopping {
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else {
                state.markDisconnected()
                Darwin.close(connection)
                return
            }
            request.append(contentsOf: buffer.prefix(count))
            guard request.count <= 16 * 1_024 else {
                Darwin.close(connection)
                return
            }
        }

        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n".utf8
        )
        guard sendAll(header, to: connection) else {
            state.markDisconnected()
            Darwin.close(connection)
            return
        }

        var byte = UInt8(ascii: " ")
        while !Task.isCancelled, !state.isStopping {
            let count = Darwin.send(connection, &byte, 1, 0)
            guard count == 1 else {
                state.markDisconnected()
                break
            }
            Darwin.usleep(20_000)
        }
        Darwin.close(connection)
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(
                    descriptor,
                    base.advanced(by: sent),
                    data.count - sent,
                    0
                )
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}
