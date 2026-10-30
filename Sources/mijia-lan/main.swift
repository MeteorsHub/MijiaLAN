import Foundation
import MijiaCore
import MijiaLAN

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
            FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String], port: UInt16) async throws {
        guard let command = args.first else { return usage() }
        switch command {
        case "discover":
            let seconds = args.dropFirst().first.flatMap(Double.init) ?? 3
            let found = try await MiioDiscovery.discover(duration: .milliseconds(Int(seconds * 1000)))
            print("找到 \(found.count) 台 miIO 设备")
            for device in found {
                print("\(device.host)\tdid \(device.did)" + (device.revealedToken.map { "\ttoken \($0)" } ?? ""))
            }
        case "info":
            let client = try makeClient(args, port: port)
            let header = try await client.handshake()
            let info = try await client.info()
            print("did \(header.deviceID)\tmodel \(info.model)\tmac \(info.mac ?? "-")\tfw \(info.firmware ?? "-")")
        case "get":
            let client = try makeClient(args, port: port)
            let props = try args.dropFirst(3).map(parseProp)
            guard !props.isEmpty else { return usage() }
            let header = try await client.handshake()
            let did = String(header.deviceID)
            let values = try await client.getProperties(did: did, props)
            for prop in props {
                let value = values[MiotPropKey(did: did, siid: prop.siid, piid: prop.piid)]
                print("\(prop.siid).\(prop.piid) = \(value?.compactJSONString ?? "（无值）")")
            }
        case "set":
            let client = try makeClient(args, port: port)
            let header = try await client.handshake()
            let did = String(header.deviceID)
            let writes = try args.dropFirst(3).map { item -> MiotPropWrite in
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw MiioError.badResponse("写法：siid.piid=值") }
                let prop = try parseProp(parts[0])
                return MiotPropWrite(did: did, siid: prop.siid, piid: prop.piid, value: try parseJSON(parts[1]))
            }
            guard !writes.isEmpty else { return usage() }
            try await client.setProperties(writes)
            print("已写入 \(writes.count) 个属性")
        case "spec":
            guard args.count >= 2 else { return usage() }
            let store = MiotSpecStore(cacheDirectory: LocalHomeProvider.specCacheDirectory)
            guard let spec = try await store.spec(model: args[1], specType: nil) else {
                print("miot-spec.org 没有 \(args[1]) 的规格")
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
            let params = try args.count >= 5 ? parseJSON(args[4]) : .array([])
            print(try await client.call(args[3], params: params).compactJSONString)
        default:
            usage()
        }
    }

    /// Polls once through `LANMiotAPI` + `MiCloudProvider`, exactly as the app does, and prints what it sees.
    static func status(_ input: Data) async throws {
        guard let config = LocalHomeConfig.decode(input) else { throw MiioError.badResponse("标准输入不是设备清单 JSON") }
        let api = LANMiotAPI(config: { config })
        let provider = LocalHomeProvider.make(api: api)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            FileHandle.standardError.write(Data("60 秒内没有拿到结果\n".utf8))
            exit(3)
        }
        var home = SynthesizedHome()
        for await event in provider.events() {
            if case .snapshotUpdated(let snapshot) = event {
                home = snapshot
                break
            }
        }
        watchdog.cancel()
        await provider.shutdown()
        let health = await api.currentHealth()
        for device in config.devices {
            let state = health[device.did].map { "\($0.state)" } ?? "unknown"
            let synthesized = home.devices.first { $0.id == device.did }
            print("\(device.name)  [\(device.model) @ \(device.host)]  \(state)  \(synthesized.map(describe) ?? "（没有合成：规格未加载或不支持）")")
            if let error = health[device.did]?.lastError { print("    \(error)") }
        }
    }

    static func describe(_ device: SmartDevice) -> String {
        switch device.kind {
        case .light(let s): return "灯 \(s.isOn ? "开" : "关") 亮度 \(s.brightnessPercent.map(String.init) ?? "-")% 色温 \(s.colorTempKelvin.map(String.init) ?? "-")K"
        case .climate(let s): return "空调 \(s.hvacMode) 目标 \(s.targetTemperature)° 风速 \(s.fanMode ?? "-")"
        case .plug(let s): return "插座 \(s.isOn ? "开" : "关")" + (s.powerWatts.map { " \($0) W" } ?? "")
        case .fan(let s): return "风扇 \(s.isOn ? "开" : "关") \(s.percentage.map { "\($0)%" } ?? "")"
        default: return device.isActiveOn ? "开" : "关"
        }
    }

    static func makeClient(_ args: [String], port: UInt16) throws -> MiioClient {
        guard args.count >= 3 else { usage(); exit(2) }
        guard let token = MiioToken.parse(args[2]) else { throw MiioError.invalidToken }
        return MiioClient(host: args[1], token: token, port: port)
    }

    static func parseProp(_ text: String) throws -> (siid: Int, piid: Int) {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { throw MiioError.badResponse("属性写成 siid.piid，例如 2.1") }
        return (parts[0], parts[1])
    }

    static func parseJSON(_ text: String) throws -> JSONValue {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { return value }
        return .string(text)
    }

    static func usage() {
        print("""
        用法：
          mijia-lan discover [秒数]
          mijia-lan info <ip> <token>
          mijia-lan get  <ip> <token> <siid>.<piid> …
          mijia-lan set  <ip> <token> <siid>.<piid>=<值> …
          mijia-lan call <ip> <token> <method> [json 参数]
          mijia-lan spec <型号>
          mijia-lan status < 设备清单.json
          可加 --port N
        """)
    }
}
