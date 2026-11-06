import Foundation
import MijiaLAN
import MijiaCore
import Observation

/// A supervised Matter child; every write shares the App's DeviceController with HomeKit and local controls.
@MainActor @Observable
final class MatterBridgeController {
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "matter.enabled"); if isEnabled { restart() } else { stop() } } }
    var keepsMacAwake: Bool { didSet { defaults.set(keepsMacAwake, forKey: "matter.awake"); updateAwake() } }
    private(set) var status = L10n.tr("已关闭", "Off")
    private(set) var setupCode: String?
    private(set) var setupURI: String?
    private(set) var isPaired = false
    private(set) var isRunning = false
    private(set) var excluded: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    let storageDirectory: URL
    @ObservationIgnored private let ephemeral: Bool
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var controller: DeviceController?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()

    init(defaults: UserDefaults = .standard, ephemeral: Bool = false) {
        self.defaults = defaults
        self.ephemeral = ephemeral
        if ephemeral {
            storageDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MijiaLAN-Matter-\(UUID().uuidString)", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            storageDirectory = support.appendingPathComponent("MijiaLAN/Matter", isDirectory: true)
        }
        isEnabled = defaults.bool(forKey: "matter.enabled")
        keepsMacAwake = defaults.object(forKey: "matter.awake") as? Bool ?? true
        excluded = Set(defaults.stringArray(forKey: "matter.excluded") ?? [])
    }
    func includes(_ id: String) -> Bool { !excluded.contains(id) }
    func include(_ id: String, _ included: Bool) {
        if included { excluded.remove(id) } else { excluded.insert(id) }
        defaults.set(Array(excluded), forKey: "matter.excluded")
        restart()
    }
    func attach(_ controller: DeviceController) {
        self.controller = controller
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    var supported: [MatterDevicePlan.Entry] { controller.map { MatterDevicePlan.entries(Array($0.snapshots.values)) } ?? [] }
    var selected: [MatterDevicePlan.Device] { supported.filter { includes($0.sourceID) }.map(\.device) }
    func restart() { stop(); failed = false }
    private func reconcile() {
        guard isEnabled else { return }
        let next = selected.map { $0.did + ":" + $0.kind }.joined(separator: "|")
        if next != signature { stop(); signature = next; failed = false }
        guard process == nil, !failed else { return }
        guard !selected.isEmpty else { status = L10n.tr("等待可桥接设备", "Waiting for supported devices"); return }
        start()
    }
    private func start() {
        guard let resources = Bundle.main.resourceURL else { return }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let node = resources.appendingPathComponent("MatterRuntime/\(arch)/bin/node")
        let script = resources.appendingPathComponent("MatterBridge/src/main.js")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: script.path) else {
            failed = true; status = L10n.tr("安装包缺少 Matter 组件，请重新安装完整版本", "Matter components missing. Reinstall the full app."); return
        }
        do {
            let storage = storageDirectory
            let child = Process(), toChild = Pipe(), fromChild = Pipe()
            let token = UUID(); generation = token
            child.executableURL = node
            child.arguments = [script.path, "--app", storage.path]
            child.standardInput = toChild; child.standardOutput = fromChild
            // Protocol diagnostics never contain the device configuration or credentials.
            child.standardError = FileHandle.nullDevice
            input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading
            output?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.receive(data)
                }
            }
            let temporary = ephemeral
            child.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    if temporary, self == nil || self?.isShuttingDown == true {
                        try? FileManager.default.removeItem(at: storage)
                    }
                    guard let self, self.generation == token else { return }
                    self.stop(); self.failed = true
                    self.status = L10n.tr("Matter 已停止，请重试", "Matter stopped. Please retry.")
                }
            }
            process = child
            status = L10n.tr("正在启动…", "Starting…")
            try child.run()
        } catch {
            stop(); failed = true; status = L10n.tr("Matter 启动失败，请重试", "Matter could not start. Please retry.")
        }
    }
    private struct Message: Decodable {
        var event: String?; var code: String?; var uri: String?; var paired: Bool?
        var id: Int?; var method: String?; var did: String?; var on: Bool?; var property: String?; var value: JSONValue?
    }
    private struct Reply: Encodable { var id: Int; var devices: [MatterDevicePlan.Device]?; var error: String? }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 1_048_576 else { stop(); failed = true; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(Message.self, from: line) else { continue }
            if message.event == "ready" {
                isRunning = true; isPaired = message.paired ?? false
                setupCode = message.code; setupURI = message.uri
                status = isPaired ? L10n.tr("已配对", "Paired") : L10n.tr("等待配对", "Ready to pair")
                updateAwake()
            } else if let id = message.id {
                let token = generation
                Task {
                    var reply = Reply(id: id)
                    do {
                        reply.devices = try await handleRPC(method: message.method, did: message.did,
                            value: message.value ?? message.on.map(JSONValue.bool), property: message.property)
                    } catch { reply.error = "Device operation failed" }
                    guard generation == token, var bytes = try? JSONEncoder().encode(reply) else { return }
                    bytes.append(10); try? input?.write(contentsOf: bytes)
                }
            }
        }
    }
    // A snapshot reads the shared cache only. It must never trigger a second LAN polling loop.
    func handleRPC(method: String?, did: String? = nil, value: JSONValue? = nil, property: String? = nil) async throws -> [MatterDevicePlan.Device] {
        guard let controller else { throw DeviceControlError.offline }
        switch method {
        case "snapshot": break
        case "set":
            guard let did, selected.contains(where: { $0.did == did }), let value else { throw DeviceControlError.unsupported("Matter") }
            try await MatterDevicePlan.execute(controller: controller, endpoint: did, property: property ?? "on", value: value)
        default: throw DeviceControlError.unsupported("RPC")
        }
        return selected
    }
    private func updateAwake() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if isRunning && keepsMacAwake {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "MijiaLAN Matter bridge")
        }
    }
    func stop() {
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; buffer = Data()
        if let child = process, child.isRunning { child.terminate() }
        process = nil; isRunning = false; isPaired = false; setupCode = nil; setupURI = nil
        status = L10n.tr("已关闭", "Off"); updateAwake()
    }
    func shutdown() {
        monitor?.cancel(); monitor = nil
        isShuttingDown = true
        let hasChild = process?.isRunning == true
        stop()
        if ephemeral && !hasChild { try? FileManager.default.removeItem(at: storageDirectory) }
    }
}
