import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private let tokenA = "00112233445566778899aabbccddeeff"
private let tokenB = "ffeeddccbbaa99887766554433221100"

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: LocalHomeConfig
    init(_ config: LocalHomeConfig) { self.config = config }
    var value: LocalHomeConfig {
        get { lock.withLock { config } }
        set { lock.withLock { config = newValue } }
    }
}

private func lamp(_ did: String, host: String, token: String = tokenA, room: String? = nil) -> LocalDevice {
    LocalDevice(did: did, name: "台灯 \(did)", model: "yeelink.light.fake1", host: host, token: token,
                specType: FakeSpecs.lightType, roomName: room)
}

struct LANMiotAPITests {
    @Test("The device list probes each device and reports who answered")
    func deviceList() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.10", token: tokenA, deviceID: 10)
        network.add(host: "192.168.1.11", token: tokenA, deviceID: 11).offline = true
        network.add(host: "192.168.1.12", token: tokenA, deviceID: 12)
        let config = ConfigBox(LocalHomeConfig(devices: [
            lamp("10", host: "192.168.1.10", room: "书房"),
            lamp("11", host: "192.168.1.11", room: "书房"),
            lamp("12", host: "192.168.1.12", token: tokenB),
        ]))
        let api = LANMiotAPI(config: { config.value }, transport: network)

        let records = try await api.deviceList()
        #expect(records.map(\.isOnline) == [true, false, false])
        #expect(records.first?.specType == FakeSpecs.lightType)
        let health = await api.currentHealth()
        #expect(health["10"]?.state == .online)
        #expect(health["11"]?.state == .offline)
        #expect(health["12"]?.state == .tokenRejected)

