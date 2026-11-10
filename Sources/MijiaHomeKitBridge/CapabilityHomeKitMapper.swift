import Foundation
import HAPCore
import MijiaCore
import MijiaLAN

public enum CapabilityHAPBinding: Sendable {
    public enum Conversion: Sendable {
        case direct, active, running, mired, fanSpeed, purifierMode, filterChange
        /// Map the device's PM2.5 reading in µg/m³ to the five HomeKit air quality levels.
        case airQuality
        /// Power as a HAP current state: off is 0 (inactive), on is the given working state.
        case working(UInt8)
        /// Power plus the mode property as HAP current heater cooler state.
        case climateCurrent(mode: String, heat: Int?, cool: Int?)
        /// The mode property as HAP target heater cooler state (0 auto, 1 heat, 2 cool).
        case climateTarget(auto: Int?, heat: Int?, cool: Int?)
        /// The property's value range scaled to 0–100.
        case percent
        /// A motor status as HAP position state (0 closing, 1 opening, 2 stopped).
        case position(opening: Int?, closing: Int?)
        /// A gear list, in ascending order, as evenly stepped HAP rotation speed; 0 is off. A purifier's favorite
        /// level only applies in its Favorite mode, so a speed also selects `mode`.
        case fanLevel([Int], mode: (id: String, value: Int)? = nil)
        /// An air conditioner's gears as evenly stepped HAP rotation speed, independent of power; 0 is auto.
        case gear([Int], auto: Int?)
        /// The mode property as HAP target fan state: the auto option is 1; leaving it selects `manual`.
        case fanAuto(auto: Int, manual: Int)
        /// A list of two settings, one of them off, as an on/off switch: on selects the other setting.
        case toggle(off: Int, on: Int)
        /// One mode of a list as a HAP state: it reads as `state`, any other mode as 0. Nonzero selects it; 0 selects
        /// `off`, but only from this mode, so a bath heater's drying run is not cancelled.
        case mode(Int, state: UInt8, off: Int)
    }
    case property(String, Conversion)
    case option(String, JSONValue)
    case action(String)
    /// A robot vacuum's switch: on invokes `start`, off invokes `dock`, and it reads on while `status` says cleaning.
    case cleaning(start: String, dock: String, status: String)
    case name(String, String)
    case legacy(HomeKitRole)
    case constant(HAPCharacteristicValue)
}

public struct CapabilityHomeKitPlan: Sendable {
    public var info: AccessoryInfo
    public var services: [HAPService]
    public var bindings: [UInt64: CapabilityHAPBinding]
    public var signature: String
    /// Services omitted to keep the accessory within HomeKit's limit, excluding duplicate definitions.
    public var omittedServiceCount: Int = 0
    /// The key of each service in `services`, in the same order, such as `sensor:p:3:4` or `control:p:2:2=1`.
    public var serviceKeys: [String] = []

    /// Include mode constraints when deciding whether Home must reload the database. Keep the layout-only
    /// signature above compatible with the migration fingerprints used to verify stable built-in IIDs.
    public var databaseSignature: String {
        signature + "|" + services.filter(\.isPrimary).map { "primary:\($0.iid)|" }.joined() + services.flatMap(\.characteristics).map {
            let values = $0.validValues.map { $0.map(String.init).joined(separator: ",") } ?? "-"
            return "\($0.iid):\($0.format.rawValue):\(values)"
        }.joined(separator: ";")
    }
}

/// One service of a device's Home accessory, as the user picks what goes to Apple Home.
public struct CapabilityHomeKitService: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case outlet, light, fan, airPurifier, climate, humidifier, windowCovering, `switch`
        case temperature, humidity, airQuality, filter, other
    }
    /// What an exclusion names: the plan's service key.
    public let key: String
    /// The name Home shows: one the user gave it in Home, else the service's own, else the accessory's.
    public let name: String
    /// The device's original label before a Home controller assigned a name.
    public let defaultName: String
    public let kind: Kind
    public let isPrimary: Bool
    public var id: String { key }

    public init(key: String, name: String, kind: Kind, isPrimary: Bool, defaultName: String? = nil) {
        self.key = key
        self.name = name
        self.defaultName = defaultName ?? name
        self.kind = kind
        self.isPrimary = isPrimary
    }
}

/// Category mapping over a complete schema. Only protocol exceptions and convenient numeric presets are model-specific.
public enum CapabilityHomeKitMapper {
    /// Includes the Accessory Information service added by HAPBridge.
    public static let maxServicesPerAccessory = 100

