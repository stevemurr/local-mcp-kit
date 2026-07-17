import Foundation
import LocalMCPContracts
import LocalMCPProducer

public actor ManualLocalMCPClock: LocalMCPClock {
    private var value: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        value = now
    }

    public func now() async -> Date { value }

    public func set(_ date: Date) {
        value = date
    }

    public func advance(by interval: TimeInterval) {
        value = value.addingTimeInterval(interval)
    }
}

public struct ImmediateLocalMCPSleeper: LocalMCPSleeping {
    public init() {}
    public func sleep(for interval: TimeInterval) async throws {}
}

/// Deterministic random bytes. Queued values are consumed first; subsequent
/// calls return a repeated, incrementing byte of the requested length.
public actor SequenceRandomBytesGenerator: RandomBytesGenerating {
    private var queued: [[UInt8]]
    private var fallback: UInt8

    public init(_ queued: [[UInt8]] = [], fallback: UInt8 = 1) {
        self.queued = queued
        self.fallback = fallback
    }

    public func randomBytes(count: Int) async throws -> [UInt8] {
        if !queued.isEmpty {
            let bytes = queued.removeFirst()
            guard bytes.count == count else { throw LocalMCPError.invalidConfiguration }
            return bytes
        }
        let result = [UInt8](repeating: fallback, count: count)
        fallback &+= 1
        return result
    }

    public func enqueue(_ bytes: [UInt8]) {
        queued.append(bytes)
    }
}

public struct ClosurePairingApprover: PairingApproving {
    private let handler: @Sendable (PairingChallenge) async throws -> PairingDecision

    public init(
        _ handler: @escaping @Sendable (PairingChallenge) async throws -> PairingDecision
    ) {
        self.handler = handler
    }

    public func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        try await handler(challenge)
    }
}

public actor RecordingPairingApprover: PairingApproving {
    private var decision: PairingDecision
    private var recorded: [PairingChallenge] = []

    public init(decision: PairingDecision = .approve) {
        self.decision = decision
    }

    public func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        recorded.append(challenge)
        return decision
    }

    public func setDecision(_ decision: PairingDecision) {
        self.decision = decision
    }

    public func challenges() -> [PairingChallenge] { recorded }
}
