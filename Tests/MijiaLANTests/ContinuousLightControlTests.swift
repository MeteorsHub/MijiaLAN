import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@MainActor
struct ContinuousLightControlTests {
    @Test("Slow slider writes send the newest target without accumulating intermediate commands")
    func latestTarget() async throws {
        let gate = PausedValueWrite()
        var starts = gate.starts.makeAsyncIterator()
        let writer = ContinuousValueWriter(minimumInterval: .zero, apply: gate.apply)
        writer.submit(10)
        #expect(await starts.next() == 10)
        for value in 11...100 { writer.submit(Double(value)) }
        #expect(writer.pendingValue == 100)
        #expect(gate.values == [10])
        gate.finish()
        #expect(await starts.next() == 100)
        #expect(writer.pendingValue == 100)
        gate.finish()
        await writer.waitUntilIdle()
        #expect(gate.values == [10, 100])
        #expect(writer.pendingValue == nil)
        #expect(writer.error == nil)
    }

    @Test("Returning to an in-flight slider value needs no duplicate write")
    func returnToActiveValue() async {
        let gate = PausedValueWrite()
        var starts = gate.starts.makeAsyncIterator()
        let writer = ContinuousValueWriter(minimumInterval: .zero, apply: gate.apply)
        writer.submit(20)
        #expect(await starts.next() == 20)
        writer.submit(90)
        writer.submit(20)
        gate.finish()
        await writer.waitUntilIdle()
        #expect(gate.values == [20])
        #expect(!writer.isSending)
    }

    @Test("An obsolete failure does not discard a newer slider target; the final failure releases edit intent")
    func failures() async {
        let gate = PausedValueWrite()
        var starts = gate.starts.makeAsyncIterator()
        let writer = ContinuousValueWriter(minimumInterval: .zero, apply: gate.apply)
        writer.submit(20)
        #expect(await starts.next() == 20)
        writer.submit(80)
        gate.finish(error: DeviceControlError.notConfirmed)
        #expect(await starts.next() == 80)
        #expect(writer.error == nil)
        #expect(writer.pendingValue == 80)
        gate.finish(error: DeviceControlError.notConfirmed)
        await writer.waitUntilIdle()
        #expect(writer.pendingValue == nil)
        #expect(writer.error == DeviceControlError.notConfirmed.localizedDescription)
    }

    @Test("Rate limiting also covers separate fast slider gestures")
    func rateLimit() async {
        let clock = ContinuousClock()
        var starts: [ContinuousClock.Instant] = []
        let writer = ContinuousValueWriter(minimumInterval: .milliseconds(60)) { _ in starts.append(clock.now) }
        writer.submit(10)
        await writer.waitUntilIdle()
        writer.submit(20)
        await writer.waitUntilIdle()
        #expect(starts.count == 2)
        #expect(starts[1] - starts[0] >= .milliseconds(50))
    }

    @Test("Closing a slider cancels unsent intent while an already-sent command still finishes")
    func navigation() async {
        let gate = PausedValueWrite()
        var starts = gate.starts.makeAsyncIterator()
        let writer = ContinuousValueWriter(minimumInterval: .zero, apply: gate.apply)
        writer.submit(20)
        #expect(await starts.next() == 20)
        writer.submit(90)
        writer.cancelPending()
        #expect(writer.pendingValue == 20)
        gate.finish()
        await writer.waitUntilIdle()
        #expect(gate.values == [20])
        #expect(!writer.isSending)
    }

    @Test("An already-on lamp brightness change uses one write and one verified read, without a debounce pause")
    func commandLatency() async throws {
        let (controller, transport) = makeLamp()
        await controller.refreshNow()
        await transport.reset(delay: .milliseconds(75))
        let clock = ContinuousClock()
        let oldStart = clock.now
        try await controller.execute(did: "lamp", .batch([.set("p:2:2", .number(80)), .set("p:2:1", .bool(true))]), coalesce: true)
        let oldMS = milliseconds(clock.now - oldStart)
        let oldMethods = await transport.methods
        await transport.reset(delay: .milliseconds(75))
        let newStart = clock.now
        try await controller.execute(did: "lamp", .setLightBrightness(60))
        let newMS = milliseconds(clock.now - newStart)
        let newMethods = await transport.methods
        #expect(oldMethods == ["set_bright", "get_prop", "set_power", "get_prop"])
        #expect(newMethods == ["set_bright", "get_prop"])
        #expect(controller.snapshots["lamp"]?.value("p:2:2") == .number(60))
        #expect(controller.snapshots["lamp"]?.commandReceipt?.confirmedAt != nil)
        print("LAMP_LATENCY old_ms=\(oldMS) new_ms=\(newMS) simulated_rtt_ms=75 old_packets=4 new_packets=2")
    }

