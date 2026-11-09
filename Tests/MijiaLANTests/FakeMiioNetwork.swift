import Foundation
import MijiaCore
@testable import MijiaLAN

/// In-memory miIO devices behind the `MiioTransport` seam. They decode requests with the real codec, so a wrong
/// token is dropped exactly like firmware does (no reply), and they answer MIoT property and action calls.
final class FakeMiioNetwork: MiioTransport, @unchecked Sendable {
    final class Device: @unchecked Sendable {
        let host: String
        let token: Data
        let deviceID: UInt32
        var stamp: UInt32 = 5_000
        var model = "yeelink.light.fake1"
        var firmware = "1.0.0"
        var simulateCurtainMovement = false
        var curtainMotionSamples: [(position: Int, status: Int)] = []
        var curtainHasWritten = false
        var failCurtainReadback = false
        var writeTimeout = false
        var wrongResponseID = false
        var props: [String: JSONValue] = [:]
        var propertyErrors: [String: Int] = [:]
        var offline = false
        var actionTimeout = false
        var quantizeSpeed = false
        var omitWriteCode = false
        /// Answers hellos but no encrypted request, like a device that was re-paired with a new token.
        var ignoresEncrypted = false
        /// Nothing at this IP: sends fail like a failed ARP lookup.
        var unreachable = false
        /// Set for a pre-MIoT device: it answers `get_prop` / `set_<name>` from these and `-9999` to MIoT methods.
        var legacyProps: [String: JSONValue]?
        var legacyCalls: [String] = []
        var receivedMethods: [String] = []
        var receivedStamps: [UInt32] = []
        var receivedPayloads: [Data] = []
        var receivedWrites: [JSONValue] = []

        init(host: String, token: Data, deviceID: UInt32) {
            self.host = host
            self.token = token
            self.deviceID = deviceID
        }
    }

    private let lock = NSLock()
    private var exchanges = 0
    var exchangeCount: Int { lock.withLock { exchanges } }
    private var devices: [String: Device] = [:]

    @discardableResult
    func add(host: String, token: String, deviceID: UInt32, props: [String: JSONValue] = [:]) -> Device {
        let device = Device(host: host, token: MiioToken.parse(token)!, deviceID: deviceID)
        device.props = props
        lock.withLock { devices[host] = device }
        return device
    }

