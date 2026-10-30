import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import Observation
import os

/// Owns the app's single Keychain item, the device config, the LAN API and the `HomeStore` + HomeKit bridge on top.
///
/// The Xiaomi account is used only inside `startCloudImport`: the session lives in that task's locals, is used for
/// one device-list read, and is gone when the task ends. Nothing else ever talks to the cloud.
@Observable
@MainActor
final class AppModel {
    nonisolated static let keychainService = "com.mijialan.MijiaLAN"
    nonisolated static let configAccount = "home_config_v1"
    nonisolated static let bridgeAccount = "homekit_bridge_v1"
    /// DHCP leases move devices around; a broadcast hello finds them again by device ID.
    static let rediscoveryInterval: Duration = .seconds(300)

    enum ImportState: Equatable {
        case idle
        case loadingQR
        case waitingForScan(QRLoginTicket, expiresAt: Date)
        case fetching
        case failed(String)
    }

    private(set) var config: LocalHomeConfig
    /// The Keychain item exists but could not be read (prompt declined); nothing is saved until it can be.
    private(set) var vaultUnavailable: Bool
    private(set) var health: [String: LANDeviceHealth] = [:]
    var importState: ImportState = .idle
    private(set) var lastImportSummary: String?
    var importRegion: String = "cn"
    private(set) var manualAddError: String?
    private(set) var isAddingManually = false
    private(set) var isRediscovering = false
    private(set) var lastRediscoveryNote: String?

