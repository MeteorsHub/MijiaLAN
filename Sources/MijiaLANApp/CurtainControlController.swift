import Foundation
import Observation
import MijiaCore
import MijiaLAN

/// Saved per-device opt-in, one background loop, and independently interruptible Stop actions.
@Observable @MainActor
final class CurtainControlController {
    private let api: LANMiotAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var devices: [String: LocalDevice] = [:]
    @ObservationIgnored private var sessions: [String: CurtainControlSession] = [:]
    @ObservationIgnored private var sessionIDs: [String: UUID] = [:]
    @ObservationIgnored private var observers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var starts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ends: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var actions: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var background: Task<Void, Never>?
    @ObservationIgnored var prepare: @MainActor () async throws -> Void = {}
    private(set) var enabledIDs: Set<String>
    private(set) var states: [String: CurtainControlSession.State] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var connecting: Set<String> = []
    private(set) var working: Set<String> = []
    private(set) var stopping: Set<String> = []
    private(set) var backgroundReading: Set<String> = []
    static let preferenceKey = "curtain.daily.enabled"

    init(api: LANMiotAPI, defaults: UserDefaults) {
        self.api = api; self.defaults = defaults
        enabledIDs = Set(defaults.stringArray(forKey: Self.preferenceKey) ?? [])
    }
    func includes(_ did: String) -> Bool { enabledIDs.contains(did) }
    func isWorking(_ did: String) -> Bool { connecting.contains(did) || working.contains(did) || backgroundReading.contains(did) }
    func setEnabled(_ device: LocalDevice, _ value: Bool) {
        if value { enabledIDs.insert(device.did) } else { enabledIDs.remove(device.did) }
        defaults.set(enabledIDs.sorted(), forKey: Self.preferenceKey)
        devices[device.did] = device
        if value { start(device) } else { end(device.did) }
    }
    func reconcile(_ configured: [LocalDevice]) {
        let next = Dictionary(uniqueKeysWithValues: configured.map { ($0.did, $0) })
        for did in Array(sessionIDs.keys) where next[did] != devices[did] || !enabledIDs.contains(did) { end(did) }
        devices = next
        for device in configured where enabledIDs.contains(device.did) && device.model == CurtainValidationSession.model && sessionIDs[device.did] == nil {
            start(device)
        }
        if background == nil {
            background = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }
                    await self.refreshEnabled()
                }
            }
        }
    }
    private func start(_ device: LocalDevice) {
        guard starts[device.did] == nil, sessions[device.did] == nil else { return }
        let did = device.did, id = UUID()
        sessionIDs[did] = id; connecting.insert(did); errors[did] = nil
        let previousEnd = ends[did]
        starts[did] = Task {
            defer { if sessionIDs[did] == id { starts[did] = nil; connecting.remove(did) } }
            do {
                await previousEnd?.value
                try Task.checkCancellation()
                try await prepare()
                try Task.checkCancellation()
                let session = try await api.beginCurtainControl(did: did)
                guard sessionIDs[did] == id, enabledIDs.contains(did), !Task.isCancelled else {
                    await api.endCurtainControl(did: did); return
                }
                sessions[did] = session
                let updates = await session.updates()
                observers[did] = Task { [weak self] in
                    for await state in updates {
                        guard let self, self.sessionIDs[did] == id else { return }
                        self.states[did] = state
                    }
                }
                _ = try await session.start()
            } catch {
                if sessionIDs[did] == id, !Task.isCancelled { errors[did] = error.localizedDescription }
            }
        }
    }
    private func end(_ did: String) {
        let start = starts.removeValue(forKey: did)
        start?.cancel()
        actions.removeValue(forKey: did)?.task.cancel()
        observers.removeValue(forKey: did)?.cancel()
        sessionIDs[did] = nil; sessions[did] = nil
        states[did] = nil; errors[did] = nil
        connecting.remove(did); working.remove(did); stopping.remove(did); backgroundReading.remove(did)
        let previous = ends[did]
        ends[did] = Task {
            await previous?.value
            await api.endCurtainControl(did: did)
            await start?.value
        }
    }
    func reconnect(_ device: LocalDevice) {
        guard !isWorking(device.did) else { return }
        end(device.did)
        if includes(device.did) { start(device) }
    }
    func send(_ did: String, _ command: CurtainControlSession.Command) {
        guard let session = sessions[did], includes(did) else { return }
        if command == .stop {
            guard !stopping.contains(did), states[did]?.canStop == true else { return }
            stopping.insert(did)
            starts[did]?.cancel() // A cancelled startup read must not overwrite the Stop result.
        } else if isWorking(did) { return }
        let id = UUID(), sessionID = sessionIDs[did]
        working.insert(did); errors[did] = nil
        // Stop deliberately replaces the UI operation token, so a cancelled move cannot overwrite its result.
        let task = Task {
            defer {
                if actions[did]?.id == id { actions[did] = nil; working.remove(did); stopping.remove(did) }
            }
            do { _ = try await session.perform(command) }
            catch {
                if actions[did]?.id == id, sessionIDs[did] == sessionID, !Task.isCancelled { errors[did] = error.localizedDescription }
            }
        }
        actions[did] = (id, task)
    }
    func read(_ did: String) {
        guard !isWorking(did), let session = sessions[did] else { return }
        let id = UUID(), sessionID = sessionIDs[did]
        working.insert(did); errors[did] = nil
        let task = Task {
            defer { if actions[did]?.id == id { actions[did] = nil; working.remove(did) } }
            do { _ = try await session.confirmByReading() }
            catch {
                if actions[did]?.id == id, sessionIDs[did] == sessionID, !Task.isCancelled { errors[did] = error.localizedDescription }
            }
        }
        actions[did] = (id, task)
    }
    private func refreshEnabled() async {
        // One loop for all enabled devices: no six independent timers or all-device refreshNow calls.
        for did in enabledIDs.sorted() {
            guard !Task.isCancelled else { return }
            guard !isWorking(did), let session = sessions[did],
                  let phase = states[did]?.phase, phase == .ready || phase == .moving else { continue }
            backgroundReading.insert(did)
            _ = try? await session.refresh()
            backgroundReading.remove(did)
        }
    }
    func summary(_ did: String) -> String? {
        guard includes(did) else { return nil }
        guard let state = states[did], let position = state.position else {
            return connecting.contains(did) ? L10n.tr("连接中", "Connecting") : L10n.tr("读数未确认", "Readings Unconfirmed")
        }
        let status = state.motorStatus == 1 ? L10n.tr("已停止", "Stopped") : L10n.tr("运动中", "Moving")
        return "\(position)% · \(status)"
    }
    func shutdown() {
        background?.cancel(); background = nil
        for did in Array(sessionIDs.keys) { end(did) }
        // Keep saved opt-ins. Runtime shutdown never sends motor commands.
    }
}
