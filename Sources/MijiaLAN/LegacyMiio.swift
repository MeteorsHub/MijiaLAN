import Foundation
import MijiaCore

/// Pre-MIoT Wi-Fi devices speak only their original miIO dialect on the LAN (`get_prop`, `set_power`, …). The
/// cloud translates MIoT for them, so a LAN `get_properties` just gets `-9999 user ack timeout` about four seconds
/// later. A profile does that translation locally for one model, MIoT property by MIoT property.
///
/// The tables come from hass-xiaomi-miot's `miio2miot_specs.py`, the mapping most Home Assistant users run. A few
/// models were checked on real devices here and keep a hand-written table; the rest are converted from the Python
/// file by `scripts/import_hass_xiaomi_miot.py` into `hass-xiaomi-miot-miio2miot.json`. Roborock vacuums are ported
/// by hand too: they report through `get_status`, which the converter does not read.
public struct LegacyMiioProfile: Sendable {
    public enum Source: Equatable, Sendable {
        /// Written and checked against a real device in this project.
        case verified
        /// Converted from hass-xiaomi-miot; `base` is the table entry a model alias points to.
        case hassXiaomiMiot(base: String?)
    }

    public struct Property: Sendable {
        /// Legacy reply value → MIoT value.
        public enum Read: Sendable, Equatable {
            /// `"on"` / `"off"` ↔ `true` / `false`.
            case onOff
            /// Whatever the MIoT format implies: booleans and numbers (also numbers sent as strings) pass, `"on"` /
            /// `"off"` style words become booleans, other text stays text. `resolved(with:)` turns it into
            /// `.boolean` or `.number` once the spec says which.
            case auto
            /// A MIoT bool from any legacy spelling: `true`, non-zero numbers, `"on"`, `"yes"`, `"1"`, ….
            case boolean
            /// `value × ratio + offset`, after removing `strip` from a text reply (`"1200rpm"`).
            case number(ratio: Double, offset: Double, strip: String?)
            /// Legacy string → MIoT value-list number; unknown strings give `fallback`, or no value.
            case values([String: Int], fallback: Int?)
            case nonZero
            case equals(JSONValue)
            case notEquals(JSONValue)
            case ifEquals(JSONValue, then: JSONValue, else: JSONValue)
            case ifNonZero(then: JSONValue, else: JSONValue)
        }

        /// MIoT value → the legacy setter's arguments (before `suffix`).
        public enum Write: Sendable, Equatable {
            case onOff
            /// The MIoT value as it is.
            case value
            case string
            /// `Int(value × ratio + offset)`.
            case integer(ratio: Double, offset: Double)
            case values([String: Int])
            case boolChoice(on: JSONValue, off: JSONValue)
            /// No arguments; the value picks the method instead (`set_usb_on` / `set_usb_off`).
            case methodSwitch(on: String, off: String)
        }

        /// Kept for the hand-written tables.
        public enum Format: Sendable {
            /// `"on"` / `"off"` ↔ `true` / `false`.
            case onOff
            /// Numbers, also when the device sends them as strings (Yeelight's `"71"`).
            case number
            /// Legacy string ↔ the MIoT value-list number.
            case values([String: Int])
        }

        public var siid: Int
        public var piid: Int
        /// The legacy property name for `get_prop`.
        public var name: String
        public var read: Read
        /// The legacy setter; nil for read-only properties.
        public var setter: String?
        public var write: Write?
        /// Arguments after the value, e.g. `["smooth", 500]` for `set_ct_abx`.
        public var setterSuffix: [JSONValue]

        init(_ siid: Int, _ piid: Int, _ name: String, _ format: Format, setter: String? = nil, suffix: [JSONValue] = []) {
            self.siid = siid
            self.piid = piid
            self.name = name
            switch format {
            case .onOff: read = .onOff; write = .onOff
            case .number: read = .number(ratio: 1, offset: 0, strip: nil); write = .value
            case .values(let table): read = .values(table, fallback: nil); write = .values(table)
            }
            self.setter = setter
            if setter == nil { write = nil }
            self.setterSuffix = suffix
        }

        init(siid: Int, piid: Int, name: String, read: Read, setter: String?, write: Write?, suffix: [JSONValue]) {
            self.siid = siid
            self.piid = piid
            self.name = name
            self.read = read
            self.setter = setter
            self.write = write
            self.setterSuffix = suffix
        }

        public var isWritable: Bool { setter != nil && write != nil }

