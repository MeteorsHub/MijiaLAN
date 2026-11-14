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
    public struct ServiceLimitWarning: Identifiable, Equatable, Sendable {
        public let id: String
        public let deviceName: String
        public let omittedServiceCount: Int
    }
    public private(set) var serviceLimitWarnings: [ServiceLimitWarning] = []
    /// Services the user kept out of Apple Home, by device ID and service key. The rest of the accessory stays as it was.
    public private(set) var excludedServices: [String: Set<String>]
    /// Moves whenever Home renames a service, so a list of names can tell it is out of date.
    public private(set) var serviceNamesRevision = 0

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                observeStore()
                enqueue { await $0.startIfReady() }
            } else {
                storeObservation.stop()
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
    static let excludedServicesKey = "homekit_bridge_excluded_services_v1"
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

    private struct CapabilityAccessory {
        let aid: UInt64
        let plan: CapabilityHomeKitPlan
        let characteristics: [UInt64: HAPCharacteristic]
    }
    private struct PublishedValue: Equatable {
        var value: HAPCharacteristicValue?
        var status: Int
    }
    /// A characteristic whose last published read failed. Home draws a warning on its accessory.
    public struct ReadFailure: Equatable, Sendable {
        public var deviceID: String
        public var service: String
        public var characteristic: String
        /// The capability it reads, such as `p:2:3 direct` or `p:6:1=1`.
        public var source: String
        public var status: Int
        public init(deviceID: String, service: String, characteristic: String, source: String, status: Int) {
            self.deviceID = deviceID; self.service = service; self.characteristic = characteristic
            self.source = source; self.status = status
        }
    }
    struct SyncStatistics {
        var planBuilds = 0
        var characteristicUpdates = 0
        var readStatusUpdates = 0
        var layoutWrites = 0
        var identifierWrites = 0
    }
    @ObservationIgnored private(set) var syncStatistics = SyncStatistics()

    private let vault: HomeKitBridgeVault
    private let defaults: UserDefaults
    private let preferredPort: UInt16?
    private let loopbackOnly: Bool
    private let logger = os.Logger(subsystem: "com.mijialan.MijiaLAN", category: "HomeKitBridge")

    @ObservationIgnored private weak var store: HomeStore?
    @ObservationIgnored private let storeObservation = HomeKitStateObservation()
    @ObservationIgnored private var capabilities: DeviceController?
    @ObservationIgnored private var capabilityPlans: [String: CapabilityAccessory] = [:]
    @ObservationIgnored private var publishedCapabilityValues: [String: [UInt64: PublishedValue]] = [:]
    @ObservationIgnored private var capabilityStructureRevision: UInt64?
    @ObservationIgnored private var capabilityHiddenIDs: Set<String>?
    @ObservationIgnored private var capabilityStructureDirty = true
    @ObservationIgnored private var capabilityPushTask: Task<Void, Never>?
    /// Devices with writes from Home still waiting for the device, by count. Their readings are published once the
    /// writes finish: a light read mid-fade would otherwise tell Home a level it did not ask for.
    @ObservationIgnored private var settlingWrites: [String: Int] = [:]
    @ObservationIgnored private var savedLayout: Layout?
    @ObservationIgnored private var savedCapabilityIIDs: [String: [String: UInt64]]?
    @ObservationIgnored private var capabilityIIDs: [String: [String: UInt64]] = [:]
    static let capabilityIIDsKey = "homekit_capability_iids_v1"
    /// Per miIO attempt for writes from Apple Home, which shows "Updating" until it has the device's answer.
    /// Wi-Fi power save delays answers by up to about 2 s, the same allowance as the reachability probe.
    static let writeAttemptTimeout: Duration = .milliseconds(2500)
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
    public init(vault: HomeKitBridgeVault, defaults: UserDefaults = .standard, port: UInt16? = nil, loopbackOnly: Bool = false) {
        self.vault = vault
        self.defaults = defaults
        self.preferredPort = port
        self.loopbackOnly = loopbackOnly
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.keepsMacAwake = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        self.layout = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(Layout.self, from: $0) } ?? Layout()
        self.capabilityIIDs = defaults.data(forKey: Self.capabilityIIDsKey)
            .flatMap { try? JSONDecoder().decode([String: [String: UInt64]].self, from: $0) } ?? [:]
        self.serviceNames = defaults.dictionary(forKey: Self.serviceNamesKey) as? [String: [String: String]] ?? [:]
        self.excludedServices = (defaults.dictionary(forKey: Self.excludedServicesKey) as? [String: [String]] ?? [:]).mapValues(Set.init)
        self.savedLayout = defaults.data(forKey: Self.layoutKey) == nil ? nil : layout
        self.savedCapabilityIIDs = defaults.data(forKey: Self.capabilityIIDsKey) == nil ? nil : capabilityIIDs
    }

    public func attach(to store: HomeStore, capabilities: DeviceController? = nil) {
        storeObservation.stop()
        self.store = store
        self.capabilities = capabilities
        capabilityStructureDirty = true
        if isEnabled {
            observeStore()
            if service != nil { scheduleSync() }
            else { enqueue { await $0.startIfReady() } }
        }
    }

    /// Keeps these services of a device out of Apple Home from the next sync on; an empty set publishes them all. Home
    /// forgets a removed service's scenes and automations, but the services that stay keep their IDs.
    public func setExcludedServices(_ keys: Set<String>, for did: String) {
        guard (excludedServices[did] ?? []) != keys else { return }
        excludedServices[did] = keys.isEmpty ? nil : keys
        defaults.set(excludedServices.mapValues { $0.sorted() }, forKey: Self.excludedServicesKey)
        capabilityStructureDirty = true
        if service != nil { scheduleSync() }
    }

    /// What the device can publish to Apple Home, service by service, under the names Home shows; see `setExcludedServices`.
    public func homeServices(for snapshot: DeviceSnapshot, legacyDevice: SmartDevice?) -> [CapabilityHomeKitService] {
        CapabilityHomeKitMapper.services(snapshot: snapshot, legacyDevice: legacyDevice, names: serviceNames[snapshot.id] ?? [:])
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
            await storeObservation.waitUntilIdle()
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
        observeStore()
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
            pairings: secrets.pairings, permissions: secrets.pairingPermissions,
            persist: { [weak self] pairings, roles in await self?.persistPairings(pairings, permissions: roles) ?? false },
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
        await pushValues(bridge: bridge, store: store)

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
                try await service.start(port: port, loopbackOnly: loopbackOnly)
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
        logger.info("HomeKit bridge running on port \(service.port) with \(self.exposedDeviceCount) accessories")
        updateSleepAssertion()
        // Changes that arrived while starting.
        scheduleSync()
    }

    private func stopNow() async {
        storeObservation.stop()
        let running = service
        service = nil
        bridge = nil
        await syncTask?.value
        await capabilityPushTask?.value
        exposed = [:]
        capabilityPlans = [:]
        publishedCapabilityValues = [:]
        capabilityStructureRevision = nil
        capabilityHiddenIDs = nil
        capabilityStructureDirty = true
        forceRefresh = []
        exposedDeviceCount = 0
        serviceLimitWarnings = []
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

    private func persistPairings(_ pairings: [String: Data], permissions: [String: UInt8]) -> Bool {
        guard var next = secrets else { return false }
        next.pairings = pairings
        next.pairingPermissions = permissions
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
        let capabilities = self.capabilities
        storeObservation.start(read: { [weak store, weak capabilities] in
            guard let store else { return }
            if let capabilities {
                _ = capabilities.structureRevision
                _ = capabilities.valuesRevision
            } else {
                _ = store.devices
            }
            _ = store.hiddenDeviceIds
            _ = store.hasReceivedInitialSnapshot
            _ = store.connectionStatus
        }, changed: { [weak self] in self?.storeChanged() })
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
        let revision = controller.structureRevision
        let hiddenIDs = store.hiddenDeviceIds
        guard capabilityStructureDirty || capabilityStructureRevision != revision || capabilityHiddenIDs != hiddenIDs else { return }
        capabilityStructureDirty = false
        capabilityStructureRevision = revision
        capabilityHiddenIDs = hiddenIDs
        let legacyDevices = Dictionary(controller.synthesizedHome().devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = controller.snapshots.values.filter { !store.hiddenDeviceIds.contains($0.id) }.sorted { $0.id < $1.id }
        let ordered = visible.filter { layout.aids[$0.id] != nil } + visible.filter { layout.aids[$0.id] == nil }
        var retained: Set<String> = []
        var limitWarnings: [ServiceLimitWarning] = []
        for snapshot in ordered.prefix(HomeKitAccessoryMapper.maxBridgedAccessories) {
            let did = snapshot.id
            var ids = capabilityIIDs[did] ?? [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: snapshot, legacyDevice: legacyDevices[did],
                names: serviceNames[did] ?? [:], identifiers: &ids, excluding: excludedServices[did] ?? [])
            syncStatistics.planBuilds += 1
            if plan.omittedServiceCount > 0 {
                limitWarnings.append(ServiceLimitWarning(id: did, deviceName: snapshot.device.name,
                                                         omittedServiceCount: plan.omittedServiceCount))
                logger.warning("HomeKit service limit reached for device \(did, privacy: .private): \(plan.omittedServiceCount) services omitted")
            }
            guard !plan.services.isEmpty else { continue }
            capabilityIIDs[did] = ids
            retained.insert(did)
            let characteristics = Dictionary(plan.services.flatMap(\.characteristics).map { ($0.iid, $0) }, uniquingKeysWith: { first, _ in first })
            if let existing = capabilityPlans[did], existing.plan.databaseSignature == plan.databaseSignature {
                capabilityPlans[did] = CapabilityAccessory(aid: existing.aid, plan: plan, characteristics: characteristics)
                continue
            }
            let aid = layout.aids[did] ?? nextAID()
            layout.aids[did] = aid
            if capabilityPlans[did] != nil { await bridge.removeAccessory(aid: aid) }
            await bridge.addAccessory(info: plan.info, services: plan.services, aid: aid, servicesHaveStableIIDs: true)
            capabilityPlans[did] = CapabilityAccessory(aid: aid, plan: plan, characteristics: characteristics)
            publishedCapabilityValues[did] = nil
            for (iid, binding) in plan.bindings {
                await bridge.registerWriteHandler(aid: aid, iid: iid, managesValue: true) { [weak self] value in
                    guard let self else { throw HAPError.unavailable }
                    try await self.handleCapabilityWrite(did: did, iid: iid, binding: binding, value: value)
                }
            }
        }
        for (did, entry) in capabilityPlans where !retained.contains(did) {
            await bridge.removeAccessory(aid: entry.aid); capabilityPlans[did] = nil
            publishedCapabilityValues[did] = nil
        }
        exposedDeviceCount = capabilityPlans.count
        serviceLimitWarnings = limitWarnings
        if savedCapabilityIIDs != capabilityIIDs, let data = try? JSONEncoder().encode(capabilityIIDs) {
            defaults.set(data, forKey: Self.capabilityIIDsKey)
            savedCapabilityIIDs = capabilityIIDs
            syncStatistics.identifierWrites += 1
        }
        saveLayout()
    }

    private func pushCapabilityValues(bridge: HAPBridge) async {
        let previous = capabilityPushTask
        let task = Task { @MainActor in
            await previous?.value
            await self.commitCapabilityValues(bridge: bridge)
        }
        capabilityPushTask = task
        await task.value
        if capabilityPushTask == task { capabilityPushTask = nil }
    }

    /// Every characteristic Home currently reads as failed, for a problem report.
    public var readFailures: [ReadFailure] {
        capabilityPlans.flatMap { did, entry in
            entry.plan.services.flatMap { service in
                service.characteristics.compactMap { c -> ReadFailure? in
                    guard let published = publishedCapabilityValues[did]?[c.iid], published.status != HAPStatus.success.rawValue,
                          let binding = entry.plan.bindings[c.iid] else { return nil }
                    let source = switch binding {
                    case .property(let id, let conversion): "\(id) \(conversion)"
                    case .option(let id, let value): "\(id)=\(value.compactJSONString)"
                    case .legacy(let role): role.rawValue
                    default: "\(binding)"
                    }
                    return ReadFailure(deviceID: did, service: service.type.rawValue, characteristic: c.type.rawValue,
                                       source: source, status: published.status)
                }
            }
        }.sorted { ($0.deviceID, $0.service, $0.characteristic, $0.source) < ($1.deviceID, $1.service, $1.characteristic, $1.source) }
    }

    private func commitCapabilityValues(bridge: HAPBridge) async {
        guard let capabilities else { return }
        let legacyDevices = Dictionary(capabilities.synthesizedHome().devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (did, entry) in capabilityPlans where settlingWrites[did] == nil {
            guard let snapshot = capabilities.snapshots[did] else { continue }
            let forced = forceRefresh.remove(did) != nil
            let legacy = legacyDevices[did].map {
                HomeKitAccessoryMapper.values(for: $0, configuredNames: configuredNames(for: did))
            } ?? [:]
            for (iid, binding) in entry.plan.bindings {
                var value = CapabilityHomeKitMapper.value(binding, snapshot: snapshot, legacyValues: legacy, names: serviceNames[did] ?? [:])
                value = value.flatMap { entry.characteristics[iid]?.normalizedRead($0) }
                let status: HAPStatus = value == nil ? .communicationFailure : .success
                let previous = publishedCapabilityValues[did]?[iid]
                let recovered = previous?.status == HAPStatus.communicationFailure.rawValue && status.rawValue == HAPStatus.success.rawValue
                if previous?.status != status.rawValue {
                    await bridge.setReadStatus(aid: entry.aid, iid: iid, status: status)
                    syncStatistics.readStatusUpdates += 1
                }
                if let value, forced || previous?.value != value {
                    // The bridge still caches the last valid value while offline. A same-value recovery must
                    // notify subscribers as well as repairing GET status, or Home can retain its error state.
                    await bridge.updateCharacteristic(aid: entry.aid, iid: iid, value: value, forceNotify: forced || recovered)
                    syncStatistics.characteristicUpdates += 1
                }
                publishedCapabilityValues[did, default: [:]][iid] = PublishedValue(value: value, status: status.rawValue)
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
                serviceNamesRevision += 1
                capabilityStructureDirty = true
                scheduleSync()
            case .legacy(let role) where role.isConfiguredName: try await handleWrite(deviceId: did, role: role, value: value)
            default:
                let commands = try CapabilityHomeKitMapper.commands(binding, value: value, snapshot: snapshot)
                // Not coalesced: a controller sends its next write only after this one's response, so waiting for
                // a later value only delays every write, such as each step of a brightness slider.
                if !commands.isEmpty {
                    settlingWrites[did, default: 0] += 1
                    defer {
                        settlingWrites[did, default: 1] -= 1
                        if settlingWrites[did] == 0 { settlingWrites[did] = nil }
                    }
                    try await MiioClient.$attemptTimeout.withValue(Self.writeAttemptTimeout) {
                        try await DeviceCommunicationContext.$source.withValue(.homeKit) {
                            try await DeviceCommunicationContext.$operation.withValue(UUID()) {
                                try await capabilities.execute(did: did, .batch(commands))
                            }
                        }
                    }
                }
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
            // A correction restores the confirmed value after an optimistic write, such as a momentary button.
            // Zero brightness turns the lamp off while preserving its last level. Resending that level
            // here would overwrite the controller's completed dimmer gesture.
            if let entry = capabilityPlans[did],
               entry.characteristics[iid]?.type != .brightness || value != .int32(0),
               let current = await bridge.readCharacteristic(aid: entry.aid, iid: iid), current != value {
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
        return Dictionary(devices.map { device in
            let isDuplicate = (counts[device.name] ?? 0) > 1 && !device.roomName.isEmpty
            return (device.id, isDuplicate ? "\(device.roomName) \(device.name)" : device.name)
        }, uniquingKeysWith: { first, _ in first })
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
        (exposed.map { "\($0.value.aid)=\($0.value.signature)" } + capabilityPlans.values.map { "\($0.aid)=\($0.plan.databaseSignature)" }).sorted().joined(separator: ";")
    }

    private func configurationChanged(_ number: Int) {
        layout.configurationNumber = number
        layout.signature = layoutSignature()
        saveLayout()
    }

    private func saveLayout() {
        guard savedLayout != layout else { return }
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: Self.layoutKey)
            savedLayout = layout
            syncStatistics.layoutWrites += 1
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
        if DeviceCommunicationContext.source == nil {
            return try await DeviceCommunicationContext.$source.withValue(.homeKit) {
                try await DeviceCommunicationContext.$operation.withValue(UUID()) { try await handleWrite(deviceId: deviceId, role: role, value: value) }
            }
        }
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
            serviceNamesRevision += 1
            capabilityStructureDirty = true
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
