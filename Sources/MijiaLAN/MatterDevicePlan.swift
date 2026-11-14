import Foundation
import MijiaCore

/// Semantic allowlist shared by the App and command-line bridge. Never serializes LocalDevice credentials.
public enum MatterDevicePlan {
    public struct Device: Encodable, Sendable {
        public var did: String
        public var name: String
        public var kind: String
        public var reachable: Bool
        public var on: Bool?
        public var attributes: [String: JSONValue]
    }
    public struct Entry: Sendable {
        public var device: Device
        public var sourceID: String
        public var bindings: [String: DeviceCapability]
    }
    /// A driver's already-validated cache. The bridge never reads managed motors through generic properties.
    public struct Covering: Sendable {
        /// Percent open: 0 fully closed, 100 fully open.
        public var position: Int?
        public var target: Int?
        /// Matter movement status: 0 stopped, 1 opening, 2 closing; nil means unknown.
        public var movement: Int?
        public var reachable: Bool
        public init(position: Int?, target: Int? = nil, movement: Int?, reachable: Bool) {
            self.position = position; self.target = target; self.movement = movement; self.reachable = reachable
        }
    }
    public static func title(_ kind: String) -> String {
        switch kind {
        case "light": L10n.tr("灯光开关", "Light")
        case "outlet": L10n.tr("插座", "Outlet")
        case "dimmableLight": L10n.tr("调光灯", "Dimmable Light")
        case "colorTemperatureLight": L10n.tr("调光与色温", "Brightness & Color Temperature")
        case "fan": L10n.tr("风扇开关与风速", "Fan Power & Speed")
        case "airPurifier": L10n.tr("净化器开关与手动风速", "Purifier Power & Manual Speed")
        case "power": L10n.tr("电源开关（平台可能显示为插座）", "Power Switch (may appear as a plug)")
        case "thermostat": L10n.tr("加热开关与目标温度", "Heating Power & Target Temperature")
        case "windowCovering": L10n.tr("卷帘位置、全开、全关与停止", "Covering Position, Open, Close & Stop")
        case "temperature": L10n.tr("温度", "Temperature")
        case "humidity": L10n.tr("湿度", "Humidity")
        case "illuminance": L10n.tr("光照", "Illuminance")
        case "occupancy": L10n.tr("人体感应", "Occupancy")
        case "contact": L10n.tr("接触传感器", "Contact")
        default: kind
        }
    }
    public static func entries(_ snapshots: [DeviceSnapshot], managedCoverings: [String: Covering] = [:]) -> [Entry] {
        snapshots.sorted { $0.id < $1.id }.flatMap { s -> [Entry] in
            if let covering = managedCoverings[s.id] {
                var attributes: [String: JSONValue] = [:]
                if let value = covering.position, (0...100).contains(value) { attributes["position"] = .number(Double(value)) }
                if let value = covering.target, (0...100).contains(value) { attributes["targetPosition"] = .number(Double(value)) }
                if let value = covering.movement, (0...2).contains(value) { attributes["movement"] = .number(Double(value)) }
                let valid = attributes["position"] != nil && attributes["movement"] != nil
                return [Entry(device: Device(did: s.id, name: s.device.name, kind: "windowCovering",
                    reachable: covering.reachable && valid, attributes: attributes), sourceID: s.id, bindings: [:])]
            }
            guard DeviceLANPolicy.allowsPropertyRequests(for: s.device.model) else { return [] }
            var result: [Entry] = []
            func add(_ suffix: String, _ kind: String, _ bindings: [String: DeviceCapability]) {
                var values: [String: JSONValue] = [:]
                for (key, cap) in bindings {
                    guard let value = s.value(cap.id), (try? cap.validatedReading(value)) != nil else { continue }
                    if let n = value.doubleValue {
                        switch key {
                        case "level", "percent":
                            if let max = cap.max, max > 0 { values[key] = .number(n / max * 100) }
                        case "colorTemperature": if n > 0 { values[key] = .number((1_000_000 / n).rounded()) }
                        case "temperature", "targetTemperature":
                            if (-273.15...327.67).contains(n) { values[key] = .number((n * 100).rounded()) }
                        case "humidity":
                            if (0...100).contains(n) { values[key] = .number((n * 100).rounded()) }
                        case "illuminance": values[key] = .number(n <= 0 ? 0 : min(65534, (10000 * log10(n) + 1).rounded()))
                        default: values[key] = value
                        }
                    } else { values[key] = value }
                }
                if let cap = bindings["colorTemperature"], let min = cap.min, let max = cap.max, min > 0 {
                    values["colorTemperatureMin"] = .number((1_000_000 / max).rounded())
                    values["colorTemperatureMax"] = .number((1_000_000 / min).rounded())
                }
                if kind == "thermostat", let cap = bindings["targetTemperature"], let min = cap.min, let max = cap.max {
                    values["targetTemperatureMin"] = .number((min * 100).rounded())
                    values["targetTemperatureMax"] = .number((max * 100).rounded())
                    values["targetTemperatureStep"] = .number((cap.step * 100).rounded())
                }
                let valid = bindings.keys.allSatisfy { values[$0] != nil }
                result.append(Entry(device: Device(did: s.id + suffix, name: s.device.name + (suffix.isEmpty ? "" : " · " + title(kind)),
                    kind: kind, reachable: s.isOnline && valid, on: values["on"]?.boolValue, attributes: values),
                    sourceID: s.id, bindings: bindings))
            }
            func writable(_ name: String, service: String? = nil, siid: Int? = nil) -> DeviceCapability? {
                s.capabilities.first { $0.kind == .property && $0.name == name && (service == nil || $0.service == service) && (siid == nil || $0.siid == siid) &&
                    $0.readable && $0.writable && !$0.prepared && ![.unsupported, .reading].contains($0.control) }
            }
            if ["light", "outlet"].contains(s.schema.category), let power = s.primaryPower,
               power.readable, power.writable, power.format == "bool", power.control == .toggle {
                var bindings = ["on": power]
                var kind = s.schema.category
                if kind == "light", let brightness = writable("brightness", service: "light"), brightness.max != nil {
                    bindings["level"] = brightness; kind = "dimmableLight"
                    if let temp = writable("color-temperature", service: "light"), temp.min != nil, temp.max != nil {
                        bindings["colorTemperature"] = temp; kind = "colorTemperatureLight"
                    }
                }
                add("", kind, bindings)
            }
            if s.schema.category == "fan", let power = s.primaryPower, power.format == "bool", power.writable,
               let speed = writable("speed-level"), speed.max != nil {
                add("", "fan", ["on": power, "percent": speed])
            }
            if s.schema.category == "air-purifier", let power = s.primaryPower, power.format == "bool", power.writable,
               let speed = writable("favorite-level"), speed.max != nil,
               let mode = writable("mode", service: "air-purifier"),
               mode.options.contains(where: { $0.description.lowercased() == "favorite" }) {
                add("", "airPurifier", ["on": power, "percent": speed])
            }
            func celsius(_ capability: DeviceCapability) -> Bool {
                capability.unit.map { ["celsius", "°C", "℃"].contains($0) } ?? true
            }
            if result.isEmpty, let power = s.primaryPower, power.readable, power.writable,
               power.format == "bool", power.control == .toggle, !power.prepared {
                // Infer heating from the service semantics, not a manufacturer's model string.
                let thermal = ["heater", "towel-rack", "water-heater", "radiator", "thermostat"].contains(power.service)
                if thermal, let target = writable("target-temperature", service: power.service, siid: power.siid),
                   target.isNumeric, let min = target.min, let max = target.max, min >= -273.15, max <= 327.67, min < max,
                   target.step >= 0.01, [min, max, target.step].allSatisfy({ ($0 * 100).isFinite && abs($0 * 100 - ($0 * 100).rounded()) < 0.00001 }),
                   celsius(target),
                   let temperature = s.capabilities.first(where: { $0.kind == .property && $0.name == "temperature" && $0.siid == power.siid && $0.service == power.service && $0.readable && $0.isNumeric && celsius($0) }) {
                    add("", "thermostat", ["on": power, "temperature": temperature, "targetTemperature": target])
                } else {
                    // A genuine idempotent on/off property is distinct from start/feed actions or mode presets.
                    add("", "power", ["on": power])
                }
            }
            // Secondary lighting has its own service and power; never substitute it for the appliance's main power.
            for power in s.capabilities where power.kind == .property && power.service == "light" && power.name == "on" &&
                power.readable && power.writable && power.format == "bool" && power.control == .toggle && !power.prepared {
                guard !result.contains(where: { $0.bindings["on"]?.id == power.id }) else { continue }
                var bindings = ["on": power]
                var kind = "light"
                if let brightness = s.capabilities.first(where: { $0.siid == power.siid && $0.name == "brightness" && $0.isNumeric && $0.control == .number && $0.readable && $0.writable && !$0.prepared && $0.max != nil }) {
                    bindings["level"] = brightness; kind = "dimmableLight"
                }
                add(":light:\(power.siid)", kind, bindings)
            }
            let sensors: [(String, String)] = [("temperature", "temperature"), ("relative-humidity", "humidity"),
                ("illumination", "illuminance"), ("illuminance", "illuminance"), ("motion-state", "occupancy"), ("contact-state", "contact")]
            var added: Set<String> = []
            for (name, kind) in sensors {
                if let cap = s.capabilities.first(where: { $0.kind == .property && $0.name == name && $0.readable &&
                    (kind == "occupancy" || kind == "contact" ? $0.format == "bool" : $0.isNumeric) }), added.insert(kind).inserted {
                    add(":" + kind, kind, [kind: cap])
                }
            }
            return result
        }
    }
    public static func devices(_ snapshots: [DeviceSnapshot]) -> [Device] { entries(snapshots).map(\.device) }

