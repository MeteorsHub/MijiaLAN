import Foundation
import MijiaCore

/// Complete MIoT schema, including action arguments and enum translations omitted by MijiaCore.
/// It is data, not a per-model device implementation. The same parser drives the panel and HomeKit.
public struct DeviceSchema: Codable, Equatable, Sendable {
    public var model: String?
    public var type: String
    public var description: String?
    public var services: [Service]

    public struct Option: Codable, Equatable, Sendable, Identifiable {
        public var value: Int
        public var description: String
        public var comment: String?
        public var id: Int { value }
        public var title: String { CapabilityNames.option(L10n.isEnglish ? description : (comment ?? description)) }
    }
    public struct Property: Codable, Equatable, Sendable {
        public var iid: Int
        public var type: String
        public var description: String?
        public var comment: String?
        public var format: String
        public var access: [String]
        public var unit: String?
        public var valueRange: [Double]?
        public var valueList: [Option]?
        enum CodingKeys: String, CodingKey {
            case iid, type, description, comment, format, access, unit
            case valueRange = "value-range", valueList = "value-list"
        }
        public var name: String { DeviceSchema.shortName(type) }
    }
    public struct Action: Codable, Equatable, Sendable {
        public var iid: Int
        public var type: String
        public var description: String?
        public var comment: String?
        public var inputs: [Int]
        public var outputs: [Int]
        enum CodingKeys: String, CodingKey {
            case iid, type, description, comment
            case inputs = "in", outputs = "out"
        }
        public var name: String { DeviceSchema.shortName(type) }
    }
    public struct Service: Codable, Equatable, Sendable {
        public var iid: Int
        public var type: String
        public var description: String?
        public var properties: [Property]
        public var actions: [Action]
        enum CodingKeys: String, CodingKey { case iid, type, description, properties, actions }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            iid = try c.decode(Int.self, forKey: .iid)
            type = try c.decode(String.self, forKey: .type)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            properties = try c.decodeIfPresent([Property].self, forKey: .properties) ?? []
            actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        }
        public var name: String { DeviceSchema.shortName(type) }
    }
    public var category: String { Self.shortName(type) }
    public var isCooking: Bool { ["cooker", "health-pot", "juicer", "air-fryer"].contains(category) }
    public static func shortName(_ urn: String) -> String {
        let pieces = urn.split(separator: ":")
        return pieces.count > 3 ? String(pieces[3]) : urn
    }
    public static func bundled(model: String) -> DeviceSchema? {
        guard let url = Bundle.module.url(forResource: model, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public static let bundledModels = [
        "dmaker.fan.p28", "zhimi.airpurifier.rma1", "yeelink.light.lamp4", "lumi.acpartner.mcn02",
        "chuangmi.plug.m3", "cuco.plug.v3", "careli.fryer.maf07c", "chunmi.cooker.cmwy3",
        "chunmi.health_pot.a1", "chunmi.juicer.a1",
    ]
    public var coreSpec: MiotDeviceSpec? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(MiotDeviceSpec.self, from: data)
    }
}

