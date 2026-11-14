import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct MatterAppliancePlanTests {
    private func snapshot(_ fixture: String, model: String) throws -> DeviceSnapshot {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        let device = LocalDevice(did: "123", name: "Fixture", model: model, host: "test", token: "00112233445566778899aabbccddeeff", specType: schema.type)
        return DeviceSnapshot(device: device, schema: schema,
            capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model), health: LANDeviceHealth(state: .online))
    }

    @Test("A different model with the same heating capabilities gets a thermostat with Celsius limits and strict availability")
    func genericHeating() throws {
        var s = try snapshot("iot.tow_w.jd015", model: "test.generic.heater")
        s.readings["p:2:1"] = DeviceReading(value: .bool(true))
        s.readings["p:2:5"] = DeviceReading(value: .number(65))
        s.readings["p:2:6"] = DeviceReading(value: .number(59))
        let entry = try #require(MatterDevicePlan.entries([s]).first)
        #expect(entry.device.kind == "thermostat" && entry.device.reachable)
        #expect(entry.device.attributes["targetTemperature"] == .number(6500))
        #expect(entry.device.attributes["temperature"] == .number(5900))
        #expect(entry.device.attributes["targetTemperatureMin"] == .number(4000))
        #expect(entry.device.attributes["targetTemperatureMax"] == .number(6500))
        #expect(entry.device.attributes["targetTemperatureStep"] == .number(500))
        s.readings["p:2:5"] = DeviceReading(code: -4004, error: "rejected", rawValue: .number(65))
        #expect(MatterDevicePlan.entries([s]).first?.device.reachable == false)
        s.readings["p:2:5"] = DeviceReading(value: .bool(true)) // A code-zero type conflict remains unavailable.
        #expect(MatterDevicePlan.entries([s]).first?.device.reachable == false)
    }

    @Test("Heating never combines one service instance's power with another instance's target or sensor", arguments: ["target-temperature", "temperature"])
    func separateHeatingInstances(moved: String) throws {
        let original = try snapshot("iot.tow_w.jd015", model: "test.multichannel.heater")
        var schema = original.schema
        let serviceIndex = schema.services.firstIndex { $0.iid == 2 }
        let index = try #require(serviceIndex)
        var other = schema.services[index]
        other.iid = 20
        other.properties = other.properties.filter { $0.name == moved }
        schema.services[index].properties.removeAll { $0.name == moved }
        schema.services.append(other)
        let s = DeviceSnapshot(device: original.device, schema: schema,
            capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: original.device.model))
        let entries = MatterDevicePlan.entries([s])
        #expect(entries.first?.device.kind == "power")
        #expect(entries.first?.bindings["on"]?.id == "p:2:1")
        #expect(!entries.contains { $0.device.kind == "thermostat" })
    }

    @Test("Dehumidifier power and measurements are independent; unsupported humidity control is reported")
    func dehumidifier() throws {
        var s = try snapshot("xiaomi.derh.13l.v1", model: "test.generic.dehumidifier")
        s.readings["p:2:1"] = DeviceReading(value: .bool(false))
        s.readings["p:3:1"] = DeviceReading(value: .number(45))
        s.readings["p:3:2"] = DeviceReading(value: .number(22.1))
        let entries = MatterDevicePlan.entries([s])
        #expect(entries.map { $0.device.kind } == ["power", "temperature", "humidity"])
        #expect(entries.allSatisfy { $0.device.reachable })
        #expect(entries.first?.bindings["on"]?.id == "p:2:1")
        #expect(entries.first { $0.device.kind == "temperature" }?.device.attributes["temperature"] == .number(2210))
        let humidity = try #require(s.capabilitiesByID["p:2:5"])
        #expect(MatterDevicePlan.unmappedControls(s, entries: entries).contains(humidity.displayTitle))
    }

    @Test("Independent heater and light services remain independent on every model, without fabricating temperature")
    func separateLightAndHeat() throws {
        var s = try snapshot("giot.heater.v13daf", model: "test.generic.fireplace")
        s.readings["p:2:1"] = DeviceReading(value: .bool(false))
        s.readings["p:3:1"] = DeviceReading(value: .bool(true))
        let entries = MatterDevicePlan.entries([s])
        #expect(entries.map { $0.device.kind } == ["power", "light"])
        #expect(entries.map { $0.device.did } == ["123", "123:light:3"])
        #expect(entries.first?.bindings["on"]?.id == "p:2:1")
        #expect(entries.last?.bindings["on"]?.id == "p:3:1")
        #expect(entries.first?.device.on == false && entries.last?.device.on == true)
    }

    @Test("Mode, lock, fault and feed properties never substitute for a main power switch", arguments: ["xiaomi.pet_waterer.70m2", "xiaomi.feeder.pi2001"])
    func noInventedPower(model: String) throws {
        var s = try snapshot(model, model: model)
        for c in s.capabilities { s.readings[c.id] = DeviceReading(value: c.format == "bool" ? .bool(true) : .number(1)) }
        #expect(MatterDevicePlan.entries([s]).isEmpty)
    }

    @Test("A managed covering is exported only from the explicitly provided driver cache, including offline placeholders")
    func managedCovering() throws {
        let s = try snapshot("dooya.motor.dc1545", model: CurtainValidationSession.model)
        #expect(MatterDevicePlan.entries([s]).isEmpty)
        let cache = MatterDevicePlan.Covering(position: 29, target: 34, movement: 1, reachable: true)
        let entry = try #require(MatterDevicePlan.entries([s], managedCoverings: [s.id: cache]).first)
        #expect(entry.device.kind == "windowCovering" && entry.device.reachable)
        #expect(entry.device.attributes["position"] == .number(29) && entry.device.attributes["targetPosition"] == .number(34))
        #expect(entry.bindings.isEmpty)
        let unknown = MatterDevicePlan.Covering(position: nil, movement: nil, reachable: false)
        let missing = try #require(MatterDevicePlan.entries([s], managedCoverings: [s.id: unknown]).first)
        #expect(!missing.device.reachable && missing.device.attributes["position"] == nil)
        let invalid = MatterDevicePlan.Covering(position: 200, movement: 9, reachable: true)
        #expect(MatterDevicePlan.entries([s], managedCoverings: [s.id: invalid]).first?.device.reachable == false)
        let data = try JSONEncoder().encode(entry.device)
        #expect(!String(decoding: data, as: UTF8.self).contains(s.device.token))
    }

    @MainActor @Test("Thermostat writes preserve exact Celsius steps and confirm through the existing controller")
    func thermostatWrite() async throws {
        var s = try snapshot("iot.tow_w.jd015", model: "test.generic.heater")
        s.schema.type += ":matter-test-\(UUID().uuidString)"
        s.device.specType = s.schema.type
        let folder = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(s.schema.type.replacingOccurrences(of: ":", with: "_") + ".json")
        try JSONEncoder().encode(s.schema).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let network = FakeMiioNetwork()
        let fake = network.add(host: s.device.host, token: s.device.token, deviceID: 123,
            props: ["2.1": .bool(true), "2.2": .number(0), "2.3": .number(3), "2.4": .number(0), "2.5": .number(65), "2.6": .number(59)])
        fake.model = s.device.model
        let config = LocalHomeConfig(devices: [s.device])
        let api = LANMiotAPI(config: { config }, transport: network)
        let controller = DeviceController(api: api, config: { config })
        defer { controller.shutdown() }
        await controller.refreshNow()
        try await MatterDevicePlan.execute(controller: controller, endpoint: "123", property: "targetTemperature", value: .number(6000))
        #expect(controller.snapshots["123"]?.value("p:2:5") == .number(60))
        #expect(controller.snapshots["123"]?.commandReceipt?.confirmedAt != nil)
        let count = fake.receivedWrites.count
        await #expect(throws: DeviceControlError.self) {
            try await MatterDevicePlan.execute(controller: controller, endpoint: "123", property: "targetTemperature", value: .number(6100))
        }
        #expect(fake.receivedWrites.count == count)
    }
}
