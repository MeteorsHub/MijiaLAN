import Foundation
import HAPCore
import MijiaCore
import MijiaLAN

public enum CapabilityHAPBinding: Sendable {
    public enum Conversion: Sendable { case direct, active, running, mired, fanSpeed, purifierMode, filterChange }
    case property(String, Conversion)
    case option(String, JSONValue)
    case adjust(String, Double)
    case action(String)
    case name(String, String)
    case legacy(HomeKitRole)
    case constant(HAPCharacteristicValue)
}

public struct CapabilityHomeKitPlan: Sendable {
    public var info: AccessoryInfo
    public var services: [HAPService]
    public var bindings: [UInt64: CapabilityHAPBinding]
    public var signature: String
}

/// Category mapping over a complete schema. Only protocol exceptions and convenient numeric presets are model-specific.
public enum CapabilityHomeKitMapper {
    public static func plan(snapshot s: DeviceSnapshot, legacyDevice: SmartDevice?, names: [String: String],
                            identifiers: inout [String: UInt64]) -> CapabilityHomeKitPlan {
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
        if s.schema.category == "air-conditioner", let base {
            for (i, service) in base.services.enumerated() {
                let key = base.serviceKeys[i]
                builder.service(key, type: service.type)
                for c in service.characteristics {
                    guard let role = HomeKitRole.allCases.first(where: { $0.serviceKey == key && $0.characteristicType == c.type }) else { continue }
                    builder.add(key, characteristic: c, binding: .legacy(role))
                }
            }
            consumed.formUnion(s.capabilities.filter { [2, 3].contains($0.siid) }.map(\.id))
        } else if let power = s.primaryPower, power.writable {
            let category = s.schema.category
            let type: HAPServiceType = switch category {
            case "fan": .fanV2
            case "air-purifier": HAPServiceType(rawValue: "BB")
            case "light": .lightbulb
            default: .outlet
            }
            let key = type.rawValue
            builder.service(key, type: type)
            let active = ["fan", "air-purifier"].contains(category)
            builder.add(key, type: active ? .active : .on, format: active ? .uint8 : .bool,
                        binding: .property(power.id, active ? .active : .direct), writable: true, min: active ? 0 : nil, max: active ? 1 : nil)
            consumed.insert(power.id)
            if category == "fan" {
                let speed = s.device.model == "dmaker.fan.p28" ? s.capabilities.first { $0.id == "p:8:1" } : s.capability("fan", "speed-level")
                if let speed, speed.writable, speed.range == [1, 100, 1] {
                    builder.add(key, type: .rotationSpeed, format: .float, binding: .property(speed.id, .fanSpeed), writable: true, min: 0, max: 100, step: 1, unit: .percentage)
                    consumed.insert(speed.id)
                }
                if let swing = s.capability("fan", "horizontal-swing") {
                    builder.add(key, type: .swingMode, format: .uint8, binding: .property(swing.id, .active), writable: true, min: 0, max: 1)
                    consumed.insert(swing.id)
                }
            } else if category == "air-purifier" {
                builder.add(key, type: HAPCharacteristicType(rawValue: "A9"), format: .uint8, binding: .property(power.id, .running), min: 0, max: 2)
                if let mode = s.capability(category, "mode") {
                    builder.add(key, type: HAPCharacteristicType(rawValue: "A8"), format: .uint8, binding: .property(mode.id, .purifierMode), writable: true, min: 0, max: 1)
                }
            } else if category == "light" {
                if let c = s.capability("light", "brightness"), c.writable {
                    builder.add(key, type: .brightness, format: .int, binding: .property(c.id, .direct), writable: true, min: 0, max: 100, step: 1, unit: .percentage)
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
        }
        for cap in s.capabilities where cap.readable && !consumed.contains(cap.id) {
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
                // No invented air-quality scale: HAP 0 means unknown; PM2.5 remains the actual measurement.
                builder.add(key, type: HAPCharacteristicType(rawValue: "95"), format: .uint8, binding: .constant(.uint8(0)), min: 0, max: 5)
            }
            if cap.name == "filter-life-level" {
                builder.add(key, type: HAPCharacteristicType(rawValue: "AC"), format: .uint8, binding: .property(cap.id, .filterChange), min: 0, max: 1)
            }
            builder.add(key, type: characteristic, format: .float, binding: .property(cap.id, .direct), min: min, max: max,
                        step: cap.step, unit: unit)
            builder.names(key, title: cap.title)
            consumed.insert(cap.id)
        }
        for c in s.controls where !consumed.contains(c.id) {
            switch c.control {
            case .toggle: builder.option(key: c.id, title: c.displayTitle, binding: .property(c.id, .direct))
            case .choice:
                for option in c.options {
                    let suffix = c.name.contains("swing-included-angle") ? "°" : ""
                    let title = "\(c.displayTitle)·\(option.title)\(suffix)"
                    builder.option(key: "\(c.id)=\(option.value)", title: title, binding: .option(c.id, .number(Double(option.value))))
                }
            case .number:
                for value in presets(model: s.device.model, capability: c) {
                    builder.option(key: "\(c.id)=\(value)", title: "\(c.displayTitle) \(c.formatted(.number(value)))", binding: .option(c.id, .number(value)))
                }
                    builder.option(key: c.id + ":minus", title: L10n.tr("\(c.displayTitle) 减 \(c.formatted(.number(c.step)))", "\(c.displayTitle) − \(c.formatted(.number(c.step)))"), binding: .adjust(c.id, -1))
                    builder.option(key: c.id + ":plus", title: L10n.tr("\(c.displayTitle) 加 \(c.formatted(.number(c.step)))", "\(c.displayTitle) + \(c.formatted(.number(c.step)))"), binding: .adjust(c.id, 1))
            case .button:
                builder.option(key: c.id, title: c.title, binding: c.kind == .action ? .action(c.id) : .option(c.id, .bool(true)))
            default: break
            }
        }
        identifiers = builder.ids
        let info = base?.info ?? AccessoryInfo(name: s.device.name, manufacturer: "Xiaomi", model: s.device.model, serialNumber: s.id, firmwareRevision: "1.0.0")
        let signature = info.name + "|" + builder.services.map { service in
            "\(service.iid):\(service.type.rawValue):" + service.characteristics.map { "\($0.iid):\($0.type.rawValue):\($0.minValue ?? 0):\($0.maxValue ?? 0):\($0.minStep ?? 0)" }.joined(separator: ",")
        }.joined(separator: "|")
        return CapabilityHomeKitPlan(info: info, services: builder.services, bindings: builder.bindings, signature: signature)
    }

    public static func presets(model: String, capability c: DeviceCapability) -> [Double] {
        let explicit: [String: [String: [Double]]] = [
            "dmaker.fan.p28": ["p:3:1": [0, 30, 60, 120, 240]],
            "zhimi.airpurifier.rma1": ["p:9:2": [0, 4, 9, 14]],
            "careli.fryer.maf07c": ["p:2:3": [10, 20, 30, 60], "p:2:4": [80, 160, 180, 200]],
            "cuco.plug.v3": ["p:8:2": [30, 60, 120, 240], "p:9:2": [1500, 2000, 2500], "p:15:1": [300, 1000, 1500, 2500]],
        ]
        let values = explicit[model]?[c.id] ?? [c.min, c.max].compactMap { $0 }
        return Array(Set(values)).sorted().filter { (try? c.validated(.number($0))) != nil }
    }

    public static func value(_ binding: CapabilityHAPBinding, snapshot s: DeviceSnapshot,
                             legacyValues: [HomeKitRole: HAPCharacteristicValue], names: [String: String]) -> HAPCharacteristicValue? {
        switch binding {
        case .name(let key, let title): return .string(names[key] ?? title)
        case .constant(let v): return v
        case .legacy(let role):
            if role.isConfiguredName { return .string(names[role.rawValue] ?? (role == .climateDryConfiguredName ? L10n.tr("除湿模式", "Dry Mode") : L10n.tr("仅送风", "Fan Only"))) }
            if role == .climateDryName || role == .climateFanOnlyName || role == .climateDisplayUnits { return legacyValues[role] }
            let ids: [String] = switch role {
            case .climateActive: ["p:2:1"]
            case .climateCurrentState, .climateTargetState, .climateDrySwitch, .climateFanOnlySwitch: ["p:2:1", "p:2:2"]
            case .climateCurrentTemperature, .climateCoolingThreshold, .climateHeatingThreshold: ["p:2:3"]
            case .climateFanSpeed: ["p:3:1"]
            case .climateSwing: ["p:3:2"]
            default: []
            }
            guard s.isOnline, ids.allSatisfy({ s.value($0) != nil }) else { return nil }
            return legacyValues[role]
        case .action, .adjust: return .bool(false)
        case .option(let id, let option):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { return nil }
            if c.control == .button { return .bool(false) }
            if c.prepared { return .bool(s.prepared[id] == option) }
            guard s.isOnline, let value = s.value(id) else { return nil }
            return .bool(value == option)
        case .property(let id, let conversion):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { return nil }
            if c.prepared, c.format == "bool" { return .bool(s.prepared[id]?.boolValue == true) }
            guard s.isOnline, let v = s.value(id) else { return nil }
            let n = v.doubleValue
            let b = v.boolValue ?? n.map { $0 != 0 }
            switch conversion {
            case .active: return b.map { .uint8($0 ? 1 : 0) }
            case .running:
                guard let b else { return nil }
                if !b { return .uint8(0) }
                // Powered on in auto mode does not necessarily mean the motor is running.
                guard let rpm = s.value("custom-service", "moto-speed-rpm")?.doubleValue else { return nil }
                return .uint8(rpm > 0 ? 2 : 1)
            case .mired: return n.flatMap { $0 > 0 ? .int32(Int32((1_000_000 / $0).rounded())) : nil }
            case .purifierMode: return n.map { .uint8($0 == 0 ? 1 : 0) }
            case .filterChange: return n.map { .uint8($0 <= 0 ? 1 : 0) }
            case .fanSpeed:
                guard let power = s.value("fan", "on")?.boolValue else { return nil }
                return n.map { .float(power ? $0 : 0) }
            case .direct:
                if c.format == "bool" { return b.map(HAPCharacteristicValue.bool) }
                return n.map(HAPCharacteristicValue.float)
            }
        }
    }

    public static func commands(_ binding: CapabilityHAPBinding, value: HAPCharacteristicValue, snapshot s: DeviceSnapshot) throws -> [CapabilityCommand] {
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
                guard let mode = [0: 0, 1: 3, 2: 1][Int(n)] else { throw HAPError.invalidValue }
                return [.set("p:2:2", .number(Double(mode))), .set("p:2:1", .bool(true))]
            case .climateFanSpeed:
                guard (0...100).contains(n) else { throw HAPError.invalidValue }
                return [.set("p:3:1", .number((n * 3 / 100).rounded()))]
            case .climateSwing: return [.set("p:3:2", .bool(n != 0))]
            case .climateDrySwitch, .climateFanOnlySwitch:
                let mode = role == .climateDrySwitch ? 2 : 4
                if n != 0 { return [.set("p:2:2", .number(Double(mode))), .set("p:2:1", .bool(true))] }
                return s.value("p:2:2")?.intValue == mode ? [.set("p:2:1", .bool(false))] : []
            case .climateDisplayUnits: return []
            default: throw HAPError.readOnly
            }
        case .action(let id): return n == 0 ? [] : [.invoke(id)]
        case .adjust(let id, let d): return n == 0 ? [] : [.adjust(id, d)]
        case .option(let id, let v): return n == 0 ? [] : [.set(id, v)]
        case .property(let id, let conversion):
            guard let c = s.capabilities.first(where: { $0.id == id }) else { throw HAPError.notFound }
            switch conversion {
            case .mired:
                guard n > 0 else { throw HAPError.invalidValue }
                let base = c.min ?? 0
                let raw = base + ((1_000_000 / n - base) / c.step).rounded() * c.step
                return [.set(id, .number(min(c.max ?? raw, max(base, raw))))]
            case .fanSpeed:
                guard (0...100).contains(n), let power = s.capability("fan", "on") else { throw HAPError.invalidValue }
                return n == 0 ? [.set(power.id, .bool(false))] : [.set(id, .number(n.rounded())), .set(power.id, .bool(true))]
            case .purifierMode: return [.set(id, .number(n == 1 ? 0 : 2))]
            case .active, .direct:
                if c.name == "brightness", n == 0, let power = s.capability("light", "on") { return [.set(power.id, .bool(false))] }
                return [.set(id, c.format == "bool" ? .bool(n != 0) : .number(n))]
            default: throw HAPError.readOnly
            }
        default: throw HAPError.readOnly
        }
    }

    private struct Builder {
        var ids: [String: UInt64]
        var names: [String: String]
        var services: [HAPService] = []
        var keys: [String] = []
        var bindings: [UInt64: CapabilityHAPBinding] = [:]
        mutating func iid(_ key: String) -> UInt64 {
            if let id = ids[key] { return id }
            let id = max(7, ids.values.max() ?? 7) + 1; ids[key] = id; return id
        }
        mutating func service(_ key: String, type: HAPServiceType) {
            guard !keys.contains(key) else { return }
            let id = iid("s:" + key)
            keys.append(key); services.append(HAPService(iid: id, type: type, characteristics: []))
        }
        mutating func add(_ key: String, characteristic c: HAPCharacteristic, binding: CapabilityHAPBinding) {
            let id = iid("c:\(key):\(c.type.rawValue)")
            let char = HAPCharacteristic(iid: id, type: c.type, value: c.value, permissions: c.permissions, format: c.format,
                minValue: c.minValue, maxValue: c.maxValue, minStep: c.minStep, unit: c.unit, validValues: c.validValues)
            services[keys.firstIndex(of: key)!].characteristics.append(char)
            bindings[id] = binding
        }
        mutating func add(_ key: String, type: HAPCharacteristicType, format: HAPFormat, binding: CapabilityHAPBinding,
                          writable: Bool = false, min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: HAPUnit? = nil) {
            add(key, characteristic: HAPCharacteristic(iid: 0, type: type, permissions: writable ? [.read, .write, .notify] : [.read, .notify],
                format: format, minValue: min, maxValue: max, minStep: step, unit: unit), binding: binding)
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
    }
}