public struct DeviceCapability: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case property, action }
    public enum Control: String, Sendable { case toggle, number, choice, button, reading, unsupported }
    public var id: String
    public var model: String = ""
    public var specification: String = ""
    public var declaredAccess: [String] = []
    public var kind: Kind
    public var siid: Int
    public var iid: Int
    public var service: String
    public var name: String
    public var title: String
    public var format: String
    public var readable: Bool
    public var writable: Bool
    public var unit: String?
    public var range: [Double]?
    public var options: [DeviceSchema.Option]
    public var inputs: [Int]
    public var outputs: [Int]
    public var control: Control
    public var prepared: Bool
    public var limitation: String?
    public var lowFrequency: Bool
    public var min: Double? { range?.first }
    public var max: Double? { range.flatMap { $0.count >= 2 ? $0[1] : nil } }
    public var step: Double { range.flatMap { $0.count >= 3 ? $0[2] : nil } ?? 1 }
    public var isNumeric: Bool { format == "float" || format.hasPrefix("int") || format.hasPrefix("uint") }
    public var displayTitle: String { prepared ? (["mode", "cook-mode"].contains(name) ? L10n.tr("下次菜单", "Next Menu") : L10n.tr("下次\(title)", "Next \(title)")) : title }
    public var displayUnit: String { CapabilityNames.unit(unit, name: name) }

    public static func propertyID(_ siid: Int, _ piid: Int) -> String { "p:\(siid):\(piid)" }
    public static func actionID(_ siid: Int, _ aiid: Int) -> String { "a:\(siid):\(aiid)" }

    public func validated(_ value: JSONValue) throws -> JSONValue {
        if let reason = DeviceLANPolicy.restriction(for: model) { throw DeviceControlError.unsupported(reason) }
        return try validate(value, enforceStep: true)
    }

    /// Sensor samples may be finer than the writable step. Types, bounds and enums still apply.
    /// Never coerce numeric strings or 0/1 into booleans when accepting device telemetry.
    public func validatedReading(_ value: JSONValue) throws -> JSONValue {
        if let reason = DeviceLANPolicy.restriction(for: model) { throw DeviceControlError.unsupported(reason) }
        if isNumeric, case .number = value {
            return try validate(value, enforceStep: format != "float")
        }
        if format == "bool", case .bool = value { return value }
        if format == "string", case .string = value { return value }
        throw DeviceControlError.invalidValue(title)
    }

    private func validate(_ value: JSONValue, enforceStep: Bool) throws -> JSONValue {
        if format == "bool" {
            guard case .bool = value else { throw DeviceControlError.invalidValue(title) }
            return value
        }
        if isNumeric {
            guard let n = value.doubleValue, n.isFinite else { throw DeviceControlError.invalidValue(title) }
            if format != "float", n.rounded() != n { throw DeviceControlError.invalidValue(title) }
            if let min, n < min { throw DeviceControlError.invalidValue(title) }
            if let max, n > max { throw DeviceControlError.invalidValue(title) }
            if !options.isEmpty, !options.contains(where: { Double($0.value) == n }) { throw DeviceControlError.invalidValue(title) }
            if enforceStep, let min, step > 0, abs((n - min) / step - ((n - min) / step).rounded()) > 0.00001 {
                throw DeviceControlError.invalidValue(title)
            }
            return .number(n)
        }
        throw DeviceControlError.unsupported(limitation ?? title)
    }

    /// A malformed property remains diagnosable and cannot supply a confirmed state to a bridge.
    public func checkedReading(_ reading: DeviceReading) -> DeviceReading {
        if let reason = DeviceLANPolicy.restriction(for: model) {
            var paused = reading
            paused.rawValue = reading.rawValue ?? reading.value
            paused.value = nil
            paused.error = reading.error ?? reason
            return paused
        }
        guard reading.isAvailable, let value = reading.value else { return reading }
        do {
            _ = try validatedReading(value)
            return reading
        } catch {
            var rejected = reading
            rejected.rawValue = value
            rejected.value = nil
            let type: String
            switch value {
            case .bool: type = "boolean"
            case .number: type = "number"
            case .string: type = "string"
            case .null: type = "null"
            case .array: type = "array"
            case .object: type = "object"
            }
            rejected.error = L10n.tr("设备读数不符合规格（规格：\(format)，实际：\(type)）",
                "Reading does not match the specification (expected: \(format), received: \(type)).")
            return rejected
        }
    }

    public func formatted(_ value: JSONValue?) -> String {
        if !DeviceLANPolicy.allowsPropertyRequests(for: model) { return DeviceLANPolicy.unverifiedReadingsTitle }
        guard let value else { return L10n.tr("尚无读数", "No Reading") }
        if let n = value.doubleValue {
            if let option = options.first(where: { Double($0.value) == n }) {
                if name == "fault", n == 0, option.description.lowercased() == "null",
                   ["giot.heater.v13daf", "xiaomi.feeder.pi2001"].contains(model) {
                    return L10n.tr("状态码 0（规格未提供说明）", "Status code 0 (no specification label)")
                }
                return option.title
            }
            let text = n.rounded() == n ? String(format: "%.0f", n) : String(format: "%.1f", n)
            return text + displayUnit
        }
        if case .bool(let b) = value { return b ? L10n.tr("开", "On") : L10n.tr("关", "Off") }
        return value.stringValue ?? L10n.tr("尚无读数", "No Reading")
    }
}