        let rooms = try await api.homeRooms()
        #expect(rooms.map(\.name) == ["书房", ""])
        #expect(rooms.first?.dids == ["10", "11"])
    }

    @Test("One silent device does not fail the poll, and goes offline after two misses")
    func partialPoll() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.10", token: tokenA, deviceID: 10, props: ["2.1": .bool(true)])
        let flaky = network.add(host: "192.168.1.11", token: tokenA, deviceID: 11, props: ["2.1": .bool(false)])
        let config = ConfigBox(LocalHomeConfig(devices: [lamp("10", host: "192.168.1.10"), lamp("11", host: "192.168.1.11")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        let keys = [MiotPropKey(did: "10", siid: 2, piid: 1), MiotPropKey(did: "11", siid: 2, piid: 1)]
        #expect(try await api.getProps(keys).count == 2)

        flaky.offline = true
        #expect(try await api.getProps(keys) == [MiotPropKey(did: "10", siid: 2, piid: 1): .bool(true)])
        #expect(await api.currentHealth()["11"]?.state == .online)
        _ = try await api.getProps(keys)
        #expect(await api.currentHealth()["11"]?.state == .offline)

        // Back on the network: the next device-list refresh finds it.
        flaky.offline = false
        #expect(try await api.deviceList().map(\.isOnline) == [true, true])
    }

    @Test("Writes are grouped per device and a rejected write throws")
    func writes() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.168.1.10", token: tokenA, deviceID: 10)
        let config = ConfigBox(LocalHomeConfig(devices: [lamp("10", host: "192.168.1.10")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)

        try await api.setProps([
            MiotPropWrite(did: "10", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "10", siid: 2, piid: 2, value: .number(30)),
        ])
        #expect(device.receivedMethods == ["set_properties"])
        #expect(device.props["2.2"] == .number(30))

        try await api.action(MiotActionCall(did: "10", siid: 3, aiid: 1, inputs: [.number(2)]))
        await #expect(throws: MiioError.self) {
            try await api.setProps([MiotPropWrite(did: "10", siid: 9, piid: 9, value: .number(1))])
        }
        await #expect(throws: MiioError.self) {
            try await api.setProps([MiotPropWrite(did: "404", siid: 2, piid: 1, value: .bool(true))])
        }
    }

    @Test("A new token from a re-import is judged afresh")
    func tokenChange() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.10", token: tokenA, deviceID: 10)
        let config = ConfigBox(LocalHomeConfig(devices: [lamp("10", host: "192.168.1.10", token: tokenB)]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        #expect(try await api.deviceList().first?.isOnline == false)
        #expect(await api.currentHealth()["10"]?.state == .tokenRejected)

        config.value.devices[0].token = tokenA
        #expect(try await api.deviceList().first?.isOnline == true)
    }
}

struct DeviceImportTests {
    static let deviceList: JSONValue = .object(["list": .array([
        .object(["did": .string("123456"), "name": .string("书房台灯"), "model": .string("yeelink.light.lamp4"),
                 "token": .string("00112233445566778899AABBCCDDEEFF"), "localip": .string("192.168.1.40"),
                 "mac": .string("5C:E5:0C:31:AF:FD"), "isOnline": .bool(true)]),
        .object(["did": .number(987654), "name": .string("空调伴侣"), "model": .string("lumi.acpartner.mcn02"),
                 "token": .string(tokenB), "localip": .string("192.168.1.41"),
                 "spec_type": .string("urn:miot-spec-v2:device:air-conditioner:0000A004:lumi-mcn02:1")]),
        .object(["did": .string("blt.3.abc"), "name": .string("温湿度计"), "model": .string("miaomiaoce.sensor_ht.t2"), "token": .string("")]),
        .object(["did": .string("lumi.158d000"), "name": .string("门窗传感器"), "model": .string("lumi.sensor_magnet.v2"),
                 "token": .string(tokenA), "localip": .string(""), "parent_id": .string("123456")]),
        .object(["did": .string("555"), "name": .string("离线插座"), "model": .string("cuco.plug.v3"), "token": .string(tokenA), "localip": .string("")]),
        .object(["did": .string("556"), "name": .string("没 token"), "model": .string("cuco.plug.v3"), "localip": .string("192.168.1.42")]),
    ])])

    @Test("Only Wi-Fi devices with a token and LAN IP are imported; the rest say why")
    func parse() {
        let rooms = [MiRoom(id: "1", name: "书房", dids: ["123456", "blt.3.abc"]), MiRoom(id: "h", name: "", dids: ["987654"])]
        let result = CloudTokenImport.parse(Self.deviceList, rooms: rooms, region: "cn")
        #expect(result.devices.map(\.did) == ["123456", "987654"])
        #expect(result.devices[0].token == "00112233445566778899aabbccddeeff")
        #expect(result.devices[0].roomName == "书房")
        #expect(result.devices[1].roomName == nil)
        #expect(result.devices[1].specType == "urn:miot-spec-v2:device:air-conditioner:0000A004:lumi-mcn02:1")
        #expect(result.skipped.map(\.did) == ["blt.3.abc", "lumi.158d000", "555", "556"])
        #expect(result.skipped[0].reason.contains("蓝牙"))
        #expect(result.skipped[1].reason.contains("网关"))
        #expect(result.skipped[2].reason.contains("IP"))
        #expect(result.skipped[3].reason.contains("token"))
    }

    @Test("An empty device list on one region moves on to the next")
    func regionFallback() async throws {
        let transport = StubCloudTransport { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""
            if path.hasSuffix("home/device_list") {
                return .object(["code": .number(0), "result": host.hasPrefix("de.") ? Self.deviceList : .object(["list": .array([])])])
            }
            return .object(["code": .number(0), "result": .object(["homelist": .array([])])])
        }
        let session = MiSession(userId: "1", cUserId: "c", ssecurity: "AAAAAAAAAAAAAAAAAAAAAA==", serviceToken: "t", region: "cn")
        let result = try await CloudTokenImport.fetch(session: session, transport: transport)
        #expect(result.region == "de")
        #expect(result.devices.count == 2)
        #expect(transport.hosts.first == "api.io.mi.com")
    }

    @Test("Adding by IP and token reads the model and proves the token")
    func manual() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.60", token: tokenA, deviceID: 6060)
        let device = try await ManualDeviceProbe.probe(host: " 192.168.1.60 ", token: tokenA.uppercased(), name: "",
                                                       specSource: StubSpecSource(), transport: network)
        #expect(device.did == "6060")
        #expect(device.model == "yeelink.light.fake1")
        #expect(device.name == "yeelink.light.fake1")
        #expect(device.specType == FakeSpecs.lightType)
        #expect(device.token == tokenA)

        await #expect(throws: MiioError.noEncryptedReply) {
            try await ManualDeviceProbe.probe(host: "192.168.1.60", token: tokenB, transport: network)
        }
        await #expect(throws: MiioError.invalidToken) {
            try await ManualDeviceProbe.probe(host: "192.168.1.60", token: "abc", transport: network)
        }
    }

    @Test("Merging keeps rooms, and discovery follows a device to its new IP")
    func configMerge() {
        var config = LocalHomeConfig(devices: [lamp("1", host: "192.168.1.5", room: "卧室")],
                                     skipped: [SkippedDevice(did: "2", name: "x", model: "m", reason: "r")])
        config.merge([LocalDevice(did: "1", name: "新名字", model: "m", host: "192.168.1.6", token: tokenB),
                      LocalDevice(did: "2", name: "插座", model: "m", host: "192.168.1.7", token: tokenA)])
        #expect(config.devices.map(\.roomName) == ["卧室", nil])
        #expect(config.devices[0].host == "192.168.1.6")
        #expect(config.skipped.isEmpty)

        let moved = config.updateHosts(from: [MiioDiscoveredDevice(host: "192.168.1.99", deviceID: 2)])
        #expect(moved)
        #expect(config.devices[1].host == "192.168.1.99")
        let movedAgain = config.updateHosts(from: [MiioDiscoveredDevice(host: "192.168.1.99", deviceID: 2)])
        #expect(!movedAgain)
        #expect(LocalHomeConfig.decode(config.encoded()!) == config)
    }
}

