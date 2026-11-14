import Foundation
import HAPCore
import MijiaCore
import MijiaLAN

/// A characteristic the bridge keeps in sync with one device. Within an accessory it is found by its service and
/// characteristic type, because the HAP bridge assigns the instance IDs.
public enum HomeKitRole: String, CaseIterable, Sendable {
    case lightOn
    case lightBrightness
    case lightColorTemperature
    case outletOn
    case outletInUse
    case fanActive
    case climateActive
    case climateCurrentState
    case climateTargetState
    case climateCurrentTemperature
    case climateCoolingThreshold
    case climateHeatingThreshold
    case climateFanSpeed
    case climateSwing
    case climateDisplayUnits
    case climateDrySwitch
    case climateDryName
    case climateDryConfiguredName
    case climateFanOnlySwitch
    case climateFanOnlyName
    case climateFanOnlyConfiguredName
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
        case .climateActive, .climateCurrentState, .climateTargetState, .climateCurrentTemperature,
             .climateCoolingThreshold, .climateHeatingThreshold, .climateFanSpeed, .climateSwing,
             .climateDisplayUnits: return HomeKitAccessoryMapper.heaterCoolerService
        case .climateDrySwitch, .climateDryName, .climateDryConfiguredName,
             .climateFanOnlySwitch, .climateFanOnlyName, .climateFanOnlyConfiguredName: return .switch
        case .sensorTemperature: return .temperatureSensor
        case .sensorHumidity: return .humiditySensor
        case .batteryLevel, .batteryChargingState, .batteryLow: return HomeKitAccessoryMapper.batteryService
        }
    }

    /// Tells apart services of one type within an accessory: the dry and fan-only switches.
    public var serviceKey: String {
        switch self {
        case .climateDrySwitch, .climateDryName, .climateDryConfiguredName: return "switch.dry"
        case .climateFanOnlySwitch, .climateFanOnlyName, .climateFanOnlyConfiguredName: return "switch.fan_only"
        default: return serviceType.rawValue
        }
    }

    public var characteristicType: HAPCharacteristicType {
        switch self {
        case .lightOn, .outletOn, .climateDrySwitch, .climateFanOnlySwitch: return .on
        case .lightBrightness: return .brightness
        case .lightColorTemperature: return .colorTemperature
        case .outletInUse: return .outletInUse
        case .fanActive, .climateActive: return .active
        case .climateCurrentState: return HomeKitAccessoryMapper.currentHeaterCoolerState
        case .climateTargetState: return HomeKitAccessoryMapper.targetHeaterCoolerState
        case .climateCurrentTemperature, .sensorTemperature: return .currentTemperature
        case .climateCoolingThreshold: return HomeKitAccessoryMapper.coolingThresholdTemperature
        case .climateHeatingThreshold: return HomeKitAccessoryMapper.heatingThresholdTemperature
        case .climateFanSpeed: return .rotationSpeed
        case .climateSwing: return .swingMode
        case .climateDisplayUnits: return HomeKitAccessoryMapper.temperatureDisplayUnits
        case .climateDryName, .climateFanOnlyName: return .name
        case .climateDryConfiguredName, .climateFanOnlyConfiguredName: return HomeKitAccessoryMapper.configuredNameType
        case .sensorHumidity: return .currentRelativeHumidity
        case .batteryLevel: return .batteryLevel
        case .batteryChargingState: return HomeKitAccessoryMapper.chargingState
        case .batteryLow: return HomeKitAccessoryMapper.statusLowBattery
        }
    }

    var isConfiguredName: Bool {
        self == .climateDryConfiguredName || self == .climateFanOnlyConfiguredName
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
    /// One of `ClimateSpec.availableFanModes`.
    case climateFanMode(String)
    /// `"off"` or one of `ClimateSpec.availableSwingModes`.
    case climateSwing(String)
}

