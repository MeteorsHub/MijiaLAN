import Foundation
import Observation
import os
import HAPApple
import HAPCore
import HAPCrypto
import HAPTransport
import MijiaCore
import MijiaLAN

/// Publishes the store's devices to Apple Home as a HAP bridge, so an iPhone, Apple Watch, HomePod or Siri can
/// control them through this Mac. On unless the user turns it off; nothing touches the Keychain or the network until
/// the home has delivered its first device list.
///
/// Production writes use the shared DeviceController, await the device result and push confirmed state back to Home.
/// The HomeStore-only attachment is retained for compatibility and the original mapper regression tests.
///
/// Removing an accessory from the bridge makes Apple Home forget its room, scenes and automations. The bridge
/// therefore stays offline until the home has delivered its first device list, and only removes a device while the
/// backend is connected and the device is really gone (or hidden).
@Observable
@MainActor
public final class HomeKitBridgeController {
    public enum Status: Equatable, Sendable {
        case stopped
        /// Enabled, waiting for the backend's first device list.
        case waitingForDevices
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public private(set) var status: Status = .stopped
    public private(set) var setupCode: String?
    /// `X-HM://…`, the payload behind the pairing QR code.
    public private(set) var setupURI: String?
    public private(set) var isPaired = false
    public private(set) var exposedDeviceCount = 0

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                enqueue { await $0.startIfReady() }
            } else {
                enqueue { await $0.stopNow() }
            }
        }
    }

    /// Holds an idle-sleep assertion while the bridge runs; a sleeping Mac shows as "No Response" in Apple Home.
    public var keepsMacAwake: Bool {
        didSet {
            defaults.set(keepsMacAwake, forKey: Self.keepAwakeKey)
            updateSleepAssertion()
        }
    }

    static let enabledKey = "homekit_bridge_enabled"
    static let keepAwakeKey = "homekit_bridge_keep_awake"
    static let layoutKey = "homekit_bridge_layout_v1"
    static let serviceNamesKey = "homekit_bridge_service_names_v1"
    public static let bridgeName = "MijiaLAN Bridge"

    /// Accessory IDs and the configuration number Apple Home caches; kept apart from the secrets because they change
    /// whenever devices come and go.
    struct Layout: Codable, Equatable {
        var aids: [String: UInt64] = [:]
        var configurationNumber = 1
        var signature = ""
        /// Reusing the last port spares Apple Home a re-resolve after a restart.
        var port: UInt16?
    }

    private struct ExposedAccessory {
        let aid: UInt64
        let signature: String
        let iids: [HomeKitRole: UInt64]
        var lastValues: [HomeKitRole: HAPCharacteristicValue]
    }

    private let vault: HomeKitBridgeVault
    private let defaults: UserDefaults
    private let preferredPort: UInt16?
    private let logger = os.Logger(subsystem: "com.mijialan.MijiaLAN", category: "HomeKitBridge")

    @ObservationIgnored private weak var store: HomeStore?
    @ObservationIgnored private var capabilities: DeviceController?
    @ObservationIgnored private var capabilityPlans: [String: (aid: UInt64, plan: CapabilityHomeKitPlan)] = [:]
    @ObservationIgnored private var capabilityIIDs: [String: [String: UInt64]] = [:]
    static let capabilityIIDsKey = "homekit_capability_iids_v1"
    @ObservationIgnored private var secrets: HomeKitBridgeSecrets?
    @ObservationIgnored var bridge: HAPBridge?
    @ObservationIgnored private var service: AppleHAPService?
    @ObservationIgnored private var layout: Layout
    @ObservationIgnored private var serviceNames: [String: [String: String]]
    @ObservationIgnored private var exposed: [String: ExposedAccessory] = [:]
    /// Devices whose every characteristic is re-sent on the next sync (after a write from Apple Home).
    @ObservationIgnored private var forceRefresh: Set<String> = []
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherSync = false
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?

    /// - Parameter port: a fixed TCP port (tests); nil reuses the last port, or lets the system pick one.
    public init(vault: HomeKitBridgeVault, defaults: UserDefaults = .standard, port: UInt16? = nil) {
        self.vault = vault
        self.defaults = defaults
        self.preferredPort = port
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.keepsMacAwake = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        self.layout = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(Layout.self, from: $0) } ?? Layout()
        self.capabilityIIDs = defaults.data(forKey: Self.capabilityIIDsKey)
            .flatMap { try? JSONDecoder().decode([String: [String: UInt64]].self, from: $0) } ?? [:]
        self.serviceNames = defaults.dictionary(forKey: Self.serviceNamesKey) as? [String: [String: String]] ?? [:]
    }

    public func attach(to store: HomeStore, capabilities: DeviceController? = nil) {
        self.store = store
        self.capabilities = capabilities
        observeStore()
        if isEnabled { enqueue { await $0.startIfReady() } }
    }

    /// Forgets every paired controller and the bridge identity; Apple Home then sees a new, unpaired bridge.
    public func resetPairing() {
        enqueue { controller in
            await controller.stopNow()
            _ = controller.vault.save(nil)
            controller.secrets = nil
            controller.setupCode = nil
            controller.setupURI = nil
            controller.isPaired = false
            controller.layout = Layout()
            controller.saveLayout()
            if controller.isEnabled { await controller.startIfReady() }
        }
    }

    /// Waits for pending start/stop and sync work (tests).
    public func waitUntilIdle() async {
        while true {
            let pendingLifecycle = lifecycle
            let pendingSync = syncTask
            if pendingLifecycle == nil && pendingSync == nil { return }
            await pendingLifecycle?.value
            await pendingSync?.value
            if lifecycle == pendingLifecycle && syncTask == pendingSync { return }
        }
    }

    // MARK: - Lifecycle

    /// Start and stop run one after another, so a quick off/on never races two servers onto one identity.
    private func enqueue(_ operation: @escaping @MainActor (HomeKitBridgeController) async -> Void) {
        let previous = lifecycle
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
        lifecycle = task
        Task { @MainActor [weak self] in
            await task.value
            if self?.lifecycle == task { self?.lifecycle = nil }
        }
    }

    private func startIfReady() async {
        guard isEnabled, service == nil, let store else { return }
        guard store.hasReceivedInitialSnapshot, store.connectionStatus.isConnected else {
            status = .waitingForDevices
            return
        }
        status = .starting

        guard let secrets = loadOrCreateSecrets() else { return }
        let identity: HAPIdentity
        do {
            identity = try HAPIdentity(privateKeyData: secrets.signingKey)
        } catch {
            status = .failed(L10n.tr("HomeKit 桥身份密钥无效，请重置配对", "Invalid bridge key; reset pairing"))
            return
        }
        self.secrets = secrets
        setupCode = secrets.setupCode
        setupURI = HomeKitSetupCode.setupURI(setupCode: secrets.setupCode, setupID: secrets.setupID)
        isPaired = !secrets.pairings.isEmpty

        let pairingStore = HomeKitBridgePairingStore(
            pairings: secrets.pairings,
            persist: { [weak self] pairings in await self?.persistPairings(pairings) ?? false },
            onChange: { [weak self] paired in await self?.pairingChanged(paired) }
        )
        let bridge = HAPBridge(info: AccessoryInfo(
            name: Self.bridgeName,
            manufacturer: "MijiaLAN",
            model: "HomeKit Bridge",
            serialNumber: secrets.deviceID,
            firmwareRevision: "1.0.0"
        ))
        for aid in layout.aids.values { await bridge.reserveAID(aid) }

        await bridge.beginBatchUpdate()
        await reconcile(bridge: bridge, store: store)
        await bridge.endBatchUpdate()

        // Apple Home re-reads the accessory list only when the configuration number moves.
        let signature = layoutSignature()
        if signature != layout.signature {
            layout.configurationNumber = layout.configurationNumber >= 65_535 ? 1 : layout.configurationNumber + 1
            layout.signature = signature
        }
        await bridge.restoreConfigurationNumber(layout.configurationNumber)
        await bridge.addAccessoryChangeHandler { [weak self] number in
            await self?.configurationChanged(number)
        }

        var started: AppleHAPService?
        for port in candidatePorts() {
            let service = AppleHAPService(
                bridge: bridge,
                setupCode: secrets.setupCode,
                deviceID: secrets.deviceID,
                setupID: secrets.setupID,
                identity: identity,
                pairingStore: pairingStore
            )
            do {
                try await service.start(port: port)
                started = service
                break
            } catch {
                logger.error("HomeKit bridge failed to listen on port \(port): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let service = started else {
            exposed = [:]
            exposedDeviceCount = 0
            status = .failed(L10n.tr("无法在局域网上启动 HomeKit 桥", "Could not start the HomeKit bridge on the network"))
            return
        }

        self.bridge = bridge
        self.service = service
        layout.port = service.port
        saveLayout()
        status = .running(port: service.port)
        logger.info("HomeKit bridge running on port \(service.port) with \(self.exposed.count) accessories")
        updateSleepAssertion()
        // Changes that arrived while starting.
        scheduleSync()
    }

    private func stopNow() async {
        let running = service
        service = nil
        bridge = nil
        exposed = [:]
        capabilityPlans = [:]
        forceRefresh = []
        exposedDeviceCount = 0
        await running?.stop()
        status = .stopped
        updateSleepAssertion()
    }

    private func candidatePorts() -> [UInt16] {
        if let preferredPort { return [preferredPort] }
        if let last = layout.port, last != 0 { return [last, 0] }
        return [0]
    }

    // MARK: - Secrets

    private func loadOrCreateSecrets() -> HomeKitBridgeSecrets? {
        switch vault.load() {
        case .unavailable:
            status = .failed(L10n.tr("无法读取钥匙串，HomeKit 桥未启动", "Keychain unavailable; bridge not started"))
            return nil
        case .value(let data):
            if let secrets = HomeKitBridgeSecrets.decode(data) { return secrets }
            logger.error("Stored HomeKit bridge secrets are unreadable; creating a new bridge identity")
        case .missing:
            break
        }
        let fresh = HomeKitBridgeSecrets.generate()
        guard let data = fresh.encoded(), vault.save(data) else {
            status = .failed(L10n.tr("无法写入钥匙串，HomeKit 桥未启动", "Could not save to the Keychain; bridge not started"))
            return nil
        }
        // A new identity is a new bridge to Apple Home; the old accessory IDs mean nothing to it.
        layout = Layout()
        saveLayout()
        return fresh
    }

    private func persistPairings(_ pairings: [String: Data]) -> Bool {
        guard var next = secrets else { return false }
        next.pairings = pairings
        guard let data = next.encoded(), vault.save(data) else { return false }
        secrets = next
        return true
    }

    private func pairingChanged(_ paired: Bool) {
        isPaired = paired
    }

    // MARK: - Store Observation

    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.devices
            _ = capabilities?.snapshots
            _ = store.hiddenDeviceIds
            _ = store.hasReceivedInitialSnapshot
            _ = store.connectionStatus
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.storeChanged()
                self.observeStore()
            }
        }
    }

    private func storeChanged() {
        if service != nil {
            scheduleSync()
        } else if isEnabled, status == .waitingForDevices {
            enqueue { await $0.startIfReady() }
        }
    }

    // MARK: - Sync

    private func scheduleSync() {
        guard syncTask == nil else {
            needsAnotherSync = true
            return
        }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherSync = false
                await self.syncNow()
            } while self.needsAnotherSync
            self.syncTask = nil
        }
    }

    private func syncNow() async {
        guard let bridge, service != nil, let store else { return }
        await bridge.beginBatchUpdate()
        await reconcile(bridge: bridge, store: store)
        await bridge.endBatchUpdate()
        await pushValues(bridge: bridge, store: store)
    }

    /// Adds, rebuilds and removes accessories so the bridge matches the visible, supported devices.
    private func reconcile(bridge: HAPBridge, store: HomeStore) async {
        if let capabilities { await reconcileCapabilities(bridge: bridge, store: store, controller: capabilities); return }
        let plans = currentPlans(store: store)
        let planById = Dictionary(plans.map { ($0.plan.deviceId, $0) }, uniquingKeysWith: { first, _ in first })
        let canRemoveMissing = store.hasReceivedInitialSnapshot && store.connectionStatus.isConnected

        for (deviceId, accessory) in exposed {
            if let entry = planById[deviceId] {
                guard entry.plan.signature != accessory.signature else { continue }
            } else if !canRemoveMissing {
                continue
            }
            await bridge.removeAccessory(aid: accessory.aid)
            exposed[deviceId] = nil
        }

        for entry in plans where exposed[entry.plan.deviceId] == nil {
            let deviceId = entry.plan.deviceId
            let aid = layout.aids[deviceId] ?? nextAID()
            layout.aids[deviceId] = aid
            await bridge.addAccessory(
                info: entry.plan.info, services: entry.plan.services, aid: aid,
                appendingCharacteristicTypes: [HomeKitAccessoryMapper.configuredNameType]
            )
            let iids = await resolveIIDs(bridge: bridge, aid: aid, plan: entry.plan)
            for (role, iid) in iids {
                await bridge.registerWriteHandler(aid: aid, iid: iid) { [weak self] value in
                    try await self?.handleWrite(deviceId: deviceId, role: role, value: value)
                }
            }
            exposed[deviceId] = ExposedAccessory(
                aid: aid,
                signature: entry.plan.signature,
                iids: iids,
                lastValues: HomeKitAccessoryMapper.values(for: entry.device, configuredNames: configuredNames(for: deviceId))
            )
        }
        exposedDeviceCount = exposed.count
        saveLayout()
    }

    private func pushValues(bridge: HAPBridge, store: HomeStore) async {
        if capabilities != nil { await pushCapabilityValues(bridge: bridge); return }
        for device in store.devices {
            guard var accessory = exposed[device.id] else { continue }
            let forced = forceRefresh.remove(device.id) != nil
            let values = HomeKitAccessoryMapper.values(for: device, configuredNames: configuredNames(for: device.id))
            for (role, value) in values where forced || accessory.lastValues[role] != value {
                guard let iid = accessory.iids[role] else { continue }
                await bridge.updateCharacteristic(aid: accessory.aid, iid: iid, value: value)
            }
            accessory.lastValues = values
            exposed[device.id] = accessory
        }
    }

    private func reconcileCapabilities(bridge: HAPBridge, store: HomeStore, controller: DeviceController) async {
        let visible = controller.snapshots.values.filter { !store.hiddenDeviceIds.contains($0.id) }.sorted { $0.id < $1.id }
        let ordered = visible.filter { layout.aids[$0.id] != nil } + visible.filter { layout.aids[$0.id] == nil }
        var retained: Set<String> = []
        for snapshot in ordered.prefix(HomeKitAccessoryMapper.maxBridgedAccessories) {
            let did = snapshot.id
            var ids = capabilityIIDs[did] ?? [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: snapshot, legacyDevice: store.devices.first { $0.id == did },
                names: serviceNames[did] ?? [:], identifiers: &ids)
            guard !plan.services.isEmpty else { continue }
            capabilityIIDs[did] = ids
            retained.insert(did)
            if capabilityPlans[did]?.plan.signature == plan.signature { continue }
            let aid = layout.aids[did] ?? nextAID()
            layout.aids[did] = aid
            if capabilityPlans[did] != nil { await bridge.removeAccessory(aid: aid) }
            await bridge.addAccessory(info: plan.info, services: plan.services, aid: aid, servicesHaveStableIIDs: true)
            capabilityPlans[did] = (aid, plan)
            for (iid, binding) in plan.bindings {
                await bridge.registerWriteHandler(aid: aid, iid: iid, managesValue: true) { [weak self] value in
                    guard let self else { throw HAPError.unavailable }
                    try await self.handleCapabilityWrite(did: did, iid: iid, binding: binding, value: value)
                }
            }
        }
        for (did, entry) in capabilityPlans where !retained.contains(did) {
            await bridge.removeAccessory(aid: entry.aid); capabilityPlans[did] = nil
        }
        exposedDeviceCount = capabilityPlans.count
        if let data = try? JSONEncoder().encode(capabilityIIDs) { defaults.set(data, forKey: Self.capabilityIIDsKey) }
        saveLayout()
        await pushCapabilityValues(bridge: bridge)
    }

    private func pushCapabilityValues(bridge: HAPBridge) async {
        guard let capabilities else { return }
        for (did, entry) in capabilityPlans {
            guard let snapshot = capabilities.snapshots[did] else { continue }
            let legacy = store?.devices.first { $0.id == did }.map {
                HomeKitAccessoryMapper.values(for: $0, configuredNames: configuredNames(for: did))
            } ?? [:]
            for (iid, binding) in entry.plan.bindings {
                var value = CapabilityHomeKitMapper.value(binding, snapshot: snapshot, legacyValues: legacy, names: serviceNames[did] ?? [:])
                if case .float(let number) = value,
                   let c = entry.plan.services.flatMap(\.characteristics).first(where: { $0.iid == iid }),
                   number < (c.minValue ?? -.infinity) || number > (c.maxValue ?? .infinity) { value = nil }
                await bridge.setReadStatus(aid: entry.aid, iid: iid, status: value == nil ? .communicationFailure : .success)
                if let value { await bridge.updateCharacteristic(aid: entry.aid, iid: iid, value: value) }
            }
        }
    }

    private func handleCapabilityWrite(did: String, iid: UInt64, binding: CapabilityHAPBinding, value: HAPCharacteristicValue) async throws {
        guard let capabilities, let snapshot = capabilities.snapshots[did] else { throw HAPError.unavailable }
        do {
            switch binding {
            case .name(let key, _):
                guard case .string(let raw) = value else { throw HAPError.invalidValue }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 64 else { throw HAPError.invalidValue }
                serviceNames[did, default: [:]][key] = name
                defaults.set(serviceNames, forKey: Self.serviceNamesKey)
            case .legacy(let role) where role.isConfiguredName: try await handleWrite(deviceId: did, role: role, value: value)
            default:
                let commands = try CapabilityHomeKitMapper.commands(binding, value: value, snapshot: snapshot)
                if !commands.isEmpty { try await capabilities.execute(did: did, .batch(commands), coalesce: true) }
            }
        } catch {
            if let bridge { await pushCapabilityValues(bridge: bridge) }
            switch error {
            case DeviceControlError.invalidValue, DeviceControlError.missingInput: throw HAPError.invalidValue
            case DeviceControlError.busy: throw HAPError.busy
            default: throw error
            }
        }
        if let bridge {
            await pushCapabilityValues(bridge: bridge)
            if let entry = capabilityPlans[did], let current = await bridge.readCharacteristic(aid: entry.aid, iid: iid) {
                // A momentary button is already false in the cache; still notify Home to undo its optimistic true.
                await bridge.updateCharacteristic(aid: entry.aid, iid: iid, value: current, forceNotify: true)
            }
        }
    }

    /// Devices the user kept out of Apple Home are hidden in the store and get no accessory.
    func currentPlans(store: HomeStore) -> [(device: SmartDevice, plan: HomeKitAccessoryPlan)] {
        let visible = store.devices.filter { !store.hiddenDeviceIds.contains($0.id) }
        let names = Self.displayNames(for: visible)
        let plans = visible.compactMap { device in
            HomeKitAccessoryMapper.plan(
                for: device, name: names[device.id] ?? device.name, configuredNames: configuredNames(for: device.id)
            ).map { (device: device, plan: $0) }
        }
        guard plans.count > HomeKitAccessoryMapper.maxBridgedAccessories else { return plans }
        // Over the limit, keep what Apple Home already knows.
        let known = plans.filter { exposed[$0.device.id] != nil }
        let new = plans.filter { exposed[$0.device.id] == nil }
        return Array((known + new).prefix(HomeKitAccessoryMapper.maxBridgedAccessories))
    }

    /// Two devices called 吸顶灯 in different rooms would both land in Apple Home's default room; prefix the room.
    nonisolated static func displayNames(for devices: [SmartDevice]) -> [String: String] {
        let counts = Dictionary(grouping: devices, by: \.name).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: devices.map { device in
            let isDuplicate = (counts[device.name] ?? 0) > 1 && !device.roomName.isEmpty
            return (device.id, isDuplicate ? "\(device.roomName) \(device.name)" : device.name)
        })
    }

    private func resolveIIDs(bridge: HAPBridge, aid: UInt64, plan: HomeKitAccessoryPlan) async -> [HomeKitRole: UInt64] {
        guard let accessory = await bridge.accessoryDatabase().first(where: { $0.aid == aid }) else { return [:] }
        return Self.iids(in: accessory.services, plan: plan)
    }

    /// Two services of one type (the dry and fan-only switches) are told apart by their order, which the bridge keeps.
    nonisolated static func iids(in services: [HAPService], plan: HomeKitAccessoryPlan) -> [HomeKitRole: UInt64] {
        var iids: [HomeKitRole: UInt64] = [:]
        for role in HomeKitRole.allCases {
            guard let position = plan.serviceKeys.firstIndex(of: role.serviceKey) else { continue }
            let occurrence = plan.services[..<position].filter { $0.type == role.serviceType }.count
            let candidates = services.filter { $0.type == role.serviceType }
            guard occurrence < candidates.count,
                  let characteristic = candidates[occurrence].characteristics.first(where: { $0.type == role.characteristicType })
            else { continue }
            iids[role] = characteristic.iid
        }
        return iids
    }

    /// Accessory IDs are never reused, even for a device that left: Apple Home may still cache the old one.
    private func nextAID() -> UInt64 {
        max(1, layout.aids.values.max() ?? 1) + 1
    }

    private func layoutSignature() -> String {
        (exposed.map { "\($0.value.aid)=\($0.value.signature)" } + capabilityPlans.values.map { "\($0.aid)=\($0.plan.signature)" }).sorted().joined(separator: ";")
    }

    private func configurationChanged(_ number: Int) {
        layout.configurationNumber = number
        layout.signature = layoutSignature()
        saveLayout()
    }

    private func saveLayout() {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Self.layoutKey)
        }
    }

    // MARK: - Writes From Apple Home

    private func configuredNames(for deviceId: String) -> [HomeKitRole: String] {
        var names: [HomeKitRole: String] = [:]
        for (key, value) in serviceNames[deviceId] ?? [:] {
            if let role = HomeKitRole(rawValue: key), role.isConfiguredName { names[role] = value }
        }
        return names
    }

    private func handleWrite(deviceId: String, role: HomeKitRole, value: HAPCharacteristicValue) async throws {
        defer {
            forceRefresh.insert(deviceId)
            scheduleSync()
        }
        if role.isConfiguredName {
            guard case .string(let text) = value else { throw HAPError.invalidValue }
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 64 else { throw HAPError.invalidValue }
            serviceNames[deviceId, default: [:]][role.rawValue] = name
            defaults.set(serviceNames, forKey: Self.serviceNamesKey)
            return
        }
        guard let store, let device = store.devices.first(where: { $0.id == deviceId }), device.isOnline else { throw HAPError.unavailable }
        if role == .climateDisplayUnits { return }
        guard let write = HomeKitAccessoryMapper.write(role, value: value, to: device) else { return }
        if let capabilities {
            let entity = MiotAddress.make(did: deviceId, siid: 2)
            let command: MijiaCore.DeviceCommand = switch write {
            case .power(let on): .setClimatePower(entityId: entity, isOn: on, fallbackMode: "cool")
            case .brightness(let percent): .setLightBrightness(entityId: entity, percent: percent)
            case .colorTemperature(let kelvin): .setLightColorTemp(entityId: entity, kelvin: kelvin)
            case .climateMode(let mode): .setClimateMode(entityId: entity, hvacMode: mode)
            case .targetTemperature(let temperature): .setClimateTemperature(entityId: entity, temperature: temperature)
            case .climateFanMode(let mode): .setClimateFanMode(entityId: entity, fanMode: mode)
            case .climateSwing(let mode): .setClimateSwingMode(entityId: entity, swingMode: mode)
            }
            try await capabilities.executeCore(command)
            return
        }
        logger.info("Apple Home → \(deviceId, privacy: .private): \(String(describing: write), privacy: .private)")
        Self.apply(write, to: device, in: store)
    }

    static func apply(_ write: HomeKitWrite, to device: SmartDevice, in store: HomeStore) {
        switch write {
        case .power(let on):
            if device.isActiveOn != on { store.togglePrimary(device) }
        case .brightness(let percent):
            store.setLightBrightness(device.id, percent: percent)
        case .colorTemperature(let kelvin):
            store.setLightColorTemp(device.id, kelvin: kelvin)
        case .climateMode(let mode):
            store.setClimateMode(device.id, mode: mode)
        case .targetTemperature(let temperature):
            if case .climate(let s) = device.kind {
                store.stepClimateTemperature(device.id, delta: temperature - s.targetTemperature)
            }
        case .climateFanMode(let mode):
            store.setClimateFanMode(device.id, fanMode: mode)
        case .climateSwing(let mode):
            store.setClimateSwingMode(device.id, swingMode: mode)
        }
    }

    // MARK: - Sleep

    private func updateSleepAssertion() {
        let shouldHold = keepsMacAwake && service != nil
        if shouldHold, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "MijiaLAN HomeKit bridge is serving Apple Home"
            )
        } else if !shouldHold, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