    @MainActor public static func execute(controller: DeviceController, endpoint: String, property: String, value: JSONValue) async throws {
        guard let entry = entries(Array(controller.snapshots.values)).first(where: { $0.device.did == endpoint }),
              let cap = entry.bindings[property], cap.writable else { throw DeviceControlError.unsupported("Matter attribute") }
        var raw = value
        if let n = value.doubleValue {
            var converted = n
            switch property {
            case "level", "percent":
                guard (0...100).contains(n), let max = cap.max else { throw DeviceControlError.invalidValue(property) }
                converted = n / 100 * max
            case "colorTemperature":
                guard n > 0 else { throw DeviceControlError.invalidValue(property) }
                converted = 1_000_000 / n
            case "targetTemperature":
                guard n.isFinite else { throw DeviceControlError.invalidValue(property) }
                converted = n / 100
            default: break
            }
            if property != "targetTemperature", let min = cap.min, let max = cap.max {
                converted = Swift.min(max, Swift.max(min, min + ((converted - min) / cap.step).rounded() * cap.step))
            }
            raw = .number(converted)
        }
        if entry.device.kind == "airPurifier", property == "percent",
           let snapshot = controller.snapshots[entry.sourceID],
           let mode = snapshot.capability("air-purifier", "mode"),
           let favorite = mode.options.first(where: { $0.description.lowercased() == "favorite" }) {
            try await controller.execute(did: entry.sourceID, .batch([.set(mode.id, .number(Double(favorite.value))), .set(cap.id, raw)]))
        } else {
            try await controller.execute(did: entry.sourceID, .set(cap.id, raw))
        }
    }

    public static func unmappedControls(_ snapshot: DeviceSnapshot, entries: [Entry]) -> [String] {
        let used = Set(entries.flatMap { $0.bindings.values.map(\.id) })
        return snapshot.controls.filter { $0.writable && !$0.prepared && !used.contains($0.id) }
            .map(\.displayTitle)
    }
}
