import Foundation

/// Bounds GPU work admitted to the engine. The engine already serializes, but its
/// internal task-chain is unbounded — burst traffic would pile up Tasks and decoded
/// buffers. This caps in-flight + waiting work; overflow throws `Busy` (HTTP 503).
public actor RequestGate {
    public struct Busy: Error { public init() {} }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 1, maxQueued: Int = 3) {
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
    }

    /// Acquire a slot (or enqueue up to `maxQueued`); throws `Busy` if full.
    /// On resume from `release()`, the slot is handed over directly — do NOT
    /// increment `running` again (the releaser kept the count balanced).
    private func acquire() async throws {
        if running < maxConcurrent {
            running += 1
            return
        }
        guard waiting.count < maxQueued else { throw Busy() }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()            // hands our slot to the next waiter (running unchanged)
        } else {
            running -= 1
        }
    }

    /// Run `body` under the gate. Caller gets `Busy` if the queue is full.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }
}
