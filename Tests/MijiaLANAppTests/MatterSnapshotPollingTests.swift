import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

private actor SnapshotTransport: MiioTransport {
    var calls = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        calls += 1
        throw MiioError.timeout
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        calls += 1
        return []
    }
}

@MainActor struct MatterSnapshotPollingTests {
    @Test("Pet status endpoints share existing cached reads and physical selection; snapshots and rejected writes add no communication")
    func petStatusCacheOnly() async throws {
        let suite = "matter-pet-cache-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["existing-exclusion"], forKey: "matter.excluded")
        var devices: [LocalDevice] = [], cacheFiles: [URL] = []
        defer { for file in cacheFiles { try? FileManager.default.removeItem(at: file) } }
        let folder = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (model, service, piid, property, format, options) in [
            ("xiaomi.pet_waterer.70m2", "pet-drinking-fountain", 10, "water-shortage-status", "bool", ""),
            ("xiaomi.feeder.pi2001", "pet-feeder", 6, "pet-food-left-level", "uint8", ",\"value-list\":[{\"value\":0,\"description\":\"Normal\"},{\"value\":1,\"description\":\"Low\"}]")
        ] {
            let type = "\(service):cache-test-\(UUID().uuidString)"
            let json = """
            {"type":"\(type)","services":[{"iid":2,"type":"\(service)","properties":[{"iid":\(piid),"type":"\(property)","format":"\(format)","access":["read","notify"]\(options)}]}]}
            """
            let file = folder.appendingPathComponent(type.replacingOccurrences(of: ":", with: "_") + ".json")
            try Data(json.utf8).write(to: file); cacheFiles.append(file)
            devices.append(LocalDevice(did: model, name: model, model: model, host: model, token: String(repeating: "0", count: 32), specType: type))
        }
        let config = LocalHomeConfig(devices: devices), network = PetCacheTransport()
        let api = LANMiotAPI(config: { config }, transport: network)
        let controller = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        let bridge = MatterBridgeController(defaults: defaults, ephemeral: true)
        bridge.attach(controller)
        defer { bridge.shutdown(); controller.shutdown() }
        await controller.refreshNow() // The existing ordinary device refresh populates the only state cache.
        var before = await network.methods
        for _ in 0..<8 {
            let snapshot = try await bridge.handleRPC(method: "snapshot")
            #expect(snapshot.count == 2 && snapshot.allSatisfy { $0.reachable })
            #expect(snapshot.allSatisfy { $0.attributes[$0.kind] == .bool(false) && $0.on == nil })
        }
        #expect(await network.methods == before)
        await network.showShortages()
        await controller.refreshNow()
        before = await network.methods
        let changed = try await bridge.handleRPC(method: "snapshot")
        #expect(changed.allSatisfy { $0.attributes[$0.kind] == .bool(true) })
        for endpoint in changed {
            await #expect(throws: DeviceControlError.self) {
                _ = try await bridge.handleRPC(method: "set", did: endpoint.did, value: .bool(false), property: endpoint.kind)
            }
        }
        #expect(await network.methods == before)
        bridge.include(devices[0].did, false)
        #expect(bridge.selected.count == 1 && bridge.selected.first?.sourceID == devices[1].did)
        #expect(!bridge.includes("existing-exclusion"))
    }
    @Test("Matter cache reads add no queries and a control still writes then reads back with the 30-second background cadence")
    func cachedReadsAndControl() async throws {
        let suite = "matter-cached-control-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = LocalDevice(did: "1", name: "Lamp", model: "yeelink.light.lamp4", host: "192.0.2.1", token: String(repeating: "0", count: 32))
        let config = LocalHomeConfig(devices: [device]), transport = CacheControlTransport()
        let api = LANMiotAPI(config: { config }, transport: transport)
        let controller = DeviceController(api: api, config: { config }, pollingDefaults: defaults)
        let matter = MatterBridgeController(defaults: defaults, ephemeral: true)
        matter.attach(controller)
        defer { matter.shutdown(); controller.shutdown() }
        #expect(controller.pollingIntervals.backgroundSeconds == 30)
        await controller.refreshNow()
        let before = await transport.methods
        for _ in 0..<10 { _ = try await matter.handleRPC(method: "snapshot") }
        #expect(await transport.methods == before)
        _ = try await matter.handleRPC(method: "set", did: device.did, value: .bool(false), property: "on")
        #expect(Array(await transport.methods.dropFirst(before.count)) == ["set_power", "get_prop"])
        #expect(controller.snapshots[device.did]?.value("p:2:1") == .bool(false))
        #expect(controller.snapshots[device.did]?.commandReceipt?.confirmedAt != nil)
    }
    @Test("Repeated Matter snapshots consume the shared cache without probing even an unexported curtain")
    func noExtraPolls() async throws {
        let transport = SnapshotTransport()
        let config = LocalHomeConfig(devices: [
            LocalDevice(did: "1", name: "Light", model: "yeelink.light.lamp4", host: "192.0.2.1", token: String(repeating: "0", count: 32)),
            LocalDevice(did: "2", name: "Curtain", model: CurtainValidationSession.model, host: "192.0.2.2", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)])
        let api = LANMiotAPI(config: { config }, transport: transport)
        let controller = DeviceController(api: api, config: { config })
        let suite = "matter-cache-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let matter = MatterBridgeController(defaults: defaults, ephemeral: true)
        matter.attach(controller)
        defer { matter.shutdown(); controller.shutdown() }
        matter.isEnabled = true
        for _ in 0..<8 {
            let devices = try await matter.handleRPC(method: "snapshot")
            #expect(devices.contains { $0.did == "1" })
            #expect(!devices.contains { $0.did == "2" })
            #expect(devices.allSatisfy { !$0.reachable })
        }
        #expect(await transport.calls == 0)
    }
}

private actor PetCacheTransport: MiioTransport {
    private var shortage = false
    private(set) var methods: [String] = []
    func showShortages() { shortage = true }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let token = Data(repeating: 0, count: 16)
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        guard case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 }) else { throw MiioError.malformedPacket }
        let method = request["method"]?.stringValue ?? ""
        methods.append(method)
        let result: JSONValue
        if method == "miIO.info" { result = .object(["model": .string(host)]) }
        else if method == "get_properties", case .array(let rows) = request["params"] {
            result = .array(rows.map { row in
                guard case .object(var fields) = row else { return .null }
                fields["code"] = .number(0)
                fields["value"] = host == "xiaomi.pet_waterer.70m2" ? .bool(shortage) : .number(shortage ? 1 : 0)
                return .object(fields)
            })
        } else { throw MiioError.unsupportedByLegacyDevice }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}

private actor CacheControlTransport: MiioTransport {
    private var on = true
    private(set) var methods: [String] = []
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let token = Data(repeating: 0, count: 16)
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        guard case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 }) else { throw MiioError.malformedPacket }
        let method = request["method"]?.stringValue ?? ""
        let params: [JSONValue]
        if case .array(let array) = request["params"] { params = array } else { params = [] }
        methods.append(method)
        let result: JSONValue
        switch method {
        case "miIO.info": result = .object(["model": .string("yeelink.light.lamp4")])
        case "get_prop": result = .array(params.map { $0 == .string("power") ? .string(on ? "on" : "off") : $0 == .string("bright") ? .number(35) : .number(3500) })
        case "set_power": on = params.first == .string("on"); result = .array([.string("ok")])
        default: throw MiioError.unsupportedByLegacyDevice
        }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
