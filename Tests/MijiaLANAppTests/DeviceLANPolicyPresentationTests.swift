import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
struct DeviceLANPolicyPresentationTests {
    @Test("Connectivity and unverified LAN readings are presented separately without trusting cached state")
    func connectivityAndReadings() throws {
        let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
        var snapshot = DeviceSnapshot(device: LocalDevice(did: "test", name: "Curtain", model: "dooya.motor.dc1545",
            host: "192.0.2.1", token: "test-only"), schema: schema,
            capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: "yeelink.light.lamp4"),
            health: LANDeviceHealth(state: .online))
        snapshot.readings["p:2:1"] = DeviceReading(value: .bool(true))
        #expect(snapshot.isOnline)
        #expect(DevicePresentation.summary(snapshot) == DeviceLANPolicy.unverifiedReadingsTitle)
        snapshot.health.state = .offline
        #expect(!snapshot.isOnline)
        #expect(DevicePresentation.summary(snapshot) == ConnectionIssue(health: snapshot.health).title)
        #expect(snapshot.lanReadingsRestriction != nil)
    }
}
