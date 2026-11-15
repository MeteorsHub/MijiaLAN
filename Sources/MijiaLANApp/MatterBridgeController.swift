import Foundation
import MijiaLAN
import MijiaCore
import Observation

/// A supervised Matter child; every write shares the App's DeviceController with HomeKit and local controls.
@MainActor @Observable
final class MatterBridgeController {
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "matter.enabled"); if !isResetting { if isEnabled { restart() } else { stop() } } } }
    var keepsMacAwake: Bool { didSet { defaults.set(keepsMacAwake, forKey: "matter.awake"); updateAwake() } }
    private(set) var status = L10n.tr("已关闭", "Off")
    private(set) var setupCode: String?
    private(set) var setupURI: String?
    private(set) var isPaired = false
    private(set) var isRunning = false
    private(set) var isResetting = false
    private(set) var resetError: String?
    private(set) var resetMessage: String?
    private(set) var resetBackupURL: URL?
    private(set) var excluded: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    let storageDirectory: URL
    @ObservationIgnored private let ephemeral: Bool
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var controller: DeviceController?
    @ObservationIgnored private weak var curtains: CurtainControlController?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var retiring: [UUID: Process] = [:]
    @ObservationIgnored private let makeProcess: @MainActor (URL) throws -> Process
    @ObservationIgnored private let resetTimeouts: ResetTimeouts
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var output: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastPairingReport: Bool?

    struct ResetTimeouts {
        var exit: Duration = .seconds(10)
        var ready: Duration = .seconds(20)
    }
    init(defaults: UserDefaults = .standard, ephemeral: Bool = false, storageDirectory: URL? = nil,
         resetTimeouts: ResetTimeouts = .init(), makeProcess: (@MainActor (URL) throws -> Process)? = nil) {
        self.defaults = defaults
        self.ephemeral = ephemeral
        self.resetTimeouts = resetTimeouts
        self.makeProcess = makeProcess ?? Self.bundledProcess
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if ephemeral {
            self.storageDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MijiaLAN-Matter-\(UUID().uuidString)", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.storageDirectory = support.appendingPathComponent("MijiaLAN/Matter", isDirectory: true)
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
    func attach(_ controller: DeviceController, curtains: CurtainControlController? = nil) {
        self.controller = controller
        self.curtains = curtains
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    var supported: [MatterDevicePlan.Entry] {
        controller.map { MatterDevicePlan.entries(Array($0.snapshots.values), managedCoverings: curtains?.matterCoverings ?? [:]) } ?? []
    }
    var selected: [MatterDevicePlan.Device] { supported.filter { includes($0.sourceID) }.map(\.device) }
    func restart() {
        guard !isResetting, !isShuttingDown else { return }
        resetError = nil; stop(); failed = false
    }
    private func pruneRetiring() { retiring = retiring.filter { $0.value.isRunning } }
    func reconcile() {
        guard isEnabled, !isResetting, !isShuttingDown, resetError == nil else { return }
        pruneRetiring()
        guard retiring.isEmpty else { return }
        let next = selected.map { ($0.sourceID ?? $0.did) + ":" + $0.did + ":" + $0.kind }.joined(separator: "|")
        if next != signature { stop(); signature = next; failed = false }
        guard process == nil, !failed else { return }
        guard !selected.isEmpty else { status = L10n.tr("等待可桥接设备", "Waiting for supported devices"); return }
        start()
    }
    private static func bundledProcess(storage: URL) throws -> Process {
        guard let resources = Bundle.main.resourceURL else { throw ResetFailure.runtimeMissing }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let node = resources.appendingPathComponent("MatterRuntime/\(arch)/bin/node")
        let script = resources.appendingPathComponent("MatterBridge/src/main.js")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: script.path) else {
            throw ResetFailure.runtimeMissing
        }
        let child = Process()
        child.executableURL = node
        child.arguments = [script.path, "--app", storage.path]
        return child
    }
    private func start(duringReset: Bool = false) {
        pruneRetiring()
        guard process == nil, retiring.isEmpty, !isShuttingDown, !isResetting || duringReset else { return }
        do {
            let storage = storageDirectory
            let child = try makeProcess(storage), toChild = Pipe(), fromChild = Pipe()
            let token = UUID(); generation = token
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
                    self?.retiring[token] = nil
                    if temporary, self == nil || (self?.isShuttingDown == true && self?.isResetting == false && self?.process == nil && self?.retiring.isEmpty == true) {
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
            stop(); failed = true
            status = (error as? ResetFailure)?.errorDescription ?? L10n.tr("Matter 启动失败，请重试", "Matter could not start. Please retry.")
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
                lastPairingReport = message.paired
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
            guard !isResetting, !isShuttingDown else { throw DeviceControlError.busy }
            guard let did, selected.contains(where: { $0.did == did }), let value else { throw DeviceControlError.unsupported("Matter") }
            try await DeviceCommunicationContext.$source.withValue(.matter) {
                try await DeviceCommunicationContext.$operation.withValue(UUID()) {
                    if let entry = supported.first(where: { $0.device.did == did }), entry.device.kind == "windowCovering" {
                        guard let curtains else { throw DeviceControlError.unsupported("Covering driver") }
                        let command: CurtainControlSession.Command
                        switch property {
                        case "position":
                            guard case .number(let n) = value, let position = Int(exactly: n), (0...100).contains(position) else { throw DeviceControlError.invalidValue("position") }
                            command = .position(position)
                        case "open", "close", "stop":
                            guard value == .bool(true) else { throw DeviceControlError.invalidValue("Covering command") }
                            command = property == "open" ? .open : property == "close" ? .close : .stop
                        default: throw DeviceControlError.unsupported("Covering command")
                        }
                        _ = try await curtains.execute(entry.sourceID, command)
                    } else {
                        try await MatterDevicePlan.execute(controller: controller, endpoint: did, property: property ?? "on", value: value)
                    }
                }
            }
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

    private enum ResetFailure: LocalizedError {
        case runtimeMissing, exitTimeout, readyTimeout, noDevices, stillPaired, invalidCodes
        case startup(String)
        var errorDescription: String? {
            switch self {
            case .runtimeMissing: L10n.tr("安装包缺少 Matter 组件，请重新安装完整版本。", "Matter components are missing. Reinstall the full App.")
            case .exitTimeout: L10n.tr("Matter 子进程尚未退出，不能安全处理配对存储。", "The Matter child has not exited; pairing storage cannot be changed safely.")
            case .readyTimeout: L10n.tr("新的 Matter 桥接未在限定时间内就绪。", "The new Matter bridge did not become ready within the time limit.")
            case .noDevices: L10n.tr("请先选择至少一个可桥接设备，再重置已启用的 Matter 桥接。", "Select at least one supported device before resetting an enabled Matter bridge.")
            case .stillPaired: L10n.tr("新的 Matter 桥接未确认配对已清空。", "The new Matter bridge did not confirm empty pairing state.")
            case .invalidCodes: L10n.tr("新的 Matter 桥接未提供有效配对码。", "The new Matter bridge did not provide valid pairing codes.")
            case .startup(let reason): reason
            }
        }
    }
    private func waitForChildrenExit(allowShutdown: Bool = false) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: resetTimeouts.exit)
        while true {
            try Task.checkCancellation()
            if isShuttingDown && !allowShutdown { throw CancellationError() }
            pruneRetiring()
            if retiring.isEmpty && process?.isRunning != true { return }
            guard clock.now < deadline else { throw ResetFailure.exitTimeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func waitForNewBridge() async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: resetTimeouts.ready)
        while !isRunning {
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            if !isEnabled { return }
            if failed { throw ResetFailure.startup(status) }
            guard clock.now < deadline else { throw ResetFailure.readyTimeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func resetReason(_ error: any Error) -> String {
        if let known = error as? ResetFailure { return known.errorDescription ?? status }
        if let known = error as? MatterPairingResetStore.Failure { return known.errorDescription ?? status }
        if let file = error as? CocoaError, [.fileReadNoPermission, .fileWriteNoPermission].contains(file.code) {
            return L10n.tr("没有权限访问 Matter 存储或备份目录。", "Permission to access Matter storage or its backup was denied.")
        }
        return L10n.tr("无法移动 Matter 节点存储，请检查本机磁盘空间和文件权限。", "Could not move Matter node storage. Check local disk space and permissions.")
    }

    /// Explicit destructive action only. Never entered by reconnect, polling or ordinary App startup.
    @discardableResult func resetPairing() async -> Bool {
        guard !isResetting, !isShuttingDown, !Task.isCancelled else { return false }
        guard !isEnabled || !selected.isEmpty else { resetError = ResetFailure.noDevices.errorDescription; return false }
        isResetting = true; resetError = nil; resetMessage = nil; resetBackupURL = nil
        status = L10n.tr("正在停止 Matter 并重置配对…", "Stopping Matter and resetting pairing…")
        let store = MatterPairingResetStore(root: storageDirectory)
        var checkpoint: MatterPairingResetStore.Checkpoint?
        defer {
            isResetting = false
            pruneRetiring()
            if ephemeral && isShuttingDown && retiring.isEmpty && process == nil { try? FileManager.default.removeItem(at: storageDirectory) }
        }
        do {
            stop()
            try await waitForChildrenExit()
            try Task.checkCancellation()
            checkpoint = try store.archive()
            try Task.checkCancellation()
            if isEnabled {
                signature = selected.map { ($0.sourceID ?? $0.did) + ":" + $0.did + ":" + $0.kind }.joined(separator: "|")
                failed = false
                start(duringReset: true)
                try await waitForNewBridge()
                try Task.checkCancellation()
                if isShuttingDown { throw CancellationError() }
            }
            if isEnabled {
                guard lastPairingReport == false else { throw ResetFailure.stillPaired }
                let code = setupCode ?? ""
                guard [11, 21].contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }),
                      setupURI?.hasPrefix("MT:") == true else { throw ResetFailure.invalidCodes }
            } else {
                stop(); try await waitForChildrenExit()
                status = L10n.tr("已关闭", "Off")
            }
            resetBackupURL = checkpoint?.archive
            resetMessage = L10n.tr("Matter 配对已重置。请在所用平台重新添加此桥接；平台内可能仍有需要移除的旧条目。", "Matter pairing was reset. Add this bridge again in your platforms; they may still contain old entries to remove.")
            failed = false
            return true
        } catch {
            stop()
            // Cancellation must not cancel cleanup: never restore while a fresh child can still write.
            let cleanup = Task { @MainActor in try await self.waitForChildrenExit(allowShutdown: true) }
            do {
                try await cleanup.value
                if let checkpoint { try store.restore(checkpoint) }
                if error is CancellationError {
                    resetMessage = L10n.tr("重置已取消，原 Matter 配对资料已保留。", "Reset cancelled. The original Matter pairing data was retained.")
                } else {
                    resetError = resetReason(error) + L10n.tr(" 原 Matter 资料已保留，可重新连接。", " Original Matter data was retained; you can reconnect.")
                }
            } catch let recoveryError {
                resetBackupURL = checkpoint?.archive
                resetError = resetReason(error) + " " + resetReason(recoveryError) + L10n.tr(" 请先退出应用；原配对备份仍保留在本机。", " Quit the App first; the original pairing backup remains local.")
            }
            failed = true
            status = L10n.tr("Matter 配对重置未完成", "Matter pairing reset did not finish")
            return false
        }
    }
    func stop() {
        let previousGeneration = generation
        generation = UUID()
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; buffer = Data()
        if let child = process, child.isRunning {
            retiring[previousGeneration] = child
            child.terminate()
        }
        process = nil; isRunning = false; isPaired = false; lastPairingReport = nil; setupCode = nil; setupURI = nil
        if !isResetting { status = L10n.tr("已关闭", "Off") }
        updateAwake()
    }
    func shutdown() {
        monitor?.cancel(); monitor = nil
        isShuttingDown = true
        stop()
        pruneRetiring()
        if ephemeral && retiring.isEmpty && !isResetting { try? FileManager.default.removeItem(at: storageDirectory) }
    }
}