    func device(_ host: String) -> Device? { lock.withLock { devices[host] } }

    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try lock.withLock {
            exchanges += 1
            if devices[host]?.unreachable == true { throw MiioError.hostUnreachable }
            guard let device = devices[host], !device.offline else { throw MiioError.timeout }
            return try Self.respond(to: packet, device: device)
        }
    }

    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        lock.withLock {
            // The sender hears its own broadcast, as on a real network.
            var replies = [MiioDatagram(host: "192.168.1.122", data: packet)]
            for device in devices.values where !device.offline {
                for _ in 0..<rounds { replies.append(MiioDatagram(host: device.host, data: Self.helloReply(device))) }
            }
            return replies
        }
    }

    static func helloReply(_ device: Device) -> Data {
        var bytes: [UInt8] = [0x21, 0x31, 0x00, 0x20, 0, 0, 0, 0]
        bytes += MiioPacket.bigEndianBytes(device.deviceID) + MiioPacket.bigEndianBytes(device.stamp)
        bytes += [UInt8](repeating: 0xFF, count: 16)
        return Data(bytes)
    }

    private static func respond(to packet: Data, device: Device) throws -> Data {
        if packet == MiioPacket.hello { return helloReply(device) }
        guard let (header, payload) = try? MiioPacket.decode(packet, token: device.token),
              header.deviceID == device.deviceID, !device.ignoresEncrypted else { throw MiioError.timeout }
        device.receivedStamps.append(header.stamp)
        device.receivedPayloads.append(payload)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let method = request["method"]?.stringValue ?? ""
        let params = request["params"] ?? .null
        device.receivedMethods.append(method)
        // Time is supplied by the fixture/clock model, not advanced once per RPC.
        // Incrementing on every call fabricates an echo-like clock jump in fast offline tests.

        var reply: [String: JSONValue] = ["id": request["id"] ?? .null]
        if var legacy = device.legacyProps, method != "miIO.info" {
            if method == "get_prop" {
                reply["result"] = .array((params.arrayValue ?? []).map { legacy[$0.stringValue ?? ""] ?? .string("") })
            } else if method.hasPrefix("set_"), let value = params.arrayValue?.first {
                device.legacyCalls.append("\(method) \(params.compactJSONString)")
                legacy[String(method.dropFirst(4))] = value
                device.legacyProps = legacy
                reply["result"] = .array([.string("ok")])
            } else {
                reply["error"] = .object(["code": .number(-9999), "message": .string("user ack timeout")])
            }
            let body = Data(JSONValue.object(reply).compactJSONString.utf8) + [0]
            return try MiioPacket.encode(body, token: device.token, deviceID: device.deviceID, stamp: device.stamp)
        }
        switch method {
        case "miIO.info":
            reply["result"] = .object(["model": .string(device.model), "mac": .string("AA:BB:CC:00:11:22"), "fw_ver": .string(device.firmware)])
        case "get_properties":
            if device.curtainHasWritten, !device.curtainMotionSamples.isEmpty {
                let sample = device.curtainMotionSamples.removeFirst()
                device.props["2.3"] = .number(Double(sample.position)); device.props["2.2"] = .number(Double(sample.status))
            }
            reply["result"] = .array((params.arrayValue ?? []).map { item in
                let key = "\(item["siid"]?.intValue ?? 0).\(item["piid"]?.intValue ?? 0)"
                if let code = device.propertyErrors[key] {
                    return .object(["did": item["did"] ?? .null, "siid": item["siid"] ?? .null,
                                    "piid": item["piid"] ?? .null, "code": .number(Double(code))])
                }
                guard let value = device.props[key] else {
                    return .object(["did": item["did"] ?? .null, "siid": item["siid"] ?? .null, "piid": item["piid"] ?? .null, "code": .number(-4003)])
                }
                // Firmware that echoes its own did: the client must match by siid/piid.
                return .object(["did": .string("own-\(device.deviceID)"), "siid": item["siid"] ?? .null,
                                "piid": item["piid"] ?? .null, "code": .number(0), "value": value])
            })
        case "set_properties":
            reply["result"] = .array((params.arrayValue ?? []).map { item in
                device.receivedWrites.append(item)
                let key = "\(item["siid"]?.intValue ?? 0).\(item["piid"]?.intValue ?? 0)"
                if key == "9.9" { return .object(["code": .number(-4004)]) }
                device.props[key] = item["value"] ?? .null
                if device.model == CurtainValidationSession.model, ["2.1", "2.4"].contains(key) {
                    device.curtainHasWritten = true
                    if key == "2.1" {
                        if item["value"] == .number(2) { device.props["2.4"] = .number(100) }
                        if item["value"] == .number(0) { device.props["2.4"] = .number(0) }
                        if item["value"] == .number(1) { device.curtainMotionSamples = []; device.props["2.2"] = .number(1) }
                    }
                    if !device.curtainMotionSamples.isEmpty { device.props["2.2"] = .number(2) }
                    else if device.simulateCurtainMovement, key == "2.4" || item["value"] != .number(1) {
                        device.props["2.3"] = device.props["2.4"]; device.props["2.2"] = .number(1)
                    }
                }
                if device.quantizeSpeed, key == "8.1", let n = item["value"]?.doubleValue { device.props[key] = .number((n / 10).rounded() * 10) }
                if device.omitWriteCode { return .object([:]) }
                return .object(["did": item["did"] ?? .null, "siid": item["siid"] ?? .null, "piid": item["piid"] ?? .null, "code": .number(0)])
            })
            if device.failCurtainReadback, device.curtainHasWritten { device.propertyErrors["2.3"] = -4004 }
            if device.writeTimeout { throw MiioError.timeout }
        case "action":
            device.receivedWrites.append(params)
            if device.actionTimeout { throw MiioError.timeout }
            if params["aiid"]?.intValue == 1 { device.props["2.1"] = .number(device.model == "careli.fryer.maf07c" ? 4 : 2) }
            if params["aiid"]?.intValue == 2 { device.props["2.1"] = .number(1) }
            reply["result"] = .object(["code": .number(0), "out": .array([])])
        default:
            reply["error"] = .object(["code": .number(-32601), "message": .string("Method not found.")])
        }
        if device.wrongResponseID { reply["id"] = .number(-1) }
        let body = Data(JSONValue.object(reply).compactJSONString.utf8) + [0]
        return try MiioPacket.encode(body, token: device.token, deviceID: device.deviceID, stamp: device.stamp)
    }
}