/// One device as Apple Home sees it.
public struct HomeKitAccessoryPlan: Sendable {
    public let deviceId: String
    public let info: AccessoryInfo
    public let services: [HAPService]
    /// `HomeKitRole.serviceKey` of each service, in order.
    public let serviceKeys: [String]
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
/// | Climate (AC, heater) | Heater cooler: on, auto / heat / cool, target temperature, fan speed and swing (when the device has them); switches for dry and fan only |
/// | Sensor | Temperature and humidity sensors, battery |
///
/// Vacuums, speakers, TVs and fridges are not exposed here: Apple Home has no matching HAP service.
/// `CapabilityHomeKitMapper` gives vacuums a switch from their spec.
public enum HomeKitAccessoryMapper {
    /// A bridge carries at most 150 accessories, itself included.
    public static let maxBridgedAccessories = 149
    /// Matches the app's own low-battery reminder.
    static let lowBatteryPercent = 15

    static let batteryService = HAPServiceType(rawValue: "96")
    static let heaterCoolerService = HAPServiceType(rawValue: "BC")
    static let temperatureDisplayUnits = HAPCharacteristicType(rawValue: "36")
    static let chargingState = HAPCharacteristicType(rawValue: "8F")
    static let statusLowBattery = HAPCharacteristicType(rawValue: "79")
    static let currentHeaterCoolerState = HAPCharacteristicType(rawValue: "B1")
    static let targetHeaterCoolerState = HAPCharacteristicType(rawValue: "B2")
    // HAP §6.6.1: short UUIDs omit leading zeros. "0D" makes iOS reject the entire accessory database.
    static let coolingThresholdTemperature = HAPCharacteristicType(rawValue: "D")
    static let heatingThresholdTemperature = HAPCharacteristicType(rawValue: "12")
    static let configuredNameType = HAPCharacteristicType(rawValue: "E3")

