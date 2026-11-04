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
    public static func title(_ kind: String) -> String {
        switch kind {
        case "light": L10n.tr("灯光开关", "Light")
        case "outlet": L10n.tr("插座", "Outlet")
        case "dimmableLight": L10n.tr("调光灯", "Dimmable Light")
        case "colorTemperatureLight": L10n.tr("调光与色温", "Brightness & Color Temperature")
        case "fan": L10n.tr("风扇开关与风速", "Fan Power & Speed")
        case "airPurifier": L10n.tr("净化器开关与手动风速", "Purifier Power & Manual Speed")
        case "temperature": L10n.tr("温度", "Temperature")
        case "humidity": L10n.tr("湿度", "Humidity")
        case "illuminance": L10n.tr("光照", "Illuminance")
        case "occupancy": L10n.tr("人体感应", "Occupancy")
        case "contact": L10n.tr("接触传感器", "Contact")
        default: kind
        }
    }
    public static func entries(_ snapshots: [DeviceSnapshot]) -> [Entry] {
        snapshots.sorted { $0.id < $1.id }.flatMap { s -> [Entry] in
            var result: [Entry] = []
            func add(_ suffix: String, _ kind: String, _ bindings: [String: DeviceCapability]) {
                var values: [String: JSONValue] = [:]
                for (key, cap) in bindings {
                    guard let value = s.value(cap.id) else { continue }
                    if let n = value.doubleValue {
                        switch key {
                        case "level", "percent":
                            if let max = cap.max, max > 0 { values[key] = .number(n / max * 100) }
                        case "colorTemperature": if n > 0 { values[key] = .number((1_000_000 / n).rounded()) }
                        case "temperature", "humidity", "targetTemperature": values[key] = .number((n * 100).rounded())
                        case "illuminance": values[key] = .number(n <= 0 ? 0 : min(65534, (10000 * log10(n) + 1).rounded()))
                        default: values[key] = value
                        }
                    } else { values[key] = value }
                }
                if let cap = bindings["colorTemperature"], let min = cap.min, let max = cap.max, min > 0 {
                    values["colorTemperatureMin"] = .number((1_000_000 / max).rounded())
                    values["colorTemperatureMax"] = .number((1_000_000 / min).rounded())
                }
                let valid = bindings.keys.allSatisfy { values[$0] != nil }
                result.append(Entry(device: Device(did: s.id + suffix, name: s.device.name + (suffix.isEmpty ? "" : " · " + title(kind)),
                    kind: kind, reachable: s.isOnline && valid, on: values["on"]?.boolValue, attributes: values),
                    sourceID: s.id, bindings: bindings))
            }
            func writable(_ name: String, service: String? = nil) -> DeviceCapability? {
                s.capabilities.first { $0.kind == .property && $0.name == name && (service == nil || $0.service == service) &&
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
            default: break
            }
            if let min = cap.min, let max = cap.max {
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
}
