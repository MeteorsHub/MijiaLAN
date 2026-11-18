import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@Suite(.serialized)
struct YeelightCeiling20Tests {
    private let model = "yeelink.light.ceiling20"
    private let token = "00112233445566778899aabbccddeeff"
    private func schema() throws -> DeviceSchema {
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        return try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
    }
    private func readings(mode: JSONValue = .string("0"), night: JSONValue = .string("0")) -> [String: JSONValue] {
        ["power": .string("on"), "bright": .string("71"), "ct": .string("4000"), "active_mode": mode, "nl_br": night,
         "bg_power": .string("off"), "bg_bright": .string("35"), "bg_ct": .string("3000"), "bg_rgb": .string("16711680")]
    }
    private func installSchema() throws -> (LocalHomeConfig, URL) {
        var schema = try schema()
        schema.type += ":test-\(UUID().uuidString)"
        let folder = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(schema.type.replacingOccurrences(of: ":", with: "_") + ".json")
        try JSONEncoder().encode(schema).write(to: url)
        return (LocalHomeConfig(devices: [LocalDevice(did: "123", name: "Dual ceiling", model: model, host: "192.0.2.20", token: token, specType: schema.type)]), url)
    }

    @Test("Main brightness strictly selects real day or moonlight readings and never invents missing or inconsistent telemetry")
    func brightnessModes() throws {
        let profile = try #require(LegacyMiioProfile.forModel(model))
        let property = try #require(profile.property(siid: 2, piid: 2))
        #expect(property.readDependencies == ["nl_br", "active_mode"])
        #expect(property.miotValue(.string("71"), context: readings()) == .number(71))
        #expect(property.miotValue(.number(71), context: readings(mode: .number(1), night: .string("8"))) == .number(8))
        #expect(property.miotValue(.number(71), context: readings(mode: .number(0), night: .number(8))) == .number(71))
        var day = readings(); day["nl_br"] = nil
        #expect(property.miotValue(.string("71"), context: day) == .number(71))
        for invalid in [JSONValue.number(0), .number(-1), .number(101), .string("bad"), .bool(true), .null, .number(1.5)] {
            #expect(property.miotValue(.number(71), context: readings(mode: .number(1), night: invalid)) == nil)
        }
        var missing = readings(mode: .number(1)); missing["nl_br"] = nil
        #expect(property.miotValue(.number(71), context: missing) == nil)
        missing["active_mode"] = nil
        #expect(property.miotValue(.number(71), context: missing) == nil)
        #expect(property.miotValue(.null, context: readings()) == nil)
        #expect(property.miotValue(.number(71), context: readings(mode: .string("invalid"))) == nil)
        let mode = try #require(profile.property(siid: 2, piid: 4))
        #expect(mode.miotValue(.string("0")) == .number(1))
        #expect(mode.miotValue(.number(1)) == .number(2))
        #expect(mode.miotValue(.string("invalid")) == nil)
        #expect(mode.legacyCall(.number(2))?.params == [.string("nightlight"), .string("on")])
        #expect(mode.legacyCall(.number(1))?.params == [.string("nightlight"), .string("off")])
    }

    @Test("Only the exact reviewed model gets logical ambient properties; extension is idempotent and never replaces a supplied service")
    func exactSchema() throws {
        let raw = try schema(), extended = YeelightCeiling20Schema.extending(raw, model: model)
        #expect(raw.services.count == 1 && extended.services.count == 2)
        #expect(YeelightCeiling20Schema.extending(extended, model: model) == extended)
        #expect(YeelightCeiling20Schema.extending(raw, model: "yeelink.light.ceiling19") == raw)
        let caps = DeviceCapabilityCatalog.capabilities(schema: extended, model: model)
        for (siid, iid) in [(2, 1), (2, 2), (2, 3), (2, 4), (200, 201), (200, 202), (200, 203), (200, 204)] {
            let cap = try #require(caps.first { $0.siid == siid && $0.iid == iid })
            #expect(cap.readable && cap.writable)
        }
        #expect(caps.first { $0.id == "p:200:203" }?.range == [1700, 6500, 1])
        #expect(caps.first { $0.id == "p:2:3" }?.range == [2700, 6500, 1])
    }

