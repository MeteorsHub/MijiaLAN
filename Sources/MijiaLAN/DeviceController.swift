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
    /// Storage always carries the freshest timestamps. Observation is committed once per batch below.
    @ObservationIgnored private var snapshotStorage: [String: DeviceSnapshot] = [:]
    public private(set) var snapshots: [String: DeviceSnapshot] {
        get { access(keyPath: \.snapshots); return snapshotStorage }
        set { snapshotStorage = newValue }
    }
    public private(set) var structureRevision: UInt64 = 0
    public private(set) var valuesRevision: UInt64 = 0
    public private(set) var retryStates: [String: ProbeRetryState] = [:]
    @ObservationIgnored private let api: LANMiotAPI
    @ObservationIgnored private let config: @Sendable () -> LocalHomeConfig
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var context = PollingContext()
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var startedProbing = false
    @ObservationIgnored private var lastConfiguration: LocalHomeConfig?
    @ObservationIgnored private var configurationLanguage: AppLanguage?
    @ObservationIgnored private var structureDirty = false
    @ObservationIgnored private var publishedSnapshots: [String: DeviceSnapshot] = [:]
    @ObservationIgnored private var cachedHome = SynthesizedHome()
    @ObservationIgnored private var readTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private struct SchemaKey: Hashable {
        var model: String
        var specification: String?
        var language: AppLanguage
    }
    @ObservationIgnored private var schemaTemplates: [SchemaKey: DeviceSnapshot] = [:]
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

    deinit {
        pollTask?.cancel()
        healthTask?.cancel()
        for read in readTasks.values { read.task.cancel() }
    }

    public func reconcileConfiguration(force: Bool = false) {
        let next = config()
        let language = L10n.currentLanguage
        guard force || next != lastConfiguration || language != configurationLanguage else { return }
        let languageChanged = language != configurationLanguage
        lastConfiguration = next; configurationLanguage = language
        let devices = next.devices
        let known = Set(devices.map(\.did))
        for (did, read) in readTasks where !devices.contains(where: { device in
            snapshotStorage[did].map { ProbeScheduler.sameEndpoint($0.device, device) } == true
        }) {
            read.task.cancel(); readTasks[did] = nil
        }
        let schemaKeys = Set(devices.map { SchemaKey(model: $0.model, specification: $0.specType, language: language) })
        schemaTemplates = force ? [:] : schemaTemplates.filter { schemaKeys.contains($0.key) }
        snapshots = snapshots.filter { known.contains($0.key) }
        lastSlow = lastSlow.filter { known.contains($0.key) }
        for device in devices {
            if !force, !languageChanged, var existing = snapshots[device.did],
               existing.device.model == device.model, existing.device.specType == device.specType {
                if !ProbeScheduler.sameEndpoint(existing.device, device) {
                    existing.health = LANDeviceHealth(); existing.readings = [:]; existing.prepared = [:]
                }
                existing.device = device; snapshots[device.did] = existing
                continue
            }
            let key = SchemaKey(model: device.model, specification: device.specType, language: language)
            if var template = schemaTemplates[key] {
                template.device = device
                preserveReadings(in: &template)
                snapshots[device.did] = template
                continue
            }
            // Bundled schemas pin the reviewed version; newly imported models can use the full raw cache.
            let cached: DeviceSchema? = device.specType.flatMap { type in
                let url = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
                    .appendingPathComponent(type.replacingOccurrences(of: ":", with: "_") + ".json")
                return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DeviceSchema.self, from: $0) }
            }
            // The restriction is independent of whether a specification was imported/cached.
            let restrictedPlaceholder: DeviceSchema? = DeviceLANPolicy.allowsPropertyRequests(for: device.model) ? nil
                : DeviceSchema(model: device.model, type: device.specType ?? "motor-controller", description: nil, services: [])
            guard let schema = DeviceSchema.bundled(model: device.model) ?? cached ?? restrictedPlaceholder else {
                snapshots[device.did] = nil
                continue
            }
            var template = DeviceSnapshot(device: device, schema: schema,
                capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: device.model))
            template.device = LocalDevice(did: "", name: "", model: device.model, host: "", token: "", specType: device.specType)
            schemaTemplates[key] = template
            template.device = device
            preserveReadings(in: &template)
            snapshots[device.did] = template
        }
        structureDirty = true
        publish()
    }

    private func preserveReadings(in next: inout DeviceSnapshot) {
        guard let old = snapshotStorage[next.id], ProbeScheduler.sameEndpoint(old.device, next.device),
              old.schema.type == next.schema.type else { return }
        next.readings = old.readings.filter { next.capabilitiesByID[$0.key] != nil }
        next.prepared = old.prepared.filter { next.capabilitiesByID[$0.key] != nil }
        next.health = old.health; next.lastCommand = old.lastCommand; next.commandReceipt = old.commandReceipt
    }

    public func events() -> AsyncStream<HomeProviderEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuations[id] = continuation
            continuation.yield(.statusChanged(.connected))
            continuation.yield(.snapshotUpdated(synthesizedHome()))
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
            if pollTask == nil {
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refreshNow()
                        guard let seconds = self.map({ $0.context.panelVisible ? 3 : 5 }) else { return }
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                }
            }
        }
    }
    public func setPollingContext(_ context: PollingContext) {
        let becomingVisible = context.panelVisible && !self.context.panelVisible
        self.context = context
        if becomingVisible { withMutation(keyPath: \.snapshots) {} }
    }
    public func shutdown() {
        pollTask?.cancel(); pollTask = nil
        healthTask?.cancel(); healthTask = nil
        for read in readTasks.values { read.task.cancel() }; readTasks = [:]
        for c in continuations.values { c.finish() }; continuations = [:]
        Task { await api.shutdown() }
    }

    public func retry(did: String) async {
        guard snapshots[did] != nil else { return }
        observeHealthIfNeeded()
        await api.retryDevice(did: did)
        let health = await api.currentHealth()
        retryStates = await api.retryStates()
        snapshots[did]?.health = health[did] ?? LANDeviceHealth()
        if let snapshot = snapshots[did], snapshot.isOnline, DeviceLANPolicy.allowsPropertyRequests(for: snapshot.device.model) {
            await refresh(did: did, capabilities: snapshot.capabilities.filter(\.readable), joinExisting: true)
            lastSlow[did] = Date()
        }
        publish()
    }

    public func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; publish() }
        reconcileConfiguration()
        observeHealthIfNeeded()
        await api.startProbing()
        if !startedProbing {
            startedProbing = true
            // Online responses are consumed independently by observeHealthIfNeeded while startup finishes.
            _ = try? await api.deviceList()
        }
        let health = await api.currentHealth()
        for did in Array(snapshots.keys) { snapshots[did]?.health = health[did] ?? LANDeviceHealth() }
        await withTaskGroup(of: Void.self) { group in
            for (did, snapshot) in snapshots where snapshot.isOnline && DeviceLANPolicy.allowsPropertyRequests(for: snapshot.device.model) {
                let slow = Date().timeIntervalSince(lastSlow[did] ?? .distantPast) >= 60
                if slow { lastSlow[did] = Date() }
                let caps = snapshot.capabilities.filter { $0.readable && (slow || !$0.lowFrequency) }
                group.addTask { await self.refresh(did: did, capabilities: caps, joinExisting: true) }
            }
        }
    }

    private func observeHealthIfNeeded() {
        guard healthTask == nil else { return }
        let api = api
        healthTask = Task { [weak self] in
            for await update in await api.healthEvents() {
                guard !Task.isCancelled, let self else { return }
                var recovered: [String] = []
                for did in self.snapshotStorage.keys {
                    if update.health[did]?.state == .online && self.snapshotStorage[did]?.isOnline != true { recovered.append(did) }
                    self.snapshotStorage[did]?.health = update.health[did] ?? LANDeviceHealth()
                }
                if self.retryStates != update.retries { self.retryStates = update.retries }
                if !self.refreshing || !recovered.isEmpty { self.publish() }
                // Never hold the health stream up behind a slow device's property request.
                for did in recovered {
                    Task { [weak self] in
                        guard let self, let snapshot = self.snapshotStorage[did], DeviceLANPolicy.allowsPropertyRequests(for: snapshot.device.model) else { return }
                        await self.refresh(did: did, capabilities: snapshot.capabilities.filter(\.readable), joinExisting: true)
                        self.lastSlow[did] = Date()
                        self.publish()
                    }
                }
            }
        }
    }

    private func refresh(did: String, capabilities: [DeviceCapability], joinExisting: Bool = false) async {
        if let prior = readTasks[did] {
            await prior.task.value
            if joinExisting { return }
        }
        guard !Task.isCancelled, let device = snapshotStorage[did]?.device, DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { return }
        let id = UUID()
        let task = Task { await self.readAndCommit(did: did, device: device, capabilities: capabilities) }
        readTasks[did] = (id, task)
        await task.value
        if readTasks[did]?.id == id { readTasks[did] = nil }
    }

    private func readAndCommit(did: String, device: LocalDevice, capabilities: [DeviceCapability]) async {
        guard !capabilities.isEmpty else { return }
        let readings = await api.readCapabilities(did: did, capabilities: capabilities)
        let health = await api.currentHealth()
        guard !Task.isCancelled, var snapshot = snapshots[did], ProbeScheduler.sameEndpoint(snapshot.device, device) else { return }
        for (key, var reading) in readings {
            if let cap = snapshot.capabilitiesByID[key] { reading = cap.checkedReading(reading) }
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
        if let reason = snapshot.lanReadingsRestriction { throw DeviceControlError.unsupported(reason) }
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
        guard let cap = snapshot.capabilitiesByID[id],
              ![.unsupported, .reading].contains(cap.control) else { throw DeviceControlError.unsupported(id) }
        if snapshot.isOnline, let reason = snapshot.controlUnavailableReason(cap) { throw DeviceControlError.unavailable(reason) }
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
        cachedHome
    }

    private func buildHome() -> SynthesizedHome {
        let devices = config().devices
        let records = devices.map { MiDeviceRecord(did: $0.did, name: $0.name, model: $0.model, isOnline: snapshots[$0.did]?.isOnline == true, specType: $0.specType) }
        let rooms = Dictionary(grouping: devices, by: { $0.roomName ?? "" }).map { MiRoom(id: $0.key, name: $0.key, dids: $0.value.map(\.did)) }
        var specs: [String: MiotDeviceSpec] = [:]
        var values: [MiotPropKey: JSONValue] = [:]
        for s in snapshots.values {
            specs[s.device.model] = s.coreSpec
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
        let valuesChanged = snapshotStorage.count != publishedSnapshots.count || snapshotStorage.contains {
            !$0.value.hasSameValues(as: publishedSnapshots[$0.key])
        }
        let uiChanged = snapshotStorage.contains {
            $0.value.lastCommand != publishedSnapshots[$0.key]?.lastCommand ||
            $0.value.commandReceipt != publishedSnapshots[$0.key]?.commandReceipt
        }
        let structureChanged = structureDirty
        structureDirty = false
        if structureChanged || valuesChanged {
            // Build before publishing revisions, so HomeKit observes one coherent source of legacy and raw values.
            cachedHome = buildHome()
            for c in continuations.values { c.yield(.snapshotUpdated(cachedHome)) }
            if structureChanged { structureRevision &+= 1 }
            valuesRevision &+= 1
        }
        if structureChanged || valuesChanged || uiChanged || context.panelVisible {
            withMutation(keyPath: \.snapshots) {}
        }
        publishedSnapshots = snapshotStorage
    }
}

public struct CapabilityHomeProvider: HomeProvider {
    public let controller: DeviceController
    public init(controller: DeviceController) { self.controller = controller }
    public func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
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