public enum DeviceControlError: LocalizedError, Equatable, Sendable {
    case offline, unavailable(String), invalidValue(String), unsupported(String), missingInput(String)
    case notConfirmed, wrongDevice, busy
    public var errorDescription: String? {
        switch self {
        case .offline: return L10n.tr("设备离线，未执行操作", "The device is offline. No command was sent.")
        case .unavailable(let s): return L10n.tr("无法读取：\(s)", "Could not read: \(s)")
        case .invalidValue(let s): return L10n.tr("参数超出设备允许范围：\(s)", "Value outside the device's allowed range: \(s)")
        case .unsupported(let s): return L10n.tr("暂不支持：\(CapabilityNames.limitation(s))", "Not supported yet: \(CapabilityNames.limitation(s))")
        case .missingInput(let s): return L10n.tr("请先选择\(s)", "Select \(s) first.")
        case .notConfirmed: return L10n.tr("指令已发送，但尚未确认设备状态", "Command sent, but the device state has not been confirmed.")
        case .wrongDevice: return L10n.tr("设备身份与清单不符，未发送控制指令", "Device identity does not match the list. No control command was sent.")
        case .busy: return L10n.tr("设备正在执行操作", "The device is busy.")
        }
    }
}

public struct DeviceReading: Equatable, Sendable {
    public var value: JSONValue?
    /// Unvalidated telemetry retained only for diagnosis; never returned by DeviceSnapshot.value.
    public var rawValue: JSONValue?
    public var updatedAt: Date?
    public var code: Int?
    public var error: String?
    public init(value: JSONValue? = nil, updatedAt: Date? = nil, code: Int? = nil, error: String? = nil, rawValue: JSONValue? = nil) {
        self.value = value; self.updatedAt = updatedAt; self.code = code; self.error = error; self.rawValue = rawValue
    }
    public var isAvailable: Bool { value != nil && error == nil && (code == nil || code == 0) }
}

