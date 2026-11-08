import Foundation
import MijiaLAN
import Testing
@testable import MijiaLANApp

private actor NoCurtainTraffic: MiioTransport {
    var count = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data { count += 1; throw MiioError.timeout }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { count += 1; return [] }
}

@MainActor struct CurtainControlPreferenceTests {
    @Test("Per-device daily opt-ins persist, restore without startup communication, and are not cleared by shutdown")
    func preferences() async throws {
        let suite = "curtain-preferences-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = LocalDevice(did: "123", name: "Curtain", model: CurtainValidationSession.model,
            host: "192.0.2.1", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let config = LocalHomeConfig(devices: [device]), network = NoCurtainTraffic()
        let api = LANMiotAPI(config: { config }, transport: network)
        let controller = CurtainControlController(api: api, defaults: defaults)
        var prepareCalls = 0
        controller.prepare = { prepareCalls += 1 }
        #expect(!controller.includes(device.did))
        controller.setEnabled(device, true)
        #expect(controller.includes(device.did))
        #expect(defaults.stringArray(forKey: CurtainControlController.preferenceKey) == [device.did])
        controller.shutdown()
        let restored = CurtainControlController(api: api, defaults: defaults)
        restored.prepare = { prepareCalls += 1 }
        #expect(restored.includes(device.did))
        restored.reconcile(config.devices)
        // Exceeds the removed 30-second loop; uses only the in-memory transport.
        try await Task.sleep(for: .seconds(31))
        #expect(await network.count == 0)
        #expect(prepareCalls == 0)
        #expect(!restored.isWorking(device.did))
        restored.setEnabled(device, false)
        #expect(!restored.includes(device.did))
        #expect(defaults.stringArray(forKey: CurtainControlController.preferenceKey) == [])
        restored.shutdown(); await api.shutdown()
    }
}