struct SecretVaultTests {
    @Test("Entries share one item, and an unreadable item is never overwritten")
    func vault() {
        let vault = SecretVault(storage: .memory())
        #expect(vault.lookup("a") == .missing)
        #expect(vault.set(Data("1".utf8), for: "a"))
        #expect(vault.set(Data("2".utf8), for: "b"))
        #expect(vault.lookup("a") == .value(Data("1".utf8)))
        #expect(vault.set(nil, for: "a"))
        #expect(vault.lookup("a") == .missing)

        final class Writes: @unchecked Sendable { var count = 0 }
        let writes = Writes()
        let locked = SecretVault(storage: .init(read: { .unavailable }, write: { _ in writes.count += 1; return true }))
        #expect(locked.lookup("a") == .unavailable)
        #expect(!locked.set(Data("x".utf8), for: "a"))
        #expect(writes.count == 0)
    }
}

/// The whole chain the app runs: LAN API → `MiCloudProvider` → `HomeStore`, with a fake light on the "network".
struct LocalHomeIntegrationTests {
    @Test("A LAN light shows up in HomeStore and the panel's toggle reaches the device")
    @MainActor
    func endToEnd() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.168.1.70", token: tokenA, deviceID: 7070,
                                 props: ["2.1": .bool(true), "2.2": .number(60), "2.3": .number(4000)])
        let config = ConfigBox(LocalHomeConfig(devices: [lamp("7070", host: "192.168.1.70", room: "书房")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        let provider = LocalHomeProvider.make(api: api, specSource: StubSpecSource(),
                                              pollInterval: .milliseconds(100), closedPollInterval: .milliseconds(100))
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.mijialan.\(UUID().uuidString)")

        let light = try await waitFor { store.devices.first(where: { $0.id.contains("7070") }) }
        #expect(light.isOnline)
        #expect(light.roomName == "书房")
        guard case .light(let spec) = light.kind else {
            Issue.record("Expected a light, got \(light.kind)")
            return
        }
        #expect(spec.isOn)
        #expect(spec.brightnessPercent == 60)

        _ = store.togglePrimary(light)
        _ = try await waitFor { device.props["2.1"] == .bool(false) ? true : nil }
        let toggled = try await waitFor { () -> SmartDevice? in
            guard let current = store.devices.first(where: { $0.id == light.id }), !current.isActiveOn else { return nil }
            return current
        }
        #expect(!toggled.isActiveOn)
        #expect(device.receivedMethods.contains("set_properties"))
        await provider.shutdown()
    }

    @MainActor
    private func waitFor<T>(timeout: Duration = .seconds(5), _ probe: @MainActor () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MiioError.timeout
    }
}
