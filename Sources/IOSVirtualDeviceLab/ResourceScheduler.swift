import Foundation

actor LabResourceGate {
    struct State: Equatable, Sendable {
        let runningCount: Int
        let reservedMemoryMB: Int
        let waitingCount: Int
    }
    private struct Waiter {
        let memoryMB: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let policy: LabResourcePolicy
    private var runningCount = 0
    private var reservedMemoryMB = 0
    private var waiters: [Waiter] = []

    init(policy: LabResourcePolicy) {
        self.policy = policy
    }

    func acquire(memoryMB requestedMemoryMB: Int) async {
        let memoryMB = min(max(1, requestedMemoryMB), max(1, policy.maximumAggregateMemoryMB))
        if canStart(memoryMB: memoryMB) {
            runningCount += 1
            reservedMemoryMB += memoryMB
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(memoryMB: memoryMB, continuation: continuation))
        }
    }

    func release(memoryMB requestedMemoryMB: Int) {
        let memoryMB = min(max(1, requestedMemoryMB), max(1, policy.maximumAggregateMemoryMB))
        runningCount = max(0, runningCount - 1)
        reservedMemoryMB = max(0, reservedMemoryMB - memoryMB)
        drainWaiters()
    }

    func state() -> State {
        State(
            runningCount: runningCount,
            reservedMemoryMB: reservedMemoryMB,
            waitingCount: waiters.count
        )
    }

    private func canStart(memoryMB: Int) -> Bool {
        runningCount < max(1, policy.maximumConcurrentVMs)
            && reservedMemoryMB + memoryMB <= max(1, policy.maximumAggregateMemoryMB)
    }

    private func drainWaiters() {
        while let first = waiters.first, canStart(memoryMB: first.memoryMB) {
            waiters.removeFirst()
            runningCount += 1
            reservedMemoryMB += first.memoryMB
            first.continuation.resume()
        }
    }
}

enum HostResourceMonitor {
    static func waitForCPU(
        below maximumPercent: Double,
        timeout: TimeInterval = 60,
        cancellation: OperationCancellationFlag? = nil
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if cpuPercent() <= maximumPercent { return true }
            if cancellation?.isCancelled == true || Task.isCancelled { return false }
            try? await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        return false
    }

    static func cpuPercent() -> Double {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-A", "-o", "%cpu="],
            timeout: 10
        )
        guard result.succeeded else { return 0 }
        let aggregate = result.output
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
            .reduce(0, +)
        return aggregate / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }
}
