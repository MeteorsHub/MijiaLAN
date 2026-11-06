import Foundation
import HAPCore
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

struct DeviceLANPolicyBridgeTests {
    @Test("Restricted model never bridges, even with a stale light schema and seemingly valid cached values")
    func staleSchema() throws {
        let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
        var snapshot = DeviceSnapshot(device: LocalDevice(did: "123", name: "Curtain", model: "dooya.motor.dc1545",
            host: "192.0.2.1", token: "test-only"), schema: schema,
            capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: "yeelink.light.lamp4"),
            health: LANDeviceHealth(state: .online))
        snapshot.readings["p:2:1"] = DeviceReading(value: .bool(true))
        snapshot.readings["p:2:2"] = DeviceReading(value: .number(50))
        #expect(MatterDevicePlan.entries([snapshot]).isEmpty)
        var ids: [String: UInt64] = ["previous": 12]
        let plan = CapabilityHomeKitMapper.plan(snapshot: snapshot, legacyDevice: nil, names: [:], identifiers: &ids)
        #expect(plan.services.isEmpty)
        #expect(plan.bindings.isEmpty)
        #expect(ids == ["previous": 12])
        #expect(throws: (any Error).self) {
            try CapabilityHomeKitMapper.commands(.property("p:2:1", .direct), value: .bool(true), snapshot: snapshot)
        }
        let legacy = SmartDevice(id: "123", name: "Curtain", roomId: "test", roomName: "Test",
            model: "dooya.motor.dc1545", isOnline: true, kind: .light(LightSpec(entityId: "test", isOn: true)))
        #expect(HomeKitAccessoryMapper.plan(for: legacy, name: legacy.name) == nil)
        #expect(HomeKitAccessoryMapper.write(.lightOn, value: .bool(false), to: legacy) == nil)
    }
}