        /// Legacy reply value → MIoT value.
        func miotValue(_ legacy: JSONValue) -> JSONValue? {
            switch read {
            case .onOff:
                if case .bool = legacy { return legacy }
                guard let text = legacy.stringValue?.lowercased(), ["on", "off"].contains(text) else { return nil }
                return .bool(text == "on")
            case .auto:
                switch legacy {
                case .bool, .number: return legacy
                case .string(let text):
                    if let number = Double(text) { return .number(number) }
                    switch text.lowercased() {
                    case "on", "true", "yes": return .bool(true)
                    case "off", "false", "no": return .bool(false)
                    default: return legacy
                    }
                default: return nil
                }
            case .boolean:
                switch legacy {
                case .bool: return legacy
                case .number(let n): return .bool(n != 0)
                case .string(let text):
                    switch text.lowercased() {
                    case "1", "true", "yes", "on", "enable": return .bool(true)
                    case "0", "false", "no", "off", "disable": return .bool(false)
                    default: return nil
                    }
                default: return nil
                }
            case .number(let ratio, let offset, let strip):
                var source = legacy
                if let strip, let text = legacy.stringValue { source = .string(text.replacingOccurrences(of: strip, with: "")) }
                return source.doubleValue.flatMap { raw in
                    let n = raw * ratio + offset
                    let value = ratio == 1 ? n : (n * 1000).rounded() / 1000
                    // "nan" and "inf" parse as numbers, but they are no reading.
                    return value.isFinite ? .number(value) : nil
                }
            case .values(let table, let fallback):
                let key = legacy.stringValue ?? legacy.doubleValue.map { Int(exactly: $0).map(String.init) ?? String($0) }
                if let key, let number = table[key] { return .number(Double(number)) }
                return fallback.map { .number(Double($0)) }
            case .nonZero:
                return Self.number(legacy).map { .bool($0 != 0) }
            case .equals(let target):
                return .bool(Self.same(legacy, target))
            case .notEquals(let target):
                return .bool(!Self.same(legacy, target))
            case .ifEquals(let target, let then, let otherwise):
                return Self.same(legacy, target) ? then : otherwise
            case .ifNonZero(let then, let otherwise):
                return (Self.number(legacy) ?? 0) != 0 ? then : otherwise
            }
        }

        /// MIoT value → the legacy setter's first argument.
        func legacyArgument(_ miot: JSONValue) -> JSONValue? {
            legacyCall(miot)?.params.first
        }

        /// MIoT value → the legacy method and its parameters, `setterSuffix` included.
        func legacyCall(_ miot: JSONValue) -> (method: String, params: [JSONValue])? {
            guard let setter, let write else { return nil }
            let on = miot.boolValue ?? miot.doubleValue.map { $0 != 0 }
            let argument: JSONValue
            switch write {
            case .onOff:
                guard let on else { return nil }
                argument = .string(on ? "on" : "off")
            case .value:
                argument = miot
            case .string:
                if let n = miot.doubleValue { argument = .string(Int(exactly: n).map(String.init) ?? String(n)) }
                else if let text = miot.stringValue { argument = .string(text) }
                else { return nil }
            case .integer(let ratio, let offset):
                guard let n = Self.number(miot) else { return nil }
                argument = .number((n * ratio + offset).rounded(.towardZero))
            case .values(let table):
                guard let number = miot.integer, let key = table.first(where: { $0.value == number })?.key else { return nil }
                argument = .string(key)
            case .boolChoice(let onValue, let offValue):
                guard let on else { return nil }
                argument = on ? onValue : offValue
            case .methodSwitch(let onMethod, let offMethod):
                guard let on else { return nil }
                return (on ? onMethod : offMethod, setterSuffix)
            }
            return (setter, [argument] + setterSuffix)
        }

        private static func number(_ value: JSONValue) -> Double? {
            if let b = value.boolValue { return b ? 1 : 0 }
            return value.doubleValue
        }

        private static func same(_ value: JSONValue, _ target: JSONValue) -> Bool {
            if let a = value.doubleValue, let b = target.doubleValue { return a == b }
            return value.stringValue != nil && value.stringValue == target.stringValue
        }
    }

    /// A MIoT action carried out by legacy methods without arguments, called in order.
    public struct Action: Sendable, Equatable {
        public var siid: Int
        public var aiid: Int
        public var methods: [String]
    }

