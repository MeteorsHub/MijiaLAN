import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

private actor ResetNoNetwork: MiioTransport {
    private(set) var calls = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        calls += 1; throw MiioError.timeout
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        calls += 1; return []
    }
}

@MainActor struct MatterPairingResetTests {
    @MainActor private final class Children { var processes: [Process] = [] }
    @MainActor private struct Fixture {
        let folder: URL
        let storage: URL
        let defaults: UserDefaults
        let suite: String
        let children: Children
        let transport: ResetNoNetwork
        let api: LANMiotAPI
        let catalog: DeviceController
        let bridge: MatterBridgeController
        var node: URL { storage.appendingPathComponent("mijialan") }
        var original: URL { node.appendingPathComponent("fabric.mock") }
        func releaseExit() { _ = FileManager.default.createFile(atPath: storage.appendingPathComponent("allow-exit").path, contents: Data()) }
        func close() async throws {
            bridge.shutdown(); releaseExit()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while children.processes.contains(where: \.isRunning), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(children.processes.allSatisfy { !$0.isRunning })
            catalog.shutdown(); await api.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: folder)
        }
    }
    private func make(enabled: Bool = true, holdExit: Bool = false, replacement: String = "normal", exitBudget: Duration = .seconds(10)) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("matter-reset-" + UUID().uuidString)
        let storage = folder.appendingPathComponent("Matter"), node = storage.appendingPathComponent("mijialan")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("original-fabric".utf8).write(to: node.appendingPathComponent("fabric.mock"))
        try Data().write(to: node.appendingPathComponent("paired"))
        try Data("commissioning-fixture".utf8).write(to: storage.appendingPathComponent("commissioning.json"))
        try Data("homekit-fixture".utf8).write(to: folder.appendingPathComponent("HomeKit.mock"))
        let script = folder.appendingPathComponent("sidecar.sh")
        try Data("""
        #!/bin/sh
        mkdir -p "$1/mijialan"
        paired=false; code=12345678901; uri=MT:TEST
        if [ -f "$1/mijialan/paired" ]; then paired=true; fi
        if [ "$2" -gt 0 ]; then
          case "$4" in
            paired) paired=true ;;
            codes) code=bad; uri=bad ;;
            exit) exit 4 ;;
            hold-new) paired=true ;;
            wait) while :; do if ! IFS= read -r line; then exit 0; fi; done ;;
          esac
        fi
        trap 'touch "$1/mijialan/exited-before-move"; exit 0' TERM
        if { [ "$3" = hold ] && [ "$2" = 0 ]; } || { [ "$4" = hold-new ] && [ "$2" -gt 0 ]; }; then trap '' TERM; fi
        printf '{"event":"ready","paired":%s,"code":"%s","uri":"%s"}\\n' "$paired" "$code" "$uri"
        if { [ "$3" = hold ] && [ "$2" = 0 ]; } || { [ "$4" = hold-new ] && [ "$2" -gt 0 ]; }; then
          while [ ! -f "$1/allow-exit" ]; do sleep 0.05; done
        else
          while IFS= read -r line; do :; done
        fi
        touch "$1/mijialan/exited-before-move"
        """.utf8).write(to: script)
        let suite = "matter-reset-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(enabled, forKey: "matter.enabled")
        defaults.set(["excluded"], forKey: "matter.excluded")
        defaults.set(true, forKey: "homekit_bridge_enabled")
        defaults.set("dark", forKey: "appearance")
        let children = Children(), transport = ResetNoNetwork()
        let device = LocalDevice(did: "1", name: "Mock", model: "yeelink.light.lamp4", host: "192.0.2.1", token: String(repeating: "0", count: 32))
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: transport)
        let catalog = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        let bridge = MatterBridgeController(defaults: defaults, storageDirectory: storage,
            resetTimeouts: .init(exit: exitBudget, ready: .seconds(20)), makeProcess: { storage in
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/bin/sh")
                child.arguments = [script.path, storage.path, String(children.processes.count), holdExit ? "hold" : "normal", replacement]
                children.processes.append(child)
                return child
            })
        bridge.attach(catalog)
        let f = Fixture(folder: folder, storage: storage, defaults: defaults, suite: suite, children: children,
                        transport: transport, api: api, catalog: catalog, bridge: bridge)
        if enabled { try await until { bridge.isRunning }; #expect(bridge.isPaired) }
        return f
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func preserved(_ f: Fixture) async throws {
        #expect(try Data(contentsOf: f.storage.appendingPathComponent("commissioning.json")) == Data("commissioning-fixture".utf8))
        #expect(try Data(contentsOf: f.folder.appendingPathComponent("HomeKit.mock")) == Data("homekit-fixture".utf8))
        #expect(f.defaults.bool(forKey: "homekit_bridge_enabled"))
        #expect(f.defaults.string(forKey: "appearance") == "dark")
        #expect(!f.bridge.includes("excluded") && f.bridge.includes("1"))
        #expect(f.catalog.snapshots["1"]?.device.name == "Mock")
        #expect(await f.transport.calls == 0)
    }

    @Test("Reset waits for old exit, privately backs up only the node, and restarts unpaired with usable codes")
    func success() async throws {
        let f = try await make()
        defer { f.bridge.shutdown(); f.releaseExit() }
        #expect(await f.bridge.resetPairing())
        #expect(f.children.processes.count == 2 && !f.children.processes[0].isRunning)
        #expect(f.bridge.isRunning && !f.bridge.isPaired && !f.bridge.isResetting)
        #expect(f.bridge.setupCode == "12345678901" && f.bridge.setupURI == "MT:TEST")
        let backup = try #require(f.bridge.resetBackupURL)
        #expect(try Data(contentsOf: backup.appendingPathComponent("fabric.mock")) == Data("original-fabric".utf8))
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("exited-before-move").path))
        #expect(!FileManager.default.fileExists(atPath: f.original.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.deletingLastPathComponent().path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(f.bridge.resetError == nil && f.bridge.resetMessage != nil)
        try await preserved(f); try await f.close()
    }
    @Test("Resetting a disabled bridge retains the switch and does not launch a child")
    func disabled() async throws {
        let f = try await make(enabled: false)
        defer { f.bridge.shutdown(); f.releaseExit() }
        #expect(await f.bridge.resetPairing())
        #expect(f.children.processes.isEmpty && !f.bridge.isEnabled && !f.bridge.isRunning)
        #expect(f.bridge.setupCode == nil && f.bridge.setupURI == nil)
        try await preserved(f); try await f.close()
    }
    @Test("Storage failure preserves original data and keeps automatic reconcile from restarting")
    func storageFailure() async throws {
        let f = try await make()
        defer { f.bridge.shutdown(); f.releaseExit() }
        try Data("not-a-directory".utf8).write(to: f.storage.appendingPathComponent("PairingBackups"))
        #expect(!(await f.bridge.resetPairing()))
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        #expect(f.bridge.resetError != nil && !f.bridge.isRunning)
        f.bridge.reconcile()
        #expect(f.children.processes.count == 1)
        try await preserved(f); try await f.close()
    }
    @Test("Failed startup, invalid codes and leftover fabrics restore the original store", arguments: ["paired", "codes", "exit"])
    func rollback(replacement: String) async throws {
        let f = try await make(replacement: replacement)
        defer { f.bridge.shutdown(); f.releaseExit() }
        #expect(!(await f.bridge.resetPairing()))
        #expect(f.children.processes.count == 2 && f.children.processes.allSatisfy { !$0.isRunning })
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        #expect(f.bridge.resetError != nil && !f.bridge.isRunning)
        f.bridge.reconcile(); #expect(f.children.processes.count == 2)
        try await preserved(f); try await f.close()
    }
    @Test("A non-exiting child prevents any storage move; reset never kills it forcibly")
    func exitTimeout() async throws {
        let f = try await make(holdExit: true, exitBudget: .milliseconds(150))
        defer { f.bridge.shutdown(); f.releaseExit() }
        #expect(!(await f.bridge.resetPairing()))
        #expect(f.children.processes.count == 1 && f.children.processes[0].isRunning)
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("PairingBackups").path))
        #expect(f.bridge.resetError != nil)
        try await preserved(f); try await f.close()
    }
    @Test("Cancelling before confirmation leaves the running bridge and data intact")
    func cancelledBeforeStart() async throws {
        let f = try await make()
        defer { f.bridge.shutdown(); f.releaseExit() }
        let operation = Task { await f.bridge.resetPairing() }
        operation.cancel()
        #expect(!(await operation.value))
        #expect(f.bridge.isPaired && f.bridge.isRunning && f.children.processes.count == 1)
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        try await preserved(f); try await f.close()
    }
    @Test("A failed fresh child that cannot exit leaves the original backup recoverable and never restores under a writer")
    func failedRecoveryKeepsBackup() async throws {
        let f = try await make(replacement: "hold-new")
        defer { f.bridge.shutdown(); f.releaseExit() }
        #expect(!(await f.bridge.resetPairing()))
        let backup = try #require(f.bridge.resetBackupURL)
        #expect(try Data(contentsOf: backup.appendingPathComponent("fabric.mock")) == Data("original-fabric".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.original.path))
        #expect(f.children.processes.count == 2 && f.children.processes[1].isRunning)
        f.bridge.reconcile(); #expect(f.children.processes.count == 2)
        #expect(f.bridge.resetError != nil)
        try await preserved(f); try await f.close()
    }
    @Test("An active reset blocks duplicate resets, reconnect and writes; cancellation preserves original data")
    func cancelledWhileStopping() async throws {
        let f = try await make(holdExit: true)
        defer { f.bridge.shutdown(); f.releaseExit() }
        let operation = Task { await f.bridge.resetPairing() }
        try await until { f.bridge.isResetting }
        #expect(!(await f.bridge.resetPairing()))
        f.bridge.restart(); f.bridge.reconcile()
        #expect(f.children.processes.count == 1)
        await #expect(throws: DeviceControlError.self) {
            _ = try await f.bridge.handleRPC(method: "set", did: "1", value: .bool(true), property: "on")
        }
        _ = try await f.bridge.handleRPC(method: "snapshot")
        operation.cancel(); f.releaseExit()
        #expect(!(await operation.value))
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        #expect(f.children.processes.count == 1 && f.bridge.resetError == nil)
        try await preserved(f); try await f.close()
    }
    @Test("The latest enabled switch determines whether reset starts another sidecar")
    func switchChanged() async throws {
        let f = try await make(holdExit: true)
        defer { f.bridge.shutdown(); f.releaseExit() }
        let operation = Task { await f.bridge.resetPairing() }
        try await until { f.bridge.isResetting }
        f.bridge.isEnabled = false; f.releaseExit()
        #expect(await operation.value)
        #expect(f.children.processes.count == 1 && !f.bridge.isRunning && !f.bridge.isEnabled)
        try await preserved(f); try await f.close()
    }
    @Test("Shutdown during new startup restores the old node without restarting")
    func shutdownDuringReset() async throws {
        let f = try await make(replacement: "wait")
        defer { f.bridge.shutdown(); f.releaseExit() }
        let operation = Task { await f.bridge.resetPairing() }
        try await until { f.children.processes.count == 2 }
        f.bridge.shutdown()
        #expect(!(await operation.value))
        #expect(try Data(contentsOf: f.original) == Data("original-fabric".utf8))
        #expect(f.children.processes.allSatisfy { !$0.isRunning })
        try await preserved(f); try await f.close()
    }
}
