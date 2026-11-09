import Foundation

/// One refresh at a time. Only the timer is interrupted by settings/visibility changes, never a LAN round.
@MainActor
final class DevicePollingLoop {
    struct Clock: Sendable {
        var now: @Sendable () -> Duration
        var sleep: @Sendable (Duration) async throws -> Void
        init() {
            let origin = ContinuousClock.now
            now = { origin.duration(to: .now) }
            sleep = { try await Task.sleep(for: $0) }
        }
        init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
            self.now = now; self.sleep = sleep
        }
    }

    private let clock: Clock
    private var interval: Duration
    private var lastStart: Duration?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Error>?
    private var generation = UUID()

    init(interval: Duration, clock: Clock = Clock()) { self.interval = interval; self.clock = clock }
    deinit { task?.cancel(); timer?.cancel() }

    func setInterval(_ interval: Duration) {
        guard self.interval != interval else { return }
        self.interval = interval
        timer?.cancel()
    }

    func start(refresh: @escaping @MainActor @Sendable () async -> Void) {
        guard task == nil else { return }
        let id = UUID(); generation = id; lastStart = nil
        task = Task { [weak self] in
            while !Task.isCancelled, self?.generation == id {
                guard let delay = self?.remaining() else { return }
                if delay > .zero {
                    guard let timer = self?.wait(for: delay) else { return }
                    try? await timer.value
                    if self?.generation == id { self?.timer = nil }
                    // Recalculate from the last start, also after an interrupted timer.
                    continue
                }
                self?.lastStart = self?.clock.now()
                await refresh()
                // A slow round drops missed deadlines. The next start becomes the new anchor.
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); timer?.cancel()
        task = nil; timer = nil; lastStart = nil
    }

    private func remaining() -> Duration {
        guard let lastStart else { return .zero }
        return max(.zero, interval - (clock.now() - lastStart))
    }

    private func wait(for delay: Duration) -> Task<Void, Error> {
        let clock = clock
        let timer = Task { try await clock.sleep(delay) }
        self.timer = timer
        return timer
    }
}
