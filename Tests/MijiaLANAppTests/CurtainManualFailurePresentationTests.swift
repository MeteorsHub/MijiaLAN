import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN
@testable import MijiaLANApp

private final class PresentationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.value } }, sleep: { amount in
        try Task.checkCancellation(); self.lock.withLock { self.value += amount }; await Task.yield()
    }) }
}
@MainActor struct CurtainManualFailurePresentationTests {
    @Test("A simulated readback failure clears busy, exposes confirmation stage/reason, and retains only an expired old position")
    func explicitFailureIsVisible() async throws {
        let suite = "curtain-error-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = LocalDevice(did: "123", name: "Simulated Curtain", model: CurtainValidationSession.model,
                                 host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let config = LocalHomeConfig(devices: [device])
        let journal = DeviceEventLog(scope: .offlineTest)
        let transport = ControlCenterPreviewTransport(failReadback: true)
        let api = LANMiotAPI(config: { config }, transport: transport, curtainEvents: journal)
        let clock = PresentationClock(), scheduler = CurtainRequestScheduler(clock: clock.clock)
        let controller = CurtainControlController(api: api, defaults: defaults, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        controller.reconcile([device])
        #expect(journal.snapshot().allSatisfy { $0.outcome == .noPacket })
        controller.send(device.did, .position(64))
        let deadline = Date().addingTimeInterval(3)
        while controller.isWorking(device.did), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!controller.isWorking(device.did))
        let state = try #require(controller.states[device.did])
        #expect(state.stage == .confirmation && state.failureReason == .propertyError)
        #expect(state.position == nil && state.lastKnownPosition == 29 && state.lastKnownMotorStatus == 1)
        #expect(state.message != nil && controller.errors[device.did] != nil)
        #expect(journal.snapshot().contains { $0.source == .postWriteRead && $0.code == -4004 })
        controller.shutdown(); await api.shutdown()
    }
}
