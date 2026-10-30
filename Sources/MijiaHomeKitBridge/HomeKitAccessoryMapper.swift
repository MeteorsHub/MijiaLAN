import Foundation
import HAPCore
import MijiaCore

/// A characteristic the bridge keeps in sync with one device. Within an accessory it is found by its service and
/// characteristic type, because the HAP bridge assigns the instance IDs.
public enum HomeKitRole: String, CaseIterable, Sendable {
    case lightOn
    case lightBrightness
    case lightColorTemperature
    case outletOn
    case outletInUse
    case fanActive
    case thermostatCurrentState
    case thermostatTargetState
    case thermostatCurrentTemperature
    case thermostatTargetTemperature
    case thermostatDisplayUnits
    case sensorTemperature
    case sensorHumidity
    case batteryLevel
    case batteryChargingState
    case batteryLow

    public var serviceType: HAPServiceType {
        switch self {
        case .lightOn, .lightBrightness, .lightColorTemperature: return .lightbulb
        case .outletOn, .outletInUse: return .outlet
        case .fanActive: return .fanV2
        case .thermostatCurrentState, .thermostatTargetState, .thermostatCurrentTemperature,
             .thermostatTargetTemperature, .thermostatDisplayUnits: return .thermostat
        case .sensorTemperature: return .temperatureSensor
        case .sensorHumidity: return .humiditySensor
        case .batteryLevel, .batteryChargingState, .batteryLow: return HomeKitAccessoryMapper.batteryService
        }
    }

    public var characteristicType: HAPCharacteristicType {
        switch self {
        case .lightOn, .outletOn: return .on
        case .lightBrightness: return .brightness
        case .lightColorTemperature: return .colorTemperature
        case .outletInUse: return .outletInUse
        case .fanActive: return .active
        case .thermostatCurrentState: return .currentHeatingCoolingState
        case .thermostatTargetState: return .targetHeatingCoolingState
        case .thermostatCurrentTemperature, .sensorTemperature: return .currentTemperature
        case .thermostatTargetTemperature: return .targetTemperature
        case .thermostatDisplayUnits: return HomeKitAccessoryMapper.temperatureDisplayUnits
        case .sensorHumidity: return .currentRelativeHumidity
        case .batteryLevel: return .batteryLevel
        case .batteryChargingState: return HomeKitAccessoryMapper.chargingState
        case .batteryLow: return HomeKitAccessoryMapper.statusLowBattery
        }
    }
}

/// What a write from Apple Home asks the store to do. Writes that would not change the device map to nothing.
public enum HomeKitWrite: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)
    case colorTemperature(kelvin: Int)
    /// `"off"` turns the device off; any other mode also turns it on (both backends do this).
    case climateMode(String)
    case targetTemperature(Double)
}

/// One device as Apple Home sees it.
public struct HomeKitAccessoryPlan: Sendable {
    public let deviceId: String
    public let info: AccessoryInfo
    public let services: [HAPService]
    /// Changes when the accessory must be rebuilt in Apple Home: another name, kind or set of controls.
    public let signature: String
}

/// Translates between `SmartDevice` and HAP services. Pure, so the mapping is testable without a network.
///
/// | Device | Apple Home service |
/// | --- | --- |
/// | Light | Lightbulb: on, brightness, colour temperature (when the light reports them) |
/// | Plug | Outlet: on, in use |
/// | Fan | Fan: active |
/// | Climate (AC, heater) | Thermostat: off / heat / cool / auto, target and current temperature |
/// | Sensor | Temperature and humidity sensors, battery |
///
/// Vacuums, speakers, TVs and fridges are not exposed: Apple Home has no matching HAP service.
public enum HomeKitAccessoryMapper {
    /// A bridge carries at most 150 accessories, itself included.
    public static let maxBridgedAccessories = 149
    /// Matches the app's own low-battery reminder.
    static let lowBatteryPercent = 15

    static let batteryService = HAPServiceType(rawValue: "96")
    static let temperatureDisplayUnits = HAPCharacteristicType(rawValue: "36")
    static let chargingState = HAPCharacteristicType(rawValue: "8F")
    static let statusLowBattery = HAPCharacteristicType(rawValue: "79")

    public static func plan(for device: SmartDevice, name: String) -> HomeKitAccessoryPlan? {
        let specs = characteristicSpecs(for: device)
        guard !specs.isEmpty else { return nil }

        var services: [HAPService] = []
        for spec in specs {
            if let index = services.firstIndex(where: { $0.type == spec.role.serviceType }) {
                services[index].characteristics.append(spec.characteristic)
            } else {
                services.append(HAPService(type: spec.role.serviceType, characteristics: [spec.characteristic]))
            }
        }

        let info = AccessoryInfo(
            name: name,
            manufacturer: manufacturer(for: device.model),
            model: device.model.isEmpty ? "MijiaLAN" : device.model,
            serialNumber: device.id,
            firmwareRevision: "1.0.0"
        )
        return HomeKitAccessoryPlan(
            deviceId: device.id,
            info: info,
            services: services,
            signature: ([name] + specs.map(\.signature)).joined(separator: "|")
        )
    }