    @MainActor @Test("App cache and both Matter routes use encrypted legacy calls with coherent mode reads and no cross-channel writes")
    func realLegacyRoutes() async throws {
        let (config, file) = try installSchema()
        defer { try? FileManager.default.removeItem(at: file) }
        let network = FakeMiioNetwork()
        let lamp = network.add(host: "192.0.2.20", token: token, deviceID: 123)
        lamp.model = model; lamp.legacyProps = readings()
        let api = LANMiotAPI(config: { config }, transport: network)
        let controller = DeviceController(api: api, config: { config })
        defer { controller.shutdown() }
        await controller.refreshNow()
        let initial = try #require(controller.snapshots["123"])
        #expect(initial.schema.services.contains { $0.iid == 200 && $0.name == "ambient-light" })
        #expect(initial.value("p:2:2") == .number(71) && initial.value("p:200:202") == .number(35))
        #expect(lamp.legacyReads.contains { Set(["bright", "nl_br", "active_mode"]).isSubset(of: Set($0)) })
        let plan = MatterDevicePlan.entries([initial])
        #expect(plan.map { $0.device.did } == ["123", "123:light:200"])
        #expect(plan.allSatisfy { $0.device.kind == "colorTemperatureLight" && $0.device.reachable && $0.device.sourceID == "123" })
        #expect(plan.map { $0.device.functionLabel } == [L10n.tr("主灯", "Main Light"), L10n.tr("副灯", "Ambient Light")])
        #expect(plan[0].bindings["level"]?.id == "p:2:2" && plan[1].bindings["level"]?.id == "p:200:202")
        #expect(plan[0].bindings["colorTemperature"]?.id == "p:2:3" && plan[1].bindings["colorTemperature"]?.id == "p:200:203")
        // Snapshot projection is cache-only.
        let before = network.exchangeCount
        for _ in 0..<10 { _ = MatterDevicePlan.entries(Array(controller.snapshots.values)) }
        #expect(network.exchangeCount == before && lamp.legacyCalls.isEmpty)
        try await controller.execute(did: "123", .setLightBrightness(42, siid: 200))
        #expect(lamp.legacyCalls == [#"bg_set_power ["on"]"#, "bg_set_bright [42]"])
        #expect(controller.snapshots["123"]?.value("p:2:2") == .number(71))
        #expect(controller.snapshots["123"]?.value("p:200:202") == .number(42))
        try await controller.execute(did: "123", .setLightBrightness(50))
        #expect(lamp.legacyCalls.last == "set_bright [50]")
        try await controller.execute(did: "123", .set("p:2:4", .number(2)))
        // Missing nl_br in a real read remains unavailable, even after a previous successful day sample.
        #expect(controller.snapshots["123"]?.value("p:2:4") == .number(2))
        #expect(controller.snapshots["123"]?.value("p:2:2") == nil)
        lamp.legacyProps?["nl_br"] = .string("8")
        await controller.refreshNow()
        #expect(controller.snapshots["123"]?.value("p:2:2") == .number(8))
        try await controller.execute(did: "123", .setLightBrightness(11))
        #expect(controller.snapshots["123"]?.value("p:2:2") == .number(11))
        #expect(lamp.legacyProps?["bright"] == .number(50))
        try await controller.execute(did: "123", .set("p:2:4", .number(1)))
        #expect(controller.snapshots["123"]?.value("p:2:2") == .number(50))
        try await MatterDevicePlan.execute(controller: controller, endpoint: "123:light:200", property: "level", value: .number(60))
        try await MatterDevicePlan.execute(controller: controller, endpoint: "123", property: "colorTemperature", value: .number(200))
        try await MatterDevicePlan.execute(controller: controller, endpoint: "123:light:200", property: "colorTemperature", value: .number(250))
        try await controller.execute(did: "123", .set("p:200:204", .number(255)))
        #expect(Array(lamp.legacyCalls.suffix(4)) == ["bg_set_bright [60]", #"set_ct_abx [5000,"smooth",500]"#, #"bg_set_ct_abx [4000,"smooth",500]"#, "bg_set_rgb [255]"])
        #expect(!lamp.receivedMethods.contains("get_properties") && !lamp.receivedMethods.contains("set_properties"))
        var unavailable = try #require(controller.snapshots["123"])
        unavailable.readings["p:200:202"] = DeviceReading(value: .number(42), code: -4004, error: "rejected")
        let partial = MatterDevicePlan.entries([unavailable])
        #expect(partial[0].device.reachable && !partial[1].device.reachable)
        let calls = lamp.legacyCalls.count
        lamp.legacyReplies["bg_set_bright"] = .array([.string("fail")])
        await #expect(throws: MiioError.self) {
            try await controller.execute(did: "123", .set("p:200:202", .number(70)))
        }
        #expect(lamp.legacyCalls.count == calls + 1)
    }
}
