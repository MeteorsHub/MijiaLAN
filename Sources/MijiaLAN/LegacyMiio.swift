import Foundation
import MijiaCore

/// Pre-MIoT Wi-Fi devices speak only their original miIO dialect on the LAN (`get_prop`, `set_power`, …). The
/// cloud translates MIoT for them, so a LAN `get_properties` just gets `-9999 user ack timeout` about four seconds
/// later. A profile does that translation locally for one model, MIoT property by MIoT property.
///
/// Tables follow hass-xiaomi-miot's `miio2miot_specs.py`, the mapping most Home Assistant users run.
public struct LegacyMiioProfile: Sendable {
    public struct Property: Sendable {
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
        public var format: Format
        /// The legacy setter; nil for read-only properties.
        public var setter: String?
        /// Arguments after the value, e.g. `["smooth", 500]` for `set_ct_abx`.
        public var setterSuffix: [JSONValue]

        init(_ siid: Int, _ piid: Int, _ name: String, _ format: Format, setter: String? = nil, suffix: [JSONValue] = []) {
            self.siid = siid
            self.piid = piid
            self.name = name
            self.format = format
            self.setter = setter
            self.setterSuffix = suffix
        }

        /// Legacy reply value → MIoT value.
        func miotValue(_ legacy: JSONValue) -> JSONValue? {
            switch format {
            case .onOff:
                if case .bool = legacy { return legacy }
                guard let text = legacy.stringValue, ["on", "off"].contains(text) else { return nil }
                return .bool(text == "on")
            case .number:
                return legacy.doubleValue.map(JSONValue.number)
            case .values(let table):
                return legacy.stringValue.flatMap { table[$0] }.map { .number(Double($0)) }
            }
        }

        /// MIoT value → the legacy setter's first argument.
        func legacyArgument(_ miot: JSONValue) -> JSONValue? {
            switch format {
            case .onOff:
                if let on = miot.boolValue { return .string(on ? "on" : "off") }
                return miot.doubleValue.map { .string($0 != 0 ? "on" : "off") }
            case .number:
                return miot.doubleValue.map(JSONValue.number)
            case .values(let table):
                guard let number = miot.intValue else { return nil }
                return table.first { $0.value == number }.map { .string($0.key) }
            }
        }
    }

    public var properties: [Property]

    public func property(siid: Int, piid: Int) -> Property? {
        properties.first { $0.siid == siid && $0.piid == piid }
    }

    public static func forModel(_ model: String) -> LegacyMiioProfile? { profiles[model] }

    public static var supportedModels: [String] { profiles.keys.sorted() }

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

    static let profiles: [String: LegacyMiioProfile] = [
        "lumi.acpartner.mcn02": acPartnerMcn02,
        "yeelink.light.lamp4": yeelightWhite,
        "chuangmi.plug.m1": chuangmiPlug,
        "chuangmi.plug.m3": chuangmiPlug,
    ]
}

extension MiioClient {
    /// MIoT reads answered through the device's legacy `get_prop`. Keys the profile does not cover are left out,
    /// like properties a MIoT device reports as failed.
    public func getProperties(did: String, _ props: [(siid: Int, piid: Int)], legacy profile: LegacyMiioProfile) async throws -> [MiotPropKey: JSONValue] {
        let mapped = props.compactMap { profile.property(siid: $0.siid, piid: $0.piid) }
        guard !mapped.isEmpty else { return [:] }
        let result = try await call("get_prop", params: .array(mapped.map { .string($0.name) }))
        let values = result.arrayValue ?? []
        var out: [MiotPropKey: JSONValue] = [:]
        for (property, raw) in zip(mapped, values) {
            guard let value = property.miotValue(raw) else { continue }
            out[MiotPropKey(did: did, siid: property.siid, piid: property.piid)] = value
        }
        return out
    }

    /// One legacy setter call per MIoT write, in order (power first, as `MiotCommandMapper` emits it).
    public func setProperties(_ writes: [MiotPropWrite], legacy profile: LegacyMiioProfile) async throws {
        for write in writes {
            guard let property = profile.property(siid: write.siid, piid: write.piid), let setter = property.setter,
                  let argument = property.legacyArgument(write.value) else {
                throw MiioError.unsupportedByLegacyDevice
            }
            let result = try await call(setter, params: .array([argument] + property.setterSuffix))
            guard result == .array([.string("ok")]) || result == .string("ok") else {
                throw MiioError.badResponse(L10n.tr("旧 miIO 写入没有返回 ok", "The legacy miIO write did not return ok."))
            }
        }
    }
}
