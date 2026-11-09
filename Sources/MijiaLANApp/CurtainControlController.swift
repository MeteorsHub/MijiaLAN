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
    @ObservationIgnored private let defaults: UserDefaults
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
    private(set) var pausedPolling: [String: DeviceEventLog.Reason]
    static let pausedKey = "curtain.polling.paused"

    init(api: LANMiotAPI, defaults: UserDefaults, makeSession: (@Sendable (String) async throws -> CurtainControlSession)? = nil) {
        self.api = api; self.defaults = defaults; events = api.curtainEvents
        self.makeSession = makeSession ?? { try await api.beginCurtainControl(did: $0) }
        // Legacy curtain.daily.enabled is deliberately ignored, including a saved empty/false choice.
        pausedPolling = (defaults.dictionary(forKey: Self.pausedKey) as? [String: String] ?? [:]).compactMapValues(DeviceEventLog.Reason.init(rawValue:))
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
        for device in configured where device.model == CurtainValidationSession.model {
            if let reason = pausedPolling[device.did] { events.record(device.did, source: .startup, stage: .idle, outcome: .noPacket, reason: reason) }
        }
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

    /// One shared round. Defer this device during editing; never cancel an already in-flight read.
    func pollConfigured() async {
        guard !shuttingDown else { return }
        for device in devices.values.sorted(by: { $0.did < $1.did }) where device.model == CurtainValidationSession.model {
            guard !Task.isCancelled, !shuttingDown else { return }
            let did = device.did
            guard pausedPolling[did] == nil, !isWorking(did), reads[did] == nil, editors[did]?.isEmpty != false else { continue }
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
                    if states[did] == nil { display.stage = .idle; display.message = nil }
                    display.phase = fresh.phase; display.position = fresh.position; display.motorStatus = fresh.motorStatus
                    display.sampledAt = fresh.sampledAt; display.lastKnownPosition = fresh.lastKnownPosition
                    display.lastKnownMotorStatus = fresh.lastKnownMotorStatus; display.lastKnownAt = fresh.lastKnownAt
                    display.canStop = fresh.canStop; display.failureReason = nil
                    states[did] = display
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
    private func savePauses() { defaults.set(pausedPolling.mapValues(\.rawValue), forKey: Self.pausedKey) }
    func pollingPauseDescription(_ did: String) -> String? {
        guard let reason = pausedPolling[did] else { return nil }
        return switch reason {
        case .timeout: L10n.tr("查询超时", "Query timed out")
        case .identity: L10n.tr("设备身份未通过校验", "Device identity failed validation")
        case .firmware: L10n.tr("型号或固件未通过验证", "Model or firmware not verified")
        case .untrustedReading: L10n.tr("不可信读数", "Untrusted readings")
        case .invalidReply: L10n.tr("应答缺值或校验失败", "Reply missing values or failed validation")
        case .propertyError: L10n.tr("设备属性返回错误", "Device property error")
        default: L10n.tr("此前查询或操作未确认", "Previous query or operation unconfirmed")
        }
    }
    private func source(_ command: CurtainControlSession.Command?) -> DeviceEventLog.Source {
        switch command { case .position: .manualPosition; case .open: .manualOpen; case .close: .manualClose; case .stop: .manualStop; case nil: .manualRead }
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
        if command != nil, command != .stop, let reason = pausedPolling[did] {
            return reject(did, command, reason: reason, message: L10n.tr("目标未接收：读取已暂停，请先手动读取并恢复。", "Target not accepted: reads are paused. Read manually to recover first."))
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
                if precedingRead != nil, command != nil, let reason = pausedPolling[did] {
                    submissions[did]?.phase = .failed
                    errors[did] = L10n.tr("已提交的请求未发送：前一读取失败，请手动读取并恢复。", "Submitted request was not sent: the preceding read failed. Read manually to recover.")
                    events.record(did, operation: id, source: source(command), stage: .waiting, outcome: .noPacket, reason: reason, target: command?.target, writeAttempted: false, writeSent: false)
                    return
                }
                submissions[did]?.phase = .running
                let session = try await session(did)
                var result = try await session.manual(command, operationID: id)
                guard actions[did]?.id == id else { return }
                result.stage = .finished; states[did] = result
                submissions[did]?.phase = .succeeded
                if command == nil, pausedPolling.removeValue(forKey: did) != nil { savePauses() }
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
        errors[did] = states[did]?.message ?? L10n.tr("请求失败；已暂停自动读取，不会重试。", "Request failed; auto reads paused without retry.")
        pausedPolling[did] = DeviceEventLog.reason(error); savePauses()
    }
    func summary(_ did: String) -> String? {
        guard devices[did]?.model == CurtainValidationSession.model else { return nil }
        if isWorking(did) { return submissions[did]?.phase == .waiting ? L10n.tr("已提交 · 等待当前读取", "Submitted · Waiting for Read") : L10n.tr("用户请求进行中", "User Request Running") }
        if pausedPolling[did] != nil { return L10n.tr("自动读取已暂停 · 请手动恢复", "Auto Reads Paused · Resume Manually") }
        guard let position = states[did]?.position else { return L10n.tr("等待统一轮询", "Awaiting Device Poll") }
        return L10n.tr("上次 \(position)%", "Last read \(position)%")
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
