import Foundation
import HAPCore
import HAPTransport
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

struct CapabilityMappingTests {
    @Test("Changing the display language preserves HomeKit signatures and identifiers", arguments: DeviceSchema.bundledModels)
    func languageStability(model: String) throws {
        let chinese = try L10n.$overrideLanguage.withValue(.zhHans) {
            let s = try snapshot(model)
            var ids: [String: UInt64] = [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
            return (plan: plan, ids: ids)
        }
        try L10n.$overrideLanguage.withValue(.en) {
            let s = try snapshot(model)
            var ids = chinese.ids
            let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
            #expect(plan.signature == chinese.plan.signature)
            #expect(ids == chinese.ids)
            #expect(plan.services.map(\.iid) == chinese.plan.services.map(\.iid))
        }
    }

    @Test("Every reviewed model has a stable, named Home database even when offline", arguments: DeviceSchema.bundledModels)
    func allModels(model: String) throws {
        var s = try snapshot(model)
        let device = smart(s)
        var ids: [String: UInt64] = [:]
        let offline = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: device, names: [:], identifiers: &ids)
        #expect(!offline.services.isEmpty)
        #expect(offline.services.flatMap(\.characteristics).allSatisfy { $0.type.rawValue.first != "0" })
        let all = offline.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }
        #expect(all.allSatisfy { $0 >= 8 })
        #expect(Set(all).count == all.count)
        for service in offline.services where service.type == .switch {
            #expect(service.characteristics.contains { $0.type.rawValue == "E3" && $0.isWritable })
        }
        let expected: [String: String] = ["dmaker.fan.p28": "B7", "zhimi.airpurifier.rma1": "BB", "yeelink.light.lamp4": "43", "lumi.acpartner.mcn02": "BC", "cuco.plug.v3": "47", "chuangmi.plug.m3": "47"]
        if let type = expected[model] { #expect(offline.services.contains { $0.type.rawValue == type }) }
        let originalIDs = ids
        s.health = LANDeviceHealth(state: .online)
        for c in s.capabilities where c.readable {
            s.readings[c.id] = DeviceReading(value: c.format == "bool" ? .bool(true) : .number(c.min ?? Double(c.options.first?.value ?? 0)), updatedAt: Date(), code: 0)
        }
        let online = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
        #expect(online.signature == offline.signature)
        #expect(ids == originalIDs)
        // New metadata reuses IDs across restarts and names don't change the database layout.
        let renamed = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: ["control:p:2:1": "我的名称"], identifiers: &ids)
        #expect(renamed.signature == online.signature)
    }

    @Test("Migration preserves all old AC, fan, lamp and outlet service and characteristic identifiers", arguments: ["lumi.acpartner.mcn02", "dmaker.fan.p28", "yeelink.light.lamp4", "cuco.plug.v3", "chuangmi.plug.m3"])
    func migration(model: String) async throws {
        let s = try snapshot(model)
        let device = try #require(smart(s))
        let base = try #require(HomeKitAccessoryMapper.plan(for: device, name: device.name))
        let old = HAPBridge(info: base.info)
        await old.addAccessory(info: base.info, services: base.services, aid: 2, appendingCharacteristicTypes: [HomeKitAccessoryMapper.configuredNameType])
        let db = try #require(await old.accessoryDatabase().first { $0.aid == 2 })
        var ids: [String: UInt64] = [:]
        let next = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: device, names: [:], identifiers: &ids)
        for service in db.services.dropFirst() {
            let retained = try #require(next.services.first { $0.iid == service.iid })
            #expect(retained.type == service.type)
            for c in service.characteristics {
                #expect(retained.characteristics.contains { $0.iid == c.iid && $0.type == c.type })
            }
        }
    }

    @Test("Fan speed is 8.1, gear is 2.2, and zero only powers off")
    func fanRouting() throws {
        var s = try snapshot("dmaker.fan.p28")
        var ids: [String: UInt64] = [:]
        let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
        let speed = try #require(plan.services.first { $0.type == .fanV2 }?.characteristics.first { $0.type == .rotationSpeed })
        let binding = try #require(plan.bindings[speed.iid])
        #expect(try CapabilityHomeKitMapper.commands(binding, value: .float(0), snapshot: s) == [.set("p:2:1", .bool(false))])
        #expect(try CapabilityHomeKitMapper.commands(binding, value: .float(43), snapshot: s) == [.set("p:8:1", .number(43)), .set("p:2:1", .bool(true))])
        #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == nil)
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:8:1"] = DeviceReading(value: .number(8), code: 0)
        s.readings["p:2:2"] = DeviceReading(value: .number(4), code: 0)
        #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == .float(8))
        // The gear list describes the same motor as the percentage slider; do not publish redundant switches.
        #expect(!plan.bindings.values.contains { binding in
            switch binding { case .property("p:2:2", _), .option("p:2:2", _): true; default: false }
        })
    }

    @Test("Purifier current state uses actual motor speed instead of assuming power-on means purifying")
    func purifierState() throws {
        var s = try snapshot("zhimi.airpurifier.rma1")
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        let binding = CapabilityHAPBinding.property("p:2:1", .running)
        #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == nil)
        s.readings["p:9:1"] = DeviceReading(value: .number(0), code: 0)
        #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == .uint8(1))
        s.readings["p:9:1"] = DeviceReading(value: .number(500), code: 0)
        #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == .uint8(2))
    }

    private func snapshot(_ model: String) throws -> DeviceSnapshot {
        let schema = try #require(DeviceSchema.bundled(model: model))
        return DeviceSnapshot(device: LocalDevice(did: "123", name: "Test", model: model, host: "test", token: ""),
            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
    }
    private func smart(_ s: DeviceSnapshot) -> SmartDevice? {
        guard let core = s.schema.coreSpec else { return nil }
        var home = MiotSynthesizer.synthesize(devices: [MiDeviceRecord(did: s.id, name: s.device.name, model: s.device.model, isOnline: s.isOnline)],
            rooms: [], specs: [s.device.model: core], values: [:])
        if case .climate(var climate) = home.devices.first?.kind {
            climate.availableSwingModes = ["off", "vertical"]; climate.swingMode = "off"
            home.devices[0].kind = .climate(climate)
        }
        return home.devices.first
    }
}
