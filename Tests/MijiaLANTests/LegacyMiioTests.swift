import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private let token = "00112233445566778899aabbccddeeff"

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: LocalHomeConfig
    init(_ config: LocalHomeConfig) { self.config = config }
    var value: LocalHomeConfig { lock.withLock { config } }
}

private func device(_ did: String, _ model: String, host: String) -> LocalDevice {
    LocalDevice(did: did, name: model, model: model, host: host, token: token)
}

struct LegacyMiioProfileTests {
    @Test("Legacy values convert to MIoT and back")
    func conversions() throws {
        let ac = try #require(LegacyMiioProfile.forModel("lumi.acpartner.mcn02"))
        let mode = try #require(ac.property(siid: 2, piid: 2))
        #expect(mode.miotValue(.string("heat")) == .number(3))
        #expect(mode.legacyArgument(.number(4)) == .string("wind"))
        #expect(mode.miotValue(.string("turbo")) == nil)
        let power = try #require(ac.property(siid: 2, piid: 1))
        #expect(power.miotValue(.string("on")) == .bool(true))
        #expect(power.legacyArgument(.bool(false)) == .string("off"))
        #expect(ac.property(siid: 5, piid: 1)?.setter == nil)

        let lamp = try #require(LegacyMiioProfile.forModel("yeelink.light.lamp4"))
        // Yeelight sends numbers as strings.
        #expect(lamp.property(siid: 2, piid: 2)?.miotValue(.string("71")) == .number(71))
        #expect(LegacyMiioProfile.forModel("cuco.plug.v3") == nil)
    }
}

struct LegacyLANTests {
    @Test("A Yeelight lamp is read with get_prop and written with its own setters")
    func yeelight() async throws {
        let network = FakeMiioNetwork()
        let lamp = network.add(host: "192.168.1.228", token: token, deviceID: 306)
        lamp.legacyProps = ["power": .string("off"), "bright": .string("71"), "ct": .string("2625")]
        let config = ConfigBox(LocalHomeConfig(devices: [device("306", "yeelink.light.lamp4", host: "192.168.1.228")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        let keys = [1, 2, 3, 4].map { MiotPropKey(did: "306", siid: 2, piid: $0) }
        let values = try await api.getProps(keys)
        #expect(values == [keys[0]: .bool(false), keys[1]: .number(71), keys[2]: .number(2625)])
        #expect(!lamp.receivedMethods.contains("get_properties"))

        try await api.setProps([
            MiotPropWrite(did: "306", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "306", siid: 2, piid: 2, value: .number(30)),
            MiotPropWrite(did: "306", siid: 2, piid: 3, value: .number(5000)),
        ])
        #expect(lamp.legacyCalls == [#"set_power ["on"]"#, "set_bright [30]", #"set_ct_abx [5000,"smooth",500]"#])
        await #expect(throws: MiioError.unsupportedByLegacyDevice) {
            try await api.setProps([MiotPropWrite(did: "306", siid: 2, piid: 4, value: .number(1))])
        }
        #expect(await api.currentHealth()["306"]?.state == .online)
    }

    @Test("A pre-MIoT model without a table is reported as such, not as a wrong token")
    func unknownLegacyModel() async throws {
        let network = FakeMiioNetwork()
        let old = network.add(host: "192.168.1.30", token: token, deviceID: 30)
        old.legacyProps = ["power": .string("on")]
        let config = ConfigBox(LocalHomeConfig(devices: [device("30", "lumi.acpartner.v9", host: "192.168.1.30")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        #expect(try await api.deviceList().first?.isOnline == true)

        let keys = [MiotPropKey(did: "30", siid: 2, piid: 1)]
        _ = try await api.getProps(keys)
        _ = try await api.getProps(keys)
        let health = try #require(await api.currentHealth()["30"])
        #expect(health.state == .unsupported)
        #expect(health.lastError?.contains("lumi.acpartner.v9") == true)

        // Not probed again (and flipped back online) on every refresh.
        let probes = old.receivedMethods.filter { $0 == "miIO.info" }.count
        #expect(try await api.deviceList().first?.isOnline == false)
        #expect(old.receivedMethods.filter { $0 == "miIO.info" }.count == probes)
    }

    @Test("An IP with nothing behind it is offline right away, with a plain explanation")
    func hostUnreachable() async throws {
        let network = FakeMiioNetwork()
        let gone = network.add(host: "192.168.1.243", token: token, deviceID: 243, props: ["2.1": .bool(true)])
        let config = ConfigBox(LocalHomeConfig(devices: [device("243", "dmaker.fan.p28", host: "192.168.1.243")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        gone.unreachable = true
        _ = try await api.getProps([MiotPropKey(did: "243", siid: 2, piid: 1)])
        let health = try #require(await api.currentHealth()["243"])
        #expect(health.state == .offline)
        #expect(health.lastError?.contains("这个 IP 上没有设备") == true)
    }
}

/// The AC companion end to end: legacy reads become a climate device, and the panel's mode change becomes
/// `set_power` + `set_mode` on the device.
struct LegacyIntegrationTests {
    @Test("小米空调伴侣 2 shows up as an AC and takes mode changes")
    @MainActor
    func acPartner() async throws {
        let network = FakeMiioNetwork()
        let ac = network.add(host: "192.168.1.134", token: token, deviceID: 683)
        ac.legacyProps = ["power": .string("off"), "mode": .string("cool"), "tar_temp": .number(29),
                          "fan_level": .string("auto_fan"), "ver_swing": .string("on"), "load_power": .number(0)]
        let config = ConfigBox(LocalHomeConfig(devices: [device("683", "lumi.acpartner.mcn02", host: "192.168.1.134")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        let provider = LocalHomeProvider.make(api: api, specSource: StubSpecSource(),
                                              pollInterval: .milliseconds(100), closedPollInterval: .milliseconds(100))
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.mijialan.legacy.\(UUID().uuidString)")

        let climate = try await waitFor { () -> ClimateSpec? in
            guard case .climate(let spec) = store.devices.first(where: { $0.id == "683" })?.kind else { return nil }
            return spec
        }
        #expect(!climate.isOn)
        #expect(climate.targetTemperature == 29)
        #expect(climate.availableModes.contains("heat"))
        #expect(climate.fanMode == "Auto")

        store.setClimateMode("683", mode: "heat")
        _ = try await waitFor { ac.legacyCalls.count >= 2 ? true : nil }
        #expect(ac.legacyCalls.prefix(2) == [#"set_power ["on"]"#, #"set_mode ["heat"]"#])
        #expect(!ac.receivedMethods.contains("get_properties"))
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
