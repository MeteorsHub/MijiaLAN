import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

private actor SnapshotTransport: MiioTransport {
    var calls = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        calls += 1
        throw MiioError.timeout
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        calls += 1
        return []
    }
}

@MainActor struct MatterSnapshotPollingTests {
    @Test("Repeated Matter snapshots consume the shared cache without probing even an unexported curtain")
    func noExtraPolls() async throws {
        let transport = SnapshotTransport()
        let config = LocalHomeConfig(devices: [
            LocalDevice(did: "1", name: "Light", model: "yeelink.light.lamp4", host: "192.0.2.1", token: String(repeating: "0", count: 32)),
            LocalDevice(did: "2", name: "Curtain", model: CurtainValidationSession.model, host: "192.0.2.2", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)])
        let api = LANMiotAPI(config: { config }, transport: transport)
        let controller = DeviceController(api: api, config: { config })
        let suite = "matter-cache-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let matter = MatterBridgeController(defaults: defaults, ephemeral: true)
        matter.attach(controller)
        defer { matter.shutdown(); controller.shutdown() }
        for _ in 0..<8 {
            let devices = try await matter.handleRPC(method: "snapshot")
            #expect(devices.contains { $0.did == "1" })
            #expect(!devices.contains { $0.did == "2" })
            #expect(devices.allSatisfy { !$0.reachable })
        }
        #expect(await transport.calls == 0)
    }
}
