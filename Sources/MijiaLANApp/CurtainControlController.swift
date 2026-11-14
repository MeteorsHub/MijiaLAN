import Foundation
import Observation
import MijiaCore
import MijiaLAN

/// Quiet polling and explicit controls share one verified session per device. Only user work is busy UI.
@Observable @MainActor
final class CurtainControlController {
    struct Submission: Equatable {
        enum Phase { case waiting, running, succeeded, failed }
        let id: UUID
        let command: CurtainControlSession.Command?
        var phase: Phase
    }
    private let api: LANMiotAPI
    let events: CurtainEventLog
    @ObservationIgnored private let makeSession: @Sendable (String) async throws -> CurtainControlSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var devices: [String: LocalDevice] = [:]
    @ObservationIgnored private var sessions: [String: CurtainControlSession] = [:]
    @ObservationIgnored private var sessionIDs: [String: UUID] = [:]
    @ObservationIgnored private var observers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ends: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var actions: [String: (id: UUID, command: CurtainControlSession.Command?, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var reads: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var editors: [String: Set<UUID>] = [:]
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored var prepare: @MainActor () async throws -> Void = {}
    private(set) var states: [String: CurtainControlSession.State] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var working: Set<String> = []
    private(set) var backgroundReading: Set<String> = []
    private(set) var stopping: Set<String> = []
    private(set) var submissions: [String: Submission] = [:]
    private(set) var readFailures: [String: DeviceEventLog.Reason] = [:]
    private(set) var retryStates: [String: ProbeRetryState] = [:]
    static let preferenceKey = "curtain.daily.enabled"
    static let pausedKey = "curtain.polling.paused"

    init(api: LANMiotAPI, defaults: UserDefaults, now: @escaping () -> Date = { Date() }, makeSession: (@Sendable (String) async throws -> CurtainControlSession)? = nil) {
        self.api = api; self.now = now; events = api.curtainEvents
        self.makeSession = makeSession ?? { try await api.beginCurtainControl(did: $0) }
        // Retire product-only gates. These keys contain no configuration, credentials or pairing data.
        // An old false/empty opt-in or persisted failure must not disable normal operation after upgrade.
        defaults.removeObject(forKey: Self.preferenceKey)
        defaults.removeObject(forKey: Self.pausedKey)
    }
    func isWorking(_ did: String) -> Bool { working.contains(did) }
    func setEditing(_ did: String, editor: UUID, active: Bool) {
        if active { editors[did, default: []].insert(editor) }
        else { editors[did]?.remove(editor); if editors[did]?.isEmpty == true { editors[did] = nil } }
    }
    func reconcile(_ configured: [LocalDevice]) {
        let next = Dictionary(uniqueKeysWithValues: configured.map { ($0.did, $0) })
        guard next != devices else { return }
        for did in Set(sessionIDs.keys).union(actions.keys).union(reads.keys) where next[did] != devices[did] { end(did) }
        events.register(configured.filter { $0.model == CurtainValidationSession.model }.map(\.did))
        devices = next
    }
    private func session(_ did: String) async throws -> CurtainControlSession {
        try Task.checkCancellation()
        if let existing = sessions[did] { return existing }
        let device = devices[did]
        await ends[did]?.value
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        let created = try await makeSession(did)
        guard devices[did] == device, device?.model == CurtainValidationSession.model, !Task.isCancelled else {
            await api.endCurtainControl(did: did); throw CancellationError()
        }
        let id = UUID()
        sessionIDs[did] = id; sessions[did] = created
        let updates = await created.updates()
        observers[did] = Task { [weak self] in
            for await state in updates {
                guard let self, self.sessionIDs[did] == id else { return }
                // Check provenance, not timing: a late-delivered background stage must also stay quiet.
                if state.source != .backgroundPoll, let active = self.actions[did], state.operationID == active.id {
                    self.states[did] = state
                }
            }
        }
        return created
    }
    private func end(_ did: String) {
        let action = actions.removeValue(forKey: did)?.task, read = reads.removeValue(forKey: did)?.task
        action?.cancel(); read?.cancel()
        observers.removeValue(forKey: did)?.cancel()
        sessionIDs[did] = nil; sessions[did] = nil; editors[did] = nil
        states[did] = nil; errors[did] = nil; submissions[did] = nil
        readFailures[did] = nil; retryStates[did] = nil
        working.remove(did); stopping.remove(did); backgroundReading.remove(did)
        let previous = ends[did]
        ends[did] = Task {
            await previous?.value
            await api.endCurtainControl(did: did)
            await action?.value; await read?.value
        }
    }
    func reconnect(_ device: LocalDevice) { read(device.did) }
    @discardableResult func send(_ did: String, _ command: CurtainControlSession.Command) -> Bool { request(did, command) }
    @discardableResult func read(_ did: String) -> Bool { request(did, nil) }

    /// Capability adapter for bridges: expose this driver's cache, never a second property reader.
    var matterCoverings: [String: MatterDevicePlan.Covering] {
        Dictionary(uniqueKeysWithValues: devices.values.filter {
            $0.model == CurtainValidationSession.model && $0.specType == CurtainValidationSession.specification
        }.map { device in
            let state = states[device.did]
            let movement: Int? = switch state?.motorStatus {
            case 1: 0
            case 2, 3: 1
            case 0, 4: 2
            default: nil
            }
            let active = submissions[device.did].map { $0.phase == .waiting || $0.phase == .running } ?? false
            let ready = state?.phase == .ready || state?.phase == .moving || state?.phase == .stopping
            return (device.did, MatterDevicePlan.Covering(position: state?.position,
                target: active ? submissions[device.did]?.command?.target : state?.position, movement: movement,
                reachable: ready && state?.sampledAt != nil && state?.failureReason == nil && readFailures[device.did] == nil))
        })
    }

    /// Await the same operation used by the App. Stop still preempts movement through request()/session.stop().
    func execute(_ did: String, _ command: CurtainControlSession.Command) async throws -> CurtainControlSession.State {
        guard request(did, command), let accepted = actions[did] else { throw DeviceControlError.busy }
        await accepted.task.value
        try Task.checkCancellation()
        guard submissions[did]?.id == accepted.id, submissions[did]?.phase == .succeeded,
              let state = states[did], state.confirmed else { throw DeviceControlError.notConfirmed }
        return state
    }

    /// One shared round. Defer this device during editing; never cancel an already in-flight read.
    func pollConfigured() async {
        guard !shuttingDown else { return }
        for device in devices.values.sorted(by: { $0.did < $1.did }) where device.model == CurtainValidationSession.model {
            guard !Task.isCancelled, !shuttingDown else { return }
            let did = device.did
            guard (retryStates[did]?.nextRetryAt ?? .distantPast) <= now(), !isWorking(did), reads[did] == nil, editors[did]?.isEmpty != false else { continue }
            let id = UUID()
            backgroundReading.insert(did)
            let task = Task {
                defer { if reads[did]?.id == id { reads[did] = nil; backgroundReading.remove(did) } }
                do {
                    let session = try await session(did)
                    let fresh = try await session.poll(operationID: id)
                    guard reads[did]?.id == id, !Task.isCancelled else { return }
                    var display = states[did] ?? fresh
                    // Publish valid values once, keeping presentation stage and the last user result stable.
                    if states[did] == nil || readFailures[did] != nil { display.stage = .idle; display.message = nil }
                    display.phase = fresh.phase; display.position = fresh.position; display.motorStatus = fresh.motorStatus
                    display.sampledAt = fresh.sampledAt; display.lastKnownPosition = fresh.lastKnownPosition
                    display.lastKnownMotorStatus = fresh.lastKnownMotorStatus; display.lastKnownAt = fresh.lastKnownAt
                    display.canStop = fresh.canStop; display.failureReason = nil
                    states[did] = display
                    clearFailure(did)
                } catch {
                    // Stop may cancel the session's old read. That is not a device failure or retry signal.
                    let failed = await sessions[did]?.snapshot()
                    guard reads[did]?.id == id, !Task.isCancelled, !(error is CancellationError) else { return }
                    if let failed { states[did] = failed }
                    fail(did, id: id, command: nil, source: .backgroundPoll, error: error)
                }
            }
            reads[did] = (id, task)
            await task.value
        }
    }
    private func clearFailure(_ did: String) {
        if readFailures.removeValue(forKey: did) != nil { errors[did] = nil }
        retryStates[did] = nil
    }
    private func source(_ command: CurtainControlSession.Command?) -> DeviceEventLog.Source {
        if let source = DeviceCommunicationContext.source, source == .matter || source == .homeKit { return source }
        return switch command { case .position: .manualPosition; case .open: .manualOpen; case .close: .manualClose; case .stop: .manualStop; case nil: .manualRead }
    }
    private func reject(_ did: String, _ command: CurtainControlSession.Command?, reason: DeviceEventLog.Reason, message: String) -> Bool {
        errors[did] = message
        events.record(did, source: source(command), stage: .requested, outcome: .noPacket, reason: reason, target: command?.target, writeAttempted: false, writeSent: false)
        return false
    }
    private func request(_ did: String, _ command: CurtainControlSession.Command?) -> Bool {
        guard !shuttingDown, devices[did]?.model == CurtainValidationSession.model else {
            return reject(did, command, reason: .configuration, message: L10n.tr("请求未接收：设备不再可用。", "Request not accepted: device is unavailable."))
        }
        if let target = command?.target, !(0...100).contains(target) {
            return reject(did, command, reason: .configuration, message: L10n.tr("请求未接收：目标位置必须为 0–100%。", "Request not accepted: target must be 0–100%."))
        }
        if let active = actions[did], active.command == command {
            events.record(did, operation: active.id, source: source(command), stage: .requested, outcome: .noPacket, reason: .deduplicated, target: command?.target)
            return true
        }
        if command == .stop {
            if (isWorking(did) || reads[did] != nil), states[did]?.canStop != true {
                return reject(did, command, reason: .busy, message: L10n.tr("停止未接收：当前请求尚未完成身份验证。", "Stop not accepted: the current request has not verified identity yet."))
            }
            actions[did]?.task.cancel()
            stopping.insert(did)
        } else if isWorking(did) {
            return reject(did, command, reason: .busy, message: L10n.tr("请求未接收：已有用户操作进行中，请等待结果；停止仍可用。", "Request not accepted: another user operation is active. Wait for its result; Stop remains available."))
        }
        let id = UUID(), precedingRead = command == .stop ? nil : reads[did]?.task
        working.insert(did); errors[did] = nil
        submissions[did] = Submission(id: id, command: command, phase: precedingRead == nil ? .running : .waiting)
        events.record(did, operation: id, source: source(command), stage: .requested, outcome: .queued, target: command?.target)
        let task = Task {
            defer { if actions[did]?.id == id { actions[did] = nil; working.remove(did); stopping.remove(did) } }
            do {
                await precedingRead?.value
                try Task.checkCancellation()
                guard actions[did]?.id == id else { return }
                if precedingRead != nil, command != nil, let reason = readFailures[did] {
                    submissions[did]?.phase = .failed
                    errors[did] = L10n.tr("已提交的请求未发送：前一读取失败。状态将自动重新检查，请确认错误后再操作。", "Submitted request was not sent: the preceding read failed. State checks resume automatically; review the error before trying again.")
                    events.record(did, operation: id, source: source(command), stage: .waiting, outcome: .noPacket, reason: reason, target: command?.target, writeAttempted: false, writeSent: false)
                    return
                }
                submissions[did]?.phase = .running
                let session = try await session(did)
                var result = try await session.manual(command, operationID: id)
                guard actions[did]?.id == id else { return }
                result.stage = .finished; states[did] = result
                submissions[did]?.phase = .succeeded
                clearFailure(did)
            } catch {
                let failed = await sessions[did]?.snapshot()
                guard actions[did]?.id == id, !Task.isCancelled else { return }
                if let failed { states[did] = failed }
                fail(did, id: id, command: command, source: source(command), error: error)
                submissions[did]?.phase = .failed
            }
        }
        actions[did] = (id, command, task)
        return true
    }
    private func fail(_ did: String, id: UUID, command: CurtainControlSession.Command?, source: DeviceEventLog.Source, error: any Error) {
        events.record(did, operation: id, source: source, stage: states[did]?.stage ?? .requested, outcome: .paused,
                      reason: DeviceEventLog.reason(error), code: DeviceEventLog.code(error), target: command?.target)
        errors[did] = states[did]?.message ?? L10n.tr("请求失败；写入不会重发，状态读取将在退避后重新检查。", "Request failed; writes are not retried. State checks resume after backoff.")
        readFailures[did] = DeviceEventLog.reason(error)
        let count = min(ProbeRetryPolicy.maximumFailures, (retryStates[did]?.consecutiveFailures ?? 0) + 1)
        retryStates[did] = ProbeRetryState(consecutiveFailures: count,
            nextRetryAt: now().addingTimeInterval(ProbeRetryPolicy().interval(afterFailures: count, jitter: 1)))
    }
    func summary(_ did: String) -> String? {
        guard devices[did]?.model == CurtainValidationSession.model else { return nil }
        if isWorking(did) { return submissions[did]?.phase == .waiting ? L10n.tr("已提交 · 等待当前读取", "Submitted · Waiting for Read") : L10n.tr("用户请求进行中", "User Request Running") }
        if readFailures[did] != nil { return L10n.tr("读取失败 · 将自动重试", "Read Failed · Will Retry Automatically") }
        guard let position = states[did]?.position else {
            return L10n.tr("等待刷新", "Awaiting Refresh")
        }
        return L10n.tr("上次 \(position)%", "Last read \(position)%")
    }
    func shutdownAndWait() async {
        shutdown()
        for ending in ends.values { await ending.value }
        events.flush()
    }
    func shutdown() {
        shuttingDown = true
        for did in Set(sessionIDs.keys).union(actions.keys).union(reads.keys) {
            if let action = actions[did] { events.record(did, operation: action.id, source: .lifecycle, stage: .finished, outcome: .cancelled, reason: .cancelled) }
            end(did)
        }
        events.record("application", source: .lifecycle, stage: .finished, outcome: .noPacket)
        events.flush()
    }
}