    /// - Parameter excluded: service keys the user kept out of Home. They still get their identifiers, so leaving one
    ///   out or bringing it back never renumbers the rest of the accessory.
    public static func plan(snapshot s: DeviceSnapshot, legacyDevice: SmartDevice?, names: [String: String],
                            identifiers: inout [String: UInt64], excluding excluded: Set<String> = []) -> CapabilityHomeKitPlan {
        guard DeviceLANPolicy.allowsPropertyRequests(for: s.device.model) else {
            return CapabilityHomeKitPlan(info: AccessoryInfo(name: s.device.name, manufacturer: "Xiaomi", model: s.device.model,
                serialNumber: s.id, firmwareRevision: "1.0.0"), services: [], bindings: [:], signature: "lan-properties-paused:" + s.device.model)
        }
        var configured: [HomeKitRole: String] = [:]
        for (key, name) in names { if let role = HomeKitRole(rawValue: key) { configured[role] = name } }
        let base = legacyDevice.flatMap { HomeKitAccessoryMapper.plan(for: $0, name: $0.name, configuredNames: configured) }
        // First migration seeds exactly the previous allocator, including appended Configured Name IIDs.
        if identifiers.isEmpty, let base {
            var next: UInt64 = 8
            for (i, service) in base.services.enumerated() {
                let key = base.serviceKeys[i]
                identifiers["s:" + key] = next; next += 1
                for c in service.characteristics where c.type != HomeKitAccessoryMapper.configuredNameType {
                    identifiers["c:\(key):\(c.type.rawValue)"] = next; next += 1
                }
            }
            for (i, service) in base.services.enumerated() {
                for c in service.characteristics where c.type == HomeKitAccessoryMapper.configuredNameType {
                    identifiers["c:\(base.serviceKeys[i]):\(c.type.rawValue)"] = next; next += 1
                }
            }
        }
        var builder = Builder(ids: identifiers, names: names)
        var consumed: Set<String> = []
        if s.schema.category == "air-conditioner", let base, hasLegacyClimateLayout(s, plan: base) {
            for (i, service) in base.services.enumerated() {
                let key = base.serviceKeys[i]
                builder.service(key, type: service.type, primary: service.type == HomeKitAccessoryMapper.heaterCoolerService)
                for c in service.characteristics {
                    guard let role = HomeKitRole.allCases.first(where: { $0.serviceKey == key && $0.characteristicType == c.type }) else { continue }
                    builder.add(key, characteristic: c, binding: .legacy(role))
                }
            }
            consumed.formUnion(s.capabilities.filter { [2, 3].contains($0.siid) }.map(\.id))
        } else if native(s, into: &builder, consumed: &consumed) {
        } else if let power = s.primaryPower, power.writable {
            let category = s.schema.category
            let type: HAPServiceType = switch category {
            case "fan": .fanV2
            case "air-purifier": HAPServiceType(rawValue: "BB")
            case "light": .lightbulb
            default: .outlet
            }
            let key = type.rawValue
            builder.service(key, type: type, primary: true)
            let active = ["fan", "air-purifier"].contains(category)
            builder.add(key, type: active ? .active : .on, format: active ? .uint8 : .bool,
                        binding: .property(power.id, active ? .active : .direct), writable: true, min: active ? 0 : nil, max: active ? 1 : nil)
            consumed.insert(power.id)
            if category == "fan" {
                let levels = fanLevels(s)
                if let speed = fanSpeed(s) {
                    builder.add(key, type: .rotationSpeed, format: .float, binding: .property(speed.id, .fanSpeed), writable: true, min: 0, max: 100, step: 1, unit: .percentage)
                    consumed.insert(speed.id)
                    // The gears are coarse settings of the same motor speed.
                    if let levels { consumed.insert(levels.capability.id) }
                } else if let levels {
                    builder.add(key, type: .rotationSpeed, format: .float, binding: .property(levels.capability.id, .fanLevel(levels.values)), writable: true,
                                min: 0, max: 100, step: 100 / Double(levels.values.count), unit: .percentage)
                    consumed.insert(levels.capability.id)
                }
                if let swing = s.capability("fan", "horizontal-swing") {
                    builder.add(key, type: .swingMode, format: .uint8, binding: .property(swing.id, .active), writable: true, min: 0, max: 1)
                    consumed.insert(swing.id)
                }
                if let mode = s.capability("fan", "mode"), mode.writable, mode.readable, let auto = option(mode, autoModes),
                   let manual = mode.options.first(where: { $0.value != auto })?.value {
                    builder.add(key, type: targetFanState, format: .uint8, binding: .property(mode.id, .fanAuto(auto: auto, manual: manual)), writable: true, min: 0, max: 1)
                    // Only the auto option is covered; the fan's other modes remain named switches.
                    consumed.insert("\(mode.id)=\(auto)")
                }
            } else if category == "air-purifier" {
                builder.add(key, type: HAPCharacteristicType(rawValue: "A9"), format: .uint8, binding: .property(power.id, .running), min: 0, max: 2)
                let mode = s.capability(category, "mode")
                if let mode {
                    builder.add(key, type: HAPCharacteristicType(rawValue: "A8"), format: .uint8, binding: .property(mode.id, .purifierMode), writable: true, min: 0, max: 1)
                }
                // Home's manual speed is the favorite level, which the purifier only follows in Favorite mode.
                if let favorite = favoriteLevel(s) {
                    let select = mode.flatMap { m in option(m, ["favorite"]).map { (id: m.id, value: $0) } }
                    builder.add(key, type: .rotationSpeed, format: .float, binding: .property(favorite.capability.id, .fanLevel(favorite.values, mode: select)),
                                writable: true, min: 0, max: 100, step: 100 / Double(favorite.values.count), unit: .percentage)
                    consumed.insert(favorite.capability.id)
                }
            } else if category == "light" {
                if let c = s.capability("light", "brightness"), c.writable {
                    // Most lights count 1–100; others 1–255 or 1–65535, which Home's percentage has to be scaled to.
                    let scaled = c.max != 100 && c.min != nil && c.max != nil
                    builder.add(key, type: .brightness, format: .int, binding: .property(c.id, scaled ? .percent : .direct), writable: true,
                                min: 0, max: 100, step: 1, unit: .percentage)
                    consumed.insert(c.id)
                }
                if let c = s.capability("light", "color-temperature"), c.writable, let lo = c.min, let hi = c.max {
                    builder.add(key, type: .colorTemperature, format: .int, binding: .property(c.id, .mired), writable: true,
                                min: (1_000_000 / hi).rounded(), max: (1_000_000 / lo).rounded(), step: 1)
                    consumed.insert(c.id)
                }
            } else {
                builder.add(key, type: .outletInUse, format: .bool, binding: .property(power.id, .direct))
            }
            if active { childLock(s, key: key, into: &builder, consumed: &consumed) }
        }
        // Fields in a manufacturer's own namespace reach Home only for reviewed models; elsewhere their meaning is
        // unknown (dmaker's private "on" would read as a second power switch), so they stay on the Mac.
        let reviewed = DeviceSchema.bundledModels.contains(s.device.model)
        // A writable temperature is a set point, never a measurement.
        for cap in s.capabilities where cap.readable && !cap.writable && (reviewed || !cap.vendorDefined) && !consumed.contains(cap.id) {
            let type: HAPServiceType
            let characteristic: HAPCharacteristicType
            let min: Double
            let max: Double
            let unit: HAPUnit?
            switch cap.name {
            case "temperature": type = .temperatureSensor; characteristic = .currentTemperature; min = -40; max = 100; unit = .celsius
            case "relative-humidity": type = .humiditySensor; characteristic = .currentRelativeHumidity; min = 0; max = 100; unit = .percentage
            case "pm2.5-density": type = HAPServiceType(rawValue: "8D"); characteristic = HAPCharacteristicType(rawValue: "C6"); min = 0; max = 1000; unit = nil
            case "filter-life-level": type = HAPServiceType(rawValue: "BA"); characteristic = HAPCharacteristicType(rawValue: "AB"); min = 0; max = 100; unit = .percentage
            default: continue
            }
            let key = "sensor:" + cap.id
            builder.service(key, type: type)
            if cap.name == "pm2.5-density" {
                // Report the air quality grade alongside the raw PM2.5 reading.
                builder.add(key, type: HAPCharacteristicType(rawValue: "95"), format: .uint8, binding: .property(cap.id, .airQuality), min: 0, max: 5)
            }
            if cap.name == "filter-life-level" {
                builder.add(key, type: HAPCharacteristicType(rawValue: "AC"), format: .uint8, binding: .property(cap.id, .filterChange), min: 0, max: 1)
            }
            builder.add(key, type: characteristic, format: .float, binding: .property(cap.id, .direct), min: min, max: max,
                        step: cap.step, unit: unit)
            builder.names(key, title: cap.title)
            consumed.insert(cap.id)
        }
        // Reviewed models keep their curated switches. Elsewhere only daily controls get switches, within a budget.
        var budget = reviewed ? Int.max : maxExtraSwitches
        for c in reviewed ? s.controls : dailyControls(s) where !consumed.contains(c.id) && (reviewed || !c.vendorDefined) {
            var switches: [(key: String, title: String, binding: CapabilityHAPBinding)] = []
            switch c.control {
            case .toggle: switches = [(c.id, c.displayTitle, .property(c.id, .direct))]
            case .choice:
                // Swing angles are set up once on the device or Mac; a switch per angle only crowds Home.
                guard !c.name.contains("swing-included-angle") else { continue }
                // Off and one other setting, such as 离子净化开关's 关闭 and 打开, is one switch rather than two.
                if let pair = offOn(c), !consumed.contains("\(c.id)=\(pair.off)"), !consumed.contains("\(c.id)=\(pair.on)") {
                    switches = [(c.id, c.displayTitle, .property(c.id, .toggle(off: pair.off, on: pair.on)))]
                    break
                }
                // A vendor list may name two values alike, such as two Pause entries; Home shows the first.
                var titles: Set<String> = []
                // A None entry, such as a bed's mode among its positions, is no setting to switch on.
                switches = c.options.filter {
                    !consumed.contains("\(c.id)=\($0.value)") && titles.insert($0.title).inserted
                        && (reviewed || !placeholderNames.contains($0.description.lowercased().filter(\.isLetter)))
                }.map {
                    ("\(c.id)=\($0.value)", "\(c.displayTitle)·\($0.title)", .option(c.id, .number(Double($0.value))))
                }
                // Longer lists are programs (washer, fryer, light scenes) or fine levels, not a row of Home switches.
                guard reviewed || switches.count <= maxSwitchOptions else { continue }
            case .number:
                // Home has no number field. Reviewed presets become switches; a range's ends and single steps do not.
                switches = presets(model: s.device.model, capability: c).map {
                    ("\(c.id)=\($0)", "\(c.displayTitle) \(c.formatted(.number($0)))", .option(c.id, .number($0)))
                }
            case .button: switches = [(c.id, c.title, c.kind == .action ? .action(c.id) : .option(c.id, .bool(true)))]
            default: continue
            }
            // A control enters Home whole or not at all: half a mode list would misrepresent the device.
            guard switches.count <= budget else { continue }
            budget -= switches.count
            for item in switches { builder.option(key: item.key, title: item.title, binding: item.binding) }
        }
        identifiers = builder.ids
        // Removed whole and only now: the switch budget and every identifier are as if nothing were excluded.
        builder.remove(excluded)
        let info = base?.info ?? AccessoryInfo(name: s.device.name, manufacturer: "Xiaomi", model: s.device.model, serialNumber: s.id, firmwareRevision: "1.0.0")
        let signature = info.name + "|" + builder.services.map { service in
            "\(service.iid):\(service.type.rawValue):" + service.characteristics.map { "\($0.iid):\($0.type.rawValue):\($0.minValue ?? 0):\($0.maxValue ?? 0):\($0.minStep ?? 0)" }.joined(separator: ",")
        }.joined(separator: "|")
        return CapabilityHomeKitPlan(info: info, services: builder.services, bindings: builder.bindings, signature: signature,
                                     omittedServiceCount: builder.omittedServiceKeys.count, serviceKeys: builder.keys)
    }