    /// Current value of every characteristic the device exposes.
    public static func values(for device: SmartDevice) -> [HomeKitRole: HAPCharacteristicValue] {
        var values: [HomeKitRole: HAPCharacteristicValue] = [:]
        for spec in characteristicSpecs(for: device) {
            if let value = spec.characteristic.value { values[spec.role] = value }
        }
        return values
    }

    /// The store action for a write from Apple Home, or nil when it is read-only or changes nothing.
    public static func write(_ role: HomeKitRole, value: HAPCharacteristicValue, to device: SmartDevice) -> HomeKitWrite? {
        guard let number = number(from: value) else { return nil }
        switch (role, device.kind) {
        case (.lightOn, .light(let s)):
            let on = number != 0
            return on == s.isOn ? nil : .power(on)

        case (.lightBrightness, .light(let s)):
            let percent = min(100, max(0, Int(number.rounded())))
            if percent == 0 { return s.isOn ? .power(false) : nil }
            return (s.isOn && s.brightnessPercent == percent) ? nil : .brightness(percent)

        case (.lightColorTemperature, .light(let s)):
            // Setting a colour temperature turns the light on; only follow it while the light is already on.
            guard s.isOn, number > 0 else { return nil }
            let requestedMired = Int(number.rounded())
            if let current = s.colorTempKelvin, mired(fromKelvin: current) == requestedMired { return nil }
            let kelvin = min(s.maxKelvin, max(s.minKelvin, Int((1_000_000 / number).rounded())))
            return .colorTemperature(kelvin: kelvin)

        case (.outletOn, .plug(let s)):
            let on = number != 0
            return on == s.isOn ? nil : .power(on)

        case (.fanActive, .fan(let s)):
            let on = number >= 1
            return on == s.isOn ? nil : .power(on)

        case (.thermostatTargetState, .climate(let s)):
            let requested = Int(number.rounded())
            guard requested != targetState(for: s) else { return nil }
            if requested == 0 { return .climateMode("off") }
            if let mode = hvacMode(forTargetState: requested, availableModes: s.availableModes) {
                return .climateMode(mode)
            }
            // No mode to pick (the device reports none): fall back to plain power-on.
            return isActive(s) ? nil : .power(true)

        case (.thermostatTargetTemperature, .climate(let s)):
            let step = s.step > 0 ? s.step : 1
            let stepped = min(s.maxTemp, max(s.minTemp, (number / step).rounded() * step))
            return abs(stepped - s.targetTemperature) < 0.01 ? nil : .targetTemperature(stepped)

        default:
            return nil
        }
    }

    // MARK: - Characteristic Layout

    private struct Spec {
        let role: HomeKitRole
        let characteristic: HAPCharacteristic
        /// The parts of the layout Apple Home caches: role and range, never the current value.
        let signature: String
    }

    private static func spec(
        _ role: HomeKitRole,
        _ value: HAPCharacteristicValue,
        writable: Bool = false,
        min minValue: Double? = nil,
        max maxValue: Double? = nil,
        step: Double? = nil,
        unit: HAPUnit? = nil,
        validValues: [Int]? = nil
    ) -> Spec {
        let permissions: [HAPPermission] = writable ? [.read, .write, .notify] : [.read, .notify]
        let characteristic = HAPCharacteristic(
            iid: 0,
            type: role.characteristicType,
            value: value,
            permissions: permissions,
            format: value.format,
            minValue: minValue,
            maxValue: maxValue,
            minStep: step,
            unit: unit,
            validValues: validValues
        )
        let range = [minValue, maxValue, step].map { $0.map { String($0) } ?? "-" }.joined(separator: ",")
        let valid = validValues.map { $0.map(String.init).joined(separator: ",") } ?? "-"
        return Spec(role: role, characteristic: characteristic, signature: "\(role.rawValue)[\(range)][\(valid)]")
    }

