import Foundation
import Testing
import HAPCore
import HAPTransport
import MijiaCore
@testable import MijiaLAN
@testable import MijiaHomeKitBridge

@MainActor
struct IncrementalSyncTests {
    @Test("Unchanged polls do not rebuild HomeKit plans, write defaults, or push characteristic actors")
    func unchangedPolls() async throws {
        let fixture = try await Fixture.make()
        let before = fixture.bridge.syncStatistics
        let configuration = await fixture.hap.currentConfigurationNumber
        let database = await fixture.hap.accessoryDatabase()
        for _ in 0..<20 { await fixture.devices.refreshNow() }
        await fixture.settle()
        let after = fixture.bridge.syncStatistics
        #expect(after.planBuilds == before.planBuilds)
        #expect(after.characteristicUpdates == before.characteristicUpdates)
        #expect(after.readStatusUpdates == before.readStatusUpdates)
        #expect(after.layoutWrites == before.layoutWrites)
        #expect(after.identifierWrites == before.identifierWrites)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        #expect(await fixture.hap.accessoryDatabase().map(\.aid) == database.map(\.aid))
        await fixture.stop()
    }

    @Test("A value change updates its characteristics without rebuilding services or changing AIDs and IIDs")
    func changedValue() async throws {
        let fixture = try await Fixture.make()
        let before = fixture.bridge.syncStatistics
        let old = await fixture.hap.accessoryDatabase()
        let configuration = await fixture.hap.currentConfigurationNumber
        await fixture.transport.set("8.1", .number(70))
        await fixture.devices.refreshNow()
        await fixture.settle()
        let after = fixture.bridge.syncStatistics
        #expect(after.planBuilds == before.planBuilds)
        #expect(after.characteristicUpdates > before.characteristicUpdates)
        #expect(after.readStatusUpdates == before.readStatusUpdates)
        #expect(after.layoutWrites == before.layoutWrites)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        let current = await fixture.hap.accessoryDatabase()
        #expect(current.map(\.aid) == old.map(\.aid))
        #expect(current.flatMap(\.services).flatMap(\.characteristics).map(\.iid) == old.flatMap(\.services).flatMap(\.characteristics).map(\.iid))
        let iid = try #require(current.first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(70))
        await fixture.stop()
    }

    @Test("Same-value offline recovery restores read status without touching the layout or pairing identity")
    func recovery() async throws {
        let fixture = try await Fixture.make()
        let uri = fixture.bridge.setupURI
        let configuration = await fixture.hap.currentConfigurationNumber
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        let events = CapturedEvents()
        await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid)
        await fixture.hap.setCharacteristicChangeHandler { _, data in await events.append(data) }
        let before = fixture.bridge.syncStatistics
        await fixture.transport.setOffline(true)
        await fixture.devices.refreshNow()
        await fixture.settle()
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .communicationFailure)
        await fixture.transport.setOffline(false)
        await fixture.devices.retry(did: "123")
        await fixture.settle()
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        #expect(fixture.bridge.syncStatistics.planBuilds == before.planBuilds)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        #expect(fixture.bridge.setupURI == uri)
        #expect(fixture.bridge.isPaired)
        for _ in 0..<100 where await events.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await events.count >= 1)
        await fixture.stop()
    }

    @Test("Same-value HomeKit writes still force a confirmation event after delta suppression")
    func forcedConfirmation() async throws {
        let fixture = try await Fixture.make()
        let events = CapturedEvents()
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid)
        await fixture.hap.setCharacteristicChangeHandler { _, data in await events.append(data) }
        try await fixture.hap.writeCharacteristic(aid: 2, iid: iid, value: .float(50))
        await fixture.settle()
        for _ in 0..<100 where await events.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await events.count >= 1)
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        await fixture.stop()
    }

    @Test("Hiding and restoring a capability device reuses its reserved identifiers")
    func hideRestore() async throws {
        let fixture = try await Fixture.make()
        let old = await fixture.hap.accessoryDatabase().first { $0.aid == 2 }
        fixture.store.hideDevice("123")
        await fixture.settle()
        #expect(await fixture.hap.accessoryDatabase().count == 1)
        fixture.store.unhideDevice("123")
        await fixture.settle()
        let restored = await fixture.hap.accessoryDatabase().first { $0.aid == 2 }
        #expect(restored?.services.map(\.iid) == old?.services.map(\.iid))
        #expect(restored?.services.flatMap(\.characteristics).map(\.iid) == old?.services.flatMap(\.characteristics).map(\.iid))
        await fixture.stop()
    }

    @MainActor private struct Fixture {
        let api: LANMiotAPI
        let devices: DeviceController
        let store: HomeStore
        let bridge: HomeKitBridgeController
        let hap: HAPBridge
        let transport: SyncTestTransport
        let defaults: UserDefaults
        let suite: String

        static func make() async throws -> Fixture {
            let suite = "test.mijialan.incremental.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(false, forKey: HomeKitBridgeController.keepAwakeKey)
            let device = LocalDevice(did: "123", name: "Fan", model: "dmaker.fan.p28", host: "test", token: String(repeating: "0", count: 32))
            let config = LocalHomeConfig(devices: [device])
            let transport = SyncTestTransport()
            let api = LANMiotAPI(config: { config }, transport: transport)
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
            let hap = try #require(bridge.bridge)
            let result = Fixture(api: api, devices: devices, store: store, bridge: bridge, hap: hap, transport: transport, defaults: defaults, suite: suite)
            await result.settle()
            return result
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
}

private actor CapturedEvents {
    private var values: [Data] = []
    var count: Int { values.count }
    func append(_ data: Data) { values.append(data) }
}

private actor SyncTestTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private var offline = false
    private var values: [String: JSONValue] = ["2.1": .bool(true), "8.1": .number(50)]
    func set(_ key: String, _ value: JSONValue) { values[key] = value }
    func setOffline(_ value: Bool) { offline = value }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if offline { throw MiioError.hostUnreachable }
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let method = request["method"]?.stringValue ?? ""
        let args = request["params"]?.arrayValue ?? []
        let result: JSONValue
        switch method {
        case "miIO.info": result = .object(["model": .string("dmaker.fan.p28")])
        case "get_properties":
            result = .array(args.map { p in
                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                return .object(["siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null,
                    "code": values[key] == nil ? .number(-4003) : .number(0), "value": values[key] ?? .null])
            })
        case "set_properties":
            result = .array(args.map { p in
                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                values[key] = p["value"]
                return .object(["code": .number(0)])
            })
        default: throw MiioError.unsupportedByLegacyDevice
        }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
