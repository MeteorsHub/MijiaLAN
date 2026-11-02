import Foundation
import MijiaCore
import Observation

public enum CapabilityCommand: Equatable, Sendable {
    case set(String, JSONValue)
    case invoke(String)
    case adjust(String, Double)
    case batch([CapabilityCommand])
    case setLightBrightness(Double)
    var coalescingID: String? {
        switch self {
        case .set(let id, _): id
        case .batch(let commands): commands.first?.coalescingID.map { "batch:" + $0 }
        case .setLightBrightness: "light:brightness"
        default: nil
        }
    }
    var hasAction: Bool {
        switch self { case .invoke: true; case .batch(let commands): commands.contains(where: \.hasAction); default: false }
    }
}

/// One owner for actual readings, pending cooking parameters and awaited commands from both interfaces.
@Observable @MainActor
public final class DeviceController {
    public private(set) var snapshots: [String: DeviceSnapshot] = [:]
    @ObservationIgnored private let api: LANMiotAPI
    @ObservationIgnored private let config: @Sendable () -> LocalHomeConfig
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var context = PollingContext()
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var lastSlow: [String: Date] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var queues: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var queueIDs: [String: UUID] = [:]
    @ObservationIgnored private var actionsPending: Set<String> = []
    @ObservationIgnored private var continuations: [UUID: AsyncStream<HomeProviderEvent>.Continuation] = [:]
    private struct Pending {
        var command: CapabilityCommand
        var replies: [CheckedContinuation<Void, Error>]
    }
    @ObservationIgnored private var coalesced: [String: Pending] = [:]

    public init(api: LANMiotAPI, config: @escaping @Sendable () -> LocalHomeConfig) {
        self.api = api; self.config = config
        reconcileConfiguration()
    }

