import Foundation
import LocalMCPContracts
import LocalMCPTwoProducerExampleSupport

@MainActor
final class TwoProducerDemoViewModel: ObservableObject {
    @Published private(set) var snapshot: TwoProducerDemoSnapshot = .empty
    @Published private(set) var busyProducers: Set<DemoProducerKind> = []
    @Published private(set) var isResetting = false
    @Published private(set) var errorMessage: String?
    @Published var greetingName = "Codex"
    @Published var leftOperand = "19"
    @Published var rightOperand = "23"

    private let demo: TwoProducerDemo
    private var wantsRunning = false
    private var lifecycleTask: Task<Void, Never>?

    init(demo: TwoProducerDemo = TwoProducerDemo()) {
        self.demo = demo
    }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        isResetting = true
        errorMessage = nil
        let predecessor = lifecycleTask
        lifecycleTask = Task { [self] in
            await predecessor?.value
            guard wantsRunning else { return }
            do {
                snapshot = try await demo.start()
            } catch {
                errorMessage = Self.message(for: error)
            }
            if wantsRunning {
                isResetting = false
            }
        }
    }

    func pair(with kind: DemoProducerKind) {
        guard wantsRunning, !isResetting, !busyProducers.contains(kind) else { return }
        busyProducers.insert(kind)
        errorMessage = nil
        Task { [self] in
            do {
                let result = try await demo.pair(with: kind)
                if wantsRunning {
                    snapshot = result
                }
            } catch {
                if wantsRunning {
                    errorMessage = Self.message(for: error)
                }
            }
            busyProducers.remove(kind)
        }
    }

    func sendGreeting() {
        run(.greeter) {
            try await self.demo.sendGreeting(to: self.greetingName)
        }
    }

    func calculate() {
        guard let left = Int(leftOperand), let right = Int(rightOperand) else {
            errorMessage = "Enter two valid signed integers."
            return
        }
        run(.calculator) {
            try await self.demo.add(left, right)
        }
    }

    func revoke(_ kind: DemoProducerKind) {
        run(kind) {
            try await self.demo.revoke(kind)
        }
    }

    func reset() {
        guard wantsRunning, !isResetting, busyProducers.isEmpty else { return }
        isResetting = true
        errorMessage = nil
        let predecessor = lifecycleTask
        lifecycleTask = Task { [self] in
            await predecessor?.value
            guard wantsRunning else { return }
            do {
                snapshot = try await demo.reset()
            } catch {
                errorMessage = Self.message(for: error)
            }
            if wantsRunning {
                isResetting = false
            }
        }
    }

    func stop() {
        guard wantsRunning || snapshot.isRunning else { return }
        wantsRunning = false
        isResetting = true
        let predecessor = lifecycleTask
        lifecycleTask = Task { [self] in
            await predecessor?.value
            guard !wantsRunning else { return }
            snapshot = await demo.stop()
            busyProducers.removeAll()
            if !wantsRunning {
                isResetting = false
            }
        }
    }

    func isBusy(_ kind: DemoProducerKind) -> Bool {
        busyProducers.contains(kind) || isResetting
    }

    private func run(
        _ kind: DemoProducerKind,
        operation: @escaping @MainActor () async throws -> TwoProducerDemoSnapshot
    ) {
        guard wantsRunning, !isResetting, !busyProducers.contains(kind) else { return }
        busyProducers.insert(kind)
        errorMessage = nil
        Task {
            do {
                let result = try await operation()
                if wantsRunning {
                    snapshot = result
                }
            } catch {
                if wantsRunning {
                    errorMessage = Self.message(for: error)
                }
            }
            busyProducers.remove(kind)
        }
    }

    private static func message(for error: any Error) -> String {
        if let localError = error as? LocalMCPError {
            return localError.description
        }
        return "The demo operation failed."
    }
}