    @Test("A dimmed-off lamp turns on once; subsequent brightness writes and unchanged values avoid extra packets")
    func powerAndNoOp() async throws {
        let (controller, transport) = makeLamp()
        await transport.setPower(false)
        await controller.refreshNow()
        await transport.reset()
        try await controller.execute(did: "lamp", .setLightBrightness(50))
        try await controller.execute(did: "lamp", .setLightBrightness(70))
        #expect(await transport.methods == ["set_power", "get_prop", "set_bright", "get_prop", "set_bright", "get_prop"])
        await transport.reset()
        try await controller.execute(did: "lamp", .setLightBrightness(70))
        #expect(await transport.methods.isEmpty)
        await #expect(throws: DeviceControlError.self) { try await controller.execute(did: "lamp", .setLightBrightness(101)) }
        #expect(await transport.methods.isEmpty)
    }

    @Test("Pending slider intent never replaces actual device readings, including a quantized final failure")
    func actualReadings() async throws {
        let (controller, transport) = makeLamp()
        await controller.refreshNow()
        await transport.reset(delay: .milliseconds(10), quantize: true)
        let writer = ContinuousValueWriter(minimumInterval: .zero) { value in
            try await controller.execute(did: "lamp", .setLightBrightness(value))
        }
        writer.submit(43)
        #expect(writer.pendingValue == 43)
        #expect(controller.snapshots["lamp"]?.value("p:2:2") == .number(35))
        await writer.waitUntilIdle()
        #expect(writer.pendingValue == nil)
        #expect(writer.error != nil)
        #expect(controller.snapshots["lamp"]?.value("p:2:2") == .number(40))
        #expect(controller.snapshots["lamp"]?.commandReceipt?.confirmedAt == nil)
    }

    private func makeLamp() -> (DeviceController, DelayedLampTransport) {
        let device = LocalDevice(did: "lamp", name: "Test lamp", model: "yeelink.light.lamp4", host: "test", token: String(repeating: "0", count: 32))
        let config = LocalHomeConfig(devices: [device])
        let transport = DelayedLampTransport()
        let api = LANMiotAPI(config: { config }, transport: transport)
        return (DeviceController(api: api, config: { config }), transport)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

@MainActor
private final class PausedValueWrite {
    let starts: AsyncStream<Double>
    private let started: AsyncStream<Double>.Continuation
    private var pending: CheckedContinuation<Void, Error>?
    private(set) var values: [Double] = []

    init() { (starts, started) = AsyncStream.makeStream() }
    func apply(_ value: Double) async throws {
        values.append(value)
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started.yield(value)
        }
    }
    func finish(error: (any Error)? = nil) {
        let pending = pending; self.pending = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

private actor DelayedLampTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private var values: [String: JSONValue] = ["power": .string("on"), "bright": .number(35), "ct": .number(3500)]
    private var delay = Duration.zero
    private var quantize = false
    private(set) var methods: [String] = []

    func reset(delay: Duration = .zero, quantize: Bool = false) {
        methods = []; self.delay = delay; self.quantize = quantize
    }
    func setPower(_ on: Bool) { values["power"] = .string(on ? "on" : "off") }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let method = request["method"]?.stringValue ?? ""
        let args = request["params"]?.arrayValue ?? []
        methods.append(method)
        try await Task.sleep(for: delay)
        let result: JSONValue
        if method == "miIO.info" { result = .object(["model": .string("yeelink.light.lamp4")]) }
        else if method == "get_prop" { result = .array(args.map { values[$0.stringValue ?? ""] ?? .null }) }
        else if method.hasPrefix("set_"), let value = args.first {
            let key = method == "set_ct_abx" ? "ct" : String(method.dropFirst(4))
            values[key] = quantize && key == "bright" ? value.doubleValue.map { .number(($0 / 10).rounded() * 10) } : value
            result = .array([.string("ok")])
        } else { throw MiioError.unsupportedByLegacyDevice }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
