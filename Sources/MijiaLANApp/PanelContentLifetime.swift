import Foundation

/// The exit animation finishes before this one-shot idle deadline starts.
/// Reopening cancels eviction; generations also reject late canceled sleepers.
@MainActor
final class PanelContentLifetime {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    private let idleDelay: Duration
    private let sleep: Sleep
    private var pendingRelease: Task<Void, Never>?
    private var generation = 0
    private(set) var isLoaded = false
    var load: (() -> Void)?
    var unload: (() -> Void)?

    init(idleDelay: Duration = .seconds(30), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.idleDelay = idleDelay
        self.sleep = sleep
    }

    @discardableResult func prepare() -> Bool {
        cancelPendingRelease()
        guard !isLoaded else { return false }
        load?()
        isLoaded = true
        return true
    }

    func didHide() {
        cancelPendingRelease()
        guard isLoaded else { return }
        let request = generation
        let delay = idleDelay, sleep = sleep
        pendingRelease = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, generation == request, !Task.isCancelled else { return }
            pendingRelease = nil
            isLoaded = false
            unload?()
        }
    }

    func stop() {
        cancelPendingRelease()
        guard isLoaded else { return }
        isLoaded = false
        unload?()
    }

    private func cancelPendingRelease() {
        generation += 1
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    deinit { pendingRelease?.cancel() }
}