    public var properties: [Property]
    public var source: Source = .verified
    /// Most properties one `get_prop` may ask for; nil means all at once.
    public var chunkSize: Int?
    /// The device answers setters with something other than `"ok"`; any reply counts as done.
    public var ignoresResult = false
    /// Set when the device reports every value through one call instead of `get_prop`, such as Roborock's
    /// `get_status`. Values are looked up by `Property.name` in the reply's first object.
    public var statusMethod: String?
    public var actions: [Action] = []

    public func property(siid: Int, piid: Int) -> Property? {
        properties.first { $0.siid == siid && $0.piid == piid }
    }

    public func action(siid: Int, aiid: Int) -> Action? {
        actions.first { $0.siid == siid && $0.aiid == aiid }
    }

    /// Whether a setter or action reply means done.
    func accepts(_ result: JSONValue) -> Bool {
        result == .array([.string("ok")]) || result == .string("ok") || (ignoresResult && result.arrayValue != nil)
    }

    /// `.auto` reads made exact by the MIoT format, as hass-xiaomi-miot does: a bool property turns `1` / `"on"`
    /// into `true`, a numeric one parses text. Without a spec the reads stay `.auto`.
    public func resolved(with schema: DeviceSchema?) -> LegacyMiioProfile {
        guard let schema else { return self }
        var profile = self
        profile.properties = properties.map { property in
            guard property.read == .auto,
                  let format = schema.services.first(where: { $0.iid == property.siid })?
                      .properties.first(where: { $0.iid == property.piid })?.format else { return property }
            var exact = property
            if format == "bool" {
                exact.read = .boolean
            } else if format == "float" || format.hasPrefix("int") || format.hasPrefix("uint") {
                exact.read = .number(ratio: 1, offset: 0, strip: nil)
            }
            return exact
        }
        return profile
    }

    /// The checked table when there is one, else hass-xiaomi-miot's.
    public static func forModel(_ model: String) -> LegacyMiioProfile? { profiles[model] ?? imported[model] }

    public static var supportedModels: [String] { Set(profiles.keys).union(imported.keys).sorted() }

    // MARK: Tables

    /// 小米空调伴侣 2.
    static let acPartnerMcn02 = LegacyMiioProfile(properties: [
        Property(2, 1, "power", .onOff, setter: "set_power"),
        Property(2, 2, "mode", .values(["auto": 0, "cool": 1, "dry": 2, "heat": 3, "wind": 4]), setter: "set_mode"),
        Property(2, 3, "tar_temp", .number, setter: "set_tar_temp"),
        Property(3, 1, "fan_level", .values(["auto_fan": 0, "small_fan": 1, "medium_fan": 2, "large_fan": 3]), setter: "set_fan_level"),
        Property(3, 2, "ver_swing", .onOff, setter: "set_ver_swing"),
        Property(5, 1, "load_power", .number),
    ])

    /// Yeelight white lights (米家台灯 1S): power, brightness, colour temperature.
    static let yeelightWhite = LegacyMiioProfile(properties: [
        Property(2, 1, "power", .onOff, setter: "set_power"),
        Property(2, 2, "bright", .number, setter: "set_bright"),
        Property(2, 3, "ct", .number, setter: "set_ct_abx", suffix: [.string("smooth"), .number(500)]),
    ])

    /// 创米智能插座 (m1 / m3).
    static let chuangmiPlug = LegacyMiioProfile(properties: [
        Property(2, 1, "power", .onOff, setter: "set_power"),
        Property(2, 2, "temperature", .number),
        Property(3, 1, "wifi_led", .onOff, setter: "set_wifi_led"),
    ])

