import Foundation
import Testing
import HAPCore
import MijiaCore
@testable import MijiaHomeKitBridge

struct HomeKitSetupCodeTests {
    /// Vectors computed independently by itsyhome-macos (HAP 5.10.3 layout, bridge category).
    @Test("Setup URI matches independent vectors")
    func setupURIVectors() {
        #expect(HomeKitSetupCode.setupURI(setupCode: "031-45-154", setupID: "ACMN") == "X-HM://0023ISYWYACMN")
        #expect(HomeKitSetupCode.setupURI(setupCode: "123-44-321", setupID: "ACMN") == "X-HM://0023OA51DACMN")
        #expect(HomeKitSetupCode.setupURI(setupCode: "000-00-001", setupID: "ACMN") == "X-HM://0023GXK3LACMN")
        #expect(HomeKitSetupCode.setupURI(setupCode: "999-99-999", setupID: "ACMN") == "X-HM://00254GWLBACMN")
    }

    @Test("Malformed setup codes produce no URI")
    func malformedSetupURI() {
        #expect(HomeKitSetupCode.setupURI(setupCode: "", setupID: "ACMN") == nil)
        #expect(HomeKitSetupCode.setupURI(setupCode: "123-45", setupID: "ACMN") == nil)
        #expect(HomeKitSetupCode.setupURI(setupCode: "abc-de-fgh", setupID: "ACMN") == nil)
        #expect(HomeKitSetupCode.setupURI(setupCode: "031-45-154", setupID: "ACM") == nil)
    }

    @Test("Trivial codes are rejected and generated codes are always valid")
    func codeValidity() {
        #expect(!HomeKitSetupCode.isValid("111-11-111"))
        #expect(!HomeKitSetupCode.isValid("123-45-678"))
        #expect(!HomeKitSetupCode.isValid("876-54-321"))
        #expect(!HomeKitSetupCode.isValid("12345678"))
        #expect(HomeKitSetupCode.isValid("031-45-154"))

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            #expect(HomeKitSetupCode.isValid(HomeKitSetupCode.generate(using: &generator)))
        }
        #expect(HomeKitSetupCode.makeSetupID(using: &generator).count == 4)
        #expect(HomeKitSetupCode.makeDeviceID(using: &generator).split(separator: ":").count == 6)
    }

    @Test("Secrets survive a round trip and a damaged blob is rejected")
    func secretsRoundTrip() throws {
        let secrets = HomeKitBridgeSecrets.generate()
        let data = try #require(secrets.encoded())
        #expect(HomeKitBridgeSecrets.decode(data) == secrets)

        var damaged = secrets
        damaged.signingKey = Data([1, 2, 3])
        #expect(HomeKitBridgeSecrets.decode(try #require(damaged.encoded())) == nil)
        #expect(HomeKitBridgeSecrets.decode(Data("not json".utf8)) == nil)
    }
}

struct HomeKitAccessoryMapperTests {
    static func light(isOn: Bool = true, brightness: Int? = 60, kelvin: Int? = 4000) -> SmartDevice {
        SmartDevice(
            id: "light_study", name: "书房台灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: isOn, brightnessPercent: brightness, colorTempKelvin: kelvin))
        )
    }

