import Foundation
import HAPCore
import HAPTransport
import MijiaCore
import Testing
@testable import MijiaLAN
@testable import MijiaHomeKitBridge

/// Manage Home Devices lets the user keep single services of an accessory out of Apple Home. Home keys rooms, scenes
/// and automations by service and characteristic ID, so leaving one out must not renumber the others.
struct ServiceSelectionTests {
    @Test("Excluding any one service leaves every other service and characteristic ID as it was", arguments: DeviceSchema.bundledModels)
    func excludingKeepsIdentifiers(model: String) throws {
        let s = try snapshot(model)
        var ids: [String: UInt64] = [:]
        let full = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
        #expect(full.serviceKeys.count == full.services.count)
        for (key, removed) in zip(full.serviceKeys, full.services) {
            var reused = ids
            let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &reused, excluding: [key])
            #expect(reused == ids, "\(model) \(key)")
            #expect(plan.serviceKeys == full.serviceKeys.filter { $0 != key })
            #expect(plan.services.map(\.iid) == full.services.filter { $0.iid != removed.iid }.map(\.iid))
            #expect(plan.services.flatMap(\.characteristics).map(\.iid)
                    == full.services.filter { $0.iid != removed.iid }.flatMap(\.characteristics).map(\.iid))
            #expect(removed.characteristics.allSatisfy { plan.bindings[$0.iid] == nil })
            #expect(plan.bindings.count == full.bindings.count - removed.characteristics.count)
            #expect(plan.signature != full.signature)
            // Brought back, it has its old IDs again.
            var restoredIDs = reused
            let restored = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &restoredIDs)
            #expect(restored.signature == full.signature)
            #expect(restoredIDs == ids)
        }
    }

    @Test("A switch the user leaves out frees no budget for another: the rest of an unreviewed model stays the same")
    func excludedSwitchKeepsBudget() throws {
        let s = try snapshot("dmaker.fan.p28", model: "test.fan.p28")
        var ids: [String: UInt64] = [:]
        let full = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids)
        let switches = full.serviceKeys.filter { $0.hasPrefix("control:") }
        let key = try #require(switches.first)
        let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids, excluding: [key])
        #expect(plan.serviceKeys == full.serviceKeys.filter { $0 != key })
    }

    @Test("Without its main service an accessory keeps the rest; without every service it has none")
    func primaryAndEverything() throws {
        let s = try snapshot("zhimi.airpurifier.rma1")
        var ids: [String: UInt64] = [:]
        let full = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids)
        let primary = try #require(zip(full.serviceKeys, full.services).first { $0.1.isPrimary }?.0)
        let rest = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids, excluding: [primary])
        #expect(!rest.services.isEmpty)
        #expect(rest.services.allSatisfy { !$0.isPrimary })
        let none = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids, excluding: Set(full.serviceKeys))
        #expect(none.services.isEmpty)
        #expect(none.bindings.isEmpty)
    }

    @Test("The list names each service as Home shows it, the main one first, in either language")
    func listedNames() throws {
        for language in [AppLanguage.zhHans, .en] {
            try L10n.$overrideLanguage.withValue(language) {
                let s = try snapshot("zhimi.airpurifier.rma1")
                let services = CapabilityHomeKitMapper.services(snapshot: s, legacyDevice: smart(s), names: [:])
                var ids: [String: UInt64] = [:]
                #expect(services.map(\.key) == CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: smart(s), names: [:], identifiers: &ids).serviceKeys)
                let main = try #require(services.first)
                #expect(main.isPrimary && main.kind == .airPurifier)
                // The main service has no name of its own; Home shows the accessory's.
                #expect(main.name == "Test")
                #expect(services.dropFirst().allSatisfy { !$0.isPrimary })
                let pm = try #require(services.first { $0.key == "sensor:p:3:4" })
                #expect(pm.kind == .airQuality)
                #expect(pm.name == s.capabilitiesByID["p:3:4"]?.title)
                #expect(services.contains { $0.kind == .filter })
                // A name given in Home wins.
                let renamed = CapabilityHomeKitMapper.services(snapshot: s, legacyDevice: smart(s), names: ["sensor:p:3:4": "卧室空气"])
                #expect(renamed.first { $0.key == "sensor:p:3:4" }?.name == "卧室空气")

                let plug = try snapshot("cuco.plug.v3")
                let plugServices = CapabilityHomeKitMapper.services(snapshot: plug, legacyDevice: smart(plug),
                                                                    names: ["control:p:8:1": "开关 14"])
                let countdown = try #require(plugServices.first { $0.key == "control:p:8:1" })
                #expect(countdown.name == "开关 14")
                #expect(countdown.defaultName == plug.capabilitiesByID["p:8:1"]?.displayTitle)
            }
        }
    }

    @Test("The air conditioner companion's mode switches are listed under their Home names")
    func companionNames() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let s = try snapshot("lumi.acpartner.mcn02")
            let services = CapabilityHomeKitMapper.services(snapshot: s, legacyDevice: smart(s), names: [:])
            #expect(services.first?.kind == .climate)
            #expect(services.first?.isPrimary == true)
            #expect(services.contains { $0.kind == .switch && $0.name == "Dry Mode" })
            #expect(services.allSatisfy { !$0.name.isEmpty })
        }
    }

    @Test("Every reviewed model lists every service it publishes, each with a name", arguments: DeviceSchema.bundledModels)
    func everyModelListed(model: String) throws {
        let s = try snapshot(model)
        let services = CapabilityHomeKitMapper.services(snapshot: s, legacyDevice: smart(s), names: [:])
        #expect(!services.isEmpty)
        #expect(Set(services.map(\.key)).count == services.count)
        #expect(services.allSatisfy { !$0.name.isEmpty })
        #expect(services.filter(\.isPrimary).count <= 1)
    }

    @MainActor
    @Test("The bridge persists exclusions, drops the service on the next sync and restores it with its old IDs")
    func bridgeSync() async throws {
        let fixture = try await SelectionFixture.make()
        do {
            let before = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
            let snapshot = try #require(fixture.devices.snapshots["123"])
            let legacy = fixture.devices.synthesizedHome().devices.first
            let services = fixture.bridge.homeServices(for: snapshot, legacyDevice: legacy)
            // The bridge adds Accessory Information.
            #expect(services.count == before.services.count - 1)
            let key = try #require(services.first { !$0.isPrimary && $0.kind == .switch }?.key)
            var ids: [String: UInt64] = [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: snapshot, legacyDevice: legacy, names: [:], identifiers: &ids)
            let removedIID = try #require(zip(plan.serviceKeys, plan.services).first { $0.0 == key }?.1.iid)
            #expect(before.services.contains { $0.iid == removedIID })
            let configuration = await fixture.hap.currentConfigurationNumber

            fixture.bridge.setExcludedServices([key], for: "123")
            await fixture.settle()
            let excluded = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
            #expect(excluded.services.map(\.iid) == before.services.map(\.iid).filter { $0 != removedIID })
            let kept = before.services.filter { $0.iid != removedIID }
            #expect(excluded.services.flatMap(\.characteristics).map(\.iid) == kept.flatMap(\.characteristics).map(\.iid))
            #expect(await fixture.hap.currentConfigurationNumber > configuration)
            #expect(fixture.defaults.dictionary(forKey: HomeKitBridgeController.excludedServicesKey) as? [String: [String]] == ["123": [key]])
            let reloaded = HomeKitBridgeController(vault: HomeKitBridgeVault(load: { .missing }, save: { _ in true }), defaults: fixture.defaults)
            #expect(reloaded.excludedServices == ["123": [key]])

            // Every service out: no accessory, as for a hidden device. Back in: the same accessory and IDs.
            fixture.bridge.setExcludedServices(Set(services.map(\.key)), for: "123")
            await fixture.settle()
            #expect(await fixture.hap.accessoryDatabase().map(\.aid) == [1])
            fixture.bridge.setExcludedServices([], for: "123")
            await fixture.settle()
            let restored = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
            #expect(restored.services.map(\.iid) == before.services.map(\.iid))
            #expect(restored.services.flatMap(\.characteristics).map(\.iid) == before.services.flatMap(\.characteristics).map(\.iid))
            #expect(fixture.defaults.dictionary(forKey: HomeKitBridgeController.excludedServicesKey) as? [String: [String]] == [:])
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    /// `model` names the bundled spec; `deviceModel`, a placeholder, keeps the reviewed and legacy tables out.
    private func snapshot(_ model: String, model deviceModel: String? = nil) throws -> DeviceSnapshot {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let deviceModel = deviceModel ?? model
        return DeviceSnapshot(device: LocalDevice(did: "123", name: "Test", model: deviceModel, host: "test", token: ""),
            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: deviceModel))
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

/// A running bridge over one simulated dmaker.fan.p28, on its own defaults suite.
@MainActor private struct SelectionFixture {
    let api: LANMiotAPI
    let devices: DeviceController
    /// The bridge holds the store weakly.
    let store: HomeStore
    let bridge: HomeKitBridgeController
    let hap: HAPBridge
    let defaults: UserDefaults
    let suite: String

    static func make() async throws -> SelectionFixture {
        let suite = "test.mijialan.selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: HomeKitBridgeController.keepAwakeKey)
        let device = LocalDevice(did: "123", name: "Fan", model: "dmaker.fan.p28", host: "test", token: String(repeating: "0", count: 32))
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: SelectionTransport())
        let devices = DeviceController(api: api, config: { config })
        await devices.refreshNow()
        let store = HomeStore(provider: CapabilityHomeProvider(controller: devices), defaultsSuiteName: suite)
        for _ in 0..<100 where !store.hasReceivedInitialSnapshot { try await Task.sleep(for: .milliseconds(2)) }
        var secrets = HomeKitBridgeSecrets.generate()
        secrets.pairings = ["existing-controller": Data(repeating: 1, count: 32)]
        let data = try #require(secrets.encoded())
        let bridge = HomeKitBridgeController(vault: HomeKitBridgeVault(load: { .value(data) }, save: { _ in true }), defaults: defaults, port: 0)
        bridge.attach(to: store, capabilities: devices)
        await bridge.waitUntilIdle()
        let fixture = SelectionFixture(api: api, devices: devices, store: store, bridge: bridge, hap: try #require(bridge.bridge), defaults: defaults, suite: suite)
        await fixture.settle()
        return fixture
    }

    func settle() async {
        for _ in 0..<10 { await Task.yield() }
        await bridge.waitUntilIdle()
    }

    func stop() async {
        bridge.isEnabled = false
        await bridge.waitUntilIdle()
        devices.shutdown()
        await api.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor SelectionTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private var values: [String: JSONValue] = ["2.1": .bool(true), "8.1": .number(50)]

    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let args = request["params"]?.arrayValue ?? []
        let result: JSONValue
        switch request["method"]?.stringValue ?? "" {
        case "miIO.info": result = .object(["model": .string("dmaker.fan.p28")])
        case "get_properties":
            result = .array(args.map { p in
                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                return .object(["siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null,
                    "code": values[key] == nil ? .number(-4003) : .number(0), "value": values[key] ?? .null])
            })
        default: throw MiioError.unsupportedByLegacyDevice
        }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }

    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