    let store: HomeStore
    let bridge: HomeKitBridgeController
    @ObservationIgnored private let vault: SecretVault
    @ObservationIgnored private let configBox: ConfigBox
    @ObservationIgnored private let api: LANMiotAPI
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var rediscoveryTask: Task<Void, Never>?
    @ObservationIgnored private var bridgeAttached = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "App")

    /// `MIJIALAN_EPHEMERAL=1` (development): secrets in memory and separate defaults, so a test run never touches
    /// the Keychain item or the real pairing. `MIJIALAN_SEED_CONFIG=<file>` then supplies the device config as JSON.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let ephemeral = environment["MIJIALAN_EPHEMERAL"] == "1"
        let vault = SecretVault(storage: ephemeral ? .memory() : .keychain(service: Self.keychainService, account: "secrets"))
        if ephemeral, let seed = environment["MIJIALAN_SEED_CONFIG"], let data = FileManager.default.contents(atPath: seed) {
            vault.set(data, for: Self.configAccount)
        }
        let defaultsSuite = ephemeral ? "com.mijialan.MijiaLAN.dev" : "com.mijialan.MijiaLAN.home"
        if ephemeral { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let bridgeDefaults = ephemeral ? (UserDefaults(suiteName: defaultsSuite) ?? .standard) : .standard
        self.vault = vault
        var loaded = LocalHomeConfig()
        var unavailable = false
        switch vault.lookup(Self.configAccount) {
        case .value(let data): loaded = LocalHomeConfig.decode(data) ?? LocalHomeConfig()
        case .missing: break
        case .unavailable: unavailable = true
        }
        config = loaded
        vaultUnavailable = unavailable
        let box = ConfigBox(loaded)
        configBox = box
        let api = LANMiotAPI(config: { box.value })
        self.api = api
        store = HomeStore(provider: LocalHomeProvider.make(api: api), defaultsSuiteName: defaultsSuite)
        bridge = HomeKitBridgeController(vault: HomeKitBridgeVault(
            load: { vault.lookup(AppModel.bridgeAccount) },
            save: { vault.set($0, for: AppModel.bridgeAccount) }
        ), defaults: bridgeDefaults)

        Task { [weak self] in
            await api.observeHealth { health in
                Task { @MainActor in self?.health = health }
            }
        }
        attachBridgeIfNeeded()
        startRediscoveryLoop()
    }

    // MARK: Devices

    var onlineCount: Int { config.devices.filter { health[$0.did]?.state == .online }.count }

    func smartDevice(for device: LocalDevice) -> SmartDevice? {
        store.devices.first { $0.id == device.did }
    }

    func togglePower(_ device: LocalDevice) {
        guard let smart = smartDevice(for: device) else { return }
        _ = store.togglePrimary(smart)
    }

    /// A device kept out of Apple Home (say, one that is HomeKit-native already) is hidden in the store, which the
    /// bridge leaves out. The choice is per device ID, so it survives a re-import.
    func isInHomeKit(_ device: LocalDevice) -> Bool { !store.hiddenDeviceIds.contains(device.did) }

    func setInHomeKit(_ device: LocalDevice, _ included: Bool) {
        if included { store.unhideDevice(device.did) } else { store.hideDevice(device.did) }
    }

    /// Whether Apple Home has an accessory type for this device at all.
    func homeKitSupports(_ device: LocalDevice) -> Bool {
        smartDevice(for: device).flatMap { HomeKitAccessoryMapper.plan(for: $0, name: $0.name) } != nil
    }

    func remove(_ device: LocalDevice) {
        var next = config
        next.remove(did: device.did)
        apply(next)
    }

    // MARK: Cloud Import (the one and only cloud use)

    func startCloudImport() {
        importTask?.cancel()
        importState = .loadingQR
        let region = importRegion
        importTask = Task { [weak self] in
            do {
                let login = MiAccountLogin(region: region)
                let ticket = try await login.start()
                guard !Task.isCancelled else { return }
                self?.importState = .waitingForScan(ticket, expiresAt: Date().addingTimeInterval(ticket.timeout))
                let session = try await login.waitForScan(ticket)
                guard !Task.isCancelled else { return }
                self?.importState = .fetching
                let result = try await CloudTokenImport.fetch(session: session)
                // `session` goes out of scope here and is never stored.
                await self?.finishImport(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.importState = .failed(Self.describe(error))
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importState = .idle
    }

    private func finishImport(_ result: CloudImportResult) async {
        var devices = result.devices
        await resolveSpecTypes(&devices)
        var next = config
        next.merge(devices)
        let imported = Set(next.devices.map(\.did))
        next.skipped = result.skipped.filter { !imported.contains($0.did) }
        next.importedAt = Date()
        apply(next)
        importState = .idle
        lastImportSummary = "导入 \(result.devices.count) 台可走局域网的设备" +
            (result.skipped.isEmpty ? "" : "，\(result.skipped.count) 台不能（见下方）") +
            (result.region == "cn" ? "" : "（服务器：\(result.region)）") + "。登录状态已丢弃。"
        logger.info("Imported \(result.devices.count, privacy: .public) devices, skipped \(result.skipped.count, privacy: .public)")
    }

    /// Looks each model's MIoT spec up once (miot-spec.org, no account) so later starts never need the internet.
    private func resolveSpecTypes(_ devices: inout [LocalDevice]) async {
        let source = MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
        for index in devices.indices {
            let device = devices[index]
            if let spec = try? await source.spec(model: device.model, specType: device.specType) {
                devices[index].specType = spec.type
            }
        }
    }

    // MARK: Manual Add

    func addManually(host: String, token: String, name: String) {
        guard !isAddingManually else { return }
        isAddingManually = true
        manualAddError = nil
        Task { [weak self] in
            do {
                let device = try await ManualDeviceProbe.probe(
                    host: host, token: token, name: name,
                    specSource: MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
                )
                guard let self else { return }
                var next = self.config
                next.merge([device])
                self.apply(next)
                self.lastImportSummary = "已添加 \(device.name)（\(device.model)）"
            } catch {
                self?.manualAddError = Self.describe(error)
            }
            self?.isAddingManually = false
        }
    }

    // MARK: Rediscovery

    func rediscoverNow() {
        Task { await rediscover() }
    }

    private func startRediscoveryLoop() {
        rediscoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.rediscover()
                try? await Task.sleep(for: Self.rediscoveryInterval)
            }
        }
    }

    private func rediscover() async {
        guard !isRediscovering else { return }
        isRediscovering = true
        defer { isRediscovering = false }
        do {
            let found = try await MiioDiscovery.discover()
            var next = config
            let moved = next.updateHosts(from: found)
            let known = Set(config.devices.map(\.did))
            let unknown = found.filter { !known.contains($0.did) }.count
            lastRediscoveryNote = found.isEmpty
                ? "局域网广播暂时没有设备回应（路由器的设备隔离也会拦住广播）"
                : "局域网里找到 \(found.count) 台 miIO 设备" + (unknown > 0 ? "，其中 \(unknown) 台还没有 token" : "")
            if moved {
                logger.info("Device IPs changed; saving")
                apply(next)
            }
        } catch {
            lastRediscoveryNote = Self.describe(error)
        }
    }

    // MARK: Persistence

    private func apply(_ next: LocalHomeConfig) {
        guard let data = next.encoded(), vault.set(data, for: Self.configAccount) else {
            vaultUnavailable = true
            logger.error("Could not save the device config to the Keychain")
            return
        }
        vaultUnavailable = false
        config = next
        configBox.value = next
        store.refreshNow()
        attachBridgeIfNeeded()
    }

    /// The bridge waits for the first imported device, so a fresh install does not advertise an empty bridge.
    private func attachBridgeIfNeeded() {
        guard !bridgeAttached, !config.devices.isEmpty else { return }
        bridgeAttached = true
        bridge.attach(to: store)
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The config as the LAN API's actor reads it, off the main actor.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: LocalHomeConfig

    init(_ config: LocalHomeConfig) { self.config = config }

    var value: LocalHomeConfig {
        get { lock.withLock { config } }
        set { lock.withLock { config = newValue } }
    }
}
