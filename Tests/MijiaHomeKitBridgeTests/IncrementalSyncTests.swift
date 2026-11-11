import Foundation
import Testing
import HAPCore
import HAPCrypto
import HAPTransport
import MijiaCore
@testable import MijiaLAN
@testable import MijiaHomeKitBridge

@MainActor
struct IncrementalSyncTests {
    @Test("Stopping and restarting bridge observations uses current cached state without extra LAN reads")
    func observationRestart() async throws {
        let fixture = try await Fixture.make()
        let uri = fixture.bridge.setupURI
        fixture.bridge.isEnabled = false
        await fixture.bridge.waitUntilIdle()
        #expect(fixture.bridge.status == .stopped)
        #expect(fixture.bridge.bridge == nil)
        await fixture.transport.set("8.1", .number(62))
        await fixture.devices.refreshNow() // Only this explicit fixture refresh may query its fake device.
        fixture.store.hideDevice("123")
        await fixture.bridge.waitUntilIdle()
        let before = await fixture.transport.methods
        #expect(fixture.bridge.bridge == nil)
        fixture.bridge.isEnabled = true
        await fixture.bridge.waitUntilIdle()
        let hap = try #require(fixture.bridge.bridge)
        #expect(await hap.accessoryDatabase().count == 1)
        fixture.store.unhideDevice("123")
        await fixture.bridge.waitUntilIdle()
        let iid = try #require(await hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        #expect(await hap.readCharacteristic(aid: 2, iid: iid) == .float(62))
        #expect(fixture.bridge.setupURI == uri)
        #expect(await fixture.transport.methods == before)
        await fixture.stop()
    }

    @Test("HomeKit reads use saved bridge state without LAN queries, while a changed control still writes and reads back immediately")
    func cachedReadsAndImmediateWrite() async throws {
        let fixture = try await Fixture.make()
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        await fixture.settle()
        let before = await fixture.transport.methods
        for _ in 0..<20 {
            #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
            #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        }
        #expect(await fixture.transport.methods == before)
        try await fixture.hap.writeCharacteristic(aid: 2, iid: iid, value: .float(70))
        await fixture.settle()
        let commands = Array(await fixture.transport.methods.dropFirst(before.count))
        #expect(commands.contains("set_properties") && commands.contains("get_properties"))
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(70))
        await fixture.stop()
    }
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

    @Test("Same-value writes confirm device state without redundant events; later device changes notify both controllers", arguments: [false, true])
    func forcedConfirmation(protocolRequest: Bool) async throws {
        let fixture = try await Fixture.make()
        // Isolate packet-count assertions from the fixture's periodic timer; refreshes below are explicit.
        fixture.devices.setPollingIntervals(.init(foregroundSeconds: 3600, backgroundSeconds: 3600))
        let events = CapturedEvents()
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        await fixture.hap.setCharacteristicChangeHandler { subscribers, data in await events.append(data, subscribers: subscribers) }
        await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid)
        await fixture.hap.subscribe(connectionID: 22, aid: 2, iid: iid)
        let initial = try await drain(events, bridge: fixture.hap, iid: iid, marker: 1000)
        let recipients = Set(initial.map { $0.subscribers })
        #expect(initial.count == 2 && recipients == Set([Set([7]), Set([22])]))

