import Foundation
import HAPCore
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

/// Native services for categories without a bundled spec, following homebridge-miot. Specs are real miot-spec.org
/// instances, trimmed; the model names are placeholders so no legacy miIO table applies.
struct CategoryMappingTests {
    @Test("A humidifier is a humidifier: humidity, threshold within the spec range, water level as a percentage")
    func humidifier() throws {
        var s = try snapshot("zhimi-ca4", model: "test.humidifier.ca4")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BD" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B3", "B4", "10", "CA", "B5", "A7"])
        #expect(characteristic(service, "B3").validValues == [0, 1, 2])
        #expect(characteristic(service, "B4").validValues == [1])
        #expect(characteristic(service, "CA").minValue == 30)
        #expect(characteristic(service, "CA").maxValue == 80)
        // Humidity lives in the humidifier; temperature remains its own sensor.
        #expect(!plan.services.contains { $0.type == .humiditySensor })
        #expect(plan.services.contains { $0.type == .temperatureSensor })

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:2:7"] = DeviceReading(value: .number(64), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(2))
        #expect(value(plan, service, "B5", s) == .float(50))
        s.readings["p:2:1"] = DeviceReading(value: .bool(false), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(0))
        #expect(try commands(plan, service, "CA", .float(45), s) == [.set("p:2:6", .number(45))])
        #expect(try commands(plan, service, "B4", .uint8(1), s) == [])
        // The child lock is part of the humidifier rather than its own switch.
        #expect(try commands(plan, service, "A7", .uint8(1), s) == [.set("p:6:1", .bool(true))])
    }

    @Test("A dehumidifier dehumidifies, with its own threshold characteristic")
    func dehumidifier() throws {
        var s = try snapshot("xiaomi-13l", model: "test.derh.13l")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BD" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B3", "B4", "10", "C9", "A7"])
        #expect(characteristic(service, "B3").validValues == [0, 1, 3])
        #expect(characteristic(service, "B4").validValues == [2])
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(3))
    }

    @Test("A heater heats only, and reads its own thermometer")
    func heater() throws {
        var s = try snapshot("zhimi-za2", model: "test.heater.za2")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BC" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "12", "36", "A7"])
        #expect(characteristic(service, "B2").validValues == [1])
        #expect(characteristic(service, "12").minValue == 16)
        #expect(characteristic(service, "12").maxValue == 28)
        #expect(plan.services.contains { $0.type == .humiditySensor })
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:2"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:5:8"] = DeviceReading(value: .number(19.5), code: 0)
        #expect(value(plan, service, "B1", s) == .uint8(2))
        #expect(value(plan, service, "11", s) == .float(19.5))
    }

    @Test("An air conditioner offers the modes it has and its gears as speed; dry, fan and auto speed stay named switches")
    func airConditioner() throws {
        var s = try snapshot("xiaomi-mc4", model: "test.aircondition.mc4")
        // MijiaCore synthesizes a climate for it too; its fixed 2.x / 3.x addresses only fit the AC companion.
        let device = try #require(smart(s))
        let plan = try plan(s, legacyDevice: device)
        #expect(!plan.bindings.values.contains { if case .legacy = $0 { true } else { false } })
        let service = try #require(plan.services.first { $0.type.rawValue == "BC" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "D", "12", "36", "B6", "29"])
        #expect(characteristic(service, "B2").validValues == [1, 2])
        #expect(characteristic(service, "D").minStep == 0.5)
        let modeSwitches = plan.bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:2", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(modeSwitches.sorted() == [3, 4])
        // An Off mode would be a second power switch.
        var withOff = s
        let m = try #require(withOff.capabilities.firstIndex { $0.id == "p:2:2" })
        withOff.capabilities[m].options[1].description = "Off"
        let offModes = try self.plan(withOff, legacyDevice: device).bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:2", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(offModes == [4])

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        for (mode, current, target) in [(2.0, UInt8(3), UInt8(2)), (5, 2, 1), (3, 1, 1)] {
            s.readings["p:2:2"] = DeviceReading(value: .number(mode), code: 0)
            #expect(value(plan, service, "B1", s) == .uint8(current))
            #expect(value(plan, service, "B2", s) == .uint8(target))
        }
        #expect(try commands(plan, service, "B2", .uint8(2), s) == [.set("p:2:2", .number(2)), .set("p:2:1", .bool(true))])
        #expect(throws: HAPError.self) { try commands(plan, service, "B2", .uint8(0), s) }

        // Level1–7 share the slider; its bottom is auto, which also stays a named switch.
        #expect(characteristic(service, "29").minStep == 100.0 / 7)
        let speeds = plan.bindings.values.compactMap { binding -> Double? in
            if case .option("p:3:2", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(speeds == [0])
        s.readings["p:3:2"] = DeviceReading(value: .number(3), code: 0)
        #expect(value(plan, service, "29", s) == .float(3 * 100 / 7.0))
        s.readings["p:3:2"] = DeviceReading(value: .number(0), code: 0)
        #expect(value(plan, service, "29", s) == .float(0))
        #expect(try commands(plan, service, "29", .float(100), s) == [.set("p:3:2", .number(7))])
        #expect(try commands(plan, service, "29", .float(0), s) == [.set("p:3:2", .number(0))])
    }

    @Test("A fan is one Fan v2: speed from the vendor service, Smart as auto and the child lock; the rest stays small")
    func fan() throws {
        // dmaker.fan.p220 as reported by a user: Home previously listed 36 services, among them range-end, ± and
        // per-angle switches, plus dmaker's private power flag and two writable temperature set points as sensors.
        var s = try snapshot("dmaker-p220", model: "test.fan.p220")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type == .fanV2 })
        #expect(service.isPrimary)
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "29", "B6", "BF", "A7"])
        #expect(plan.services.filter(\.isPrimary).count == 1)
        #expect(plan.services.count == 7)
        // The gears 2.2 are covered by the speed. Angles, the timer, the vendor service, the indicator light and the
        // alarm sound stay on the Mac.
        let bound = Set(plan.bindings.values.compactMap { binding -> String? in
            switch binding { case .property(let id, _), .option(let id, _), .action(let id): id; default: nil }
        })
        #expect(bound == ["p:2:1", "p:8:1", "p:2:4", "p:2:3", "p:7:1", "p:9:1", "p:9:2", "p:2:7"])
        let modes = plan.bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:3", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(modes.sorted() == [0, 1, 3])

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:8:1"] = DeviceReading(value: .number(40), code: 0)
        s.readings["p:2:3"] = DeviceReading(value: .number(2), code: 0)
        s.readings["p:7:1"] = DeviceReading(value: .bool(true), code: 0)
        #expect(value(plan, service, "29", s) == .float(40))
        #expect(value(plan, service, "BF", s) == .uint8(1))
        #expect(value(plan, service, "A7", s) == .uint8(1))
        #expect(try commands(plan, service, "29", .float(60), s) == [.set("p:8:1", .number(60)), .set("p:2:1", .bool(true))])
        #expect(try commands(plan, service, "BF", .uint8(0), s) == [.set("p:2:3", .number(0))])
        #expect(try commands(plan, service, "A7", .uint8(0), s) == [.set("p:7:1", .bool(false))])
        // Natural wind is already manual; auto selects Smart.
        s.readings["p:2:3"] = DeviceReading(value: .number(1), code: 0)
        #expect(value(plan, service, "BF", s) == .uint8(0))
        #expect(try commands(plan, service, "BF", .uint8(0), s) == [])
        #expect(try commands(plan, service, "BF", .uint8(1), s) == [.set("p:2:3", .number(2))])
    }

    @Test("Without a percentage speed, four gears become a slider in steps of 25")
    func fanGears() throws {
        var s = try snapshot("dmaker-p220", model: "test.fan.p220")
        s.capabilities.removeAll { $0.name == "speed-level" }
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type == .fanV2 })
        #expect(characteristic(service, "29").minStep == 25)
        #expect(!plan.bindings.values.contains { if case .option("p:2:2", _) = $0 { true } else { false } })

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:2:2"] = DeviceReading(value: .number(3), code: 0)
        #expect(value(plan, service, "29", s) == .float(75))
        for (speed, level) in [(25.0, 1.0), (40, 2), (50, 2), (75, 3), (100, 4)] {
            #expect(try commands(plan, service, "29", .float(speed), s) == [.set("p:2:2", .number(level)), .set("p:2:1", .bool(true))])
        }
        #expect(try commands(plan, service, "29", .float(0), s) == [.set("p:2:1", .bool(false))])
        s.readings["p:2:1"] = DeviceReading(value: .bool(false), code: 0)
        #expect(value(plan, service, "29", s) == .float(0))
    }

    @Test("A gear list with an auto entry has no speed scale and stays named switches")
    func fanGearsWithAuto() throws {
        var s = try snapshot("dmaker-p220", model: "test.fan.p220")
        s.capabilities.removeAll { $0.name == "speed-level" }
        let i = try #require(s.capabilities.firstIndex { $0.id == "p:2:2" })
        s.capabilities[i].options[3].description = "Auto"
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type == .fanV2 })
        #expect(!service.characteristics.contains { $0.type == .rotationSpeed })
        #expect(plan.bindings.values.filter { if case .option("p:2:2", _) = $0 { true } else { false } }.count == 4)
    }

    @Test("An unreviewed device gets daily switches only: settings and program lists stay on the Mac, within a budget")
    func dailySwitchBudget() throws {
        var s = try snapshot("zhimi-ca4", model: "test.humidifier.ca4")
        let level = try #require(s.capabilities.first { $0.id == "p:2:5" })
        let dry = try #require(s.capabilities.first { $0.id == "p:2:8" })
        func copy(_ c: DeviceCapability, _ iid: Int, _ name: String, options count: Int? = nil) -> DeviceCapability {
            var c = c
            c.id = "p:2:\(iid)"; c.iid = iid; c.name = name; c.vendorDefined = false
            if let count {
                c.options = (0..<count).map { i in var o = level.options[0]; o.value = i; o.description = "Program\(i)"; return o }
            }
            return c
        }
        s.capabilities += [copy(level, 20, "mode", options: 3), copy(level, 21, "program", options: 8)] + (30..<42).map { copy(dry, $0, "feature-\($0)") }
        let plan = try plan(s)
        let switched = plan.services.filter { $0.type == .switch }.compactMap { service -> String? in
            switch service.characteristics.first.flatMap({ plan.bindings[$0.iid] }) {
            case .property(let id, _)?: id
            case .option(let id, let v)?: "\(id)=\(Int(v.doubleValue ?? -1))"
            default: nil
            }
        }
        // The device's mode comes first, then its main service in spec order until ten switches are used. The alarm
        // and screen brightness are settings, eight programs are too many for switches, and dry is zhimi's own field.
        #expect(switched == ["p:2:20=0", "p:2:20=1", "p:2:20=2", "p:2:5=0", "p:2:5=1", "p:2:5=2", "p:2:5=3", "p:2:30", "p:2:31", "p:2:32"])
    }

    @Test("Each key of a wall switch has its own name in Home, and so does each key's mode")
    func wallSwitchNames() throws {
        let names = try L10n.$overrideLanguage.withValue(.zhHans) { switchNames(try plan(try snapshot("xiaomi-2b2", model: "test.switch.2b2"))) }
        #expect(Set(names) == ["左键模式·有线和无线开关", "左键模式·无线开关", "右键模式·有线和无线开关", "右键模式·无线开关", "防闪烁模式", "右键"])
        #expect(Set(names).count == names.count)
    }

    @Test("An airer's light is named for the light, and a repeated Pause option is one switch")
    func airerNames() throws {
        let (plan, names) = try L10n.$overrideLanguage.withValue(.zhHans) {
            let plan = try plan(try snapshot("xiaomi-airer-0002", model: "test.airer.0002"))
            return (plan, switchNames(plan))
        }
        #expect(names == ["电机控制·暂停", "电机控制·升高", "电机控制·降低", "电机控制·设限时上升", "电机控制·设限时降低", "照明", "夜灯开关"])
        #expect(plan.bindings.values.contains { if case .option("p:2:5", .number(0)) = $0 { true } else { false } })
        #expect(!plan.bindings.values.contains { if case .option("p:2:5", .number(3)) = $0 { true } else { false } })
    }

    @Test("A setting the device never reports, such as the airer's motor control, is a momentary switch that reads off")
    func writeOnlySwitches() throws {
        var s = try snapshot("xiaomi-airer-0002", model: "test.airer.0002")
        #expect(s.capabilitiesByID["p:2:5"]?.readable == false)
        let plan = try plan(s)
        let up = try #require(plan.services.first { service in
            service.characteristics.contains { if case .option("p:2:5", .number(1))? = plan.bindings[$0.iid] { true } else { false } }
        })
        s.health = LANDeviceHealth(state: .online)
        #expect(value(plan, up, "25", s) == .bool(false))
        #expect(try commands(plan, up, "25", .bool(true), s) == [.set("p:2:5", .number(1))])
        #expect(try commands(plan, up, "25", .bool(false), s) == [])
    }

    @Test("A mode the spec does not list turns every mode switch off rather than making the fan unavailable")
    func unlistedMode() throws {
        var s = try snapshot("dmaker-p220", model: "test.fan.p220")
        let plan = try plan(s)
        let fan = try #require(plan.services.first { $0.type == .fanV2 })
        let modes = plan.services.filter { service in
            service.characteristics.contains { if case .option("p:2:3", _)? = plan.bindings[$0.iid] { true } else { false } }
        }
        #expect(!modes.isEmpty)
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:2:3"] = DeviceReading(value: .number(9), code: 0)
        for mode in modes { #expect(value(plan, mode, "25", s) == .bool(false)) }
        #expect(value(plan, fan, "BF", s) == .uint8(0))
    }

    @Test("A bed without a power switch reaches Home as its positions, leaving out the mode list's None and its vendor motors")
    func bedPositions() throws {
        var s = try snapshot("satori-sd01", model: "test.bed.sd01")
        #expect(CapabilityHomeKitMapper.mapsToHome(s))
        let plan = try plan(s)
        let positions = plan.services.compactMap { service -> (HAPService, Double)? in
            for c in service.characteristics { if case .option("p:2:2", .number(let v))? = plan.bindings[c.iid] { return (service, v) } }
            return nil
        }
        #expect(positions.map(\.1).sorted() == [0, 1, 2, 3, 4, 5])
        #expect(!plan.bindings.values.contains { if case .option(let id, _) = $0 { id.hasPrefix("p:3:") } else { false } })
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:2"] = DeviceReading(value: .number(6), code: 0)
        for (service, _) in positions { #expect(value(plan, service, "25", s) == .bool(false)) }
        let flat = try #require(positions.first { $0.1 == 4 }?.0)
        #expect(try commands(plan, flat, "25", .bool(true), s) == [.set("p:2:2", .number(4))])
    }

    @Test("A device whose every control is vendor-defined maps to no Home accessory, so the app can say so")
    func vendorOnlyDevice() throws {
        var s = try snapshot("satori-sd01", model: "test.bed.sd01")
        s.capabilities = s.capabilities.filter { $0.service != "bed" }
        #expect(!s.controls.isEmpty)
        #expect(!CapabilityHomeKitMapper.mapsToHome(s))
    }

    @Test("Every characteristic Home reads has a value once the device answers each of its properties")
    func everyBindingReads() throws {
        let fixtures = try #require(Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Specs"))
            .filter { $0.lastPathComponent != "rust-value-reference.json" }
        var snapshots: [DeviceSnapshot] = []
        for url in fixtures {
            let name = url.deletingPathExtension().lastPathComponent
            let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
            snapshots.append(try snapshot(name, model: "test.\(schema.category).\(name)"))
        }
        for model in DeviceSchema.bundledModels {
            let schema = try #require(DeviceSchema.bundled(model: model))
            snapshots.append(DeviceSnapshot(device: LocalDevice(did: "9", name: "Test", model: model, host: "test", token: ""),
                                            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model)))
        }
        #expect(snapshots.count == fixtures.count + DeviceSchema.bundledModels.count)
        var missing: [String] = []
        for var s in snapshots {
            let plan = try plan(s, legacyDevice: smart(s))
            let characteristics = plan.services.flatMap(\.characteristics)
            s.health = LANDeviceHealth(state: .online)
            for power in [true, false] {
                // A valid answer for every readable property: power on or off, the first listed option, the low end
                // of a range (a pot's 0–255 °C scale never reaches its middle).
                for c in s.capabilities where c.readable {
                    let answer: JSONValue = if c.format == "bool" { .bool(power) }
                        else if let first = c.options.first { .number(Double(first.value)) }
                        else if c.isNumeric { .number(c.min ?? 0) } else { .string("x") }
                    s.readings[c.id] = DeviceReading(value: try c.validatedReading(answer), code: 0)
                }
                for c in characteristics {
                    // The air conditioner companion's layout is read from MijiaCore's climate values instead.
                    guard let binding = plan.bindings[c.iid] else { continue }
                    if case .legacy = binding { continue }
                    let read = CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:])
                    if read.flatMap(c.normalizedRead) == nil { missing.append("\(s.device.model) power=\(power) \(c.type.rawValue) \(binding)") }
                }
            }
        }
        #expect(missing == [])
    }

    @Test("Off and one other setting make one switch that writes both values; other pairs stay two switches")
    func offOnSwitch() throws {
        var s = try snapshot("xiaomi-airer-0002", model: "test.airer.0002")
        let motor = try #require(s.capabilities.first { $0.id == "p:2:5" })
        s.capabilities.removeAll { $0.id == "p:2:5" }
        func list(_ iid: Int, _ options: [(Int, String, String?)]) -> DeviceCapability {
            var c = motor
            c.id = "p:2:\(iid)"; c.iid = iid; c.name = "feature-\(iid)"; c.readable = true
            c.options = options.map { value, description, comment in
                var o = motor.options[0]; o.value = value; o.description = description; o.comment = comment; return o
            }
            return c
        }
        s.capabilities += [list(20, [(0, "Off", "关闭"), (1, "On", "打开")]), list(21, [(0, "Enable", nil), (1, "Disable", nil)]),
                           list(22, [(0, "0", "关"), (1, "1", "开")]), list(23, [(0, "Low", "低风"), (1, "High", "高风")])]
        let plan = try plan(s)
        func toggle(_ id: String) throws -> HAPService {
            try #require(plan.services.first { service in
                service.characteristics.contains { if case .property(id, .toggle)? = plan.bindings[$0.iid] { true } else { false } }
            })
        }
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:20"] = DeviceReading(value: .number(1), code: 0)
        let purify = try toggle("p:2:20")
        #expect(value(plan, purify, "25", s) == .bool(true))
        s.readings["p:2:20"] = DeviceReading(value: .number(0), code: 0)
        #expect(value(plan, purify, "25", s) == .bool(false))
        #expect(try commands(plan, purify, "25", .bool(true), s) == [.set("p:2:20", .number(1))])
        #expect(try commands(plan, purify, "25", .bool(false), s) == [.set("p:2:20", .number(0))])
        // Enable comes first in some lists, and some name their values only in the comment.
        #expect(try commands(plan, try toggle("p:2:21"), "25", .bool(true), s) == [.set("p:2:21", .number(0))])
        #expect(try commands(plan, try toggle("p:2:22"), "25", .bool(false), s) == [.set("p:2:22", .number(0))])
        // Low and High are two speeds, not off and on.
        let low = plan.bindings.values.filter { if case .option("p:2:23", _) = $0 { true } else { false } }
        #expect(low.count == 2)
        #expect(plan.services.filter { $0.type == .switch }.count == 7)
    }

    @Test("A bath heater heats from its heating switch, reads the room's temperature, and its light is a lightbulb")
    func bathHeater() throws {
        var s = try L10n.$overrideLanguage.withValue(.zhHans) { try snapshot("xiaomi-bhf-na1", model: "test.bhf.na1") }
        let plan = try plan(s)
        let heater = try #require(plan.services.first { $0.type.rawValue == "BC" })
        #expect(heater.isPrimary)
        #expect(heater.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "12", "36"])
        #expect(characteristic(heater, "B2").validValues == [1])
        #expect(characteristic(heater, "12").minValue == 25)
        #expect(characteristic(heater, "12").maxValue == 35)
        // The room's thermometer is the heater's temperature rather than a sensor of its own.
        #expect(!plan.services.contains { $0.type == .temperatureSensor })
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:4:6"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:11:7"] = DeviceReading(value: .number(22), code: 0)
        #expect(value(plan, heater, "B1", s) == .uint8(2))
        #expect(value(plan, heater, "11", s) == .float(22))
        #expect(try commands(plan, heater, "B0", .uint8(0), s) == [.set("p:4:6", .bool(false))])

        let light = try #require(plan.services.first { $0.type == .lightbulb })
        #expect(!light.isPrimary)
        #expect(light.characteristics.map(\.type.rawValue) == ["25", "8", "23", "E3"])
        #expect(try commands(plan, light, "8", .int32(0), s) == [.set("p:2:1", .bool(false))])
        #expect(!switchNames(plan).contains("照明"))
        #expect(!switchNames(plan).contains("暖风"))
    }

    @Test("Apple Home draws heating up to 38 °C, so a higher set point stays on the Mac")
    func bathHeaterHotSetPoint() throws {
        var s = try snapshot("xiaomi-bhf-na1", model: "test.bhf.na1")
        let i = try #require(s.capabilities.firstIndex { $0.id == "p:4:4" })
        s.capabilities[i].range = [25, 45, 1]
        let heater = try #require(try plan(s).services.first { $0.type.rawValue == "BC" })
        #expect(heater.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "36"])
    }

    @Test("Without a heating switch, the Heat mode is Active; switching off leaves other modes running")
    func bathHeaterMode() throws {
        var s = try L10n.$overrideLanguage.withValue(.zhHans) { try snapshot("xiaomi-bhf-na2", model: "test.bhf.na2") }
        let plan = try plan(s)
        let heater = try #require(plan.services.first { $0.type.rawValue == "BC" })
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:4:17"] = DeviceReading(value: .number(2), code: 0)
        #expect(value(plan, heater, "B0", s) == .uint8(1))
        #expect(value(plan, heater, "B1", s) == .uint8(2))
        #expect(try commands(plan, heater, "B0", .uint8(0), s) == [.set("p:4:17", .number(0))])
        s.readings["p:4:17"] = DeviceReading(value: .number(3), code: 0)
        #expect(value(plan, heater, "B0", s) == .uint8(0))
        #expect(value(plan, heater, "B1", s) == .uint8(0))
        #expect(try commands(plan, heater, "B0", .uint8(0), s) == [])
        #expect(try commands(plan, heater, "B0", .uint8(1), s) == [.set("p:4:17", .number(2))])
        // Heat and Idle are the heater itself; drying and the other modes stay switches.
        let modes = plan.bindings.values.compactMap { binding -> Int? in
            if case .option("p:4:17", let v) = binding { v.doubleValue.map(Int.init) } else { nil }
        }
        #expect(Set(modes) == [1, 3, 4, 5])
    }

    @Test("A bath heater without any temperature keeps its heating switch, now the main control")
    func bathHeaterWithoutTemperature() throws {
        let plan = try L10n.$overrideLanguage.withValue(.zhHans) { try plan(try snapshot("yeelink-bhf-v10", model: "test.bhf.v10")) }
        #expect(!plan.services.contains { $0.type.rawValue == "BC" })
        let heating = try #require(plan.services.first { $0.isPrimary })
        #expect(heating.type == .switch)
        #expect(heating.characteristics.contains { if case .property("p:3:3", .direct)? = plan.bindings[$0.iid] { true } else { false } })
        #expect(plan.services.contains { $0.type == .lightbulb && !$0.isPrimary })
        #expect(switchNames(plan).contains("照明模式·日光"))
        #expect(switchNames(plan).contains("浴霸模式·干燥"))
    }

    @Test("Reset flags and display units are settings, never Home switches")
    func resetIsSetting() throws {
        var s = try snapshot("xiaomi-airer-0002", model: "test.airer.0002")
        let i = try #require(s.capabilities.firstIndex { $0.id == "p:3:4" })
        s.capabilities[i].name = "set-factory-reset-flag"
        var unit = s.capabilities[i]
        unit.id = "p:3:9"; unit.iid = 9; unit.name = "temperature-display-unit"
        s.capabilities.append(unit)
        let bound = Set(try plan(s).bindings.values.compactMap { binding -> String? in if case .property(let id, _) = binding { id } else { nil } })
        #expect(!bound.contains("p:3:4"))
        #expect(!bound.contains("p:3:9"))
        #expect(bound.contains("p:3:1"))
    }

    @Test("A curtain moves to a position and reports which way it is going")
    func curtain() throws {
        var s = try snapshot("dooya-m2", model: "test.curtain.m2")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type == .windowCovering })
        #expect(service.characteristics.map(\.type.rawValue) == ["6D", "7C", "72"])
        s.health = LANDeviceHealth(state: .online)
        for (status, state) in [(0.0, UInt8(0)), (1, 2), (2, 1)] {
            s.readings["p:2:4"] = DeviceReading(value: .number(status), code: 0)
            #expect(value(plan, service, "72", s) == .uint8(state))
        }
        #expect(try commands(plan, service, "7C", .uint8(40), s) == [.set("p:2:7", .number(40))])
        // Open / pause / close remain buttons.
        #expect(plan.bindings.values.filter { if case .option("p:2:2", _) = $0 { true } else { false } }.count == 3)
    }

    @Test("A robot vacuum is one switch: on starts cleaning, off returns to the dock")
    func vacuum() throws {
        // The layout in issue #1: speed level 2.2, start-sweep 2.1, start-charge in the battery service 3.1.
        var s = try snapshot("roborock-c1", model: "test.vacuum.c1")
        let plan = try plan(s)
        let service = try cleaningSwitch(plan)
        #expect(service.characteristics.map(\.type.rawValue) == ["25"])
        // Stop stays a named switch; identify is maintenance.
        #expect(actionSwitches(plan) == ["a:2:2"])
        // A suction range without reviewed presets stays on the Mac rather than becoming range-end switches.
        #expect(!plan.bindings.values.contains { if case .option("p:2:2", _) = $0 { true } else { false } })

        #expect(value(plan, service, "25", s) == nil)
        s.health = LANDeviceHealth(state: .online)
        for (status, on) in [(2.0, true), (1, false), (3, false), (4, false), (5, false)] {
            s.readings["p:2:1"] = DeviceReading(value: .number(status), code: 0)
            #expect(value(plan, service, "25", s) == .bool(on))
        }
        // Charging: on cleans, off has nothing to do.
        s.readings["p:2:1"] = DeviceReading(value: .number(3), code: 0)
        #expect(try commands(plan, service, "25", .bool(true), s) == [.invoke("a:2:1")])
        #expect(try commands(plan, service, "25", .bool(false), s) == [])
        // Sweeping: off docks, on has nothing to do.
        s.readings["p:2:1"] = DeviceReading(value: .number(2), code: 0)
        #expect(try commands(plan, service, "25", .bool(false), s) == [.invoke("a:3:1")])
        #expect(try commands(plan, service, "25", .bool(true), s) == [])
        // Paused mid-clean: off still sends it home.
        s.readings["p:2:1"] = DeviceReading(value: .number(4), code: 0)
        #expect(try commands(plan, service, "25", .bool(false), s) == [.invoke("a:3:1")])
    }

    @Test("Vacuum status is read by its description; cleaning variants without inputs are named switches")
    func vacuumModes() throws {
        var s = try snapshot("ijai-v19", model: "test.vacuum.v19")
        let plan = try plan(s)
        let service = try cleaningSwitch(plan)
        // Only sweep, mop and both beside stop: room sweeping needs room IDs.
        #expect(actionSwitches(plan) == ["a:2:2", "a:2:3", "a:2:5", "a:2:6"])
        let modes = plan.bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:4", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(modes.sorted() == [0, 1, 2])

        s.health = LANDeviceHealth(state: .online)
        for (status, on) in [(5.0, true), (6, true), (7, true), (2, false), (3, false), (4, false)] {
            s.readings["p:2:1"] = DeviceReading(value: .number(status), code: 0)
            #expect(value(plan, service, "25", s) == .bool(on))
        }
        s.readings["p:2:1"] = DeviceReading(value: .number(3), code: 0)
        #expect(try commands(plan, service, "25", .bool(false), s) == [])
    }

    @Test("An old Roborock gets the same switch through its legacy miIO table")
    func legacyVacuum() throws {
        // The real model name this time, so the legacy table applies: identify has no legacy method.
        var s = try snapshot("roborock-c1", model: "roborock.vacuum.c1")
        let plan = try plan(s)
        let service = try cleaningSwitch(plan)
        #expect(actionSwitches(plan) == ["a:2:2"])
        #expect(s.capabilitiesByID["a:4:1"]?.control == .unsupported)
        #expect(s.capabilitiesByID["p:2:2"]?.control == .number)
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .number(2), code: 0)
        #expect(value(plan, service, "25", s) == .bool(true))
        #expect(try commands(plan, service, "25", .bool(false), s) == [.invoke("a:3:1")])
    }

    @Test("Without a dock action a vacuum keeps start as a named switch")
    func vacuumWithoutDock() throws {
        var s = try snapshot("roborock-c1", model: "test.vacuum.c1")
        s.capabilities.removeAll { $0.name == "start-charge" }
        let plan = try plan(s)
        #expect(!plan.bindings.values.contains { if case .cleaning = $0 { true } else { false } })
        #expect(actionSwitches(plan) == ["a:2:1", "a:2:2"])
    }

    @Test("Without a humidity reading a humidifier stays an outlet with named switches")
    func fallback() throws {
        var s = try snapshot("zhimi-ca4", model: "test.humidifier.ca4")
        s.capabilities.removeAll { $0.name == "relative-humidity" }
        let plan = try plan(s)
        #expect(!plan.services.contains { $0.type.rawValue == "BD" })
        #expect(plan.services.contains { $0.type == .outlet })
    }

    private func snapshot(_ file: String, model: String) throws -> DeviceSnapshot {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Specs"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return DeviceSnapshot(device: LocalDevice(did: "9", name: "Test", model: model, host: "test", token: ""),
                              schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
    }
    private func plan(_ s: DeviceSnapshot, legacyDevice: SmartDevice? = nil) throws -> CapabilityHomeKitPlan {
        var ids: [String: UInt64] = [:]
        let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: legacyDevice, names: [:], identifiers: &ids)
        let all = plan.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 >= 8 })
        return plan
    }
    private func smart(_ s: DeviceSnapshot) -> SmartDevice? {
        guard let core = s.schema.coreSpec else { return nil }
        let home = MiotSynthesizer.synthesize(devices: [MiDeviceRecord(did: s.id, name: s.device.name, model: s.device.model, isOnline: false)],
                                              rooms: [], specs: [s.device.model: core], values: [:])
        return home.devices.first
    }
    private func cleaningSwitch(_ plan: CapabilityHomeKitPlan) throws -> HAPService {
        try #require(plan.services.first { service in
            service.type == .switch && service.characteristics.contains {
                if case .cleaning = plan.bindings[$0.iid] { true } else { false }
            }
        })
    }
    private func switchNames(_ plan: CapabilityHomeKitPlan) -> [String] {
        plan.services.filter { $0.type == .switch }.compactMap { service in
            service.characteristics.first { $0.type == .name }.flatMap { c -> String? in
                if case .name(_, let title)? = plan.bindings[c.iid] { title } else { nil }
            }
        }
    }
    private func actionSwitches(_ plan: CapabilityHomeKitPlan) -> [String] {
        plan.bindings.values.compactMap { binding -> String? in if case .action(let id) = binding { id } else { nil } }.sorted()
    }
    private func characteristic(_ service: HAPService, _ type: String) -> HAPCharacteristic {
        service.characteristics.first { $0.type.rawValue == type }!
    }
    private func value(_ plan: CapabilityHomeKitPlan, _ service: HAPService, _ type: String, _ s: DeviceSnapshot) -> HAPCharacteristicValue? {
        plan.bindings[characteristic(service, type).iid].flatMap { CapabilityHomeKitMapper.value($0, snapshot: s, legacyValues: [:], names: [:]) }
    }
    private func commands(_ plan: CapabilityHomeKitPlan, _ service: HAPService, _ type: String, _ value: HAPCharacteristicValue,
                          _ s: DeviceSnapshot) throws -> [CapabilityCommand] {
        try CapabilityHomeKitMapper.commands(try #require(plan.bindings[characteristic(service, type).iid]), value: value, snapshot: s)
    }
}
