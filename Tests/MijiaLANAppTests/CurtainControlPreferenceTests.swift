import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN
@testable import MijiaLANApp

private final class PollingCurtainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.value } }, sleep: { amount in
        try Task.checkCancellation(); self.lock.withLock { self.value += amount }; await Task.yield()
    }) }
}
private actor CountedPreview: MiioTransport {
    private let preview: ControlCenterPreviewTransport
    var count = 0
    init(failReadback: Bool = false) { preview = ControlCenterPreviewTransport(failReadback: failReadback) }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        count += 1
        return try await preview.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { count += 1; return [] }
}

@MainActor struct CurtainControlPreferenceTests {
    private func device() -> LocalDevice {
        LocalDevice(did: "123", name: "Simulated Curtain", model: CurtainValidationSession.model,
            host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
    }
    private func make(_ defaults: UserDefaults, transport: CountedPreview) -> (CurtainControlController, DeviceController, LANMiotAPI) {
        let config = LocalHomeConfig(devices: [device()])
        let api = LANMiotAPI(config: { config }, transport: transport)
        let clock = PollingCurtainClock(), scheduler = CurtainRequestScheduler(clock: clock.clock)
        let curtains = CurtainControlController(api: api, defaults: defaults, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        curtains.reconcile(config.devices)
        let devices = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        devices.refreshCurtains = { [weak curtains] in await curtains?.pollConfigured() }
        return (curtains, devices, api)
    }
    @Test("A default unified round reads a curtain with controls off; opt-in and polling intervals persist without a separate startup timer")
    func preferences() async throws {
        let suite = "curtain-preferences-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let network = CountedPreview(), (curtains, devices, api) = make(defaults, transport: network)
        #expect(!curtains.includes(device().did))
        #expect(await network.count == 0)
        await devices.refreshNow()
        #expect(curtains.states[device().did]?.position == 29)
        #expect(!curtains.includes(device().did))
        #expect(!api.curtainEvents.snapshot().contains { $0.kind == .write || $0.kind == .action })
        let before = await network.count
        await devices.refreshNow()
        #expect(await network.count == before + 1)
        devices.setPollingIntervals(.init(foregroundSeconds: 8, backgroundSeconds: 45))
        curtains.setEnabled(device(), true)
        #expect(await network.count == before + 1)
        curtains.shutdown(); devices.shutdown(); await api.shutdown()
        let next = CountedPreview(), (restored, restoredDevices, restoredAPI) = make(defaults, transport: next)
        #expect(restored.includes(device().did))
        #expect(restoredDevices.pollingIntervals == .init(foregroundSeconds: 8, backgroundSeconds: 45))
        #expect(await next.count == 0)
        await restoredDevices.refreshNow()
        #expect(restored.states[device().did]?.position == 29)
        restored.shutdown(); restoredDevices.shutdown(); await restoredAPI.shutdown()
    }
    @Test("A failed readback pauses automatic polls across restart, and an explicit successful manual read restores them")
    func persistedPauseAndRecovery() async throws {
        let suite = "curtain-paused-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let network = CountedPreview(failReadback: true), (curtains, devices, api) = make(defaults, transport: network)
        curtains.setEnabled(device(), true)
        curtains.send(device().did, .position(64))
        for _ in 0..<5_000 { if !curtains.isWorking(device().did) { break }; await Task.yield() }
        #expect(curtains.pausedPolling[device().did] == .propertyError)
        let count = await network.count
        for _ in 0..<3 { await devices.refreshNow() }
        #expect(await network.count == count)
        curtains.shutdown(); devices.shutdown(); await api.shutdown()
        let next = CountedPreview(), (restored, restoredDevices, restoredAPI) = make(defaults, transport: next)
        #expect(restored.pausedPolling[device().did] == .propertyError)
        await restoredDevices.refreshNow()
        #expect(await next.count == 0)
        restored.read(device().did)
        for _ in 0..<5_000 { if !restored.isWorking(device().did) { break }; await Task.yield() }
        #expect(restored.pausedPolling[device().did] == nil)
        let afterManual = await next.count
        await restoredDevices.refreshNow()
        #expect(await next.count == afterManual + 1)
        restored.shutdown(); restoredDevices.shutdown(); await restoredAPI.shutdown()
    }
}
