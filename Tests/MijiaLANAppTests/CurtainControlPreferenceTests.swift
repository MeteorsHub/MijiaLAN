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
    private var preview: ControlCenterPreviewTransport
    var count = 0
    init(failReadback: Bool = false) { preview = ControlCenterPreviewTransport(failReadback: failReadback) }
    func recover() { preview = ControlCenterPreviewTransport() }
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
    private func make(_ defaults: UserDefaults, transport: CountedPreview, now: @escaping () -> Date = { Date() }) -> (CurtainControlController, DeviceController, LANMiotAPI) {
        let config = LocalHomeConfig(devices: [device()])
        let api = LANMiotAPI(config: { config }, transport: transport)
        let clock = PollingCurtainClock(), scheduler = CurtainRequestScheduler(clock: clock.clock)
        let curtains = CurtainControlController(api: api, defaults: defaults, now: now, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        curtains.reconcile(config.devices)
        let devices = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        devices.refreshCurtains = { [weak curtains] in await curtains?.pollConfigured() }
        return (curtains, devices, api)
    }
    private func idle(_ controller: CurtainControlController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.isWorking(device().did), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!controller.isWorking(device().did))
    }
    @Test("Absent or legacy disabled/paused preferences never gate automatic reads or normal controls")
    func migration() async throws {
        for legacy in [false, true] {
            let suite = "curtain-migration-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if legacy {
                defaults.set([String](), forKey: CurtainControlController.preferenceKey)
                defaults.set([device().did: "propertyError"], forKey: CurtainControlController.pausedKey)
            }
            defaults.set("unchanged", forKey: "unrelated.pairing.fixture")
            let network = CountedPreview(), (curtains, devices, api) = make(defaults, transport: network)
            #expect(await network.count == 0) // Configuration alone does not send; the unified round does.
            #expect(defaults.object(forKey: CurtainControlController.preferenceKey) == nil)
            #expect(defaults.object(forKey: CurtainControlController.pausedKey) == nil)
            #expect(defaults.string(forKey: "unrelated.pairing.fixture") == "unchanged")
            await devices.refreshNow()
            #expect(curtains.states[device().did]?.position == 29)
            #expect(curtains.send(device().did, .position(64)))
            try await idle(curtains)
            #expect(curtains.states[device().did]?.position == 64)
            #expect(api.curtainEvents.snapshot().filter { $0.kind == .write && $0.outcome == .attempt }.count == 1)
            let before = await network.count
            for _ in 0..<12 { await devices.refreshNow() }
            #expect(await network.count > before)
            devices.setPollingIntervals(.init(foregroundSeconds: 8, backgroundSeconds: 45))
            curtains.shutdown(); devices.shutdown(); await api.shutdown()
            let next = CountedPreview(), (restored, nextDevices, nextAPI) = make(defaults, transport: next)
            #expect(nextDevices.pollingIntervals == .init(foregroundSeconds: 8, backgroundSeconds: 45))
            await nextDevices.refreshNow()
            #expect(restored.states[device().did]?.position == 29)
            restored.shutdown(); nextDevices.shutdown(); await nextAPI.shutdown()
        }
    }
    @Test("Failed confirmation ends the write; shared polling uses standard backoff and recovers without manual unlocking")
    func backoffAndRecovery() async throws {
        let suite = "curtain-retry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1000)
        let network = CountedPreview(failReadback: true)
        let (curtains, devices, api) = make(defaults, transport: network, now: { now })
        #expect(curtains.send(device().did, .position(64)))
        try await idle(curtains)
        #expect(curtains.readFailures[device().did] == .propertyError)
        #expect(curtains.states[device().did]?.position == nil && curtains.errors[device().did] != nil)
        let before = await network.count
        for _ in 0..<12 { await devices.refreshNow() }
        #expect(await network.count == before)
        #expect(curtains.retryStates[device().did]?.nextRetryAt == now.addingTimeInterval(20))
        now.addTimeInterval(20)
        await devices.refreshNow() // Still faulty: one bounded round, no write retry, then 40-second backoff.
        #expect(curtains.retryStates[device().did]?.consecutiveFailures == 2)
        #expect(curtains.retryStates[device().did]?.nextRetryAt == now.addingTimeInterval(40))
        await network.recover(); now.addTimeInterval(40)
        await devices.refreshNow()
        #expect(curtains.readFailures[device().did] == nil && curtains.retryStates[device().did] == nil)
        #expect(curtains.errors[device().did] == nil && curtains.states[device().did]?.message == nil)
        #expect(curtains.states[device().did]?.position == 29)
        #expect(api.curtainEvents.snapshot().filter { $0.kind == .write && $0.outcome == .attempt }.count == 1)
        #expect(defaults.object(forKey: CurtainControlController.pausedKey) == nil)
        curtains.shutdown(); devices.shutdown(); await api.shutdown()
    }
}