    public func reconcileConfiguration() {
        let devices = config().devices
        snapshots = snapshots.filter { key, _ in devices.contains { $0.did == key } }
        for device in devices {
            if var existing = snapshots[device.did], existing.device.model == device.model {
                existing.device = device; snapshots[device.did] = existing
                continue
            }
            // Bundled schemas pin the reviewed version; newly imported models can use the full raw cache.
            let cached: DeviceSchema? = device.specType.flatMap { type in
                let url = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
                    .appendingPathComponent(type.replacingOccurrences(of: ":", with: "_") + ".json")
                return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DeviceSchema.self, from: $0) }
            }
            guard let schema = DeviceSchema.bundled(model: device.model) ?? cached else { continue }
            snapshots[device.did] = DeviceSnapshot(device: device, schema: schema,
                capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: device.model))
        }
    }

    public func events() -> AsyncStream<HomeProviderEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(synthesizedHome()))
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
            if pollTask == nil {
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refreshNow()
                        let seconds = self?.context.panelVisible == true ? 3 : 5
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                }
            }
        }
    }
    public func setPollingContext(_ context: PollingContext) { self.context = context }
    public func shutdown() { pollTask?.cancel(); pollTask = nil }

    public func retry(did: String) async {
        guard snapshots[did] != nil else { return }
        await api.retryDevice(did: did)
        let health = await api.currentHealth()
        snapshots[did]?.health = health[did] ?? LANDeviceHealth()
        if let snapshot = snapshots[did], snapshot.isOnline {
            await refresh(did: did, capabilities: snapshot.capabilities.filter(\.readable))
            lastSlow[did] = Date()
        }
        publish()
    }

    public func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; publish() }
        reconcileConfiguration()
        if Date().timeIntervalSince(lastProbe) >= 20 {
            lastProbe = Date()
            _ = try? await api.deviceList()
        }
        let health = await api.currentHealth()
        for did in Array(snapshots.keys) { snapshots[did]?.health = health[did] ?? LANDeviceHealth() }
        await withTaskGroup(of: Void.self) { group in
            for (did, snapshot) in snapshots where snapshot.isOnline {
                let slow = Date().timeIntervalSince(lastSlow[did] ?? .distantPast) >= 60
                if slow { lastSlow[did] = Date() }
                let caps = snapshot.capabilities.filter { $0.readable && (slow || !$0.lowFrequency) }
                group.addTask { await self.refresh(did: did, capabilities: caps) }
            }
        }
    }

    private func refresh(did: String, capabilities: [DeviceCapability]) async {
        let readings = await api.readCapabilities(did: did, capabilities: capabilities)
        let health = await api.currentHealth()
        guard var snapshot = snapshots[did] else { return }
        for (key, var reading) in readings {
            if let value = reading.value, reading.isAvailable,
               let cap = capabilities.first(where: { $0.id == key }), cap.format != "string",
               (try? cap.validated(value)) == nil {
                reading.error = L10n.tr("设备返回的数据类型或取值不符合规格", "The returned value or data type does not match the device specification.")
                reading.value = nil
            }
            // Keep the last confirmed value for diagnosis, but never return it as a fresh successful read.
            if reading.value == nil {
                reading.value = snapshot.readings[key]?.value
                reading.updatedAt = snapshot.readings[key]?.updatedAt
            }
            snapshot.readings[key] = reading
        }
        snapshot.health = health[did] ?? LANDeviceHealth()
        snapshots[did] = snapshot
    }

    public func execute(did: String, _ command: CapabilityCommand, coalesce: Bool = false) async throws {
        if coalesce, let id = command.coalescingID, !command.hasAction {
            let key = did + ":" + id
            return try await withCheckedThrowingContinuation { reply in
                if var pending = coalesced[key] {
                    pending.command = command; pending.replies.append(reply); coalesced[key] = pending
                } else {
                    coalesced[key] = Pending(command: command, replies: [reply])
                    Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        guard let pending = coalesced.removeValue(forKey: key) else { return }
                        do {
                            try await execute(did: did, pending.command)
                            for reply in pending.replies { reply.resume() }
                        } catch { for reply in pending.replies { reply.resume(throwing: error) } }
                    }
                }
            }
        }
        let isAction = command.hasAction
        if isAction, !actionsPending.insert(did).inserted { throw DeviceControlError.busy }
        defer { if isAction { actionsPending.remove(did) } }
        let prior = queues[did]
        let id = UUID()
        let task = Task { @MainActor in
            _ = await prior?.result
            try Task.checkCancellation()
            do {
                try await perform(did: did, command)
            } catch {
                snapshots[did]?.lastCommand = error.localizedDescription
                snapshots[did]?.commandReceipt?.error = error.localizedDescription
                publish()
                throw error
            }
        }
        queues[did] = task; queueIDs[did] = id
        defer { if queueIDs[did] == id { queues[did] = nil; queueIDs[did] = nil } }
        try await task.value
    }

    private func perform(did: String, _ command: CapabilityCommand) async throws {
        if case .batch(let commands) = command {
            for command in commands { try await perform(did: did, command) }
            return
        }
        guard let snapshot = snapshots[did] else { throw DeviceControlError.unavailable(did) }
        if case .setLightBrightness(let number) = command {
            guard snapshot.schema.category == "light", let brightness = snapshot.capability("light", "brightness"),
                  brightness.writable, brightness.control == .number else {
                throw DeviceControlError.unsupported(L10n.tr("亮度", "Brightness"))
            }
            let value = try brightness.validated(.number(number))
            guard snapshot.isOnline else { throw DeviceControlError.offline }
            // Evaluate power in the device queue, after any earlier command has finished.
            if let power = snapshot.primaryPower, snapshot.value(power.id)?.boolValue != true {
                try await perform(did: did, .set(power.id, .bool(true)))
            }
            if !Self.matches(snapshots[did]?.value(brightness.id), value) {
                try await perform(did: did, .set(brightness.id, value))
            }
            return
        }
        let id: String
        switch command {
        case .set(let key, _), .invoke(let key), .adjust(let key, _): id = key
        case .batch, .setLightBrightness: return
        }
        guard let cap = snapshot.capabilities.first(where: { $0.id == id }),
              ![.unsupported, .reading].contains(cap.control) else { throw DeviceControlError.unsupported(id) }
        switch command {
        case .batch, .setLightBrightness: return
        case .adjust(_, let delta):
            guard let value = snapshot.controlValue(cap)?.doubleValue else { throw DeviceControlError.unavailable(cap.title) }
            let next = min(cap.max ?? .infinity, max(cap.min ?? -.infinity, value + delta * cap.step))
            try await perform(did: did, .set(id, .number(next)))
        case .set(_, let raw):
            let value = try cap.validated(raw)
            if cap.prepared {
                snapshots[did]?.prepared[id] = value
                snapshots[did]?.lastCommand = "已选择下次参数，尚未启动"
                publish(); return
            }
            snapshots[did]?.commandReceipt = DeviceCommandReceipt(capabilityID: id)
            guard snapshot.isOnline else { throw DeviceControlError.offline }
            guard cap.writable else { throw DeviceControlError.unsupported(cap.title) }
            try await api.setProps([MiotPropWrite(did: did, siid: cap.siid, piid: cap.iid, value: value)])
            snapshots[did]?.commandReceipt?.acceptedAt = Date()
            snapshots[did]?.lastCommand = L10n.tr("设备已接受指令，正在确认状态", "Command accepted. Confirming device state.")
            if cap.readable {
                for attempt in 0..<3 {
                    if attempt > 0 { try await Task.sleep(for: .milliseconds(250)) }
                    await refresh(did: did, capabilities: [cap])
                    if Self.matches(snapshots[did]?.value(id), value) { break }
                }
                let confirmed = snapshots[did]?.value(id)
                snapshots[did]?.lastCommand = L10n.tr("状态已回读：\(cap.formatted(confirmed))", "State read back: \(cap.formatted(confirmed))")
                guard Self.matches(confirmed, value) else { throw DeviceControlError.notConfirmed }
                snapshots[did]?.commandReceipt?.confirmedAt = Date()
            } else {
                await refresh(did: did, capabilities: snapshot.capabilities.filter { $0.readable && !$0.lowFrequency })
                snapshots[did]?.lastCommand = L10n.tr("设备已接受动作；此接口没有完成状态回读", "Action accepted. This interface does not report completion.")
            }
        case .invoke:
            snapshots[did]?.commandReceipt = DeviceCommandReceipt(capabilityID: id)
            guard snapshot.isOnline else { throw DeviceControlError.offline }
            let inputs = try actionInputs(snapshot: snapshot, action: cap)
            if cap.name == "start-cook" {
                let params = snapshot.capabilities.filter { $0.prepared && $0.writable && snapshot.prepared[$0.id] != nil }.sorted {
                    let left = ["mode", "cook-mode"].contains($0.name) ? 0 : 1
                    let right = ["mode", "cook-mode"].contains($1.name) ? 0 : 1
                    return left == right ? $0.iid < $1.iid : left < right
                }
                for param in params {
                    let value = try param.validated(snapshot.prepared[param.id]!)
                    try await api.setProps([MiotPropWrite(did: did, siid: param.siid, piid: param.iid, value: value)])
                }
            }
            do {
                try await api.action(MiotActionCall(did: did, siid: cap.siid, aiid: cap.iid, inputs: inputs))
                snapshots[did]?.commandReceipt?.acceptedAt = Date()
            } catch {
                // Non-idempotent actions are never retried. Re-read before a person decides what to do next.
                await refresh(did: did, capabilities: snapshot.capabilities.filter(\.readable))
                throw error
            }
            snapshots[did]?.lastCommand = L10n.tr("设备已接受动作，正在确认状态", "Action accepted. Confirming device state.")
            var confirmed = false
            for attempt in 0..<3 {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(350)) }
                await refresh(did: did, capabilities: snapshot.capabilities.filter { $0.readable && !$0.lowFrequency })
                if let status = snapshot.capability(snapshot.schema.category, "status"),
                   let actual = snapshots[did]?.value(status.id)?.intValue,
                   Self.actionConfirmed(cap.name, category: snapshot.schema.category, status: actual) {
                    snapshots[did]?.lastCommand = L10n.tr("状态已确认：\(status.formatted(.number(Double(actual))))", "State confirmed: \(status.formatted(.number(Double(actual))))")
                    snapshots[did]?.commandReceipt?.confirmedAt = Date()
                    confirmed = true; break
                }
            }
            guard confirmed else { throw DeviceControlError.notConfirmed }
        }
        publish()
    }

    private static func matches(_ actual: JSONValue?, _ requested: JSONValue) -> Bool {
        if actual == requested { return true }
        if let a = actual?.doubleValue, let b = requested.doubleValue { return abs(a - b) < 0.00001 }
        return false
    }
    private static func actionConfirmed(_ action: String, category: String, status: Int) -> Bool {
        switch (category, action) {
        case ("air-fryer", "start-cook"), ("air-fryer", "resume-cook"): return [3, 4, 5, 10, 13, 14].contains(status)
        case ("air-fryer", "pause"): return [2, 8, 9, 11].contains(status)
        case ("air-fryer", "cancel-cooking"): return [0, 1, 6, 7, 12].contains(status)
        case ("juicer", "start-cook"): return [2, 4, 6].contains(status)
        case ("juicer", "cancel-cooking"): return [1, 5, 7].contains(status)
        case ("health-pot", "start-cook"): return [2, 3, 4, 6, 7, 8].contains(status)
        case ("health-pot", "cancel-cooking"): return [1, 5, 11].contains(status)
        case ("cooker", "start-cook"): return [2, 3, 4].contains(status)
        case ("cooker", "cancel-cooking"): return [1, 7].contains(status)
        default: return false
        }
    }

    public func actionInputs(snapshot: DeviceSnapshot, action: DeviceCapability) throws -> [JSONValue] {
        if action.name == "start-cook" {
            guard let menu = snapshot.capabilities.first(where: { $0.prepared && ["mode", "cook-mode"].contains($0.name) }),
                  snapshot.prepared[menu.id] != nil else { throw DeviceControlError.missingInput(L10n.tr("下次菜单", "Next Menu")) }
        }
        return try action.inputs.map { piid in
            let id = DeviceCapability.propertyID(action.siid, piid)
            guard let input = snapshot.capabilities.first(where: { $0.id == id }), let value = snapshot.prepared[id] else {
                throw DeviceControlError.missingInput(L10n.tr("动作参数 \(piid)", "action argument \(piid)"))
            }
            return try input.validated(value)
        }
    }

    /// Legacy HomeStore controls also use the same awaited executor, without a second poller or cache.
    public func executeCore(_ command: MijiaCore.DeviceCommand) async throws {
        for snapshot in snapshots.values {
            guard let spec = snapshot.schema.coreSpec, let mapped = try? MiotCommandMapper.map(command, spec: spec), mapped.did == snapshot.id else { continue }
            switch mapped {
            case .setProps(let writes):
                try await execute(did: snapshot.id, .batch(writes.map { .set(DeviceCapability.propertyID($0.siid, $0.piid), $0.value) }))
            case .action(let action): try await execute(did: action.did, .invoke(DeviceCapability.actionID(action.siid, action.aiid)))
            }
            return
        }
        if case .setClimateSwingMode(let entity, let mode) = command,
           let address = MiotAddress.parse(entity), let s = snapshots[address.did],
           let c = s.capabilities.first(where: { ["vertical-swing", "horizontal-swing"].contains($0.name) && $0.writable }) {
            return try await execute(did: address.did, .set(c.id, .bool(mode != "off")))
        }
        throw DeviceControlError.unsupported(L10n.tr("此控制尚未映射", "This control has not been mapped yet."))
    }

    public func synthesizedHome() -> SynthesizedHome {
        let devices = config().devices
        let records = devices.map { MiDeviceRecord(did: $0.did, name: $0.name, model: $0.model, isOnline: snapshots[$0.did]?.isOnline == true, specType: $0.specType) }
        let rooms = Dictionary(grouping: devices, by: { $0.roomName ?? "" }).map { MiRoom(id: $0.key, name: $0.key, dids: $0.value.map(\.did)) }
        var specs: [String: MiotDeviceSpec] = [:]
        var values: [MiotPropKey: JSONValue] = [:]
        for s in snapshots.values {
            specs[s.device.model] = s.schema.coreSpec
            for c in s.capabilities where c.kind == .property {
                if let value = s.value(c.id) { values[MiotPropKey(did: s.id, siid: c.siid, piid: c.iid)] = value }
            }
        }
        var home = MiotSynthesizer.synthesize(devices: records, rooms: rooms, specs: specs, values: values)
        for i in home.devices.indices {
            guard case .climate(var climate) = home.devices[i].kind, let s = snapshots[home.devices[i].id],
                  let swing = s.capabilities.first(where: { ["vertical-swing", "horizontal-swing"].contains($0.name) && $0.readable }) else { continue }
            climate.availableSwingModes = ["off", swing.name == "vertical-swing" ? "vertical" : "horizontal"]
            climate.swingMode = s.value(swing.id)?.boolValue == true ? climate.availableSwingModes[1] : "off"
            home.devices[i].kind = .climate(climate)
        }
        return home
    }
    private func publish() {
        let home = synthesizedHome()
        for c in continuations.values { c.yield(.snapshotUpdated(home)) }
    }
}

public struct CapabilityHomeProvider: HomeProvider {
    public let controller: DeviceController
    public init(controller: DeviceController) { self.controller = controller }
    public func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await event in await controller.events() { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func execute(_ command: MijiaCore.DeviceCommand) async throws { try await controller.executeCore(command) }
    public func refreshNow() async { await controller.refreshNow() }
    public func setPollingContext(_ context: PollingContext) async { await controller.setPollingContext(context) }
}
