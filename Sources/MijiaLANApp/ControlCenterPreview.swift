#if DEBUG
import Foundation
import MijiaCore
import MijiaLAN

/// Isolated native UI preview. No Keychain, Home bridge, discovery broadcast or real device traffic.
/// Addresses use the RFC 5737 TEST-NET-1 documentation range; names, rooms and tokens are fixtures.
enum ControlCenterPreview {
    static let config: LocalHomeConfig = {
        let rows = [
            ("plug", "插座", "chuangmi.plug.m3", "卧室", "192.0.2.1"),
            ("purifier", "米家空气净化器 4 Lite", "zhimi.airpurifier.rma1", "卧室", "192.0.2.2"),
            ("lamp", "台灯", "yeelink.light.lamp4", "卧室", "192.0.2.3"),
            ("blender", "米家智能破壁料理机", "chunmi.juicer.a1", "厨房", "192.0.2.4"),
            ("kettle", "米家智能多功能养生壶", "chunmi.health_pot.a1", "客厅", "192.0.2.5"),
            ("ac", "空调插座", "lumi.acpartner.mcn02", "卧室", "192.0.2.6"),
            ("fryer", "米家智能空气炸锅 5.5L 可视版", "careli.fryer.maf07c", "厨房", "192.0.2.7"),
            ("cooker", "米家智能微压 IH 电饭煲 3L", "chunmi.cooker.cmwy3", "厨房", "192.0.2.8"),
            ("fan", "米家智能直流变频循环扇 落地式", "dmaker.fan.p28", "卧室", "192.0.2.9"),
            ("plug3", "客厅-米家智能插座 3", "cuco.plug.v3", "客厅", "192.0.2.10"),
            ("plug2", "米家智能插座 3", "cuco.plug.v3", "卧室", "192.0.2.11"),
            ("123", "客厅卷帘", "dooya.motor.dc1545", "客厅", "192.0.2.12")
        ]
        return LocalHomeConfig(devices: rows.map { LocalDevice(did: $0.0, name: $0.1, model: $0.2, host: $0.4, token: String(repeating: "0", count: 32), specType: $0.2 == CurtainValidationSession.model ? CurtainValidationSession.specification : nil, roomName: $0.3) })
    }()
}

actor ControlCenterPreviewTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private let latency: Duration
    private let failReadback: Bool
    private var curtainWritten = false
    private var values: [String: [String: JSONValue]] = [
        "192.0.2.12": ["2.2": .number(1), "2.3": .number(29), "2.4": .number(29), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)],
        "192.0.2.3": ["power": .string("on"), "bright": .number(71), "ct": .number(3500)],
        "192.0.2.6": ["power": .string("off"), "mode": .string("auto"), "tar_temp": .number(29),
                          "fan_level": .string("auto_fan"), "ver_swing": .string("on"), "load_power": .number(1)]
    ]

    init(failReadback: Bool? = nil) {
        self.failReadback = failReadback ?? (ProcessInfo.processInfo.environment["MIJIALAN_PREVIEW_READBACK_ERROR"] == "1")
        let milliseconds = Int(ProcessInfo.processInfo.environment["MIJIALAN_UI_PREVIEW_DELAY_MS"] ?? "") ?? 0
        latency = .milliseconds(max(0, milliseconds))
    }

    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        guard values[host] != nil else { throw MiioError.hostUnreachable }
        if packet == MiioPacket.hello {
            var hello: [UInt8] = [0x21, 0x31, 0, 32, 0, 0, 0, 0]
            hello += [0, 0, 0, 123, 0, 0, 0x13, 0x88]
            return Data(hello + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        guard case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 }) else { throw MiioError.timeout }
        let method = request["method"]?.stringValue ?? ""
        if latency > .zero { try await Task.sleep(for: latency) }
        let args: [JSONValue]
        if case .array(let array) = request["params"] { args = array } else { args = [] }
        let result: JSONValue
        if method == "miIO.info" {
            let model = host == "192.0.2.12" ? "dooya.motor.dc1545" : (host == "192.0.2.3" ? "yeelink.light.lamp4" : "lumi.acpartner.mcn02")
            result = .object(["model": .string(model), "fw_ver": .string("1.1.3")])
        } else if host == "192.0.2.12", method == "get_properties" {
            result = .array(args.map { item in
                guard case .object(let fields) = item else { return .null }
                let key = "\(fields["siid"]?.intValue ?? 0).\(fields["piid"]?.intValue ?? 0)"
                if failReadback, curtainWritten, key == "2.3" {
                    return .object(["siid": .number(2), "piid": .number(3), "code": .number(-4004)])
                }
                return .object(["siid": fields["siid"] ?? .null, "piid": fields["piid"] ?? .null,
                    "code": .number(values[host]?[key] == nil ? -4003 : 0), "value": values[host]?[key] ?? .null])
            })
        } else if host == "192.0.2.12", method == "set_properties", args.count == 1, case .object(let fields) = args[0],
                  fields["siid"] == .number(2), let value = fields["value"] {
            curtainWritten = true
            if fields["piid"] == .number(4) {
                values[host]?["2.4"] = value; values[host]?["2.3"] = value
            } else if fields["piid"] == .number(1) {
                if value == .number(2) { values[host]?["2.4"] = .number(100); values[host]?["2.3"] = .number(100) }
                if value == .number(0) { values[host]?["2.4"] = .number(0); values[host]?["2.3"] = .number(0) }
            }
            values[host]?["2.2"] = .number(1)
            result = .array([.object(["code": .number(0)])])
        } else if method == "get_prop" {
            result = .array(args.map { values[host]?[$0.stringValue ?? ""] ?? .null })
        } else if method.hasPrefix("set_"), let value = args.first {
            values[host]?[method == "set_ct_abx" ? "ct" : String(method.dropFirst(4))] = value
            result = .array([.string("ok")])
        } else { throw MiioError.unsupportedByLegacyDevice }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }

    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
#endif