        let identity = HAPIdentity(), pairings = InMemoryPairingStore()
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: pairings, deviceID: "test")
        try await VerifiedTestController.authenticate(verify, store: pairings)
        let handler = CharacteristicProtocol(bridge: fixture.hap,
            pairingStateMachine: PairingStateMachine(setupCode: "031-45-154", identity: identity, pairingStore: pairings, deviceID: "test"),
            pairVerifyStateMachine: verify, pairingStore: pairings, identity: identity, connectionID: 7)
        let beforeWrites = await fixture.transport.writes.count
        let beforeMethods = await fixture.transport.methods.count
        if protocolRequest {
            let request = HTTPRequest(method: "PUT", path: "/characteristics",
                body: Data("{\"characteristics\":[{\"aid\":2,\"iid\":\(iid),\"value\":50}]}".utf8))
            let response = try await handler.handleRequest(request)
            #expect(response.statusCode == 204 && response.body.isEmpty)
        } else {
            // Retain the old fixture's direct-write path, which has no originating connection.
            try await fixture.hap.writeCharacteristic(aid: 2, iid: iid, value: .float(50))
        }
        await fixture.settle()
        let repeated = try await drain(events, bridge: fixture.hap, iid: iid, marker: 1001)
        #expect(repeated.isEmpty)
        let writes = Array(await fixture.transport.writes.dropFirst(beforeWrites))
        let addresses = writes.map { "\($0["siid"]?.intValue ?? 0).\($0["piid"]?.intValue ?? 0)" }
        let values = writes.compactMap { $0["value"] }
        // The existing fan plan sends speed then power, each once; both writes must have their own readback.
        #expect(addresses == ["8.1", "2.1"] && values == [.number(50), .bool(true)])
        let methods = Array(await fixture.transport.methods.dropFirst(beforeMethods))
        #expect(methods == ["set_properties", "get_properties", "set_properties", "get_properties"])
        #expect(fixture.devices.snapshots["123"]?.commandReceipt?.confirmedAt != nil)
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        let beforeRead = await fixture.transport.methods
        let read = try await handler.handleRequest(HTTPRequest(method: "GET", path: "/characteristics?id=2.\(iid)"))
        #expect(read.statusCode == 200)
        let json = try JSONDecoder().decode(JSONValue.self, from: read.body)
        #expect(json["characteristics"]?.arrayValue?.first?["value"] == .number(50))
        #expect(await fixture.transport.methods == beforeRead)

        // A subsequent external change must still reach the former writer as well as the other controller.
        let writeCount = await fixture.transport.writes.count
        await fixture.transport.set("8.1", .number(70))
        await fixture.devices.refreshNow()
        await fixture.settle()
        let external = try await drain(events, bridge: fixture.hap, iid: iid, marker: 1002)
        #expect(external.count == 1)
        let event = try #require(external.first)
        #expect(event.subscribers == [7, 22])
        let boundary = try #require(event.data.range(of: Data("\r\n\r\n".utf8)))
        let change = try JSONDecoder().decode(JSONValue.self, from: event.data[boundary.upperBound...])
        #expect(change["characteristics"]?.arrayValue?.first?["value"] == .number(70))
        #expect(await fixture.transport.writes.count == writeCount)
        await fixture.stop()
    }

    private func drain(_ events: CapturedEvents, bridge: HAPBridge, iid: UInt64, marker: Int) async throws -> [CapturedEvents.Delivery] {
        // A fresh subscription queues a snapshot behind all earlier notifications in the same FIFO.
        // Its unique recipient proves delivery completion without waiting for an absent duplicate event.
        await bridge.subscribe(connectionID: marker, aid: 2, iid: iid)
        for _ in 0..<200 {
            if await events.hasMarker(marker) {
                await bridge.unsubscribe(connectionID: marker, aid: 2, iid: iid)
                return await events.take().filter { $0.subscribers != [marker] }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw WireHAPController.Failure.timedOut
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
    struct Delivery: Sendable {
        let subscribers: Set<Int>
        let data: Data
    }
    private var values: [Delivery] = []
    var count: Int { values.count }
    func append(_ data: Data, subscribers: Set<Int> = []) { values.append(Delivery(subscribers: subscribers, data: data)) }
    func hasMarker(_ marker: Int) -> Bool { values.contains { $0.subscribers == [marker] } }
    func take() -> [Delivery] { defer { values.removeAll() }; return values }
}

private actor SyncTestTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private var offline = false
    private var values: [String: JSONValue] = ["2.1": .bool(true), "8.1": .number(50)]
    private(set) var methods: [String] = []
    private(set) var writes: [JSONValue] = []
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
        methods.append(method)
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
            writes.append(contentsOf: args)
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
