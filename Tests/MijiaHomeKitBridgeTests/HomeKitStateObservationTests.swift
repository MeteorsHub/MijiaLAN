import Observation
import Testing
@testable import MijiaHomeKitBridge

@MainActor
struct HomeKitStateObservationTests {
    @Observable @MainActor final class State {
        var devices = [1]
        var hidden: Set<Int> = []
        var initial = false
        var connected = false
        var revision = 0
    }

    @Test("The observer joins pending work without sleeps and reads completed mutations once")
    func coalescedChanges() async {
        let state = State(), observation = HomeKitStateObservation()
        var changes: [(devices: [Int], hidden: Set<Int>, initial: Bool, connected: Bool)] = []
        observation.start(read: {
            _ = state.devices; _ = state.hidden; _ = state.initial; _ = state.connected
        }, changed: {
            changes.append((state.devices, state.hidden, state.initial, state.connected))
        })
        #expect(changes.isEmpty)
        state.devices = [2, 3]
        state.hidden = [2]
        state.initial = true
        state.connected = true
        await observation.waitUntilIdle()
        #expect(changes.count == 1)
        #expect(changes.first?.devices == [2, 3] && changes.first?.hidden == [2])
        #expect(changes.first?.initial == true && changes.first?.connected == true)
        state.hidden = []
        await observation.waitUntilIdle()
        #expect(changes.count == 2 && changes.last?.hidden == [])
        state.connected = false
        await observation.waitUntilIdle()
        #expect(changes.count == 3 && changes.last?.connected == false)
        observation.stop()
    }

    @Test("Rebinding cancels queued old callbacks and invalidates registrations on the old source")
    func replacement() async {
        let old = State(), current = State(), observation = HomeKitStateObservation()
        var oldChanges = 0, revisions: [Int] = []
        observation.start(read: { _ = old.revision }, changed: { oldChanges += 1 })
        old.revision = 1 // Queued callback must not run after replacement.
        observation.start(read: { _ = current.revision }, changed: { revisions.append(current.revision) })
        old.revision = 2
        await observation.waitUntilIdle()
        #expect(oldChanges == 0 && revisions.isEmpty)
        current.revision = 3
        await observation.waitUntilIdle()
        #expect(oldChanges == 0 && revisions == [3])
        observation.stop()
    }

    @Test("Stopping rejects pending changes; restarting observes new changes without an initial notification")
    func stopAndRestart() async {
        let state = State(), observation = HomeKitStateObservation()
        var revisions: [Int] = []
        let read = { @MainActor in _ = state.revision }
        let changed = { @MainActor in revisions.append(state.revision) }
        observation.start(read: read, changed: changed)
        state.revision = 1
        observation.stop()
        state.revision = 2
        await observation.waitUntilIdle()
        #expect(revisions.isEmpty)
        observation.start(read: read, changed: changed)
        await observation.waitUntilIdle()
        #expect(revisions.isEmpty)
        state.revision = 3
        await observation.waitUntilIdle()
        #expect(revisions == [3])
        observation.stop()
    }

    @Test("Re-arming precedes delivery, so a change caused by the handler is also delivered")
    func mutationDuringDelivery() async {
        let state = State(), observation = HomeKitStateObservation()
        var revisions: [Int] = []
        observation.start(read: { _ = state.revision }, changed: {
            revisions.append(state.revision)
            if state.revision == 1 { state.revision = 2 }
        })
        state.revision = 1
        await observation.waitUntilIdle()
        #expect(revisions == [1, 2])
        observation.stop()
    }

    @Test("A source registration does not retain a released observer or deliver its queued callback")
    func releasedObserver() async {
        let state = State()
        var changes = 0
        var observation: HomeKitStateObservation? = HomeKitStateObservation()
        weak var released = observation
        observation?.start(read: { _ = state.revision }, changed: { changes += 1 })
        state.revision = 1
        observation = nil
        for _ in 0..<4 { await Task.yield() }
        #expect(released == nil && changes == 0)
        state.revision = 2
        #expect(changes == 0)
    }
}
