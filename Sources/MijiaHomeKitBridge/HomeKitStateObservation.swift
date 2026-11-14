import Observation

/// One-shot Observation registrations for the bridge's MainActor-owned store and device controller.
/// Coalesce mutations until the setter has completed, then re-arm before notifying the bridge.
@MainActor
final class HomeKitStateObservation {
    private var generation = 0
    private var read: (@MainActor () -> Void)?
    private var changed: (@MainActor () -> Void)?
    private var pending: Task<Void, Never>?

    func start(read: @escaping @MainActor () -> Void, changed: @escaping @MainActor () -> Void) {
        stop()
        self.read = read
        self.changed = changed
        arm(generation: generation)
    }

    func stop() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        read = nil
        changed = nil
    }

    func waitUntilIdle() async {
        while let task = pending { await task.value }
    }

    private func arm(generation: Int) {
        guard self.generation == generation, let read else { return }
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Both tracked production models are @MainActor. Observation calls onChange synchronously
            // from their setters, so pending work can be registered before the setter returns.
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.pending = Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.pending = nil
                    self.arm(generation: generation)
                    self.changed?()
                }
            }
        }
    }
}