    public static func plan(
        for device: SmartDevice, name: String, configuredNames: [HomeKitRole: String] = [:]
    ) -> HomeKitAccessoryPlan? {
        guard DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { return nil }
        let specs = characteristicSpecs(for: device, configuredNames: configuredNames)
        guard !specs.isEmpty else { return nil }

        var services: [HAPService] = []
        var serviceKeys: [String] = []
        for spec in specs {
            if let index = serviceKeys.firstIndex(of: spec.role.serviceKey) {
                services[index].characteristics.append(spec.characteristic)
            } else {
                services.append(HAPService(type: spec.role.serviceType, characteristics: [spec.characteristic]))
                serviceKeys.append(spec.role.serviceKey)
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
            serviceKeys: serviceKeys,
            signature: ([name] + specs.map(\.signature)).joined(separator: "|")
        )
    }

    /// Current value of every characteristic the device exposes.
    public static func values(
        for device: SmartDevice, configuredNames: [HomeKitRole: String] = [:]
    ) -> [HomeKitRole: HAPCharacteristicValue] {
        var values: [HomeKitRole: HAPCharacteristicValue] = [:]
        for spec in characteristicSpecs(for: device, configuredNames: configuredNames) {
            if let value = spec.characteristic.value { values[spec.role] = value }
        }
        return values
    }

    /// The store action for a write from Apple Home, or nil when it is read-only or changes nothing.
    public static func write(_ role: HomeKitRole, value: HAPCharacteristicValue, to device: SmartDevice) -> HomeKitWrite? {
        guard DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { return nil }
        guard let number = number(from: value) else { return nil }
        switch (role, device.kind) {
        case (.lightOn, .light(let s)):
            let on = number != 0
            return on == s.isOn ? nil : .power(on)

        case (.lightBrightness, .light(let s)):
            let percent = Int(min(100, max(0, number)).rounded())
            if percent == 0 { return s.isOn ? .power(false) : nil }
            return (s.isOn && s.brightnessPercent == percent) ? nil : .brightness(percent)

        case (.lightColorTemperature, .light(let s)):
            // Setting a colour temperature turns the light on; only follow it while the light is already on.
            guard s.isOn, number > 0 else { return nil }
            if let current = s.colorTempKelvin, Double(mired(fromKelvin: current)) == number.rounded() { return nil }
            let kelvin = Int(min(Double(s.maxKelvin), max(Double(s.minKelvin), (1_000_000 / number).rounded())))
            return .colorTemperature(kelvin: kelvin)

        case (.outletOn, .plug(let s)):
            let on = number != 0
            return on == s.isOn ? nil : .power(on)

        case (.outletOn, .climate(let s)):
            let on = number != 0
            return on == isActive(s) ? nil : .power(on)

        case (.fanActive, .fan(let s)):
            let on = number >= 1
            return on == s.isOn ? nil : .power(on)

        case (.climateActive, .climate(let s)):
            let on = number >= 1
            return on == isActive(s) ? nil : .power(on)

        case (.climateTargetState, .climate(let s)):
            // Picking a mode also turns the device on, as it did with the thermostat.
            guard let state = Int(exactly: number.rounded()),
                  let mode = hvacMode(forTargetState: state, availableModes: s.availableModes) else { return nil }
            return isActive(s) && s.hvacMode == mode ? nil : .climateMode(mode)

        case (.climateCoolingThreshold, .climate(let s)), (.climateHeatingThreshold, .climate(let s)):
            // One set point: in auto Apple Home shows both thresholds, and either one moves it.
            let step = s.step > 0 ? s.step : 1
            let stepped = min(s.maxTemp, max(s.minTemp, (number / step).rounded() * step))
            return abs(stepped - s.targetTemperature) < 0.01 ? nil : .targetTemperature(stepped)

        case (.climateFanSpeed, .climate(let s)):
            let levels = fanLevels(of: s)
            guard !levels.isEmpty else { return nil }
            let index = Int((min(100, max(0, number)) * Double(levels.count) / 100).rounded())
            // 0 % is the device's automatic speed, when it has one.
            let mode = index == 0 ? (s.availableFanModes.first(where: isAutoFan) ?? levels[0]) : levels[index - 1]
            return mode == s.fanMode ? nil : .climateFanMode(mode)

        case (.climateSwing, .climate(let s)):
            guard let axis = swingAxis(of: s) else { return nil }
            let mode = number >= 1 ? axis : "off"
            return mode == (s.swingMode ?? "off") ? nil : .climateSwing(mode)

        case (.climateDrySwitch, .climate(let s)), (.climateFanOnlySwitch, .climate(let s)):
            let mode = role == .climateDrySwitch ? "dry" : "fan_only"
            let running = isActive(s) && s.hvacMode == mode
            // Switching the running mode off turns the device off.
            if number != 0 { return running ? nil : .climateMode(mode) }
            return running ? .power(false) : nil

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
        constant: Bool = false,
        min minValue: Double? = nil,
        max maxValue: Double? = nil,
        step: Double? = nil,
        unit: HAPUnit? = nil,
        validValues: [Int]? = nil
    ) -> Spec {
        let permissions: [HAPPermission] = writable ? [.read, .write, .notify] : constant ? [.read] : [.read, .notify]
        let characteristic = HAPCharacteristic(
            iid: 0,
            type: role.characteristicType,
            value: aligned(value, min: minValue, max: maxValue, step: step),
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

    private static func characteristicSpecs(
        for device: SmartDevice, configuredNames: [HomeKitRole: String]
    ) -> [Spec] {
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
            return climateSpecs(s, configuredNames: configuredNames)

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

    private static func climateSpecs(_ s: ClimateSpec, configuredNames: [HomeKitRole: String]) -> [Spec] {
        let states = validTargetStates(for: s)
        guard !states.isEmpty else {
            // No auto, heat or cool capability: keep power and supported mode switches without inventing a mode.
            return [
                spec(.outletOn, .bool(isActive(s)), writable: true),
                spec(.outletInUse, .bool(isActive(s))),
            ] + climateModeSpecs(s, configuredNames: configuredNames)
        }
        // The device's own range, kept within what Apple Home draws.
        let minTemp = max(0, s.minTemp)
        let maxTemp = min(38, max(minTemp, s.maxTemp))
        let target = min(maxTemp, max(minTemp, s.targetTemperature))
        let step = s.step > 0 ? s.step : 1
        var specs = [
            spec(.climateActive, .uint8(isActive(s) ? 1 : 0), writable: true, min: 0, max: 1),
            spec(.climateCurrentState, .uint8(UInt8(currentState(for: s))), min: 0, max: 3),
            spec(.climateTargetState, .uint8(UInt8(targetState(for: s))), writable: true, min: 0, max: 2, validValues: states),
            // Most ACs have no thermometer of their own: the set point stands in.
            spec(
                .climateCurrentTemperature, .float(min(100, max(0, s.currentTemperature ?? s.targetTemperature))),
                min: 0, max: 100, step: 0.1, unit: .celsius
            ),
        ]
        if states.contains(0) || states.contains(2) {
            specs.append(spec(.climateCoolingThreshold, .float(target), writable: true, min: minTemp, max: maxTemp, step: step, unit: .celsius))
        }
        if states.contains(0) || states.contains(1) {
            specs.append(spec(.climateHeatingThreshold, .float(target), writable: true, min: minTemp, max: maxTemp, step: step, unit: .celsius))
        }
        if !fanLevels(of: s).isEmpty {
            // A step of 100 / 3 overshoots 100 after three steps, and Apple Home then refuses the whole bridge.
            specs.append(spec(.climateFanSpeed, .float(fanSpeed(of: s)), writable: true, min: 0, max: 100, step: 1, unit: .percentage))
        }
        if swingAxis(of: s) != nil {
            let swinging = (s.swingMode ?? "off") != "off"
            specs.append(spec(.climateSwing, .uint8(swinging ? 1 : 0), writable: true, min: 0, max: 1))
        }
        // Celsius; Apple Home converts for display.
        specs.append(spec(.climateDisplayUnits, .uint8(0), writable: true, min: 0, max: 1))

        return specs + climateModeSpecs(s, configuredNames: configuredNames)
    }

    private static func climateModeSpecs(_ s: ClimateSpec, configuredNames: [HomeKitRole: String]) -> [Spec] {
        var specs: [Spec] = []
        // Apple Home's heater cooler knows auto, heat and cool only.
        let extraModes: [(mode: String, role: HomeKitRole, nameRole: HomeKitRole, configuredRole: HomeKitRole, name: String, displayName: String)] = [
            ("dry", .climateDrySwitch, .climateDryName, .climateDryConfiguredName, L10n.tr("除湿", "Dry"), L10n.tr("除湿模式", "Dry Mode")),
            ("fan_only", .climateFanOnlySwitch, .climateFanOnlyName, .climateFanOnlyConfiguredName, L10n.tr("送风", "Fan"), L10n.tr("仅送风", "Fan Only")),
        ]
        for extra in extraModes where s.availableModes.contains(extra.mode) {
            specs.append(spec(extra.role, .bool(isActive(s) && s.hvacMode == extra.mode), writable: true))
            specs.append(spec(extra.nameRole, .string(extra.name), constant: true))
            // Name alone leaves Apple's combined-accessory controls labelled "Switch" / "Switch 2".
            // Configured Name is writable; controller-supplied overrides survive refreshes and restarts.
            specs.append(spec(extra.configuredRole,
                              .string(configuredNames[extra.configuredRole] ?? extra.displayName), writable: true))
        }
        return specs
    }

    // MARK: - Climate States

    private static let autoModes = ["auto", "heat_cool"]

    /// HAP target state: 0 auto, 1 heat, 2 cool. Dry and fan only show as auto, or the first state the device has.
    static func targetState(for s: ClimateSpec) -> Int {
        let states = validTargetStates(for: s)
        switch s.hvacMode {
        case "heat" where states.contains(1): return 1
        case "cool" where states.contains(2): return 2
        default: return states.contains(0) ? 0 : (states.first ?? 0)
        }
    }

    /// HAP current state: 0 inactive, 1 idle, 2 heating, 3 cooling.
    static func currentState(for s: ClimateSpec) -> Int {
        guard isActive(s) else { return 0 }
        switch s.hvacMode {
        case "heat": return 2
        case "cool": return 3
        default: return 1
        }
    }

    static func validTargetStates(for s: ClimateSpec) -> [Int] {
        var states: [Int] = []
        if s.availableModes.contains(where: autoModes.contains) { states.append(0) }
        if s.availableModes.contains("heat") { states.append(1) }
        if s.availableModes.contains("cool") { states.append(2) }
        return states
    }

    static func hvacMode(forTargetState state: Int, availableModes: [String]) -> String? {
        switch state {
        case 0: return autoModes.first(where: availableModes.contains)
        case 1: return availableModes.contains("heat") ? "heat" : nil
        case 2: return availableModes.contains("cool") ? "cool" : nil
        default: return nil
        }
    }

    private static func isActive(_ s: ClimateSpec) -> Bool {
        s.isOn && s.hvacMode != "off"
    }

    // MARK: - Fan Speed & Swing

    static func isAutoFan(_ mode: String) -> Bool {
        mode.lowercased().contains("auto")
    }

    /// Fixed speeds, slowest first, as the spec lists them.
    static func fanLevels(of s: ClimateSpec) -> [String] {
        s.availableFanModes.filter { !isAutoFan($0) }
    }

    /// Fixed speeds spread evenly up to 100 % in whole percent; the automatic speed (or none reported) is 0 %.
    static func fanSpeed(of s: ClimateSpec) -> Double {
        let levels = fanLevels(of: s)
        guard let mode = s.fanMode, let index = levels.firstIndex(of: mode) else { return 0 }
        return (Double(index + 1) * 100 / Double(levels.count)).rounded()
    }

    static func swingAxis(of s: ClimateSpec) -> String? {
        s.availableSwingModes.first { $0 != "off" }
    }

    // MARK: - Values

    /// Apple Home refuses to add a bridge with a value off its characteristic's `minValue + n × minStep` grid, or above
    /// the last grid point under `maxValue` (HAP-NodeJS #1077), so float values are snapped onto that grid.
    static func aligned(_ value: HAPCharacteristicValue, min minValue: Double?, max maxValue: Double?, step: Double?) -> HAPCharacteristicValue {
        guard case .float(let raw) = value, let step, step > 0 else { return value }
        let base = minValue ?? 0
        var steps = ((raw - base) / step).rounded()
        if let maxValue { steps = min(steps, ((maxValue - base) / step + 1e-9).rounded(.down)) }
        if minValue != nil { steps = max(steps, 0) }
        // Divide by a whole scale where there is one, so 258 × 0.1 comes out as 25.8 and not 25.800000000000004.
        let scale = (1 / step).rounded()
        let offset = step < 1 && abs(scale * step - 1) < 1e-9 ? steps / scale : steps * step
        return .float(base + offset)
    }

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
        case .string(let v): return Double(v).flatMap { $0.isFinite ? $0 : nil }
        case .data, .tlv8: return nil
        }
    }

    /// `yeelink.light.ceiling13` → `yeelink`; Apple Home shows it under the accessory details.
    static func manufacturer(for model: String) -> String {
        let vendor = model.split(separator: ".").first.map(String.init) ?? ""
        return vendor.isEmpty ? "MijiaLAN" : vendor
    }
}
