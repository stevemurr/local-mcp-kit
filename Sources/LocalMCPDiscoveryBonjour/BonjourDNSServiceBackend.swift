import Dispatch
import Foundation
import dnssd

let bonjourLocalOnlyInterfaceIndex = UInt32(kDNSServiceInterfaceIndexLocalOnly)

func bonjourRegistrationCallbackSucceeded(errorCode: Int32, flags: UInt32) -> Bool {
    errorCode == Int32(kDNSServiceErr_NoError)
        && flags & UInt32(kDNSServiceFlagsAdd) != 0
}

protocol BonjourDNSServiceOperation: Sendable {
    func cancel()
}

struct BonjourRegistrationRequest: Sendable, Equatable {
    var name: String
    var serviceType: String
    var interfaceIndex: UInt32
    var port: UInt16
    var txtRecord: Data
}

struct BonjourServiceKey: Sendable, Hashable {
    var name: String
    var serviceType: String
    var domain: String
    var interfaceIndex: UInt32
}

enum BonjourBrowseEvent: Sendable, Equatable {
    case added(BonjourServiceKey)
    case removed(BonjourServiceKey)
    case failure(Int32)
}

struct BonjourResolveResult: Sendable, Equatable {
    var interfaceIndex: UInt32
    var fullName: String
    var hostTarget: String
    var port: UInt16
    var txtRecord: Data
}

enum BonjourResolveEvent: Sendable, Equatable {
    case resolved(BonjourResolveResult)
    case failure(Int32)
}

