import Foundation
import MijiaLAN
import Testing
@testable import mijia_lan

struct MatterRPCTests {
    private func snapshot(_ model: String) throws -> DeviceSnapshot {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let device = LocalDevice(did: "123", name: "Matter test", model: model,
                                 host: "192.0.2.1", token: "private-token")
        return DeviceSnapshot(device: device, schema: schema,
                              capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
    }

    @Test("Reviewed device families expose independent primary endpoints", arguments: DeviceSchema.bundledModels)
    func supportedModels(_ model: String) throws {
        let s = try snapshot(model)
        let expected = ["light", "outlet", "fan", "air-purifier"].contains(s.schema.category)
        #expect(MatterRPC.devices([s]).contains { $0.did == "123" } == expected)
        #expect(MatterRPC.devices([s]).allSatisfy { !$0.did.isEmpty })
    }

    @Test("RPC projection contains no LAN credentials; missing readings are unreachable")
    func privateProjection() throws {
        let s = try snapshot("yeelink.light.lamp4")
        let devices = MatterRPC.devices([s])
        let d = try #require(devices.first)
        #expect(!d.reachable)
        #expect(d.on == nil)
        let data = try JSONEncoder().encode(MatterRPC.Reply(id: 7, devices: devices))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(Set(encoded.keys) == ["did", "name", "kind", "reachable", "attributes"])
        #expect(!String(decoding: data, as: UTF8.self).contains("private-token"))
        #expect(!String(decoding: data, as: UTF8.self).contains("192.0.2.1"))
    }
}

@MainActor struct MatterPollingScopeTests {
    @Test("Standalone Matter polling excludes unexported devices before any probing starts")
    func boundedScope() {
        let config = LocalHomeConfig(devices: [
            LocalDevice(did: "1", name: "Light", model: "yeelink.light.lamp4", host: "192.0.2.1", token: "test-only"),
            LocalDevice(did: "2", name: "Curtain", model: CurtainValidationSession.model, host: "192.0.2.2", token: "test-only", specType: CurtainValidationSession.specification),
            LocalDevice(did: "3", name: "Unknown", model: "unknown.test", host: "192.0.2.3", token: "test-only")])
        let bounded = MatterRPC.pollingConfiguration(config)
        #expect(bounded.devices.map(\.did) == ["1"])
        #expect(bounded.devices[0] == config.devices[0])
        #expect(config.devices.count == 3)
    }
}
