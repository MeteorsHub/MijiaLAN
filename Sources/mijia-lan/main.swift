import Foundation
import MijiaCore
import MijiaLAN
import MijiaHomeKitBridge

/// Probe for the LAN layer, independent of the app and its Keychain item.
///
///     mijia-lan discover [seconds]
///     mijia-lan info <ip> <token>
///     mijia-lan get  <ip> <token> <siid>.<piid> …
///     mijia-lan set  <ip> <token> <siid>.<piid>=<json> …
///     mijia-lan call <ip> <token> <method> [json-params]
///     mijia-lan spec <model>          (MIoT spec from miot-spec.org, cached like the app)
///     mijia-lan status < config.json  (one LAN poll through the app's own stack; config as the app stores it)
///
/// `--port N` talks to a test device on another port.
@main
struct MijiaLANCommand {
    static func main() async {
        LANLocalization.configure()
        var args = Array(CommandLine.arguments.dropFirst())
        var port = MiioPacket.port
        if let index = args.firstIndex(of: "--port"), index + 1 < args.count, let value = UInt16(args[index + 1]) {
            port = value
            args.removeSubrange(index...index + 1)
        }
        do {
            try await run(args, port: port)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data(L10n.tr("错误：\(message)\n", "Error: \(message)\n").utf8))
            exit(1)
        }
    }

    static func run(_ args: [String], port: UInt16) async throws {
        guard let command = args.first else { return usage() }
        switch command {
        case "curtain-experiment":
            try await CurtainExperiment.run(Array(args.dropFirst()), port: port)
        case "diagnose":
            guard args.count == 1 else { throw MiioError.badResponse("Usage: mijia-lan diagnose < private-config.json") }
            try await ReadOnlyDiagnostics.run(FileHandle.standardInput.readDataToEndOfFile(), port: port)
        case "diagnose-followup":
            guard args.count == 1 else { throw MiioError.badResponse("Usage: mijia-lan diagnose-followup < private-config.json") }
            try await ReadOnlyDiagnostics.run(FileHandle.standardInput.readDataToEndOfFile(), port: port, followup: true)
        case "matter-rpc":
            guard args.count == 2 else { throw MiioError.badResponse("Usage: mijia-lan matter-rpc <local-home.json>") }
            try await MatterRPC.run(configURL: URL(fileURLWithPath: args[1]))
        case "matrix":
            // The checked-in developer matrix is intentionally a Chinese document.
            print(await L10n.$overrideLanguage.withValue(.zhHans) { await DeviceInterfaceReport.markdown() })
        case "discover":
            let showTokens = args.contains("--show-tokens")
            let seconds = args.dropFirst().first(where: { $0 != "--show-tokens" }).flatMap(Double.init) ?? 3
            let found = try await MiioDiscovery.discover(duration: .milliseconds(Int(seconds * 1000)))
            print(L10n.tr("找到 \(found.count) 台 miIO 设备", "miIO devices found: \(found.count)"))
            for device in found {
                let token = showTokens ? device.revealedToken.map { "\ttoken \($0)" } ?? "" : ""
                print("\(device.host)\tdid \(device.did)" + token)
            }
        case "info":
            let client = try makeClient(args, port: port)
            let header = try await client.handshake()
            let info = try await client.info()
            print("did \(header.deviceID)\tmodel \(info.model)\tmac \(info.mac ?? "-")\tfw \(info.firmware ?? "-")")
        case "get":
            let client = try makeClient(args, port: port)
            try await requireVerifiedPropertyProtocol(client)
            let props = try args.dropFirst(3).map(parseProp)
            guard !props.isEmpty else { return usage() }
            let header = try await client.handshake()
            let did = String(header.deviceID)
            let values = try await client.getProperties(did: did, props)
            for prop in props {
                let value = values[MiotPropKey(did: did, siid: prop.siid, piid: prop.piid)]
                print("\(prop.siid).\(prop.piid) = \(value?.compactJSONString ?? L10n.tr("（无值）", "(no value)"))")
            }
        case "set":
            let client = try makeClient(args, port: port)
            try await requireVerifiedPropertyProtocol(client)
            let header = try await client.handshake()
            let did = String(header.deviceID)
            let writes = try args.dropFirst(3).map { item -> MiotPropWrite in
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw MiioError.badResponse(L10n.tr("写法：siid.piid=值", "Expected: siid.piid=value")) }
                let prop = try parseProp(parts[0])
                return MiotPropWrite(did: did, siid: prop.siid, piid: prop.piid, value: try parseJSON(parts[1]))
            }
            guard !writes.isEmpty else { return usage() }
            try await client.setProperties(writes)
            print(L10n.tr("已写入 \(writes.count) 个属性", "Properties written: \(writes.count)"))
        case "spec":
            guard args.count >= 2 else { return usage() }
            let store = MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
            guard let spec = try await store.spec(model: args[1], specType: nil) else {
                print(L10n.tr("miot-spec.org 没有 \(args[1]) 的规格", "No specification found for \(args[1]) on miot-spec.org."))
                return
            }
            print(spec.type)
            for service in spec.services {
                let props = service.properties.map { "\($0.iid):\($0.shortName)" }.joined(separator: " ")
                print("  \(service.iid) \(service.shortName)  \(props)")
            }
        case "status":
            try await status(FileHandle.standardInput.readDataToEndOfFile())
        case "call":
            let client = try makeClient(args, port: port)
            guard args.count >= 4 else { return usage() }
            if args[3] != "miIO.info" { try await requireVerifiedPropertyProtocol(client) }
            let params = try args.count >= 5 ? parseJSON(args[4]) : .array([])
            print(try await client.call(args[3], params: params).compactJSONString)
        default:
            usage()
        }
    }

    /// Poll the exact shared capability stack; input stays on stdin and tokens are never printed.
    @MainActor static func status(_ input: Data) async throws {
        guard let config = LocalHomeConfig.decode(input) else { throw MiioError.badResponse(L10n.tr("标准输入不是设备清单 JSON", "Standard input is not valid device-list JSON.")) }
        let api = LANMiotAPI(config: { config })
        let controller = DeviceController(api: api, config: { config })
        await controller.refreshNow()
        for device in config.devices {
            guard let snapshot = controller.snapshots[device.did] else { print(L10n.tr("\(device.name)：规格尚未加载", "\(device.name): specification not loaded yet.")); continue }
            print("\(device.name) [\(device.model)] \(snapshot.health.state)")
            for capability in snapshot.capabilities where capability.readable {
                let reading = snapshot.readings[capability.id]
                print("  \(capability.id) \(capability.title): \(reading?.error ?? capability.formatted(snapshot.value(capability.id)))")
            }
        }
    }

    static func describe(_ device: SmartDevice) -> String {
        switch device.kind {
        case .light(let s): return L10n.tr("灯 \(s.isOn ? "开" : "关") 亮度 \(s.brightnessPercent.map(String.init) ?? "-")% 色温 \(s.colorTempKelvin.map(String.init) ?? "-")K", "Light \(s.isOn ? "On" : "Off") brightness \(s.brightnessPercent.map(String.init) ?? "-")% color temperature \(s.colorTempKelvin.map(String.init) ?? "-")K")
        case .climate(let s): return L10n.tr("空调 \(s.hvacMode) 目标 \(s.targetTemperature)° 风速 \(s.fanMode ?? "-") 扫风 \(s.swingMode ?? "-")", "AC \(s.hvacMode) target \(s.targetTemperature)° fan \(s.fanMode ?? "-") swing \(s.swingMode ?? "-")")
        case .plug(let s): return L10n.tr("插座 \(s.isOn ? "开" : "关")", "Outlet \(s.isOn ? "On" : "Off")") + (s.powerWatts.map { " \($0) W" } ?? "")
        case .fan(let s): return L10n.tr("风扇 \(s.isOn ? "开" : "关") \(s.percentage.map { "\($0)%" } ?? "")", "Fan \(s.isOn ? "On" : "Off") \(s.percentage.map { "\($0)%" } ?? "")")
        default: return device.isActiveOn ? L10n.tr("开", "On") : L10n.tr("关", "Off")
        }
    }

    static func makeClient(_ args: [String], port: UInt16) throws -> MiioClient {
        guard args.count >= 3 else { usage(); exit(2) }
        guard let token = MiioToken.parse(args[2]) else { throw MiioError.invalidToken }
        return MiioClient(host: args[1], token: token, port: port)
    }

    static func parseProp(_ text: String) throws -> (siid: Int, piid: Int) {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { throw MiioError.badResponse(L10n.tr("属性写成 siid.piid，例如 2.1", "Use siid.piid for a property, for example 2.1.")) }
        return (parts[0], parts[1])
    }

    static func parseJSON(_ text: String) throws -> JSONValue {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { return value }
        return .string(text)
    }

    private static func requireVerifiedPropertyProtocol(_ client: MiioClient) async throws {
        let info = try await client.info()
        if let reason = DeviceLANPolicy.restriction(for: info.model) { throw DeviceControlError.unsupported(reason) }
    }

    static func usage() {
        print(L10n.tr("""
        用法：
          mijia-lan discover [秒数] [--show-tokens]
          mijia-lan info <ip> <token>
          mijia-lan get  <ip> <token> <siid>.<piid> …
          mijia-lan set  <ip> <token> <siid>.<piid>=<值> …
          mijia-lan call <ip> <token> <method> [json 参数]
          mijia-lan spec <型号>
          mijia-lan diagnose < local-home.json
          mijia-lan diagnose-followup < local-home.json
          mijia-lan matter-rpc <local-home.json>
          mijia-lan status < 设备清单.json
          可加 --port N
        """, """
        Usage:
          mijia-lan discover [seconds] [--show-tokens]
          mijia-lan info <ip> <token>
          mijia-lan get  <ip> <token> <siid>.<piid> …
          mijia-lan set  <ip> <token> <siid>.<piid>=<value> …
          mijia-lan call <ip> <token> <method> [json-params]
          mijia-lan spec <model>
          mijia-lan diagnose < local-home.json
          mijia-lan diagnose-followup < local-home.json
          mijia-lan matter-rpc <local-home.json>
          mijia-lan status < devices.json
          Optional: --port N
        """))
    }
}