protocol BonjourDNSServiceBackend: Sendable {
    func register(
        _ request: BonjourRegistrationRequest,
        failureHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> any BonjourDNSServiceOperation

    func browse(
        serviceType: String,
        interfaceIndex: UInt32,
        handler: @escaping @Sendable (BonjourBrowseEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation

    func resolve(
        _ service: BonjourServiceKey,
        handler: @escaping @Sendable (BonjourResolveEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation
}

enum BonjourDNSServiceBackendError: Error, Sendable, Equatable {
    case dnsService(Int32)
    case cancelled
}

final class SystemBonjourDNSServiceBackend: BonjourDNSServiceBackend, @unchecked Sendable {
    func register(
        _ request: BonjourRegistrationRequest,
        failureHandler: @escaping @Sendable (Int32) -> Void
    ) async throws -> any BonjourDNSServiceOperation {
        let state = RegistrationState(failureHandler: failureHandler)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation)
                do {
                    let callback = RegistrationCallbackBox { errorCode, added in
                        state.receive(errorCode: errorCode, added: added)
                    }
                    let context = Unmanaged.passUnretained(callback).toOpaque()
                    var serviceRef: DNSServiceRef?
                    let errorCode = request.txtRecord.withUnsafeBytes { txtBytes in
                        request.name.withCString { name in
                            request.serviceType.withCString { serviceType in
                                DNSServiceRegister(
                                    &serviceRef,
                                    0,
                                    request.interfaceIndex,
                                    name,
                                    serviceType,
                                    nil,
                                    nil,
                                    request.port.bigEndian,
                                    UInt16(request.txtRecord.count),
                                    txtBytes.baseAddress,
                                    systemRegistrationCallback,
                                    context
                                )
                            }
                        }
                    }
                    guard errorCode == kDNSServiceErr_NoError, let serviceRef else {
                        throw BonjourDNSServiceBackendError.dnsService(Int32(errorCode))
                    }
                    let operation = try SystemBonjourDNSServiceOperation(
                        serviceRef: serviceRef,
                        callbackContext: callback,
                        label: "registration"
                    )
                    state.install(operation)
                } catch {
                    state.fail(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    func browse(
        serviceType: String,
        interfaceIndex: UInt32,
        handler: @escaping @Sendable (BonjourBrowseEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation {
        let callback = BrowseCallbackBox(handler: handler)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var serviceRef: DNSServiceRef?
        let errorCode = serviceType.withCString { serviceType in
            DNSServiceBrowse(
                &serviceRef,
                0,
                interfaceIndex,
                serviceType,
                nil,
                systemBrowseCallback,
                context
            )
        }
        guard errorCode == kDNSServiceErr_NoError, let serviceRef else {
            throw BonjourDNSServiceBackendError.dnsService(Int32(errorCode))
        }
        return try SystemBonjourDNSServiceOperation(
            serviceRef: serviceRef,
            callbackContext: callback,
            label: "browse"
        )
    }

    func resolve(
        _ service: BonjourServiceKey,
        handler: @escaping @Sendable (BonjourResolveEvent) -> Void
    ) throws -> any BonjourDNSServiceOperation {
        let callback = ResolveCallbackBox(handler: handler)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var serviceRef: DNSServiceRef?
        let errorCode = service.name.withCString { name in
            service.serviceType.withCString { serviceType in
                service.domain.withCString { domain in
                    DNSServiceResolve(
                        &serviceRef,
                        0,
                        service.interfaceIndex,
                        name,
                        serviceType,
                        domain,
                        systemResolveCallback,
                        context
                    )
                }
            }
        }
        guard errorCode == kDNSServiceErr_NoError, let serviceRef else {
            throw BonjourDNSServiceBackendError.dnsService(Int32(errorCode))
        }
        return try SystemBonjourDNSServiceOperation(
            serviceRef: serviceRef,
            callbackContext: callback,
            label: "resolve"
        )
    }
}

private final class SystemBonjourDNSServiceOperation: BonjourDNSServiceOperation, @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let callbackContext: AnyObject
    private var serviceRef: DNSServiceRef?

    init(serviceRef: DNSServiceRef, callbackContext: AnyObject, label: String) throws {
        self.serviceRef = serviceRef
        self.callbackContext = callbackContext
        queue = DispatchQueue(label: "LocalMCPKit.Bonjour.\(label).\(UUID().uuidString)")
        queue.setSpecific(key: queueKey, value: 1)
        let errorCode = DNSServiceSetDispatchQueue(serviceRef, queue)
        guard errorCode == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
            throw BonjourDNSServiceBackendError.dnsService(Int32(errorCode))
        }
    }

    func cancel() {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            cancelOnQueue()
        } else {
            queue.sync { cancelOnQueue() }
        }
    }

    deinit {
        cancel()
        _ = callbackContext
    }

    private func cancelOnQueue() {
        guard let serviceRef else { return }
        DNSServiceRefDeallocate(serviceRef)
        self.serviceRef = nil
    }
}

private final class RegistrationState: @unchecked Sendable {
    private let lock = NSLock()
    private let failureHandler: @Sendable (Int32) -> Void
    private var continuation: CheckedContinuation<any BonjourDNSServiceOperation, any Error>?
    private var operation: (any BonjourDNSServiceOperation)?
    private var pendingResult: Result<Void, any Error>?
    private var completed = false
    private var cancelled = false

    init(failureHandler: @escaping @Sendable (Int32) -> Void) {
        self.failureHandler = failureHandler
    }

    func begin(_ continuation: CheckedContinuation<any BonjourDNSServiceOperation, any Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func install(_ operation: any BonjourDNSServiceOperation) {
        var action: (() -> Void)?
        lock.withLock {
            guard !completed else {
                action = { operation.cancel() }
                return
            }
            self.operation = operation
            if cancelled {
                completed = true
                let continuation = self.continuation
                self.continuation = nil
                action = {
                    operation.cancel()
                    continuation?.resume(throwing: CancellationError())
                }
            } else if let pendingResult {
                completed = true
                let continuation = self.continuation
                self.continuation = nil
                action = {
                    switch pendingResult {
                    case .success:
                        continuation?.resume(returning: operation)
                    case let .failure(error):
                        operation.cancel()
                        continuation?.resume(throwing: error)
                    }
                }
            }
        }
        action?()
    }

    func receive(errorCode: Int32, added: Bool) {
        let normalizedError = errorCode == Int32(kDNSServiceErr_NoError) && !added
            ? Int32(kDNSServiceErr_Unknown)
            : errorCode
        let result: Result<Void, any Error> = normalizedError == Int32(kDNSServiceErr_NoError)
            ? .success(())
            : .failure(BonjourDNSServiceBackendError.dnsService(normalizedError))
        var action: (() -> Void)?
        lock.withLock {
            if completed {
                if case .failure = result, !cancelled {
                    action = { [failureHandler] in failureHandler(normalizedError) }
                }
                return
            }
            guard let operation else {
                pendingResult = result
                return
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            action = {
                switch result {
                case .success:
                    continuation?.resume(returning: operation)
                case let .failure(error):
                    operation.cancel()
                    continuation?.resume(throwing: error)
                }
            }
        }
        action?()
    }

    func fail(_ error: any Error) {
        var continuation: CheckedContinuation<any BonjourDNSServiceOperation, any Error>?
        lock.withLock {
            guard !completed else { return }
            completed = true
            continuation = self.continuation
            self.continuation = nil
        }
        continuation?.resume(throwing: error)
    }

    func cancel() {
        var action: (() -> Void)?
        lock.withLock {
            guard !completed else { return }
            cancelled = true
            if let operation {
                completed = true
                let continuation = self.continuation
                self.continuation = nil
                action = {
                    operation.cancel()
                    continuation?.resume(throwing: CancellationError())
                }
            }
        }
        action?()
    }
}

private final class RegistrationCallbackBox: @unchecked Sendable {
    let handler: @Sendable (Int32, Bool) -> Void

    init(handler: @escaping @Sendable (Int32, Bool) -> Void) {
        self.handler = handler
    }
}

private final class BrowseCallbackBox: @unchecked Sendable {
    let handler: @Sendable (BonjourBrowseEvent) -> Void

    init(handler: @escaping @Sendable (BonjourBrowseEvent) -> Void) {
        self.handler = handler
    }
}

private final class ResolveCallbackBox: @unchecked Sendable {
    let handler: @Sendable (BonjourResolveEvent) -> Void

    init(handler: @escaping @Sendable (BonjourResolveEvent) -> Void) {
        self.handler = handler
    }
}

private let systemRegistrationCallback: DNSServiceRegisterReply = {
    _, flags, errorCode, _, _, _, context in
    guard let context else { return }
    let callback = Unmanaged<RegistrationCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let numericError = Int32(errorCode)
    callback.handler(numericError, UInt32(flags) & UInt32(kDNSServiceFlagsAdd) != 0)
}

private let systemBrowseCallback: DNSServiceBrowseReply = {
    _, flags, interfaceIndex, errorCode, serviceName, serviceType, domain, context in
    guard let context else { return }
    let callback = Unmanaged<BrowseCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard errorCode == kDNSServiceErr_NoError,
          let serviceName,
          let serviceType,
          let domain
    else {
        callback.handler(.failure(Int32(errorCode)))
        return
    }

    let service = BonjourServiceKey(
        name: String(cString: serviceName),
        serviceType: String(cString: serviceType),
        domain: String(cString: domain),
        interfaceIndex: interfaceIndex
    )
    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
        callback.handler(.added(service))
    } else {
        callback.handler(.removed(service))
    }
}

private let systemResolveCallback: DNSServiceResolveReply = {
    _, _, interfaceIndex, errorCode, fullName, hostTarget, port, txtLength, txtRecord, context in
    guard let context else { return }
    let callback = Unmanaged<ResolveCallbackBox>.fromOpaque(context).takeUnretainedValue()
    guard errorCode == kDNSServiceErr_NoError,
          let fullName,
          let hostTarget,
          let txtRecord
    else {
        callback.handler(.failure(Int32(errorCode)))
        return
    }

    callback.handler(
        .resolved(
            BonjourResolveResult(
                interfaceIndex: interfaceIndex,
                fullName: String(cString: fullName),
                hostTarget: String(cString: hostTarget),
                port: UInt16(bigEndian: port),
                txtRecord: Data(bytes: txtRecord, count: Int(txtLength))
            )
        )
    )
}