    static func climate(isOn: Bool = true, mode: String = "cool", modes: [String] = ["off", "cool", "heat", "auto", "dry"]) -> SmartDevice {
        SmartDevice(
            id: "ac_living", name: "客厅空调", roomId: "living", roomName: "客厅",
            model: "xiaomi.aircondition.m9", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.living", isOn: isOn, hvacMode: mode, availableModes: modes,
                targetTemperature: 24, currentTemperature: 27.5, minTemp: 16, maxTemp: 30, step: 0.5
            ))
        )
    }

    static func characteristic(_ plan: HomeKitAccessoryPlan, _ role: HomeKitRole) -> HAPCharacteristic? {
        plan.services.first(where: { $0.type == role.serviceType })?
            .characteristics.first(where: { $0.type == role.characteristicType })
    }

    @Test("A dimmable white light becomes a lightbulb with its own colour temperature range")
    func lightPlan() throws {
        let plan = try #require(HomeKitAccessoryMapper.plan(for: Self.light(), name: "书房台灯"))
        #expect(plan.services.map(\.type) == [.lightbulb])
        #expect(plan.info.manufacturer == "yeelink")

        let ct = try #require(Self.characteristic(plan, .lightColorTemperature))
        #expect(ct.minValue == 154) // 6500 K
        #expect(ct.maxValue == 370) // 2700 K
        #expect(ct.value == .int32(250))
        #expect(ct.isWritable)

        let values = HomeKitAccessoryMapper.values(for: Self.light())
        #expect(values[.lightOn] == .bool(true))
        #expect(values[.lightBrightness] == .int32(60))
    }

    @Test("A light without brightness or colour temperature exposes only on/off")
    func plainLight() throws {
        let plan = try #require(HomeKitAccessoryMapper.plan(for: Self.light(brightness: nil, kelvin: nil), name: "灯"))
        #expect(plan.services.first?.characteristics.map(\.type) == [.on])
    }

    @Test("Changing the controls changes the signature; changing a value does not")
    func signature() throws {
        let base = try #require(HomeKitAccessoryMapper.plan(for: Self.light(), name: "书房台灯"))
        let dimmer = try #require(HomeKitAccessoryMapper.plan(for: Self.light(isOn: false, brightness: 10, kelvin: 3000), name: "书房台灯"))
        let plain = try #require(HomeKitAccessoryMapper.plan(for: Self.light(brightness: nil), name: "书房台灯"))
        let renamed = try #require(HomeKitAccessoryMapper.plan(for: Self.light(), name: "台灯"))
        #expect(base.signature == dimmer.signature)
        #expect(base.signature != plain.signature)
        #expect(base.signature != renamed.signature)
    }

    @Test("Air conditioner modes map to HAP thermostat states")
    func climatePlan() throws {
        let plan = try #require(HomeKitAccessoryMapper.plan(for: Self.climate(), name: "客厅空调"))
        let target = try #require(Self.characteristic(plan, .thermostatTargetState))
        #expect(target.validValues == [0, 1, 2, 3])
        #expect(target.value == .uint8(2))
        #expect(Self.characteristic(plan, .thermostatTargetTemperature)?.minStep == 0.5)
        #expect(Self.characteristic(plan, .thermostatCurrentTemperature)?.value == .float(27.5))

        let off = HomeKitAccessoryMapper.values(for: Self.climate(isOn: false))
        #expect(off[.thermostatTargetState] == .uint8(0))
        #expect(off[.thermostatCurrentState] == .uint8(0))

        let heater = Self.climate(mode: "heat", modes: ["heat"])
        let heaterPlan = try #require(HomeKitAccessoryMapper.plan(for: heater, name: "电暖器"))
        #expect(Self.characteristic(heaterPlan, .thermostatTargetState)?.validValues == [0, 1])
    }

    @Test("Sensors expose temperature, humidity and battery; a sensor with neither reading is skipped")
    func sensorPlan() throws {
        let sensor = SmartDevice(
            id: "th", name: "温湿度计", roomId: "bed", roomName: "主卧", model: "miaomiaoce.sensor_ht.t2",
            isOnline: true, kind: .sensor(SensorSpec(temperature: 25.8, humidity: 58, battery: 9))
        )
        let plan = try #require(HomeKitAccessoryMapper.plan(for: sensor, name: "温湿度计"))
        #expect(Set(plan.services.map(\.type)) == [.temperatureSensor, .humiditySensor, HomeKitAccessoryMapper.batteryService])
        let values = HomeKitAccessoryMapper.values(for: sensor)
        #expect(values[.batteryLow] == .uint8(1))
        #expect(values[.batteryChargingState] == .uint8(2))

        let statusOnly = SmartDevice(
            id: "door", name: "门锁", roomId: "hall", roomName: "玄关", model: "loock.lock.v1",
            isOnline: true, kind: .sensor(SensorSpec(battery: 80, statusText: "已上锁"))
        )
        #expect(HomeKitAccessoryMapper.plan(for: statusOnly, name: "门锁") == nil)
    }

    @Test("Devices without a HAP counterpart are not exposed")
    func unsupportedKinds() {
        let vacuum = SmartDevice(
            id: "vac", name: "扫地机", roomId: "bed", roomName: "主卧", model: "roborock.vacuum.a15",
            isOnline: true, kind: .vacuum(VacuumSpec(entityId: "vacuum.r", status: "docked"))
        )
        #expect(HomeKitAccessoryMapper.plan(for: vacuum, name: "扫地机") == nil)
    }

    @Test("Writes that change nothing are dropped")
    func noOpWrites() {
        let light = Self.light()
        #expect(HomeKitAccessoryMapper.write(.lightOn, value: .bool(true), to: light) == nil)
        #expect(HomeKitAccessoryMapper.write(.lightBrightness, value: .uint8(60), to: light) == nil)
        #expect(HomeKitAccessoryMapper.write(.lightColorTemperature, value: .uint8(250), to: light) == nil)
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetTemperature, value: .float(24), to: Self.climate()) == nil)
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetState, value: .uint8(2), to: Self.climate()) == nil)
        // Read-only roles never map to a write.
        #expect(HomeKitAccessoryMapper.write(.outletInUse, value: .bool(true), to: light) == nil)
    }

    @Test("Writes map to the store action for the change")
    func writes() {
        let light = Self.light()
        // Controllers send JSON 1/0 as often as true/false.
        #expect(HomeKitAccessoryMapper.write(.lightOn, value: .uint8(0), to: light) == .power(false))
        #expect(HomeKitAccessoryMapper.write(.lightBrightness, value: .uint8(0), to: light) == .power(false))
        #expect(HomeKitAccessoryMapper.write(.lightBrightness, value: .uint8(35), to: light) == .brightness(35))
        #expect(HomeKitAccessoryMapper.write(.lightColorTemperature, value: .uint16(200), to: light) == .colorTemperature(kelvin: 5000))
        #expect(HomeKitAccessoryMapper.write(.lightColorTemperature, value: .uint16(500), to: light) == .colorTemperature(kelvin: 2700))
        // Colour temperature alone must not switch a light on.
        #expect(HomeKitAccessoryMapper.write(.lightColorTemperature, value: .uint16(200), to: Self.light(isOn: false)) == nil)

        let ac = Self.climate()
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetState, value: .uint8(0), to: ac) == .climateMode("off"))
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetState, value: .uint8(1), to: ac) == .climateMode("heat"))
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetState, value: .uint8(3), to: ac) == .climateMode("auto"))
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetState, value: .uint8(2), to: Self.climate(isOn: false)) == .climateMode("cool"))
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetTemperature, value: .float(26.2), to: ac) == .targetTemperature(26))
        #expect(HomeKitAccessoryMapper.write(.thermostatTargetTemperature, value: .float(35), to: ac) == .targetTemperature(30))
    }

    @Test("Duplicate names across rooms get the room as a prefix")
    func duplicateNames() {
        let a = SmartDevice(id: "a", name: "吸顶灯", roomId: "bed", roomName: "主卧", model: "m", isOnline: true,
                            kind: .light(LightSpec(entityId: "light.a", isOn: false)))
        let b = SmartDevice(id: "b", name: "吸顶灯", roomId: "living", roomName: "客厅", model: "m", isOnline: true,
                            kind: .light(LightSpec(entityId: "light.b", isOn: false)))
        let c = Self.light()
        let names = HomeKitBridgeController.displayNames(for: [a, b, c])
        #expect(names == ["a": "主卧 吸顶灯", "b": "客厅 吸顶灯", "light_study": "书房台灯"])
    }
}