    /// Roborock vacuums from before MIoT: 米家扫地机器人 and 石头 C1 / E2 / S5. Ported from hass-xiaomi-miot's
    /// `rockrobo.vacuum.v1` table, with python-miio's Roborock driver (`9a00e08`) where that table falls short:
    /// docking (15) and charging complete (100) count as returning and charging rather than idle, and the first
    /// generation has to pause before it can be sent home. Not checked on a real device here.
    static func roborock(base: String?, pausesBeforeDock: Bool) -> LegacyMiioProfile {
        // Roborock state → MIoT status: 1 idle, 2 sweeping, 3 charging, 4 paused, 5 go charging, 6 remote control, 7 error.
        let status = ["1": 2, "2": 7, "3": 1, "4": 6, "5": 2, "6": 5, "7": 6, "8": 3, "9": 7, "10": 4, "11": 2, "12": 7,
                      "13": 7, "15": 5, "16": 6, "17": 2, "18": 2, "100": 3]
        let number = Property.Read.number(ratio: 1, offset: 0, strip: nil)
        return LegacyMiioProfile(
            properties: [
                Property(siid: 2, piid: 1, name: "state", read: .values(status, fallback: 1), setter: nil, write: nil, suffix: []),
                Property(siid: 2, piid: 2, name: "fan_power", read: number, setter: "set_custom_mode", write: .value, suffix: []),
                Property(siid: 3, piid: 1, name: "battery", read: number, setter: nil, write: nil, suffix: []),
                // MIoT charging state: 1 charging, 2 not charging.
                Property(siid: 3, piid: 2, name: "state", read: .values(["8": 1], fallback: 2), setter: nil, write: nil, suffix: []),
            ],
            source: .hassXiaomiMiot(base: base),
            statusMethod: "get_status",
            actions: [
                Action(siid: 2, aiid: 1, methods: ["app_start"]),
                Action(siid: 2, aiid: 2, methods: ["app_stop"]),
                Action(siid: 3, aiid: 1, methods: pausesBeforeDock ? ["app_pause", "app_charge"] : ["app_charge"]),
            ]
        )
    }

    static let profiles: [String: LegacyMiioProfile] = [
        "lumi.acpartner.mcn02": acPartnerMcn02,
        "yeelink.light.lamp4": yeelightWhite,
        "chuangmi.plug.m1": chuangmiPlug,
        "chuangmi.plug.m3": chuangmiPlug,
        "rockrobo.vacuum.v1": roborock(base: nil, pausesBeforeDock: true),
        "roborock.vacuum.c1": roborock(base: "rockrobo.vacuum.v1", pausesBeforeDock: false),
        "roborock.vacuum.e2": roborock(base: "rockrobo.vacuum.v1", pausesBeforeDock: false),
        "roborock.vacuum.s5": roborock(base: "rockrobo.vacuum.v1", pausesBeforeDock: false),
    ]

    static var importedTableURL: URL? { Bundle.module.url(forResource: "hass-xiaomi-miot-miio2miot", withExtension: "json") }

    /// hass-xiaomi-miot's tables, loaded once from the bundled JSON.
    static let imported: [String: LegacyMiioProfile] = {
        guard let url = importedTableURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? ImportedTables.decode(data)) ?? [:]
    }()
}

/// The JSON written by `scripts/import_hass_xiaomi_miot.py`.
enum ImportedTables {
    private struct Document: Decodable {
        var models: [String: Model]
    }

    private struct Model: Decodable {
        var base: String?
        var chunk: Int?
        var ignoreResult: Bool?
        var properties: [Entry]
    }

    private struct Entry: Decodable {
        var siid: Int
        var piid: Int
        var name: String
        var read: Transform
        var write: Transform?
    }

    /// One read or write transform; the fields used depend on `kind`.
    private struct Transform: Decodable {
        var kind: String
        var method: String?
        var table: [String: Int]?
        var `default`: Int?
        var ratio: Double?
        var offset: Double?
        var strip: String?
        var value: JSONValue?
        var then: JSONValue?
        var `else`: JSONValue?
        var on: JSONValue?
        var off: JSONValue?
        var suffix: [JSONValue]?
    }

