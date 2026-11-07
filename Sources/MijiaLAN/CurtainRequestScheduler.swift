import Foundation

/// Shared by all daily curtain sessions in one API. Only one UDP exchange can be in flight.
/// Stop jumps ahead of queued ordinary requests; an already-sent packet must finish (2 s timeout).
actor CurtainRequestScheduler {
    enum Priority: Int, Sendable { case ordinary, stop }
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, any Error>
    }
    var queuedCount: Int { waiters.count }
    private var busy = false
    private var waiters: [Waiter] = []
    private var lastCompletion: Duration?
    private let clock: CurtainValidationSession.Clock
    init(clock: CurtainValidationSession.Clock = .init()) { self.clock = clock }

    func perform<T: Sendable>(priority: Priority, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { lastCompletion = clock.now(); release() }
        try Task.checkCancellation()
        if priority == .ordinary, let lastCompletion {
            let remaining = Duration.milliseconds(250) - (clock.now() - lastCompletion)
            if remaining > .zero { try await clock.sleep(remaining) }
        }
        try Task.checkCancellation()
        return try await body()
    }
    private func acquire(_ priority: Priority) async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard !waiters.isEmpty else { busy = false; return }
        let index = waiters.firstIndex { $0.priority == .stop } ?? 0
        waiters.remove(at: index).continuation.resume()
    }
}
