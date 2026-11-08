import Foundation
import Observation
import MijiaCore
import MijiaLAN

/// Saved preference only. No startup request, background loop, or automatic reconnect.
@Observable @MainActor
final class CurtainControlController {
    private let api: LANMiotAPI
    let events: CurtainEventLog
    @ObservationIgnored private let makeSession: @Sendable (String) async throws -> CurtainControlSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var devices: [String: LocalDevice] = [:]
    @ObservationIgnored private var sessions: [String: CurtainControlSession] = [:]
    @ObservationIgnored private var sessionIDs: [String: UUID] = [:]
    @ObservationIgnored private var observers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ends: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var actions: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var prepare: @MainActor () async throws -> Void = {}
    private(set) var enabledIDs: Set<String>
    private(set) var states: [String: CurtainControlSession.State] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var working: Set<String> = []
    private(set) var stopping: Set<String> = []
    static let preferenceKey = "curtain.daily.enabled"

    init(api: LANMiotAPI, defaults: UserDefaults, makeSession: (@Sendable (String) async throws -> CurtainControlSession)? = nil) {
        self.api = api; self.defaults = defaults; events = api.curtainEvents
        self.makeSession = makeSession ?? { try await api.beginCurtainControl(did: $0) }
        enabledIDs = Set(defaults.stringArray(forKey: Self.preferenceKey) ?? [])
    }
    func includes(_ did: String) -> Bool { enabledIDs.contains(did) }
    func isWorking(_ did: String) -> Bool { working.contains(did) }
    func setEnabled(_ device: LocalDevice, _ value: Bool) {
        if value { enabledIDs.insert(device.did) } else { enabledIDs.remove(device.did) }
        defaults.set(enabledIDs.sorted(), forKey: Self.preferenceKey)
        devices[device.did] = device
        events.record(device.did, source: .preference, stage: .idle, outcome: .noPacket, reason: .manualOnly)
        if !value { end(device.did) }
    }
    func reconcile(_ configured: [LocalDevice]) {
        let next = Dictionary(uniqueKeysWithValues: configured.map { ($0.did, $0) })
        guard next != devices else { return }
        for did in Array(sessionIDs.keys) where next[did] != devices[did] || !enabledIDs.contains(did) { end(did) }
        events.register(configured.filter { $0.model == CurtainValidationSession.model }.map(\.did))
        for device in configured where enabledIDs.contains(device.did) && device.model == CurtainValidationSession.model {
            events.record(device.did, source: .startup, stage: .idle, outcome: .noPacket, reason: .manualOnly)
            events.record(device.did, source: .idleBackground, stage: .idle, outcome: .noPacket, reason: .manualOnly)
        }
        devices = next
    }
    private func session(_ did: String) async throws -> CurtainControlSession {
        try Task.checkCancellation()
        if let existing = sessions[did] { return existing }
        await ends[did]?.value
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        let created = try await makeSession(did)
        guard includes(did), !Task.isCancelled else { await api.endCurtainControl(did: did); throw CancellationError() }
        let id = UUID()
        sessionIDs[did] = id; sessions[did] = created
        let updates = await created.updates()
        observers[did] = Task { [weak self] in
            for await state in updates {
                guard let self, self.sessionIDs[did] == id else { return }
                self.states[did] = state
            }
        }
        return created
    }
    private func end(_ did: String) {
        let action = actions.removeValue(forKey: did)?.task
        action?.cancel()
        observers.removeValue(forKey: did)?.cancel()
        sessionIDs[did] = nil; sessions[did] = nil
        states[did] = nil; errors[did] = nil; working.remove(did); stopping.remove(did)
        let previous = ends[did]
        ends[did] = Task {
            await previous?.value
            await api.endCurtainControl(did: did)
            await action?.value
        }
    }
    // Explicit retry UI is a single read, not a separate connection recovery loop.
    func reconnect(_ device: LocalDevice) { read(device.did) }
    func send(_ did: String, _ command: CurtainControlSession.Command) { request(did, command) }
    func read(_ did: String) { request(did, nil) }
    private func request(_ did: String, _ command: CurtainControlSession.Command?) {
        guard includes(did), devices[did] != nil else { return }
        if command == .stop {
            guard !stopping.contains(did), !isWorking(did) || states[did]?.canStop == true else { return }
            stopping.insert(did)
        } else { guard !isWorking(did) else { return } }
        let id = UUID()
        working.insert(did); errors[did] = nil
        let source: CurtainEventLog.Source
        switch command { case .position: source = .manualPosition; case .open: source = .manualOpen; case .close: source = .manualClose; case .stop: source = .manualStop; case nil: source = .manualRead }
        events.record(did, operation: id, source: source, stage: .requested, outcome: .queued, target: command?.target)
        let task = Task {
            defer {
                if actions[did]?.id == id { actions[did] = nil; working.remove(did); stopping.remove(did) }
            }
            do {
                let session = try await session(did)
                _ = try await session.manual(command, operationID: id)
                if actions[did]?.id == id { states[did] = await session.snapshot() }
            } catch {
                if actions[did]?.id == id, !Task.isCancelled {
                    if let session = sessions[did] { states[did] = await session.snapshot() }
                    events.record(did, operation: id, source: source, stage: states[did]?.stage ?? .requested, outcome: .paused,
                                  reason: CurtainEventLog.reason(error), code: CurtainEventLog.code(error))
                    errors[did] = states[did]?.message ?? L10n.tr("本次请求未完成；已停止，不会自动重试。", "Request did not complete; stopped without automatic retry.")
                }
            }
        }
        actions[did] = (id, task)
    }
    func summary(_ did: String) -> String? {
        guard includes(did) else { return nil }
        if isWorking(did) { return L10n.tr("本次手动请求进行中", "Manual Request Running") }
        if states[did]?.failureReason != nil || errors[did] != nil { return L10n.tr("请求已停止 · 读数未确认", "Request Stopped · Readings Unconfirmed") }
        guard let state = states[did], let position = state.position else { return L10n.tr("等待手动读取", "Awaiting Manual Read") }
        return L10n.tr("上次 \(position)%", "Last read \(position)%")
    }
    func shutdown() {
        for did in Set(sessionIDs.keys).union(actions.keys) {
            if let action = actions[did] { events.record(did, operation: action.id, source: .lifecycle, stage: .finished, outcome: .cancelled, reason: .cancelled) }
            end(did)
        }
        events.record("application", source: .lifecycle, stage: .finished, outcome: .noPacket, reason: .manualOnly)
        events.flush()
    }
}