    static func decode(_ data: Data) throws -> [String: LegacyMiioProfile] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        var profiles: [String: LegacyMiioProfile] = [:]
        for (model, entry) in document.models {
            let properties = entry.properties.compactMap(property)
            guard !properties.isEmpty else { continue }
            profiles[model] = LegacyMiioProfile(
                properties: properties, source: .hassXiaomiMiot(base: entry.base),
                chunkSize: entry.chunk.flatMap { $0 > 0 ? $0 : nil }, ignoresResult: entry.ignoreResult ?? false
            )
        }
        return profiles
    }

    /// Nil when the read transform is unknown to this version, so a newer table never yields wrong readings.
    private static func property(_ entry: Entry) -> LegacyMiioProfile.Property? {
        guard let read = read(entry.read) else { return nil }
        let write = entry.write.flatMap(write)
        return LegacyMiioProfile.Property(
            siid: entry.siid, piid: entry.piid, name: entry.name, read: read,
            setter: write == nil ? nil : entry.write?.method, write: write, suffix: entry.write?.suffix ?? []
        )
    }

    private static func read(_ t: Transform) -> LegacyMiioProfile.Property.Read? {
        switch t.kind {
        case "onOff": return .onOff
        case "auto": return .auto
        case "boolean": return .boolean
        case "number": return .number(ratio: t.ratio ?? 1, offset: t.offset ?? 0, strip: t.strip)
        case "values": return t.table.map { .values($0, fallback: t.default) }
        case "nonZero": return .nonZero
        case "equals": return t.value.map { .equals($0) }
        case "notEquals": return t.value.map { .notEquals($0) }
        case "ifEquals":
            guard let value = t.value, let then = t.then, let otherwise = t.else else { return nil }
            return .ifEquals(value, then: then, else: otherwise)
        case "ifNonZero":
            guard let then = t.then, let otherwise = t.else else { return nil }
            return .ifNonZero(then: then, else: otherwise)
        default: return nil
        }
    }

    private static func write(_ t: Transform) -> LegacyMiioProfile.Property.Write? {
        guard t.method != nil else { return nil }
        switch t.kind {
        case "onOff": return .onOff
        case "value": return .value
        case "string": return .string
        case "integer": return .integer(ratio: t.ratio ?? 1, offset: t.offset ?? 0)
        case "values": return t.table.map { .values($0) }
        case "boolChoice":
            guard let on = t.on, let off = t.off else { return nil }
            return .boolChoice(on: on, off: off)
        case "methodSwitch":
            guard let on = t.on?.stringValue, let off = t.off?.stringValue else { return nil }
            return .methodSwitch(on: on, off: off)
        default: return nil
        }
    }
}

extension MiioClient {
    /// MIoT reads answered through the device's legacy `get_prop`, or its status method. Keys the profile does not
    /// cover are left out, like properties a MIoT device reports as failed.
    public func getProperties(did: String, _ props: [(siid: Int, piid: Int)], legacy profile: LegacyMiioProfile) async throws -> [MiotPropKey: JSONValue] {
        let mapped = props.compactMap { profile.property(siid: $0.siid, piid: $0.piid) }
        guard !mapped.isEmpty else { return [:] }
        var raw: [String: JSONValue] = [:]
        if let method = profile.statusMethod {
            // `[{"state": 8, "battery": 100, …}]`.
            let result = try await call(method)
            guard case .object(let status) = result.arrayValue?.first ?? result else {
                throw MiioError.badResponse(L10n.tr("旧 miIO 状态没有返回对象", "The legacy miIO status reply is not an object."))
            }
            raw = status
        } else {
            var names: [String] = []
            for property in mapped where !names.contains(property.name) { names.append(property.name) }
            let size = profile.chunkSize ?? names.count
            for start in stride(from: 0, to: names.count, by: size) {
                let chunk = Array(names[start..<min(start + size, names.count)])
                let result = try await call("get_prop", params: .array(chunk.map(JSONValue.string)))
                for (name, value) in zip(chunk, result.arrayValue ?? []) { raw[name] = value }
            }
        }
        var out: [MiotPropKey: JSONValue] = [:]
        for property in mapped {
            guard let legacy = raw[property.name], let value = property.miotValue(legacy) else { continue }
            out[MiotPropKey(did: did, siid: property.siid, piid: property.piid)] = value
        }
        return out
    }

    /// One legacy setter call per MIoT write, in order (power first, as `MiotCommandMapper` emits it).
    public func setProperties(_ writes: [MiotPropWrite], legacy profile: LegacyMiioProfile) async throws {
        for write in writes {
            guard let property = profile.property(siid: write.siid, piid: write.piid),
                  let legacyCall = property.legacyCall(write.value) else {
                throw MiioError.unsupportedByLegacyDevice
            }
            let result = try await call(legacyCall.method, params: .array(legacyCall.params))
            guard profile.accepts(result) else {
                throw MiioError.badResponse(L10n.tr("旧 miIO 写入没有返回 ok", "The legacy miIO write did not return ok."))
            }
        }
    }

    /// A MIoT action through the legacy methods the profile lists for it. Like MIoT actions, none is retried.
    public func action(_ action: MiotActionCall, legacy profile: LegacyMiioProfile) async throws {
        guard action.inputs.isEmpty, let mapped = profile.action(siid: action.siid, aiid: action.aiid) else {
            throw MiioError.unsupportedByLegacyDevice
        }
        for method in mapped.methods {
            guard profile.accepts(try await call(method, retryCount: 0)) else {
                throw MiioError.badResponse(L10n.tr("旧 miIO 动作没有返回 ok", "The legacy miIO action did not return ok."))
            }
        }
    }
}
