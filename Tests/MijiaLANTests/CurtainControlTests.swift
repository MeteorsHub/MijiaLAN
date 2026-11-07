import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class DailyTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var now: Duration { lock.withLock { value } }
    func advance(_ amount: Duration) { lock.withLock { value += amount } }
    var clock: CurtainValidationSession.Clock {
        .init(now: { self.now }, sleep: { delay in
            try Task.checkCancellation(); self.advance(delay); await Task.yield()
        })
    }
}
private actor DailyGate {
    private var count = 0
    private let blockAt: Int
    init(blockAt: Int = 6) { self.blockAt = blockAt }
    private var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep() async throws {
        count += 1
        if count == blockAt { // Initial hello/info/full read, move preflight/write, then first motion read wait.
            reached = true; waiter?.resume(); waiter = nil
            try await Task.sleep(for: .seconds(60))
        }
    }
    func wait() async {
        if reached { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
private actor PacketTrace: MiioTransport {
    let network: FakeMiioNetwork
    let time: DailyTime
    var writes: [(Duration, JSONValue)] = []
    var active = 0
    var maxActive = 0
    init(_ network: FakeMiioNetwork, _ time: DailyTime) { self.network = network; self.time = time }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        if packet != MiioPacket.hello {
            let token = try #require(network.device(host)?.token)
            let (_, payload) = try MiioPacket.decode(packet, token: token)
            let json = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
            if json["method"] == .string("set_properties"), let write = json["params"]?.arrayValue?.first { writes.append((time.now, write)) }
        }
        await Task.yield()
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}

struct CurtainControlTests {
    private let token = "00112233445566778899aabbccddeeff"
    private func device(_ id: String = "123", host: String = "curtain") -> LocalDevice {
        LocalDevice(did: id, name: "Curtain", model: CurtainValidationSession.model, host: host, token: token, specType: CurtainValidationSession.specification)
    }
    private func fake(_ network: FakeMiioNetwork, device: LocalDevice) -> FakeMiioNetwork.Device {
        let fake = network.add(host: device.host, token: token, deviceID: UInt32(device.did)!, props: [
            "2.2": .number(1), "2.3": .number(29), "2.4": .number(29), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = device.model; fake.firmware = "1.1.3"; fake.simulateCurtainMovement = true
        return fake
    }
    private func setup(clock: CurtainValidationSession.Clock? = nil, time: DailyTime = DailyTime()) throws -> (FakeMiioNetwork, FakeMiioNetwork.Device, DailyTime, PacketTrace, CurtainControlSession) {
        let d = device(), network = FakeMiioNetwork()
        let f = fake(network, device: d), transport = PacketTrace(network, time)
        let effectiveClock = clock ?? time.clock
        let scheduler = CurtainRequestScheduler(clock: effectiveClock)
        let client = MiioClient(host: d.host, token: try #require(MiioToken.parse(token)), transport: transport, knownModel: d.model)
        let session = CurtainControlSession(device: d, client: client, scheduler: scheduler, clock: effectiveClock, isCurrent: { true })
        return (network, f, time, transport, session)
    }
    @Test("Daily targets accept the whole 0...100 range and send one write per explicit command", arguments: [0, 1, 50, 99, 100])
    func fullRange(_ target: Int) async throws {
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        let state = try await session.perform(.position(target))
        #expect(state.position == target && state.motorStatus == 1 && state.confirmed)
        #expect(fake.receivedWrites.count == 1)
        #expect(fake.receivedWrites[0]["piid"] == .number(4))
        #expect(fake.receivedWrites[0]["value"] == .number(Double(target)))
        _ = try await session.perform(.position(target))
        #expect(fake.receivedWrites.count == 1)
        await session.end()
    }
    @Test("Motor mapping matches the pinned v1 specification; stepping/reverse/mode are not command entry points")
    func specificationMapping() async throws {
        let url = try #require(Bundle.module.url(forResource: "dooya.motor.dc1545", withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        let spec = try #require(schema.coreSpec)
        let service = try #require(spec.services.first { $0.iid == 2 })
        let motor = try #require(service.properties.first { $0.iid == 1 })
        #expect(motor.access == ["write"])
        let options = try #require(motor.valueList)
        for (command, value, label) in [(CurtainControlSession.Command.close, 0, "Close"), (.stop, 1, "Stop"), (.open, 2, "Open")] {
            #expect(command.write.piid == 1 && command.write.value == value)
            #expect(options.contains { $0.value == value && $0.description == label })
        }
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        #expect(try await session.perform(.open).position == 100)
        #expect(try await session.perform(.close).position == 0)
        #expect(try await session.perform(.stop).motorStatus == 1)
        #expect(fake.receivedWrites.map { $0["piid"] } == [.number(1), .number(1), .number(1)])
        #expect(fake.receivedWrites.map { $0["value"] } == [.number(2), .number(0), .number(1)])
    }
    @Test("Several valid moving samples extend confirmation until actual target and stopped state, without rewriting")
    func longTravel() async throws {
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        fake.curtainMotionSamples = [(40, 2), (65, 2), (90, 2), (100, 1)]
        let result = try await session.perform(.position(100))
        #expect(result.confirmed && result.position == 100 && result.motorStatus == 1)
        #expect(fake.receivedWrites.count == 1 && fake.curtainMotionSamples.isEmpty)
    }
    @Test("Stop interrupts motion confirmation sleep and skips ordinary pacing; it sends one 2.1=1 then reads actual stop")
    func urgentStop() async throws {
        let time = DailyTime(), gate = DailyGate()
        let clock = CurtainValidationSession.Clock(now: { time.now }, sleep: { delay in
            try await gate.sleep(); try Task.checkCancellation(); time.advance(delay)
        })
        let (_, fake, _, trace, session) = try setup(clock: clock, time: time)
        _ = try await session.start()
        fake.curtainMotionSamples = [(40, 2), (70, 2), (100, 1)]
        let movement = Task { try await session.perform(.position(100)) }
        await gate.wait()
        let stopped = try await session.stop()
        await #expect(throws: (any Error).self) { try await movement.value }
        #expect(stopped.confirmed && stopped.command == .stop && stopped.motorStatus == 1)
        #expect(fake.receivedWrites.count == 2)
        #expect(fake.receivedWrites.last?["piid"] == .number(1))
        #expect(fake.receivedWrites.last?["value"] == .number(1))
        let writes = await trace.writes
        #expect(writes.count == 2)
        #expect(writes[1].0 - writes[0].0 < .seconds(5))
        #expect(!fake.receivedMethods.contains("action"))
    }
    @Test("Stop cancels a position write that is still waiting for ordinary pacing")
    func stopBeforeWrite() async throws {
        let time = DailyTime(), gate = DailyGate(blockAt: 5)
        let clock = CurtainValidationSession.Clock(now: { time.now }, sleep: { delay in
            try await gate.sleep(); try Task.checkCancellation(); time.advance(delay)
        })
        let (_, fake, _, _, session) = try setup(clock: clock, time: time)
        _ = try await session.start()
        let movement = Task { try await session.perform(.position(100)) }
        await gate.wait()
        #expect(try await session.stop().confirmed)
        await #expect(throws: (any Error).self) { try await movement.value }
        #expect(fake.receivedWrites.count == 1)
        #expect(fake.receivedWrites[0]["piid"] == .number(1) && fake.receivedWrites[0]["value"] == .number(1))
    }
    @Test("A timed-out target can be followed by explicit Stop without resending the target")
    func stopAfterLostReply() async throws {
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        fake.writeTimeout = true
        await #expect(throws: (any Error).self) { try await session.perform(.position(80)) }
        fake.writeTimeout = false
        let result = try await session.stop()
        #expect(result.confirmed && result.command == .stop)
        #expect(fake.receivedWrites.map { $0["piid"] } == [.number(4), .number(1)])
        #expect(fake.receivedWrites.last?["value"] == .number(1))
    }
    @Test("Daily opt-in cannot bypass firmware verification or accept a mismatched response ID")
    func dailyIdentity() async throws {
        let (_, fake, _, _, session) = try setup()
        fake.firmware = "9.9"
        await #expect(throws: (any Error).self) { try await session.start() }
        await #expect(throws: (any Error).self) { try await session.stop() }
        #expect(fake.receivedMethods == ["miIO.info"] && fake.receivedWrites.isEmpty)
        let (_, wrong, _, _, b) = try setup()
        wrong.wrongResponseID = true
        await #expect(throws: (any Error).self) { try await b.start() }
        #expect(wrong.receivedMethods == ["miIO.info"] && wrong.receivedWrites.isEmpty)
    }

    @Test("A lost write reply pauses without retry or automatic reads; explicit read confirmation never repeats the write")
    func lostReply() async throws {
        let (network, fake, _, _, session) = try setup()
        _ = try await session.start()
        fake.writeTimeout = true
        await #expect(throws: (any Error).self) { try await session.perform(.position(80)) }
        #expect(await session.snapshot().phase == .unconfirmed)
        let calls = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.refresh() }
        await #expect(throws: (any Error).self) { try await session.perform(.position(80)) }
        #expect(network.exchangeCount == calls && fake.receivedWrites.count == 1)
        let state = try await session.confirmByReading()
        #expect(state.confirmed && state.position == 80 && !state.writeAccepted)
        #expect(fake.receivedWrites.count == 1)
    }
    @Test("Malformed old replies and missing properties pause subsequent automatic probing; a hello timeout cannot write")
    func faults() async throws {
        let (network, fake, _, _, session) = try setup()
        fake.props["2.2"] = .number(2)
        fake.propertyErrors = ["2.3": -4004, "2.4": -4004, "2.5": -4004, "2.9": -4004, "2.10": -4004]
        await #expect(throws: (any Error).self) { try await session.start() }
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.refresh() }
        await #expect(throws: (any Error).self) { try await session.perform(.open) }
        #expect(count == network.exchangeCount && fake.receivedWrites.isEmpty)
        let (otherNetwork, other, _, _, b) = try setup()
        other.offline = true
        await #expect(throws: (any Error).self) { try await b.start() }
        #expect(otherNetwork.exchangeCount == 1 && other.receivedWrites.isEmpty)
    }
    @Test("Motion readback has an upper bound and a target echo alone cannot confirm completion")
    func boundedReadback() async throws {
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        fake.curtainMotionSamples = Array(repeating: (40, 2), count: 30)
        let before = fake.receivedMethods.count
        await #expect(throws: (any Error).self) { try await session.perform(.position(100)) }
        #expect(fake.receivedMethods.count - before <= 26)
        #expect(fake.receivedWrites.count == 1)
        #expect(await session.snapshot().phase == .unconfirmed)
        #expect(await session.snapshot().position == nil)
        let (_, echo, _, _, b) = try setup()
        _ = try await b.start()
        echo.simulateCurtainMovement = false
        await #expect(throws: (any Error).self) { try await b.perform(.position(100)) }
        #expect(echo.props["2.4"] == .number(100) && echo.props["2.3"] == .number(29))
        #expect(!(await b.snapshot().confirmed))
    }
    @Test("Concurrent duplicate target commands are joined, not queued for a second write")
    func duplicate() async throws {
        let (_, fake, _, _, session) = try setup()
        _ = try await session.start()
        async let a = session.perform(.position(80))
        async let b = session.perform(.position(80))
        let result = try await [a, b]
        #expect(result.allSatisfy { $0.confirmed })
        #expect(fake.receivedWrites.count == 1)
    }
    @Test("Completed-command dedup expires so an external move cannot leave the same target permanently ignored")
    func dedupExpires() async throws {
        let (_, fake, time, _, session) = try setup()
        _ = try await session.start()
        _ = try await session.perform(.position(80))
        time.advance(.seconds(3))
        fake.props["2.3"] = .number(40); fake.props["2.4"] = .number(40)
        let result = try await session.perform(.position(80))
        #expect(result.confirmed && result.position == 80)
        #expect(fake.receivedWrites.count == 2)
    }

    @Test("Six enabled sessions share a wire scheduler while generic controls and metadata probes stay closed")
    func sixSessions() async throws {
        let network = FakeMiioNetwork(), time = DailyTime()
        let trace = PacketTrace(network, time), scheduler = CurtainRequestScheduler(clock: time.clock)
        let devices = (1...6).map { device(String($0), host: "curtain\($0)") }
        let fakes = devices.map { fake(network, device: $0) }
        let config = LocalHomeConfig(devices: devices)
        let api = LANMiotAPI(config: { config }, transport: trace)
        var sessions: [CurtainControlSession] = []
        for device in devices { sessions.append(try await api.beginCurtainControl(did: device.did, scheduler: scheduler, clock: time.clock)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { _ = try await session.start() } }
            try await group.waitForAll()
        }
        #expect(await trace.maxActive == 1)
        let before = network.exchangeCount
        for device in devices { await api.retryDevice(did: device.did) }
        _ = try await api.deviceList()
        #expect(network.exchangeCount == before)
        await #expect(throws: DeviceControlError.self) {
            try await api.setProps([MiotPropWrite(did: "1", siid: 2, piid: 4, value: .number(80))])
        }
        #expect(fakes.allSatisfy { $0.receivedWrites.isEmpty })
        for device in devices { await api.endCurtainControl(did: device.did) }
        await api.shutdown()
    }
}