/// Writes from Apple Home must land in the store exactly like panel actions.
struct HomeKitWriteRoutingTests {
    @MainActor
    func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "书房"), RoomArea(id: "living", name: "客厅")],
            devices: devices,
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.homekit.\(UUID().uuidString)")
        for _ in 0..<100 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @MainActor
    func waitForCommands(_ mock: MockHomeProvider, count: Int) async throws -> [DeviceCommand] {
        for _ in 0..<200 {
            let commands = await mock.executedCommands
            if commands.count >= count { return commands }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await mock.executedCommands
    }

    @Test("Power, brightness and AC mode writes reach the provider")
    @MainActor
    func routesWrites() async throws {
        let (store, mock) = try await makeStore([HomeKitAccessoryMapperTests.light(), HomeKitAccessoryMapperTests.climate()])
        let light = try #require(store.devices.first(where: { $0.id == "light_study" }))
        let ac = try #require(store.devices.first(where: { $0.id == "ac_living" }))

        HomeKitBridgeController.apply(.power(false), to: light, in: store)
        HomeKitBridgeController.apply(.climateMode("heat"), to: ac, in: store)
        var commands = try await waitForCommands(mock, count: 2)
        #expect(commands.contains(.setLightPower(entityId: "light.study", isOn: false)))
        #expect(commands.contains(.setClimateMode(entityId: "climate.living", hvacMode: "heat")))

        // The optimistic state is what the bridge re-sends to Apple Home right away.
        #expect(HomeKitAccessoryMapper.values(for: try #require(store.devices.first(where: { $0.id == "light_study" })))[.lightOn] == .bool(false))

        let refreshedAC = try #require(store.devices.first(where: { $0.id == "ac_living" }))
        HomeKitBridgeController.apply(.targetTemperature(26.5), to: refreshedAC, in: store)
        commands = try await waitForCommands(mock, count: 3)
        #expect(commands.contains(.setClimateTemperature(entityId: "climate.living", temperature: 26.5)))
    }

    @Test("Power writes that match the current state send nothing")
    @MainActor
    func samePowerIsNoOp() async throws {
        let (store, mock) = try await makeStore([HomeKitAccessoryMapperTests.light(isOn: true)])
        let light = try #require(store.devices.first)
        HomeKitBridgeController.apply(.power(true), to: light, in: store)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mock.executedCommands.isEmpty)
    }
}