    private static func characteristicSpecs(for device: SmartDevice) -> [Spec] {
        switch device.kind {
        case .light(let s):
            var specs = [spec(.lightOn, .bool(s.isOn), writable: true)]
            if let brightness = s.brightnessPercent {
                specs.append(spec(
                    .lightBrightness, .int32(Int32(min(100, max(0, brightness)))), writable: true,
                    min: 0, max: 100, step: 1, unit: .percentage
                ))
            }
            if let kelvin = s.colorTempKelvin, s.minKelvin > 0, s.maxKelvin > s.minKelvin {
                let warmest = mired(fromKelvin: s.minKelvin)
                let coolest = mired(fromKelvin: s.maxKelvin)
                let value = min(warmest, max(coolest, mired(fromKelvin: kelvin)))
                specs.append(spec(
                    .lightColorTemperature, .int32(Int32(value)), writable: true,
                    min: Double(coolest), max: Double(warmest), step: 1
                ))
            }
            return specs

        case .plug(let s):
            let inUse = s.isOn && (s.powerWatts.map { $0 > 0.5 } ?? true)
            return [
                spec(.outletOn, .bool(s.isOn), writable: true),
                spec(.outletInUse, .bool(inUse))
            ]

        case .fan(let s):
            return [spec(.fanActive, .uint8(s.isOn ? 1 : 0), writable: true, min: 0, max: 1)]

        case .climate(let s):
            // HAP limits a thermostat's target to 10–38 °C.
            let minTemp = max(10, s.minTemp)
            let maxTemp = min(38, max(minTemp, s.maxTemp))
            let target = min(maxTemp, max(minTemp, s.targetTemperature))
            let current = s.currentTemperature ?? s.targetTemperature
            return [
                spec(.thermostatCurrentState, .uint8(UInt8(currentState(for: s))), min: 0, max: 2),
                spec(
                    .thermostatTargetState, .uint8(UInt8(targetState(for: s))), writable: true,
                    min: 0, max: 3, validValues: validTargetStates(for: s)
                ),
                spec(
                    .thermostatCurrentTemperature, .float(min(100, max(0, current))),
                    min: 0, max: 100, step: 0.1, unit: .celsius
                ),
                spec(
                    .thermostatTargetTemperature, .float(target), writable: true,
                    min: minTemp, max: maxTemp, step: s.step > 0 ? s.step : 1, unit: .celsius
                ),
                // Celsius; Apple Home converts for display.
                spec(.thermostatDisplayUnits, .uint8(0), writable: true, min: 0, max: 1)
            ]

        case .sensor(let s):
            var specs: [Spec] = []
            if let temperature = s.temperature {
                specs.append(spec(
                    .sensorTemperature, .float(min(100, max(-40, temperature))),
                    min: -40, max: 100, step: 0.1, unit: .celsius
                ))
            }
            if let humidity = s.humidity {
                specs.append(spec(
                    .sensorHumidity, .float(min(100, max(0, humidity))),
                    min: 0, max: 100, step: 1, unit: .percentage
                ))
            }
            guard !specs.isEmpty else { return [] }
            if let battery = s.battery {
                let level = min(100, max(0, battery))
                specs.append(spec(.batteryLevel, .uint8(UInt8(level)), min: 0, max: 100, step: 1, unit: .percentage))
                // 2 = not chargeable.
                specs.append(spec(.batteryChargingState, .uint8(2), min: 0, max: 2))
                specs.append(spec(.batteryLow, .uint8(level < lowBatteryPercent ? 1 : 0), min: 0, max: 1))
            }
            return specs

        case .vacuum, .speaker, .tv, .fridge:
            return []
        }
    }

    // MARK: - Climate States

    /// HAP target state: 0 off, 1 heat, 2 cool, 3 auto (every other running mode, e.g. dry or fan only).
    static func targetState(for s: ClimateSpec) -> Int {
        guard isActive(s) else { return 0 }
        switch s.hvacMode {
        case "heat": return 1
        case "cool": return 2
        default: return 3
        }
    }

    /// HAP current state: 0 idle/off, 1 heating, 2 cooling.
    static func currentState(for s: ClimateSpec) -> Int {
        guard isActive(s) else { return 0 }
        switch s.hvacMode {
        case "heat": return 1
        case "cool": return 2
        default: return 0
        }
    }

    static func validTargetStates(for s: ClimateSpec) -> [Int] {
        var states: Set<Int> = [0]
        for mode in s.availableModes where mode != "off" {
            switch mode {
            case "heat": states.insert(1)
            case "cool": states.insert(2)
            default: states.insert(3)
            }
        }
        // A device that reports no modes can still be switched on.
        if states.count == 1 { states.insert(3) }
        return states.sorted()
    }

    private static let autoLikeModes = ["auto", "heat_cool", "dry", "fan_only"]

    static func hvacMode(forTargetState state: Int, availableModes: [String]) -> String? {
        switch state {
        case 1: return availableModes.contains("heat") ? "heat" : nil
        case 2: return availableModes.contains("cool") ? "cool" : nil
        case 3:
            return autoLikeModes.first(where: availableModes.contains)
                ?? availableModes.first(where: { $0 != "off" && $0 != "heat" && $0 != "cool" })
        default: return nil
        }
    }

    private static func isActive(_ s: ClimateSpec) -> Bool {
        s.isOn && s.hvacMode != "off"
    }

    // MARK: - Values

    static func mired(fromKelvin kelvin: Int) -> Int {
        guard kelvin > 0 else { return 0 }
        return Int((1_000_000 / Double(kelvin)).rounded())
    }

    /// Controllers send JSON numbers or booleans regardless of the declared format.
    static func number(from value: HAPCharacteristicValue) -> Double? {
        switch value {
        case .bool(let v): return v ? 1 : 0
        case .uint8(let v): return Double(v)
        case .uint16(let v): return Double(v)
        case .uint32(let v): return Double(v)
        case .int32(let v): return Double(v)
        case .float(let v): return v.isFinite ? v : nil
        case .string(let v): return Double(v)
        case .data, .tlv8: return nil
        }
    }

    /// `yeelink.light.ceiling13` → `yeelink`; Apple Home shows it under the accessory details.
    static func manufacturer(for model: String) -> String {
        let vendor = model.split(separator: ".").first.map(String.init) ?? ""
        return vendor.isEmpty ? "MijiaLAN" : vendor
    }
}