/// A light whose spec mirrors the shape of a real Yeelight MIoT spec.
enum FakeSpecs {
    static let lightType = "urn:miot-spec-v2:device:light:0000A001:yeelink-fake1:1"

    static let light = MiotDeviceSpec(type: lightType, services: [
        MiotService(iid: 2, type: "urn:miot-spec-v2:service:light:00007802:yeelink-fake1:1", properties: [
            MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:yeelink-fake1:1", format: "bool", access: ["read", "write", "notify"]),
            MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:brightness:0000000D:yeelink-fake1:1", format: "uint8",
                         access: ["read", "write", "notify"], valueRange: [1, 100, 1], unit: "percentage"),
            MiotProperty(iid: 3, type: "urn:miot-spec-v2:property:color-temperature:0000000F:yeelink-fake1:1", format: "uint32",
                         access: ["read", "write", "notify"], valueRange: [2700, 6500, 1], unit: "kelvin"),
        ]),
    ])
}

extension FakeSpecs {
    /// The shape of the real `lumi.acpartner.mcn02` spec (only the services the bridge reads).
    static let acPartner = MiotDeviceSpec(type: "urn:miot-spec-v2:device:air-conditioner:0000A004:lumi-mcn02:1", services: [
        MiotService(iid: 2, type: "urn:miot-spec-v2:service:air-conditioner:0000780F:lumi-mcn02:1", properties: [
            MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:lumi-mcn02:1", format: "bool", access: ["read", "write", "notify"]),
            MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:mode:00000008:lumi-mcn02:1", format: "uint8", access: ["read", "write", "notify"],
                         valueList: [.init(value: 0, description: "Auto"), .init(value: 1, description: "Cool"), .init(value: 2, description: "Dry"),
                                     .init(value: 3, description: "Heat"), .init(value: 4, description: "Fan")]),
            MiotProperty(iid: 3, type: "urn:miot-spec-v2:property:target-temperature:00000021:lumi-mcn02:1", format: "float",
                         access: ["read", "write", "notify"], valueRange: [16, 30, 1], unit: "celsius"),
        ]),
        MiotService(iid: 3, type: "urn:miot-spec-v2:service:fan-control:00007808:lumi-mcn02:1", properties: [
            MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:fan-level:00000016:lumi-mcn02:1", format: "uint8", access: ["read", "write", "notify"],
                         valueList: [.init(value: 0, description: "Auto"), .init(value: 1, description: "Low"),
                                     .init(value: 2, description: "Medium"), .init(value: 3, description: "High")]),
            MiotProperty(iid: 2, type: "urn:miot-spec-v2:property:vertical-swing:00000018:lumi-mcn02:1", format: "bool", access: ["read", "write", "notify"]),
        ]),
        MiotService(iid: 5, type: "urn:miot-spec-v2:service:power-consumption:0000780E:lumi-mcn02:1", properties: [
            MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:electric-power:00000066:lumi-mcn02:1", format: "float",
                         access: ["read", "notify"], valueRange: [0, 10000, 0.01], unit: "watt"),
        ]),
    ])
}

struct StubSpecSource: MiotSpecSource {
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        if model.hasPrefix("yeelink.light.fake") || model == "yeelink.light.lamp4" { return FakeSpecs.light }
        if model.hasPrefix("lumi.acpartner") { return FakeSpecs.acPartner }
        return nil
    }
}

/// Answers Mi cloud requests with plain JSON (which `MiCloudClient` accepts the same way it accepts error replies).
final class StubCloudTransport: MiHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) -> JSONValue
    private(set) var hosts: [String] = []

    init(handler: @escaping @Sendable (URLRequest) -> JSONValue) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { hosts.append(request.url?.host ?? "") }
        let body = Data(handler(request).compactJSONString.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
