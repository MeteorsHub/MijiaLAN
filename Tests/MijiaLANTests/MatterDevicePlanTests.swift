import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct MatterDevicePlanTests {
    func snapshot(_ model: String) throws -> DeviceSnapshot {
        let schema = try #require(DeviceSchema.bundled(model: model))
        return DeviceSnapshot(device: LocalDevice(did: "123", name: "Test", model: model, host: "192.0.2.1", token: "private"),
            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model), health: LANDeviceHealth(state: .online))
    }
    @Test("Lights retain brightness and convert Kelvin to mireds")
    func light() throws {
        var s = try snapshot("yeelink.light.lamp4")
        for (name, value) in [("on", JSONValue.bool(true)), ("brightness", .number(50)), ("color-temperature", .number(4000))] {
            let cap = try #require(s.capability("light", name)); s.readings[cap.id] = DeviceReading(value: value)
        }
        let device = try #require(MatterDevicePlan.devices([s]).first)
        #expect(device.kind == "colorTemperatureLight")
        #expect(device.attributes["level"] == .number(50))
        #expect(device.attributes["colorTemperature"] == .number(250))
        #expect(device.reachable)
    }
    @Test("Fans and purifiers map independently of kitchen controls")
    func families() throws {
        #expect(MatterDevicePlan.devices([try snapshot("dmaker.fan.p28")]).contains { $0.kind == "fan" })
        #expect(MatterDevicePlan.devices([try snapshot("zhimi.airpurifier.rma1")]).contains { $0.kind == "airPurifier" })
        #expect(!MatterDevicePlan.devices([try snapshot("careli.fryer.maf07c")]).contains { $0.kind == "outlet" })
        #expect(MatterDevicePlan.devices([try snapshot("dmaker.fan.p28")]).allSatisfy { !$0.reachable })
    }
    @Test("Sensor endpoints have stable independent identities and correct units")
    func sensors() throws {
        var s = try snapshot("zhimi.airpurifier.rma1")
        for cap in s.capabilities where cap.name == "temperature" || cap.name == "relative-humidity" {
            s.readings[cap.id] = DeviceReading(value: .number(25))
        }
        let devices = MatterDevicePlan.devices([s])
        #expect(Set(devices.map(\.did)).count == devices.count)
        for d in devices where d.kind == "temperature" || d.kind == "humidity" {
            #expect(d.attributes[d.kind] == .number(2500))
            #expect(d.did.hasPrefix("123:"))
        }
    }
}