/// A provider that never delivers a device list, like a backend still logging in.
private actor SilentProvider: HomeProvider {
    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { $0.yield(.statusChanged(.connecting)) }
    }
    func execute(_ command: DeviceCommand) async throws {}
    func refreshNow() async {}
}

private final class VaultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _saves = 0
    var loads: Int { lock.withLock { _loads } }
    var saves: Int { lock.withLock { _saves } }
    func recordLoad() { lock.withLock { _loads += 1 } }
    func recordSave() { lock.withLock { _saves += 1 } }
}

struct HomeKitBridgeControllerTests {
    @Test("The bridge stays offline, and never reads the Keychain, until the first device list arrives")
    @MainActor
    func waitsForDevices() async throws {
        let probe = VaultProbe()
        let vault = HomeKitBridgeVault(load: { probe.recordLoad(); return .missing }, save: { _ in true })
        let defaults = try #require(UserDefaults(suiteName: "test.homekit.controller.\(UUID().uuidString)"))
        let store = HomeStore(provider: SilentProvider(), defaultsSuiteName: "test.homekit.silent.\(UUID().uuidString)")

        let controller = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0)
        // MijiaLAN exists to be a bridge, so it is on until the user turns it off.
        #expect(controller.isEnabled)
        controller.attach(to: store)
        await controller.waitUntilIdle()

        #expect(controller.status == .waitingForDevices)
        #expect(probe.loads == 0)
        #expect(controller.setupCode == nil)

        controller.isEnabled = false
        await controller.waitUntilIdle()
        #expect(controller.status == .stopped)
        #expect(defaults.object(forKey: HomeKitBridgeController.enabledKey) as? Bool == false)
    }

    @Test("A device kept out of Apple Home gets no accessory, and comes back when included again")
    @MainActor
    func hiddenDevicesAreLeftOut() async throws {
        let (store, _) = try await HomeKitWriteRoutingTests().makeStore([HomeKitAccessoryMapperTests.light(), HomeKitAccessoryMapperTests.climate()])
        let vault = HomeKitBridgeVault(load: { .missing }, save: { _ in true })
        let defaults = try #require(UserDefaults(suiteName: "test.homekit.controller.\(UUID().uuidString)"))
        let controller = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0)
        #expect(Set(controller.currentPlans(store: store).map(\.plan.deviceId)) == ["light_study", "ac_living"])

        store.hideDevice("light_study")
        #expect(controller.currentPlans(store: store).map(\.plan.deviceId) == ["ac_living"])

        store.unhideDevice("light_study")
        #expect(Set(controller.currentPlans(store: store).map(\.plan.deviceId)) == ["light_study", "ac_living"])
    }

    @Test("An unreadable Keychain keeps the bridge off instead of inventing a new identity")
    @MainActor
    func unreadableVault() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: [], devices: [HomeKitAccessoryMapperTests.light()], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.homekit.vault.\(UUID().uuidString)")
        for _ in 0..<100 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let probe = VaultProbe()
        let vault = HomeKitBridgeVault(load: { .unavailable }, save: { _ in probe.recordSave(); return true })
        let defaults = try #require(UserDefaults(suiteName: "test.homekit.controller.\(UUID().uuidString)"))

        let controller = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0)
        controller.attach(to: store)
        controller.isEnabled = true
        await controller.waitUntilIdle()

        guard case .failed = controller.status else {
            Issue.record("Expected a failed status, got \(controller.status)")
            return
        }
        #expect(probe.saves == 0)
        #expect(controller.exposedDeviceCount == 0)
    }
}