    /// Every service the device can publish, excluded or not, in the plan's order: the main service first.
    public static func services(snapshot s: DeviceSnapshot, legacyDevice: SmartDevice?, names: [String: String]) -> [CapabilityHomeKitService] {
        var ids: [String: UInt64] = [:]
        let p = plan(snapshot: s, legacyDevice: legacyDevice, names: names, identifiers: &ids)
        return zip(p.serviceKeys, p.services).map { key, service in
            // Home prefers the Configured Name; a service with neither, such as the main one, shows the accessory's.
            let titles = [HomeKitAccessoryMapper.configuredNameType, .name].lazy.compactMap { type -> (name: String, original: String?)? in
                guard let c = service.characteristics.first(where: { $0.type == type }), let binding = p.bindings[c.iid],
                      case .string(let text)? = value(binding, snapshot: s, legacyValues: [:], names: names) else { return nil }
                if case .name(_, let title) = binding { return (text, HAPString.bounded(title)) }
                return (text, nil)
            }.first
            return CapabilityHomeKitService(key: key, name: titles?.name ?? p.info.name, kind: kind(of: service.type),
                                            isPrimary: service.isPrimary, defaultName: titles?.original)
        }
    }

    static func kind(of type: HAPServiceType) -> CapabilityHomeKitService.Kind {
        switch type.rawValue {
        case "47": .outlet
        case "43": .light
        case "40", "B7": .fan
        case "BB": .airPurifier
        case "BC": .climate
        case "BD": .humidifier
        case "8C": .windowCovering
        case "49": .switch
        case "8A": .temperature
        case "82": .humidity
        case "8D": .airQuality
        case "BA": .filter
        default: .other
        }
    }

