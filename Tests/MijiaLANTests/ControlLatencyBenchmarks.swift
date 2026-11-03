import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

/// Opt-in RTT-controlled benchmark, also run unchanged against the pre-optimization source archive.
@MainActor
struct ControlLatencyBenchmarks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIJIALAN_RUN_PERFORMANCE_BENCHMARKS"] == "1"))
    func verifiedBrightnessLatency() async throws {
        let device = LocalDevice(did: "123", name: "Benchmark lamp", model: "yeelink.light.lamp4", host: "test", token: String(repeating: "0", count: 32))
        let config = LocalHomeConfig(devices: [device])
        let transport = LatencyBenchmarkTransport()
        let api = LANMiotAPI(config: { config }, transport: transport)
        let controller = DeviceController(api: api, config: { config })
        await controller.refreshNow()
        defer { controller.shutdown() }
        var milliseconds: [Double] = []
        for index in 0..<25 {
            let value: Double = index.isMultiple(of: 2) ? 40 : 60
            let start = ContinuousClock.now
            try await controller.execute(did: "123", .setLightBrightness(value))
            let elapsed = ContinuousClock.now - start
            #expect(controller.snapshots["123"]?.value("p:2:2") == .number(value))
            #expect(controller.snapshots["123"]?.commandReceipt?.confirmedAt != nil)
            if index >= 5 { milliseconds.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) }
        }
        milliseconds.sort()
        print("CONTROL_LATENCY_BENCHMARK samples=\(milliseconds.count) simulated_rtt_ms=20 median_ms=\(milliseconds[10]) p95_ms=\(milliseconds[18]) max_ms=\(milliseconds[19])")
    }
}

private actor LatencyBenchmarkTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private var brightness = 35.0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await Task.sleep(for: .milliseconds(20))
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let args = request["params"]?.arrayValue ?? []
        let result: JSONValue
        switch request["method"]?.stringValue {
        case "miIO.info": result = .object(["model": .string("yeelink.light.lamp4")])
        case "get_prop": result = .array(args.map {
            switch $0.stringValue { case "power": .string("on"); case "bright": .number(brightness); case "ct": .number(4000); default: .null }
        })
        case "set_bright": brightness = args.first?.doubleValue ?? brightness; result = .array([.string("ok")])
        default: throw MiioError.unsupportedByLegacyDevice
        }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