public struct DeviceSnapshot: Equatable, Sendable, Identifiable {
    public var device: LocalDevice
    public var schema: DeviceSchema { didSet { coreSpec = schema.coreSpec } }
    public var capabilities: [DeviceCapability] {
        didSet {
            capabilities = capabilities.filter { DeviceLANPolicy.allowsCapability(model: device.model, kind: $0.kind, siid: $0.siid, iid: $0.iid, inputs: $0.inputs, outputs: $0.outputs) }
            capabilitiesByID = Dictionary(capabilities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    public private(set) var coreSpec: MiotDeviceSpec?
    public private(set) var capabilitiesByID: [String: DeviceCapability]
    public var readings: [String: DeviceReading] = [:]
    public var prepared: [String: JSONValue] = [:]
    public var health = LANDeviceHealth()
    public var lastCommand: String?
    public var commandReceipt: DeviceCommandReceipt?
    public init(device: LocalDevice, schema: DeviceSchema, capabilities: [DeviceCapability],
                readings: [String: DeviceReading] = [:], prepared: [String: JSONValue] = [:], health: LANDeviceHealth = LANDeviceHealth()) {
        self.device = device; self.schema = schema
        self.capabilities = capabilities.filter { DeviceLANPolicy.allowsCapability(model: device.model, kind: $0.kind, siid: $0.siid, iid: $0.iid, inputs: $0.inputs, outputs: $0.outputs) }
        self.coreSpec = schema.coreSpec
        self.capabilitiesByID = Dictionary(self.capabilities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.readings = readings; self.prepared = prepared; self.health = health
    }
    public var id: String { device.did }
    public var isOnline: Bool { health.state == .online }
    public var lanReadingsRestriction: String? { DeviceLANPolicy.restriction(for: device.model) }
    public var controls: [DeviceCapability] { DeviceLANPolicy.allowsPropertyRequests(for: device.model) ? capabilities.filter { $0.control != .unsupported && $0.control != .reading } : [] }
    public var primaryPower: DeviceCapability? {
        capability(schema.category, "on") ?? (schema.category == "outlet" ? capability("switch", "on") : nil)
    }
    public func capability(_ service: String, _ name: String) -> DeviceCapability? {
        capabilities.first { $0.kind == .property && $0.service == service && $0.name == name }
    }
    public func value(_ id: String) -> JSONValue? {
        guard DeviceLANPolicy.allowsPropertyRequests(for: device.model), readings[id]?.isAvailable == true else { return nil }
        return readings[id]?.value
    }
    public func value(_ service: String, _ name: String) -> JSONValue? {
        capability(service, name).flatMap { value($0.id) }
    }
    public func controlValue(_ c: DeviceCapability) -> JSONValue? {
        guard DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { return nil }
        return c.prepared ? prepared[c.id] : value(c.id)
    }

    /// An observed read failure disables only its corresponding control until it can be confirmed again.
    public func controlUnavailableReason(_ c: DeviceCapability) -> String? {
        if let reason = lanReadingsRestriction { return reason }
        guard !c.prepared, c.kind == .property else { return nil }
        if c.readable, let error = readings[c.id]?.error { return error }
        if device.model == "dooya.motor.dc1545", c.siid == 2, c.name == "motor-control",
           (value("motor-controller", "status") == nil || value("motor-controller", "current-position") == nil) {
            return L10n.tr("尚无法确认卷帘状态，请先完成只读诊断", "Curtain state is unconfirmed. Complete read-only diagnostics first.")
        }
        return nil
    }

    /// Contact/read timestamps remain accurate without making a no-change poll a semantic update.
    func hasSameValues(as other: DeviceSnapshot?) -> Bool {
        guard let other, health.state == other.health.state, health.lastError == other.health.lastError,
              prepared == other.prepared, readings.count == other.readings.count else { return false }
        return readings.allSatisfy { id, reading in
            guard let previous = other.readings[id] else { return false }
            return reading.value == previous.value && reading.rawValue == previous.rawValue && reading.code == previous.code && reading.error == previous.error
        }
    }
}

public struct DeviceCommandReceipt: Equatable, Sendable {
    public var capabilityID: String
    public var requestedAt: Date
    public var acceptedAt: Date?
    public var confirmedAt: Date?
    public var error: String?
    public init(capabilityID: String) { self.capabilityID = capabilityID; requestedAt = Date() }
}

/// Configuration by semantic service/property. Model-specific entries only express protocol differences.
public enum DeviceCapabilityCatalog {
    private static let excludedServices: Set<String> = [
        "device-information", "self-check", "air-condition-outlet-matching", "aqi",
    ]
    private static let actionNames: Set<String> = ["start-cook", "cancel-cooking", "pause", "resume-cook"]
    private static let preparedNames: Set<String> = [
        "mode", "cook-mode", "target-time", "target-temperature", "auto-keep-warm", "target-cooking-measure",
        "texture", "reservation-left-time", "cooking-weight", "turn-pot-config",
    ]
    private static let unverifiedNames: Set<String> = [
        "swing-updown-manual", "swing-lr-manual", "start-left", "start-right", "start-up", "start-down",
        "recipe-id", "recipe-name", "recipe-sync", "data-value",
    ]

    public static func capabilities(schema: DeviceSchema, model: String) -> [DeviceCapability] {
        let legacy = LegacyMiioProfile.forModel(model)
        var result: [DeviceCapability] = []
        for service in schema.services where !excludedServices.contains(service.name) {
            let argumentIDs = Set(service.actions.filter { actionNames.contains($0.name) }.flatMap(\.inputs))
            for p in service.properties {
                guard DeviceLANPolicy.allowsCapability(model: model, kind: .property, siid: service.iid, iid: p.iid) else { continue }
                let prepared = schema.isCooking && (argumentIDs.contains(p.iid) || (service.name == schema.category && preparedNames.contains(p.name)))
                var readable = p.access.contains("read")
                var writable = p.access.contains("write")
                var limitation: String?
                if let legacy {
                    let binding = legacy.property(siid: service.iid, piid: p.iid)
                    readable = readable && binding != nil
                    writable = writable && binding?.setter != nil
                    if binding == nil { limitation = "规格存在，尚无经过确认的旧 miIO 映射" }
                }
                let numeric = p.format == "float" || p.format.hasPrefix("int") || p.format.hasPrefix("uint")
                let knownRange = (p.valueRange?.count ?? 0) >= 2 || !(p.valueList ?? []).isEmpty
                var control: DeviceCapability.Control = readable ? .reading : .unsupported
                if prepared || writable {
                    if p.format == "bool" { control = readable || prepared ? .toggle : .button }
                    else if !(p.valueList ?? []).isEmpty { control = .choice }
                    else if numeric && knownRange { control = .number }
                    else { limitation = "缺少可验证的参数定义，暂不写入" }
                }
                if unverifiedNames.contains(p.name) || (p.format == "string" && writable) {
                    limitation = "厂商参数或停止语义尚未确认，暂不写入"
                    writable = false; control = readable ? .reading : .unsupported
                }
                if !readable && !writable && !prepared { control = .unsupported }
                var options = p.valueList ?? []
                var unit = p.unit
                let fallback = L10n.isEnglish ? (p.description ?? p.name) : (p.comment ?? p.description ?? p.name)
                var title = CapabilityNames.property(service: service.name, name: p.name, fallback: fallback)
                if service.properties.filter({ $0.name == p.name }).count > 1 {
                    // Vendor specs reuse standard property names for distinct meanings. Retain the
                    // available description/comment, and always expose a stable, non-secret address.
                    let specific = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !specific.isEmpty, specific.lowercased() != p.name.lowercased() { title = specific }
                    title += " (S\(service.iid)/P\(p.iid))"
                }
                if model == "giot.heater.v13daf", p.name == "on" {
                    if service.name == "heater" { title = L10n.tr("壁炉主电源", "Fireplace Main Power") }
                    if service.name == "light" { title = L10n.tr("壁炉灯光电源", "Fireplace Light Power") }
                }
                if model == "dmaker.fan.p28", service.iid == 3, p.iid == 1 { unit = "minutes" }
                if p.name.contains("swing-included-angle") { unit = "arcdegrees" }
                if model == "cuco.plug.v3" {
                    if service.iid == 2, p.iid == 2 {
                        // Meanings preserved in the reviewed raw specification's Chinese comment.
                        options = [L10n.tr("恢复断电前状态", "Restore Previous State"), L10n.tr("上电打开", "Turn On"), L10n.tr("上电关闭", "Stay Off")].enumerated().map { .init(value: $0.offset, description: $0.element) }
                        control = .choice
                    }
                    if service.iid == 11, p.iid == 1 { title = L10n.tr("累计电量（原始值 × 0.01 kWh）", "Energy Used (raw value × 0.01 kWh)") }
                    if service.iid == 8, p.iid == 3 { writable = false; control = .reading }
                    if service.iid == 5 {
                        writable = false; control = readable ? .reading : .unsupported
                        limitation = "复合循环计划尚未确认，暂不启用或修改"
                    }
                }
                if schema.isCooking, p.name == "current-keep-warm" {
                    // A current-state field is not a future cooking parameter.
                    writable = false; control = .reading
                }
                if let reason = DeviceLANPolicy.restriction(for: model) {
                    writable = false
                    control = readable ? .reading : .unsupported
                    limitation = reason
                }
                result.append(DeviceCapability(
                    id: DeviceCapability.propertyID(service.iid, p.iid), model: model, specification: schema.type, declaredAccess: p.access, kind: .property, siid: service.iid, iid: p.iid,
                    service: service.name, name: p.name, title: title, format: p.format, readable: readable,
                    writable: writable, unit: unit, range: p.valueRange, options: options, inputs: [], outputs: [],
                    control: control, prepared: prepared, limitation: limitation,
                    lowFrequency: ["filter", "power-consumption", "on-off-count"].contains(service.name)
                ))
            }
            for a in service.actions {
                guard DeviceLANPolicy.allowsCapability(model: model, kind: .action, siid: service.iid, iid: a.iid, inputs: a.inputs, outputs: a.outputs) else { continue }
                let supported = DeviceLANPolicy.allowsPropertyRequests(for: model) && legacy == nil && actionNames.contains(a.name) && service.name == schema.category
                result.append(DeviceCapability(
                    id: DeviceCapability.actionID(service.iid, a.iid), model: model, specification: schema.type, kind: .action, siid: service.iid, iid: a.iid,
                    service: service.name, name: a.name,
                    title: CapabilityNames.action(a.name, fallback: L10n.isEnglish ? (a.description ?? a.name) : (a.comment ?? a.description ?? a.name)),
                    format: "action", readable: false, writable: supported, unit: nil, range: nil, options: [],
                    inputs: a.inputs, outputs: a.outputs, control: supported ? .button : .unsupported, prepared: false,
                    limitation: supported ? nil : "维护操作或厂商复合参数，不作为日常控制", lowFrequency: false
                ))
            }
        }
        return result
    }
}
