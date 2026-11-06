import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class CurtainClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    private var packets: [Duration] = []
    var now: Duration { lock.withLock { value } }
    var packetTimes: [Duration] { lock.withLock { packets } }
    func record() { lock.withLock { packets.append(value) } }
    var clock: CurtainValidationSession.Clock {
        .init(now: { self.now }, sleep: { delay in
            try Task.checkCancellation()
            self.lock.withLock { self.value += delay }
            await Task.yield()
        })
    }
}
private actor CurtainGapGate {
    private var count = 0
    private var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep() async throws {
        count += 1
        if count == 5 { // Immediately before the target write.
            reached = true; waiter?.resume(); waiter = nil
            try await Task.sleep(for: .seconds(60))
        }
    }
    func waitUntilWriteGap() async {
        if reached { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private struct CurtainTimedTransport: MiioTransport {
    let network: FakeMiioNetwork
    let time: CurtainClock
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        time.record()
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}

struct CurtainValidationTests {
    private let token = "00112233445566778899aabbccddeeff"
    private func setup(position: Int = 29, host: String = "curtain") throws -> (LocalDevice, FakeMiioNetwork, FakeMiioNetwork.Device, CurtainClock, CurtainValidationSession) {
        let device = LocalDevice(did: "123", name: "Curtain", model: CurtainValidationSession.model, host: host, token: token,
            specType: CurtainValidationSession.specification)
        let network = FakeMiioNetwork()
        let fake = network.add(host: host, token: token, deviceID: 123, props: [
            "2.2": .number(1), "2.3": .number(Double(position)), "2.4": .number(Double(position)),
            "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = device.model; fake.firmware = "1.1.3"; fake.simulateCurtainMovement = true
        let time = CurtainClock()
        let client = MiioClient(host: host, token: try #require(MiioToken.parse(token)), transport: CurtainTimedTransport(network: network, time: time), knownModel: device.model)
        return (device, network, fake, time, CurtainValidationSession(device: device, client: client, clock: time.clock))
    }

    @Test("A small move writes exactly once and confirms current position plus stopped state, with five-second packet gaps")
    func successfulMove() async throws {
        let (_, _, fake, time, session) = try setup()
        #expect(try await session.start().position == 29)
        let state = try await session.move(to: 34)
        #expect(state.position == 34 && state.motorStatus == 1 && state.confirmed && state.writeAccepted)
        #expect(fake.receivedWrites.count == 1)
        #expect(fake.receivedWrites[0]["siid"] == .number(2))
        #expect(fake.receivedWrites[0]["piid"] == .number(4))
        #expect(fake.receivedWrites[0]["value"] == .number(34))
        let times = time.packetTimes
        for (a, b) in zip(times, times.dropFirst()) { #expect(b - a >= .seconds(5)) }
        let count = fake.receivedMethods.count
        _ = try await session.move(to: 34)
        #expect(fake.receivedMethods.count == count)
    }

    @Test("Concurrent duplicate triggers join one transaction; no duplicate target write is queued")
    func deduplication() async throws {
        let (_, _, fake, _, session) = try setup()
        _ = try await session.start()
        async let a = session.move(to: 34)
        async let b = session.move(to: 34)
        let states = try await [a, b]
        #expect(states.allSatisfy { $0.confirmed })
        #expect(fake.receivedWrites.count == 1)
    }

    @Test("A hello timeout pauses before info/property reads or any write; there is no retry")
    func handshakeTimeout() async throws {
        let (_, network, fake, _, session) = try setup()
        fake.offline = true
        await #expect(throws: (any Error).self) { try await session.start() }
        #expect(network.exchangeCount == 1)
        #expect(fake.receivedMethods.isEmpty)
        #expect(fake.receivedWrites.isEmpty)
        await #expect(throws: (any Error).self) { try await session.refresh() }
        #expect(network.exchangeCount == 1)
        #expect(await session.snapshot().phase == .paused)
    }

    @Test("Old mixed/order-dependent replies never establish a trusted motor state or permit writing")
    func oldMixedResponse() async throws {
        let (_, network, fake, _, session) = try setup()
        fake.props["2.2"] = .number(2)
        fake.propertyErrors = ["2.3": -4004, "2.4": -4004, "2.5": -4004, "2.9": -4004, "2.10": -4004]
        await #expect(throws: (any Error).self) { try await session.start() }
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(network.exchangeCount == count)
        #expect(fake.receivedWrites.isEmpty)
        let state = await session.snapshot()
        #expect(state.phase == .paused && state.position == nil && state.motorStatus == nil)
    }

    @Test("A target echo without matching current position is unconfirmed and pauses automatic requests")
    func echoIsNotCompletion() async throws {
        let (_, network, fake, _, session) = try setup()
        fake.simulateCurtainMovement = false
        _ = try await session.start()
        await #expect(throws: DeviceControlError.notConfirmed) { try await session.move(to: 34) }
        #expect(fake.props["2.4"] == .number(34))
        #expect(fake.props["2.3"] == .number(29))
        let state = await session.snapshot()
        #expect(state.phase == .unconfirmed && !state.confirmed && state.writeAccepted)
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(network.exchangeCount == count && fake.receivedWrites.count == 1)
    }

    @Test("A timed-out write is never resent; explicit read-only confirmation can confirm a completed move")
    func unknownWriteOutcome() async throws {
        let (_, network, fake, _, session) = try setup()
        _ = try await session.start()
        fake.writeTimeout = true
        await #expect(throws: DeviceControlError.notConfirmed) { try await session.move(to: 34) }
        let failed = await session.snapshot()
        #expect(failed.phase == .unconfirmed && !failed.confirmed && !failed.writeAccepted)
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(network.exchangeCount == count)
        let confirmed = try await session.confirmPendingMove()
        #expect(confirmed.confirmed && confirmed.position == 34 && confirmed.motorStatus == 1)
        #expect(!confirmed.writeAccepted)
        #expect(fake.receivedWrites.count == 1)
    }

    @Test("Endpoint targets and moves exceeding five percentage points are refused without extra packets")
    func limitedScope() async throws {
        let (_, network, fake, _, session) = try setup()
        _ = try await session.start()
        let count = network.exchangeCount
        for target in [0, 100, 35, 80, -1] {
            await #expect(throws: (any Error).self) { try await session.move(to: target) }
        }
        #expect(network.exchangeCount == count && fake.receivedWrites.isEmpty)
    }

    @Test("Response identity mismatch pauses; unverified firmware cannot progress to property reads")
    func identityAndFirmware() async throws {
        let (_, _, wrong, _, a) = try setup()
        wrong.wrongResponseID = true
        await #expect(throws: (any Error).self) { try await a.start() }
        #expect(wrong.receivedMethods == ["miIO.info"])
        let (_, _, firmware, _, b) = try setup()
        firmware.firmware = "2.0.0"
        await #expect(throws: (any Error).self) { try await b.start() }
        #expect(firmware.receivedMethods == ["miIO.info"])
        #expect(firmware.receivedWrites.isEmpty)
    }

    @Test("A moving motor prevents writing; missing or corrupt state pauses the session")
    func incompleteOrMovingState() async throws {
        let (_, network, fake, _, session) = try setup()
        _ = try await session.start()
        fake.props["2.2"] = .number(2)
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(fake.receivedWrites.isEmpty)
        fake.props["2.3"] = nil
        await #expect(throws: (any Error).self) { try await session.refresh() }
        #expect(await session.snapshot().phase == .paused)
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(network.exchangeCount == count && fake.receivedWrites.isEmpty)
    }

    @Test("Ending the session or invalidating its configuration prevents subsequent writes")
    func invalidation() async throws {
        let (device, network, fake, time, _) = try setup()
        let lease = CurtainValidationLease()
        let client = MiioClient(host: device.host, token: try #require(MiioToken.parse(token)), transport: network, knownModel: device.model)
        let session = CurtainValidationSession(device: device, client: client, clock: time.clock, isCurrent: { lease.isValid })
        _ = try await session.start()
        lease.invalidate()
        let count = network.exchangeCount
        await #expect(throws: (any Error).self) { try await session.move(to: 34) }
        #expect(network.exchangeCount == count && fake.receivedWrites.isEmpty)
        await session.end()
        #expect(await session.snapshot().phase == .disabled)
    }

    @Test("Disabling validation during the write gap cancels the queued write before it reaches the transport")
    func endDuringWriteGap() async throws {
        let (device, network, fake, time, _) = try setup()
        let gate = CurtainGapGate()
        let clock = CurtainValidationSession.Clock(now: { time.now }, sleep: { delay in
            try await gate.sleep()
            try await time.clock.sleep(delay)
        })
        let client = MiioClient(host: device.host, token: try #require(MiioToken.parse(token)), transport: network, knownModel: device.model)
        let session = CurtainValidationSession(device: device, client: client, clock: clock)
        _ = try await session.start()
        let move = Task { try await session.move(to: 34) }
        await gate.waitUntilWriteGap()
        await session.end()
        await #expect(throws: (any Error).self) { try await move.value }
        #expect(fake.receivedWrites.isEmpty)
        #expect(await session.snapshot().phase == .disabled)
    }

    @Test("A hello for a different configured DID stops before authenticated reads or writes")
    func wrongHandshakeIdentity() async throws {
        let (original, network, fake, time, _) = try setup()
        var device = original; device.did = "999"
        let client = MiioClient(host: device.host, token: try #require(MiioToken.parse(token)), transport: network, knownModel: device.model)
        let session = CurtainValidationSession(device: device, client: client, clock: time.clock)
        await #expect(throws: (any Error).self) { try await session.start() }
        #expect(network.exchangeCount == 1 && fake.receivedMethods.isEmpty && fake.receivedWrites.isEmpty)
    }

    @Test("Each household-reported small move is replayed without inventing Open/Close/Stop acceptance")
    func householdMoves() async throws {
        let url = try #require(Bundle.module.url(forResource: "dooya-small-position-validation", withExtension: "json"))
        struct Record: Decodable { var start: Int; var target: Int; var current: Int; var status: Int; var writeCode: Int }
        struct Report: Decodable { var moves: [Record] }
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        #expect(report.moves.count == 6)
        for move in report.moves {
            let (_, _, fake, _, session) = try setup(position: move.start)
            _ = try await session.start()
            let state = try await session.move(to: move.target)
            #expect(state.position == move.current && state.motorStatus == move.status && state.confirmed)
            #expect(state.writeAccepted == (move.writeCode == 0))
            #expect(fake.receivedWrites.count == 1)
            await session.end()
        }
    }

    @Test("Validation start suppresses automatic metadata probing for all curtains while ordinary APIs stay locked")
    func sharedAPIIsolation() async throws {
        let (device, network, fake, time, _) = try setup()
        let other = network.add(host: "other", token: token, deviceID: 456, props: [
            "2.2": .number(1), "2.3": .number(7), "2.4": .number(7), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        other.model = device.model; other.firmware = "1.1.3"
        let second = LocalDevice(did: "456", name: "Other", model: device.model, host: "other", token: token, specType: device.specType)
        let config = LocalHomeConfig(devices: [device, second])
        let api = LANMiotAPI(config: { config }, transport: CurtainTimedTransport(network: network, time: time))
        _ = try await api.deviceList()
        let selected = try await api.beginCurtainValidation(did: device.did, clock: time.clock)
        _ = try await selected.start()
        let before = other.receivedMethods.count
        await api.retryDevice(did: second.did)
        _ = try await api.deviceList()
        #expect(other.receivedMethods.count == before)
        #expect(try await api.getProps([MiotPropKey(did: device.did, siid: 2, piid: 3)]).isEmpty)
        await #expect(throws: DeviceControlError.self) {
            try await api.setProps([MiotPropWrite(did: device.did, siid: 2, piid: 4, value: .number(34))])
        }
        _ = try await selected.move(to: 34)
        #expect(fake.receivedWrites.count == 1)
        await api.endCurtainValidation()
        await #expect(throws: (any Error).self) { try await selected.refresh() }
        await api.shutdown()
    }
}
