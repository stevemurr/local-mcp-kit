import Foundation

/// Package-scoped bridge around an unstructured operation.
///
/// Unlike a task group, resolving this operation does not wait for a losing
/// child to cooperate with cancellation. Timeout and explicit cancellation
/// therefore release the caller immediately. The underlying task is still
/// cancelled and retained by Swift until it actually exits, while its late
/// result is discarded by the one-shot gate.
package final class LocalMCPAsyncOperation<Success: Sendable>: @unchecked Sendable {
    package typealias Timeout = @Sendable () async throws -> Void

    private let gate: LocalMCPResultGate<Success>
    private let operationTask: Task<Success, any Error>
    private let timeoutTask: Task<Void, Never>?

    package init(
        timeout: Timeout? = nil,
        timeoutError: (any Error)? = nil,
        operation: @escaping @Sendable () async throws -> Success
    ) {
        precondition((timeout == nil) == (timeoutError == nil))

        let gate = LocalMCPResultGate<Success>()
        self.gate = gate

        let operationTask = Task<Success, any Error> {
            do {
                let value = try await operation()
                _ = gate.finish(.success(value))
                return value
            } catch {
                _ = gate.finish(.failure(error))
                throw error
            }
        }
        self.operationTask = operationTask

        if let timeout, let timeoutError {
            timeoutTask = Task<Void, Never> {
                do {
                    try await timeout()
                    if gate.finish(.failure(timeoutError)) {
                        operationTask.cancel()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if gate.finish(.failure(error)) {
                        operationTask.cancel()
                    }
                }
            }
        } else {
            timeoutTask = nil
        }
    }

    package convenience init(
        timeoutAfter seconds: TimeInterval,
        timeoutError: any Error,
        operation: @escaping @Sendable () async throws -> Success
    ) {
        precondition(seconds >= 0 && seconds.isFinite)
        self.init(
            timeout: {
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            timeoutError: timeoutError,
            operation: operation
        )
    }

    /// Waits only for the one-shot visible result. Cancellation resolves the
    /// gate and returns without joining a cancellation-insensitive operation.
    package func value(
        cancellationError: any Error = CancellationError()
    ) async throws -> Success {
        do {
            let value = try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: {
                self.cancel(with: cancellationError)
            }
            timeoutTask?.cancel()
            return value
        } catch {
            timeoutTask?.cancel()
            throw error
        }
    }

    /// Cancels the underlying work and resolves any waiter immediately. A late
    /// success cannot replace the cancellation result.
    package func cancel(with error: any Error = CancellationError()) {
        timeoutTask?.cancel()
        _ = gate.finish(.failure(error))
        operationTask.cancel()
    }

    /// Intentionally waits for the real task, not the visible gate. Use only in
    /// detached convergence cleanup that must not hold up an API response.
    package func awaitUnderlyingCompletion() async {
        _ = await operationTask.result
        timeoutTask?.cancel()
    }
}

private final class LocalMCPResultGate<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Success, any Error>?
    private var waiters: [CheckedContinuation<Result<Success, any Error>, Never>] = []

    func value() async throws -> Success {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Success, any Error>, Never>) in
            let completed = lock.withLock { () -> Result<Success, any Error>? in
                if let existing = self.result { return existing }
                waiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
        return try result.get()
    }

    @discardableResult
    func finish(_ result: Result<Success, any Error>) -> Bool {
        let waiters = lock.withLock {
            () -> [CheckedContinuation<Result<Success, any Error>, Never>]? in
            guard self.result == nil else { return nil }
            self.result = result
            let current = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            return current
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: result) }
        return true
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