    /// Whether the device becomes a Home accessory at all; the bridge leaves out one that maps to no service. The
    /// plan follows the spec alone, never readings.
    public static func mapsToHome(_ s: DeviceSnapshot) -> Bool {
        var ids: [String: UInt64] = [:]
        return !plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids).services.isEmpty
    }

    public static func presets(model: String, capability c: DeviceCapability) -> [Double] {
        let explicit: [String: [String: [Double]]] = [
            "dmaker.fan.p28": ["p:3:1": [0, 30, 60, 120, 240]],
            "zhimi.airpurifier.rma1": ["p:9:2": [0, 4, 9, 14]],
            "careli.fryer.maf07c": ["p:2:3": [10, 20, 30, 60], "p:2:4": [80, 160, 180, 200]],
            "cuco.plug.v3": ["p:8:2": [30, 60, 120, 240], "p:9:2": [1500, 2000, 2500], "p:15:1": [300, 1000, 1500, 2500]],
        ]
        return Array(Set(explicit[model]?[c.id] ?? [])).sorted().filter { (try? c.validated(.number($0))) != nil }
    }

    static let humidifierService = HAPServiceType(rawValue: "BD")
    static let currentHumidifierState = HAPCharacteristicType(rawValue: "B3")
    static let targetHumidifierState = HAPCharacteristicType(rawValue: "B4")
    static let waterLevel = HAPCharacteristicType(rawValue: "B5")
    static let dehumidifierThreshold = HAPCharacteristicType(rawValue: "C9")
    static let humidifierThreshold = HAPCharacteristicType(rawValue: "CA")
    static let targetFanState = HAPCharacteristicType(rawValue: "BF")
    static let lockPhysicalControls = HAPCharacteristicType(rawValue: "A7")
    /// Fan modes that let the device choose its own speed, such as dmaker's Smart.
    static let autoModes: Set<String> = ["auto", "automatic", "smart", "smartwind"]

    /// The percentage speed, wherever the vendor put it: dmaker fans keep it in their own service, and some
    /// Xiaomi fans name it fan-level beside the gear list.
    static func fanSpeed(_ s: DeviceSnapshot) -> DeviceCapability? {
        let speeds = s.capabilities.filter {
            $0.kind == .property && ["speed-level", "fan-level"].contains($0.name) && $0.control == .number && $0.readable && $0.writable
                && ($0.min == 0 || $0.min == 1) && $0.max == 100 && $0.step == 1
        }
        return speeds.first { $0.service == s.schema.category } ?? speeds.first
    }

    /// Option names that are speed steps, compared like `option`: Level1 and plain numbers reduce to "level" and "".
    static let gearNames: Set<String> = ["level", "", "low", "medium", "middle", "high", "strong", "turbo", "silent", "quiet"]

    /// A choice that holds only gears in ascending order, apart from at most one auto entry. Lists that mix in modes
    /// such as Sleep or Constant Humidity have no speed scale.
    static func gears(_ c: DeviceCapability) -> (values: [Int], auto: Int?)? {
        guard c.kind == .property, c.control == .choice, c.readable, c.writable else { return nil }
        let auto = option(c, autoModes)
        let levels = c.options.filter { $0.value != auto }
        guard (2...10).contains(levels.count), levels.allSatisfy({ gearNames.contains($0.description.lowercased().filter(\.isLetter)) }),
              zip(levels, levels.dropFirst()).allSatisfy({ $0.value < $1.value }) else { return nil }
        return (levels.map(\.value), auto)
    }

    /// A fan's gear list without an auto entry: a fan's 0% is off, so auto has nowhere on the slider.
    static func fanLevels(_ s: DeviceSnapshot) -> (capability: DeviceCapability, values: [Int])? {
        for c in s.capabilities where c.service == s.schema.category && c.name == "fan-level" {
            if let g = gears(c), g.auto == nil { return (c, g.values) }
        }
        return nil
    }

    /// Option names that mean off, compared like `option`. Some lists name their values only in the comment, as in
    /// soft-wind's 0 "关" and 1 "开".
    static let offNames: Set<String> = ["off", "close", "closed", "disable", "disabled", "disenable"]

    /// A readable list of exactly two settings, one of them off. A cooking menu's next setting is held on the Mac
    /// until cooking starts, so it keeps its option switches.
    static func offOn(_ c: DeviceCapability) -> (off: Int, on: Int)? {
        guard c.kind == .property, c.control == .choice, c.readable, c.writable, !c.prepared, c.options.count == 2 else { return nil }
        let off = c.options.filter {
            offNames.contains($0.description.lowercased().filter(\.isLetter)) || ["关", "关闭"].contains($0.comment?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        guard off.count == 1, let on = c.options.first(where: { $0.value != off[0].value }) else { return nil }
        return (off[0].value, on.value)
    }

    /// A purifier's favorite level: a choice in its favorite service, or an integer range such as zhimi's 0–14.
    static func favoriteLevel(_ s: DeviceSnapshot) -> (capability: DeviceCapability, values: [Int])? {
        for c in s.capabilities where c.kind == .property && c.readable && c.writable
            && (["favorite-level", "favorite-fan-level"].contains(c.name) || c.service == "air-purifier-favorite" && c.name == "fan-level") {
            if c.control == .choice, (2...20).contains(c.options.count), zip(c.options, c.options.dropFirst()).allSatisfy({ $0.value < $1.value }) {
                return (c, c.options.map(\.value))
            }
            if c.control == .number, let lo = c.min.flatMap(Int.init(exactly:)), let hi = c.max.flatMap(Int.init(exactly:)),
               c.step == 1, (1...19).contains(hi - lo) {
                return (c, Array(lo...hi))
            }
        }
        return nil
    }

    /// A child lock is a characteristic of the device's main service rather than a separate switch.
    private static func childLock(_ s: DeviceSnapshot, key: String, into builder: inout Builder, consumed: inout Set<String>) {
        guard let lock = s.capabilities.first(where: {
            $0.kind == .property && $0.name == "physical-controls-locked" && $0.format == "bool" && $0.readable && $0.writable
        }) else { return }
        builder.add(key, type: lockPhysicalControls, format: .uint8, binding: .property(lock.id, .active), writable: true, min: 0, max: 1)
        consumed.insert(lock.id)
    }

    /// Switches an unreviewed model may add beyond its native services; the Mac keeps every control.
    static let maxExtraSwitches = 10
    /// The most options of one choice an unreviewed model shows as switches.
    static let maxSwitchOptions = 6
    /// Option descriptions that name the absence of a setting.
    static let placeholderNames: Set<String> = ["none", "null"]
    /// Configuration that is set once, on the device or the Mac, rather than daily from a Home tile.
    static let settingServices: Set<String> = [
        "alarm", "indicator-light", "screen", "display", "physical-controls-locked", "delay", "no-disturb", "panel-service",
        "remote-control-management", "iot-linkage", "detect-nobody-save-energy", "switch-sensor", "occupancy-sensor", "speaker",
        "camera-control",
    ]
    static let settingWords = ["position", "direction", "angle", "sensitivity", "distance", "effect", "linkage", "power-on-state",
                               "screen", "volume", "language", "alarm", "indicator", "reset", "display-unit", "room-size"]

    /// An unreviewed model's switch candidates, most useful first: actions, the device's own mode, swing, the rest of
    /// its main service, then other services. Settings stay on the Mac.
    static func dailyControls(_ s: DeviceSnapshot) -> [DeviceCapability] {
        let category = s.schema.category
        func rank(_ c: DeviceCapability) -> Int {
            if c.control == .button { return 0 }
            if c.service == category && c.name == "mode" { return 1 }
            if c.name.contains("swing") { return 2 }
            return c.service == category ? 3 : 4
        }
        let daily = s.controls.filter { c in
            !settingServices.contains(c.service) && !c.service.hasSuffix("-dev-mode") && !settingWords.contains { c.name.contains($0) }
        }
        return daily.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// The AC companion's mapping addresses 2.1–2.3 and 3.1–3.2 directly. Other air conditioners use `native`.
    static func hasLegacyClimateLayout(_ s: DeviceSnapshot, plan: HomeKitAccessoryPlan) -> Bool {
        guard s.device.model == "lumi.acpartner.mcn02" else { return false }
        guard [("p:2:1", "air-conditioner", "on"), ("p:2:2", "air-conditioner", "mode"), ("p:2:3", "air-conditioner", "target-temperature"),
         ("p:3:1", "fan-control", "fan-level"), ("p:3:2", "fan-control", "vertical-swing")].allSatisfy({ id, service, name in
            s.capabilitiesByID[id].map { $0.service == service && $0.name == name } == true
        }) else { return false }
        // The fixed legacy write routing is valid only for this mode table. A changed or incomplete table
        // must use the schema-driven mapper, including its generic fallback when no native modes exist.
        let mode = s.capability("air-conditioner", "mode")
        let auto = option(mode, ["auto", "automatic"]), heat = option(mode, ["heat", "heating"]), cool = option(mode, ["cool", "cooling"])
        let states = [auto.map { _ in 0 }, heat.map { _ in 1 }, cool.map { _ in 2 }].compactMap { $0 }
        guard !states.isEmpty, auto == nil || auto == 0, heat == nil || heat == 3, cool == nil || cool == 1 else { return false }
        return plan.services.first { $0.type == HomeKitAccessoryMapper.heaterCoolerService }?
            .characteristics.first { $0.type == HomeKitAccessoryMapper.targetHeaterCoolerState }?.validValues == states
    }

    /// The value of the option whose spec description is one of `names`, compared without case or separators.
    static func option(_ c: DeviceCapability?, _ names: Set<String>) -> Int? {
        c?.options.first { names.contains($0.description.lowercased().filter(\.isLetter)) }?.value
    }

    /// Native Home services beyond fan, purifier and light, following homebridge-miot's category accessories
    /// (MIT, `2186f61`). Returns false, leaving an outlet and named switches, when a required property is missing.
    /// Fan levels stay named switches: their values carry no speed scale, and some lists mix in an auto level.
    private static func native(_ s: DeviceSnapshot, into builder: inout Builder, consumed: inout Set<String>) -> Bool {
        let category = s.schema.category
        let power = s.primaryPower.flatMap { $0.writable ? $0 : nil }
        func number(_ name: String) -> DeviceCapability? {
            s.capability(category, name).flatMap {
                guard $0.control == .number, $0.writable, let lo = $0.min, let hi = $0.max,
                      lo.isFinite, hi.isFinite, lo <= hi, $0.step.isFinite, $0.step > 0 else { return nil }
                return $0
            }
        }
        func reading(_ name: String) -> DeviceCapability? {
            (s.capability("environment", name) ?? s.capability(category, name)).flatMap { $0.readable ? $0 : nil }
        }
        /// Apple Home requires a current temperature; most air conditioners and heaters have no thermometer, so the set point stands in.
        func climate(_ key: String, power: DeviceCapability, target: DeviceCapability, states: [Int]) {
            let temperature = reading("temperature") ?? reading("indoor-temperature") ?? target
            builder.add(key, type: .currentTemperature, format: .float, binding: .property(temperature.id, .direct), min: -40, max: 100, step: 0.1, unit: .celsius)
            let lo = max(0, target.min ?? 0)
            let hi = min(38, max(lo, target.max ?? 38))
            if states.contains(0) || states.contains(2) {
                builder.add(key, type: HomeKitAccessoryMapper.coolingThresholdTemperature, format: .float, binding: .property(target.id, .direct),
                            writable: true, min: lo, max: hi, step: target.step, unit: .celsius)
            }
            if states.contains(0) || states.contains(1) {
                builder.add(key, type: HomeKitAccessoryMapper.heatingThresholdTemperature, format: .float, binding: .property(target.id, .direct),
                            writable: true, min: lo, max: hi, step: target.step, unit: .celsius)
            }
            // Celsius; Apple Home converts for display.
            builder.add(key, type: HomeKitAccessoryMapper.temperatureDisplayUnits, format: .uint8, binding: .constant(.uint8(0)), writable: true, min: 0, max: 1)
            consumed.formUnion([power.id, target.id, temperature.id])
        }
        switch category {
        case "humidifier", "dehumidifier":
            guard let power, let humidity = reading("relative-humidity"), let threshold = number("target-humidity"),
                  let minimum = threshold.min, let maximum = threshold.max,
                  max(0, minimum) <= min(100, maximum) else { return false }
            let humidifying = category == "humidifier"
            let key = humidifierService.rawValue
            builder.service(key, type: humidifierService, primary: true)
            builder.add(key, type: .active, format: .uint8, binding: .property(power.id, .active), writable: true, min: 0, max: 1)
            let working: UInt8 = humidifying ? 2 : 3
            builder.add(key, type: currentHumidifierState, format: .uint8, binding: .property(power.id, .working(working)),
                        min: 0, max: 3, validValues: [0, 1, Int(working)])
            let target: UInt8 = humidifying ? 1 : 2
            builder.add(key, type: targetHumidifierState, format: .uint8, binding: .constant(.uint8(target)), writable: true,
                        min: 0, max: 2, validValues: [Int(target)])
            builder.add(key, type: .currentRelativeHumidity, format: .float, binding: .property(humidity.id, .direct), min: 0, max: 100, step: 1, unit: .percentage)
            builder.add(key, type: humidifying ? humidifierThreshold : dehumidifierThreshold, format: .float, binding: .property(threshold.id, .direct),
                        writable: true, min: max(0, minimum), max: min(100, maximum), step: threshold.step, unit: .percentage)
            consumed.formUnion([power.id, humidity.id, threshold.id])
            if let water = s.capability(category, "water-level"), water.readable, water.min != nil, water.max != nil {
                builder.add(key, type: waterLevel, format: .float, binding: .property(water.id, .percent), min: 0, max: 100, step: 1, unit: .percentage)
                consumed.insert(water.id)
            }
            childLock(s, key: key, into: &builder, consumed: &consumed)
            return true
        case "heater":
            guard let power, let target = number("target-temperature") else { return false }
            let key = HomeKitAccessoryMapper.heaterCoolerService.rawValue
            builder.service(key, type: HomeKitAccessoryMapper.heaterCoolerService, primary: true)
            builder.add(key, type: .active, format: .uint8, binding: .property(power.id, .active), writable: true, min: 0, max: 1)
            builder.add(key, type: HomeKitAccessoryMapper.currentHeaterCoolerState, format: .uint8, binding: .property(power.id, .working(2)),
                        min: 0, max: 3, validValues: [0, 1, 2])
            builder.add(key, type: HomeKitAccessoryMapper.targetHeaterCoolerState, format: .uint8, binding: .constant(.uint8(1)), writable: true,
                        min: 0, max: 2, validValues: [1])
            climate(key, power: power, target: target, states: [1])
            childLock(s, key: key, into: &builder, consumed: &consumed)
            return true
        case "air-conditioner":
            guard let power, let target = number("target-temperature"), let mode = s.capability(category, "mode"), mode.writable else { return false }
            let auto = option(mode, ["auto", "automatic"]), heat = option(mode, ["heat", "heating"]), cool = option(mode, ["cool", "cooling"])
            let states = [auto.map { _ in 0 }, heat.map { _ in 1 }, cool.map { _ in 2 }].compactMap { $0 }
            guard !states.isEmpty else { return false }
            let key = HomeKitAccessoryMapper.heaterCoolerService.rawValue
            builder.service(key, type: HomeKitAccessoryMapper.heaterCoolerService, primary: true)
            builder.add(key, type: .active, format: .uint8, binding: .property(power.id, .active), writable: true, min: 0, max: 1)
            builder.add(key, type: HomeKitAccessoryMapper.currentHeaterCoolerState, format: .uint8,
                        binding: .property(power.id, .climateCurrent(mode: mode.id, heat: heat, cool: cool)), min: 0, max: 3)
            builder.add(key, type: HomeKitAccessoryMapper.targetHeaterCoolerState, format: .uint8,
                        binding: .property(mode.id, .climateTarget(auto: auto, heat: heat, cool: cool)), writable: true, min: 0, max: 2, validValues: states)
            climate(key, power: power, target: target, states: states)
            if let swing = s.capability("fan-control", "vertical-swing") ?? s.capability("fan-control", "horizontal-swing"), swing.writable, swing.format == "bool" {
                builder.add(key, type: .swingMode, format: .uint8, binding: .property(swing.id, .active), writable: true, min: 0, max: 1)
                consumed.insert(swing.id)
            }
            if let level = s.capability("fan-control", "fan-level"), let gears = gears(level) {
                builder.add(key, type: .rotationSpeed, format: .float, binding: .property(level.id, .gear(gears.values, auto: gears.auto)), writable: true,
                            min: 0, max: 100, step: 100 / Double(gears.values.count), unit: .percentage)
                // The slider covers the gears; auto, its bottom, also stays a named switch so it can be found.
                consumed.formUnion(gears.values.map { "\(level.id)=\($0)" })
            }
            childLock(s, key: key, into: &builder, consumed: &consumed)
            // Apple Home's heater cooler knows auto, heat and cool only; the other modes stay named switches. An Off
            // mode is the power control again.
            let off = option(mode, ["off", "none"])
            for o in mode.options where ![auto, heat, cool, off].contains(o.value) {
                builder.option(key: "\(mode.id)=\(o.value)", title: "\(mode.displayTitle)·\(o.title)", binding: .option(mode.id, .number(Double(o.value))))
            }
            consumed.insert(mode.id)
            return true
        case "curtain":
            guard let current = s.capability(category, "current-position"), current.readable, current.min != nil, current.max != nil,
                  let target = number("target-position") else { return false }
            let key = HAPServiceType.windowCovering.rawValue
            builder.service(key, type: .windowCovering, primary: true)
            builder.add(key, type: .currentPosition, format: .uint8, binding: .property(current.id, .percent), min: 0, max: 100, step: 1, unit: .percentage)
            builder.add(key, type: .targetPosition, format: .uint8, binding: .property(target.id, .percent), writable: true, min: 0, max: 100, step: 1, unit: .percentage)
            if let status = s.capability(category, "status"), status.readable {
                builder.add(key, type: .positionState, format: .uint8,
                            binding: .property(status.id, .position(opening: option(status, ["opening"]), closing: option(status, ["closing"]))), min: 0, max: 2)
                consumed.insert(status.id)
            } else {
                builder.add(key, type: .positionState, format: .uint8, binding: .constant(.uint8(2)), min: 0, max: 2)
            }
            consumed.formUnion([current.id, target.id])
            return true
        case "bath-heater":
            return bathHeater(s, into: &builder, consumed: &consumed)
        case "vacuum":
            // Apple Home has no vacuum service. One switch, as in homebridge-miot: on cleans, off returns to the dock.
            func action(_ service: String, _ name: String) -> DeviceCapability? {
                s.capabilities.first { $0.kind == .action && $0.control == .button && $0.service == service && $0.name == name }
            }
            guard let status = s.capability(category, "status"), status.readable, !status.options.isEmpty,
                  let start = action(category, "start-sweep"),
                  let dock = action("battery", "start-charge") ?? action(category, "start-charge") else { return false }
            let key = HAPServiceType.switch.rawValue
            builder.service(key, type: .switch, primary: true)
            builder.add(key, type: .on, format: .bool, binding: .cleaning(start: start.id, dock: dock.id, status: status.id), writable: true)
            consumed.formUnion([start.id, dock.id])
            return true
        default:
            return false
        }
    }

    /// A bath heater as homebridge-miot maps it (MIT, `2186f61`): a heat-only heater cooler whose Active is the heating
    /// switch, or the Heat mode where there is none, and its light as a lightbulb. Without any temperature Home has no
    /// heater, so the heating switch becomes the main control instead.
    private static func bathHeater(_ s: DeviceSnapshot, into builder: inout Builder, consumed: inout Set<String>) -> Bool {
        func heater(_ name: String) -> DeviceCapability? { s.capability("ptc-bath-heater", name).flatMap { $0.readable ? $0 : nil } }
        let heating = heater("heating").flatMap { $0.writable && $0.format == "bool" ? $0 : nil }
        let mode = heater("mode").flatMap { $0.writable && $0.control == .choice ? $0 : nil }
        let heat = option(mode, ["heat"]), idle = option(mode, ["idle"])
        let target = heater("target-temperature").flatMap { c -> DeviceCapability? in
            guard c.control == .number, c.writable, let lo = c.min, let hi = c.max, lo.isFinite, hi.isFinite, lo <= hi else { return nil }
            return c
        }
        let measured = heater("temperature") ?? s.capability("environment", "temperature").flatMap { $0.readable ? $0 : nil }
        let power: (active: CapabilityHAPBinding, state: CapabilityHAPBinding, covers: [String])? =
            if let heating { (.property(heating.id, .active), .property(heating.id, .working(2)), [heating.id]) }
            else if let mode, let heat, let idle {
                (.property(mode.id, .mode(heat, state: 1, off: idle)), .property(mode.id, .mode(heat, state: 2, off: idle)), ["\(mode.id)=\(heat)", "\(mode.id)=\(idle)"])
            } else { nil }
        var built = false
        if let power, let temperature = measured ?? target {
            let key = HomeKitAccessoryMapper.heaterCoolerService.rawValue
            builder.service(key, type: HomeKitAccessoryMapper.heaterCoolerService, primary: true)
            builder.add(key, type: .active, format: .uint8, binding: power.active, writable: true, min: 0, max: 1)
            builder.add(key, type: HomeKitAccessoryMapper.currentHeaterCoolerState, format: .uint8, binding: power.state, min: 0, max: 3, validValues: [0, 1, 2])
            consumed.formUnion(power.covers)
            builder.add(key, type: HomeKitAccessoryMapper.targetHeaterCoolerState, format: .uint8, binding: .constant(.uint8(1)), writable: true,
                        min: 0, max: 2, validValues: [1])
            // Most bath heaters have no thermometer of their own; the room's, or else the set point, stands in.
            builder.add(key, type: .currentTemperature, format: .float, binding: .property(temperature.id, .direct), min: -40, max: 100, step: 0.1, unit: .celsius)
            // Apple Home draws heating up to 38 °C, and a reading above the advertised range is unavailable, so a set
            // point that goes higher stays on the Mac.
            if let target, let lo = target.min, let hi = target.max, lo >= 0, hi <= 38 {
                builder.add(key, type: HomeKitAccessoryMapper.heatingThresholdTemperature, format: .float, binding: .property(target.id, .direct),
                            writable: true, min: lo, max: hi, step: target.step, unit: .celsius)
                consumed.insert(target.id)
            }
            builder.add(key, type: HomeKitAccessoryMapper.temperatureDisplayUnits, format: .uint8, binding: .constant(.uint8(0)), writable: true, min: 0, max: 1)
            childLock(s, key: key, into: &builder, consumed: &consumed)
            consumed.insert(temperature.id)
            built = true
        } else if let heating {
            // The same key as its former named switch, so scenes that used it keep working.
            let key = "control:" + heating.id
            builder.service(key, type: .switch, primary: true)
            builder.add(key, type: .on, format: .bool, binding: .property(heating.id, .direct), writable: true)
            builder.names(key, title: heating.displayTitle)
            consumed.insert(heating.id)
            built = true
        }
        if let on = s.capability("light", "on"), on.readable, on.writable, on.format == "bool" {
            let key = "light:" + on.id
            builder.service(key, type: .lightbulb, primary: !built)
            builder.add(key, type: .on, format: .bool, binding: .property(on.id, .direct), writable: true)
            if let brightness = s.capability("light", "brightness"), brightness.control == .number, brightness.writable,
               let lo = brightness.min, lo >= 0, brightness.max == 100 {
                builder.add(key, type: .brightness, format: .int, binding: .property(brightness.id, .direct), writable: true,
                            min: 0, max: 100, step: 1, unit: .percentage)
                consumed.insert(brightness.id)
            }
            builder.names(key, title: on.title)
            consumed.insert(on.id)
            built = true
        }
        return built
    }

    /// The description of the vacuum status option `id` currently reads, or nil when it has no valid reading.
    private static func vacuumStatus(_ id: String, in s: DeviceSnapshot) -> String? {
        guard let c = s.capabilitiesByID[id], s.isOnline, let raw = s.value(id),
              let value = try? c.validatedReading(raw) else { return nil }
        return c.options.first { Double($0.value) == value.doubleValue }?.description
    }

    public static func value(_ binding: CapabilityHAPBinding, snapshot s: DeviceSnapshot,
                             legacyValues: [HomeKitRole: HAPCharacteristicValue], names: [String: String]) -> HAPCharacteristicValue? {
        guard DeviceLANPolicy.allowsPropertyRequests(for: s.device.model) else { return nil }
        switch binding {
        case .name(let key, let title): return .string(HAPString.bounded(names[key] ?? title))
        case .constant(let v): return v
        case .legacy(let role):
            if role.isConfiguredName { return .string(HAPString.bounded(names[role.rawValue] ?? (role == .climateDryConfiguredName ? L10n.tr("除湿模式", "Dry Mode") : L10n.tr("仅送风", "Fan Only")))) }
            if role == .climateDryName || role == .climateFanOnlyName || role == .climateDisplayUnits { return legacyValues[role] }
            let ids: [String] = switch role {
            case .climateActive: ["p:2:1"]
            case .climateCurrentState, .climateTargetState, .climateDrySwitch, .climateFanOnlySwitch: ["p:2:1", "p:2:2"]
            case .climateCurrentTemperature, .climateCoolingThreshold, .climateHeatingThreshold: ["p:2:3"]
            case .climateFanSpeed: ["p:3:1"]
            case .climateSwing: ["p:3:2"]
            default: []
            }
            guard s.isOnline, ids.allSatisfy({ id in
                // MijiaCore never sees an unlisted option, so its climate values would not reflect one.
                guard let c = s.capabilitiesByID[id], let value = s.value(id) else { return false }
                return (try? c.validatedReading(value)) != nil && c.lists(value)
            }) else { return nil }
            return legacyValues[role]
        case .action: return .bool(false)
        case .cleaning(_, _, let status): return vacuumStatus(status, in: s).map { .bool(VacuumStatus.isCleaning($0)) }
        case .option(let id, let option):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { return nil }
            if c.control == .button { return .bool(false) }
            if c.prepared { return .bool(s.prepared[id] == option) }
            // A setting the device takes but never reports, such as a fan's or airer's motor-control, is a momentary
            // switch like a button. Waiting for a reading would leave the whole accessory showing No Response.
            if !c.readable { return .bool(false) }
            guard s.isOnline, let raw = s.value(id), let value = try? c.validatedReading(raw) else { return nil }
            return .bool(value == option)
        case .property(let id, let conversion):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { return nil }
            if c.prepared, c.format == "bool" { return .bool(s.prepared[id]?.boolValue == true) }
            guard s.isOnline, let raw = s.value(id), let v = try? c.validatedReading(raw) else { return nil }
            let n = v.doubleValue
            let b = v.boolValue ?? n.map { $0 != 0 }
            switch conversion {
            case .active: return b.map { .uint8($0 ? 1 : 0) }
            case .running:
                guard let b else { return nil }
                if !b { return .uint8(0) }
                // Powered on in auto mode does not necessarily mean the motor is running. Most purifiers have no
                // reviewed motor speed, and for them power-on is the only evidence of purifying there is.
                guard let motor = s.capability("custom-service", "moto-speed-rpm") else { return .uint8(2) }
                guard let rpm = s.value(motor.id)?.doubleValue else { return nil }
                return .uint8(rpm > 0 ? 2 : 1)
            case .mired:
                guard let n, n > 0 else { return nil }
                let mired = (1_000_000 / n).rounded()
                guard mired.isFinite, mired >= Double(Int32.min), mired <= Double(Int32.max) else { return nil }
                return .int32(Int32(mired))
            case .purifierMode: return n.map { .uint8($0 == 0 ? 1 : 0) }
            case .filterChange: return n.map { .uint8($0 <= 0 ? 1 : 0) }
            case .airQuality:
                // Use the historical HJ 633-2012 PM2.5 breakpoints as fixed thresholds for device readings.
                return n.map { pm in .uint8(1 + UInt8([35.0, 75, 115, 150].filter { pm > $0 }.count)) }
            case .fanSpeed:
                guard let power = s.value("fan", "on")?.boolValue else { return nil }
                return n.map { .float(power ? $0 : 0) }
            case .fanLevel(let levels, _):
                guard let power = s.primaryPower.flatMap({ s.value($0.id)?.boolValue }), let n,
                      let i = levels.firstIndex(where: { Double($0) == n }) else { return nil }
                return .float(power ? Double(i + 1) * 100 / Double(levels.count) : 0)
            case .gear(let levels, let auto):
                guard let n else { return nil }
                if let auto, n == Double(auto) { return .float(0) }
                return levels.firstIndex { Double($0) == n }.map { .float(Double($0 + 1) * 100 / Double(levels.count)) }
            case .fanAuto(let auto, _): return n.map { .uint8($0 == Double(auto) ? 1 : 0) }
            case .toggle(_, let on): return n.map { .bool($0 == Double(on)) }
            case .mode(let mode, let state, _): return n.map { .uint8($0 == Double(mode) ? state : 0) }
            case .working(let state): return b.map { .uint8($0 ? state : 0) }
            case .climateCurrent(let modeID, let heat, let cool):
                guard let b else { return nil }
                if !b { return .uint8(0) }
                guard let mode = s.value(modeID)?.integer else { return nil }
                return .uint8(mode == heat ? 2 : mode == cool ? 3 : 1)
            case .climateTarget(let auto, let heat, let cool):
                guard let n else { return nil }
                let states = [(auto, UInt8(0)), (heat, 1), (cool, 2)].filter { $0.0 != nil }
                // Other modes show as auto, or the first state the device has.
                let match = states.first { $0.0.map(Double.init) == n } ?? states.first { $0.1 == 0 } ?? states.first
                return match.map { .uint8($0.1) }
            case .percent:
                guard let n, let lo = c.min, let hi = c.max, hi > lo else { return nil }
                return .float(((n - lo) * 100 / (hi - lo)).rounded())
            case .position(let opening, let closing):
                guard let n else { return nil }
                return .uint8(n == opening.map(Double.init) ? 1 : n == closing.map(Double.init) ? 0 : 2)
            case .direct:
                if c.format == "bool" { return b.map(HAPCharacteristicValue.bool) }
                return n.map(HAPCharacteristicValue.float)
            }
        }
    }

    public static func commands(_ binding: CapabilityHAPBinding, value: HAPCharacteristicValue, snapshot s: DeviceSnapshot) throws -> [CapabilityCommand] {
        guard DeviceLANPolicy.allowsPropertyRequests(for: s.device.model) else { throw HAPError.unavailable }
        let n: Double? = switch value {
        case .bool(let v): v ? 1 : 0
        case .uint8(let v): Double(v)
        case .uint16(let v): Double(v)
        case .uint32(let v): Double(v)
        case .int32(let v): Double(v)
        case .float(let v): v
        default: nil
        }
        guard let n, n.isFinite else { throw HAPError.invalidValue }
        switch binding {
        case .legacy(let role):
            switch role {
            case .climateActive: return [.set("p:2:1", .bool(n != 0))]
            case .climateCoolingThreshold, .climateHeatingThreshold: return [.set("p:2:3", .number(n))]
            case .climateTargetState:
                guard let mode = Int(exactly: n).flatMap({ [0: 0, 1: 3, 2: 1][$0] }) else { throw HAPError.invalidValue }
                return [.set("p:2:2", .number(Double(mode))), .set("p:2:1", .bool(true))]
            case .climateFanSpeed:
                guard (0...100).contains(n) else { throw HAPError.invalidValue }
                return [.set("p:3:1", .number((n * 3 / 100).rounded()))]
            case .climateSwing: return [.set("p:3:2", .bool(n != 0))]
            case .climateDrySwitch, .climateFanOnlySwitch:
                let mode = role == .climateDrySwitch ? 2 : 4
                if n != 0 { return [.set("p:2:2", .number(Double(mode))), .set("p:2:1", .bool(true))] }
                return s.value("p:2:2")?.integer == mode ? [.set("p:2:1", .bool(false))] : []
            case .climateDisplayUnits: return []
            default: throw HAPError.readOnly
            }
        // A fixed state, such as a humidifier's only target mode or Celsius display units: nothing to send.
        case .constant: return []
        case .action(let id): return n == 0 ? [] : [.invoke(id)]
        case .cleaning(let start, let dock, let status):
            // Off also sends a paused or idle robot home. Nothing is sent when it already does what was asked.
            let current = vacuumStatus(status, in: s)
            if n != 0 { return current.map(VacuumStatus.isCleaning) == true ? [] : [.invoke(start)] }
            return current.map(VacuumStatus.isDocking) == true ? [] : [.invoke(dock)]
        case .option(let id, let v): return n == 0 ? [] : [.set(id, v)]
        case .property(let id, let conversion):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { throw HAPError.notFound }
            // Home can write brightness before On. Like the app's dimmer, confirm power in the
            // device queue first: Yeelight rejects set_bright while off, which Home sees as unreachable.
            let primaryLightBrightness = s.schema.category == "light" && s.capability("light", "brightness")?.id == id
            switch conversion {
            case .mired:
                guard n > 0 else { throw HAPError.invalidValue }
                let base = c.min ?? 0
                let raw = base + ((1_000_000 / n - base) / c.step).rounded() * c.step
                return [.set(id, .number(min(c.max ?? raw, max(base, raw))))]
            case .fanSpeed:
                guard (0...100).contains(n), let power = s.capability("fan", "on") else { throw HAPError.invalidValue }
                return n == 0 ? [.set(power.id, .bool(false))] : [.set(id, .number(n.rounded())), .set(power.id, .bool(true))]
            case .fanLevel(let levels, let mode):
                guard (0...100).contains(n), !levels.isEmpty, let power = s.primaryPower else { throw HAPError.invalidValue }
                if n == 0 { return [.set(power.id, .bool(false))] }
                return [.set(id, .number(Double(gear(n, of: levels))))] + (mode.map { [.set($0.id, .number(Double($0.value)))] } ?? [])
                    + [.set(power.id, .bool(true))]
            case .gear(let levels, let auto):
                guard (0...100).contains(n), !levels.isEmpty else { throw HAPError.invalidValue }
                if n == 0 { return auto.map { [.set(id, .number(Double($0)))] } ?? [] }
                return [.set(id, .number(Double(gear(n, of: levels))))]
            case .fanAuto(let auto, let manual):
                guard n == 0 || n == 1 else { throw HAPError.invalidValue }
                if n == 1 { return [.set(id, .number(Double(auto)))] }
                // Leaving auto picks the first other mode; a fan already in a manual mode keeps it.
                return s.value(id)?.doubleValue == Double(auto) ? [.set(id, .number(Double(manual)))] : []
            case .purifierMode: return [.set(id, .number(n == 1 ? 0 : 2))]
            case .toggle(let off, let on): return [.set(id, .number(Double(n != 0 ? on : off)))]
            case .mode(let mode, _, let off):
                if n != 0 { return [.set(id, .number(Double(mode)))] }
                return s.value(id)?.doubleValue == Double(mode) ? [.set(id, .number(Double(off)))] : []
            case .climateTarget(let auto, let heat, let cool):
                guard (0...2).contains(n), n.rounded() == n, let mode = [auto, heat, cool][Int(n)] else { throw HAPError.invalidValue }
                return [.set(id, .number(Double(mode)))] + (s.primaryPower.map { [.set($0.id, .bool(true))] } ?? [])
            case .percent:
                guard (0...100).contains(n), let lo = c.min, let hi = c.max, hi > lo else { throw HAPError.invalidValue }
                if c.name == "brightness", n == 0, let power = s.capability("light", "on") { return [.set(power.id, .bool(false))] }
                let raw = lo + ((n * (hi - lo) / 100) / c.step).rounded() * c.step
                let target = min(hi, max(lo, raw))
                if primaryLightBrightness { return [.setLightBrightness(target)] }
                return [.set(id, .number(target))]
            case .active, .direct:
                if c.name == "brightness", n == 0, let power = s.capability("light", "on") { return [.set(power.id, .bool(false))] }
                if primaryLightBrightness { return [.setLightBrightness(n)] }
                return [.set(id, c.format == "bool" ? .bool(n != 0) : .number(n))]
            default: throw HAPError.readOnly
            }
        default: throw HAPError.readOnly
        }
    }

    /// The gear a nonzero HAP speed selects. Each gear covers the band up to its step, so a speed between
    /// steps rounds up to the next gear.
    static func gear(_ speed: Double, of levels: [Int]) -> Int {
        let i = Int((speed * Double(levels.count) / 100 - 1e-6).rounded(.up)) - 1
        return levels[min(levels.count - 1, max(0, i))]
    }

    private struct Builder {
        var ids: [String: UInt64]
        var names: [String: String]
        var services: [HAPService] = []
        var keys: [String] = []
        var bindings: [UInt64: CapabilityHAPBinding] = [:]
        var omittedServiceKeys: Set<String> = []
        mutating func iid(_ key: String) -> UInt64 {
            if let id = ids[key] { return id }
            let id = max(7, ids.values.max() ?? 7) + 1; ids[key] = id; return id
        }
        mutating func service(_ key: String, type: HAPServiceType, primary: Bool = false) {
            guard !keys.contains(key) else { return }
            guard services.count < CapabilityHomeKitMapper.maxServicesPerAccessory - 1 else {
                omittedServiceKeys.insert(key)
                return
            }
            let id = iid("s:" + key)
            keys.append(key); services.append(HAPService(iid: id, type: type, characteristics: [], isPrimary: primary))
        }
        mutating func add(_ key: String, characteristic c: HAPCharacteristic, binding: CapabilityHAPBinding) {
            guard let index = keys.firstIndex(of: key),
                  !services[index].characteristics.contains(where: { $0.type == c.type }) else { return }
            let id = iid("c:\(key):\(c.type.rawValue)")
            let char = HAPCharacteristic(iid: id, type: c.type, value: c.value, permissions: c.permissions, format: c.format,
                minValue: c.minValue, maxValue: c.maxValue, minStep: c.minStep, unit: c.unit, validValues: c.validValues)
            services[index].characteristics.append(char)
            bindings[id] = binding
        }
        mutating func add(_ key: String, type: HAPCharacteristicType, format: HAPFormat, binding: CapabilityHAPBinding,
                          writable: Bool = false, min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: HAPUnit? = nil,
                          validValues: [Int]? = nil) {
            add(key, characteristic: HAPCharacteristic(iid: 0, type: type, permissions: writable ? [.read, .write, .notify] : [.read, .notify],
                format: format, minValue: min, maxValue: max, minStep: step, unit: unit, validValues: validValues), binding: binding)
        }
        mutating func names(_ key: String, title: String) {
            add(key, type: .name, format: .string, binding: .name(key, title))
            add(key, type: HomeKitAccessoryMapper.configuredNameType, format: .string, binding: .name(key, title), writable: true)
        }
        mutating func option(key: String, title: String, binding: CapabilityHAPBinding) {
            let serviceKey = "control:" + key
            service(serviceKey, type: .switch)
            add(serviceKey, type: .on, format: .bool, binding: binding, writable: true)
            names(serviceKey, title: title)
        }
        mutating func remove(_ excluded: Set<String>) {
            for index in keys.indices.reversed() where excluded.contains(keys[index]) {
                for c in services[index].characteristics { bindings[c.iid] = nil }
                keys.remove(at: index)
                services.remove(at: index)
            }
        }
    }
}
