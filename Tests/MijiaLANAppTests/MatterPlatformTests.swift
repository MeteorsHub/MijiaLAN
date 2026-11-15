import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
struct MatterPlatformTests {
    @Test("Saved physical-device selection excludes and restores all grouped functions without any device query")
    func groupedSelection() async throws {
        let suite = "matter-group-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "homekit_bridge_enabled")
        let config = LocalHomeConfig(devices: [LocalDevice(did: "1", name: "Purifier", model: "zhimi.airpurifier.rma1",
            host: "192.0.2.1", token: String(repeating: "0", count: 32))])
        let network = MatterSelectionNoNetwork()
        let api = LANMiotAPI(config: { config }, transport: network)
        let catalog = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        let bridge = MatterBridgeController(defaults: defaults, ephemeral: true)
        bridge.attach(catalog)
        let expected = bridge.selected.map(\.did)
        #expect(Set(expected) == ["1", "1:temperature", "1:humidity"])
        #expect(bridge.selected.allSatisfy { $0.sourceID == "1" && $0.sourceName == "Purifier" })
        bridge.include("1", false)
        #expect(bridge.selected.isEmpty)
        let restored = MatterBridgeController(defaults: defaults, ephemeral: true)
        restored.attach(catalog)
        #expect(restored.selected.isEmpty)
        restored.include("1", true)
        #expect(restored.selected.map(\.did) == expected)
        #expect(defaults.bool(forKey: "homekit_bridge_enabled"))
        #expect(await network.calls == 0)
        bridge.shutdown(); restored.shutdown(); catalog.shutdown(); await api.shutdown()
    }
    @Test("Matter enabled and device selection persist without altering HomeKit settings")
    func independentPlatforms() throws {
        let suite = "matter-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "homekit_bridge_enabled")
        let matter = MatterBridgeController(defaults: defaults)
        #expect(!matter.isEnabled)
        matter.isEnabled = true
        matter.include("123", false)
        #expect(defaults.bool(forKey: "homekit_bridge_enabled"))
        let restored = MatterBridgeController(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(!restored.includes("123"))
        matter.isEnabled = false
        #expect(defaults.bool(forKey: "homekit_bridge_enabled"))
        matter.shutdown(); restored.shutdown()
    }
}

private actor MatterSelectionNoNetwork: MiioTransport {
    private(set) var calls = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data { calls += 1; throw MiioError.timeout }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { calls += 1; return [] }
}

@MainActor
struct MatterStorageSecurityTests {
    @Test("Ephemeral Matter storage is unique and never reuses the production pairing directory")
    func isolation() {
        let first = MatterBridgeController(ephemeral: true)
        let second = MatterBridgeController(ephemeral: true)
        let production = MatterBridgeController()
        #expect(first.storageDirectory != second.storageDirectory)
        #expect(first.storageDirectory != production.storageDirectory)
        #expect(first.storageDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: first.storageDirectory.path))
        first.shutdown(); second.shutdown(); production.shutdown()
    }
}
