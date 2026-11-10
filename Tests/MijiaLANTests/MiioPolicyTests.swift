import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class PolicyTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var now: Duration { lock.withLock { value } }
    func advance(_ amount: Duration) { lock.withLock { value += amount } }
    var sessionClock: CurtainValidationSession.Clock { .init(now: { self.now }, sleep: { try Task.checkCancellation(); self.advance($0); await Task.yield() }) }
}
private actor ClockReplyTransport: MiioTransport {
    enum Model { case real, echo, delayed, backward, jump }
    let time: PolicyTime
    let model: Model
    let network = FakeMiioNetwork()
    let fake: FakeMiioNetwork.Device
    var hellos = 0
    var layouts: [[Int]] = []
    var calls = 0
    init(time: PolicyTime, model: Model) {
        self.time = time; self.model = model
        fake = network.add(host: "192.0.2.12", token: String(repeating: "0", count: 32), deviceID: 123,
            props: ["2.2": .number(1), "2.3": .number(29), "2.4": .number(29), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = CurtainValidationSession.model; fake.firmware = "1.1.3"; fake.simulateCurtainMovement = true
    }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        calls += 1
        let header = try MiioPacket.parseHeader(packet)
        if packet == MiioPacket.hello { hellos += 1 }
        else {
            let (_, body) = try MiioPacket.decode(packet, token: Data(repeating: 0, count: 16))
            let request = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 })
            if request["method"] == .string("get_properties") {
                layouts.append((request["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue })
            }
        }
        if model == .delayed { time.advance(.milliseconds(1_500)) }
        let real = UInt32(5_000 + time.now.components.seconds)
        if packet == MiioPacket.hello { fake.stamp = real }
        else {
            switch model {
            case .echo: fake.stamp = header.stamp
            case .backward where calls > 4: fake.stamp = real - 10
            case .jump where calls > 4: fake.stamp = real + 100
            default: fake.stamp = real
            }
        }
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func injectFault() { fake.propertyErrors["2.9"] = -4004; fake.propertyErrors["2.10"] = -4004 }
    func writeCount() -> Int { fake.receivedWrites.count }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
struct MiioPolicyTests {
    private func make(_ model: ClockReplyTransport.Model, policy: MiioCommunicationPolicy = .revised) -> (CurtainControlSession, ClockReplyTransport, PolicyTime, DeviceEventLog) {
        let time = PolicyTime(), transport = ClockReplyTransport(time: time, model: model), journal = DeviceEventLog(scope: .offlineTest)
        let device = LocalDevice(did: "123", name: "Synthetic", model: CurtainValidationSession.model, host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let client = MiioClient(host: device.host, token: Data(repeating: 0, count: 16), transport: transport, knownModel: device.model,
            events: journal, eventIdentifier: device.did, policy: policy, expectedDeviceID: 123, time: .init(now: { time.now }))
        return (CurtainControlSession(device: device, client: client, scheduler: CurtainRequestScheduler(clock: time.sessionClock), clock: time.sessionClock, isCurrent: { true }, journal: journal), transport, time, journal)
    }
    @Test("Real, echo and delayed clock replies stay bounded across multiple independent hello periods", arguments: [ClockReplyTransport.Model.real, .echo, .delayed])
    fileprivate func manyHelloPeriods(_ model: ClockReplyTransport.Model) async throws {
        let (session, transport, time, journal) = make(model)
        for _ in 0..<32 { time.advance(.seconds(30)); #expect(try await session.poll().position == 29) }
        #expect(await transport.hellos >= 7)
        let layouts = await transport.layouts
        #expect(layouts.first == [2,3,4,9,10] && layouts.contains([2,3]))
        #expect(layouts.filter { $0.count == 5 }.count >= 3)
        #expect(journal.snapshot().filter { $0.outcome == .packetChecked }.allSatisfy { $0.packet?.clockAccepted != false })
        await session.end()
    }
    @Test("Backward or jumping response clocks pause without a retry or a write", arguments: [ClockReplyTransport.Model.backward, .jump])
    fileprivate func clockFailure(_ model: ClockReplyTransport.Model) async throws {
        let (session, transport, time, journal) = make(model)
        _ = try await session.poll()
        var failed = false
        for _ in 0..<5 {
            time.advance(.seconds(30))
            do { _ = try await session.poll() } catch { failed = true; break }
        }
        let state = await session.snapshot()
        #expect(failed && state.failureReason == .clockDiscontinuity)
        let before = await transport.calls
        await #expect(throws: (any Error).self) { try await session.poll() }
        #expect(await transport.calls == before)
        #expect(journal.snapshot().contains { $0.outcome == .packetChecked && $0.packet?.clockAccepted == false })
        #expect(journal.snapshot().contains { $0.outcome == .observedValue && $0.packet?.clockAccepted == false })
        #expect(!journal.snapshot().contains { $0.kind == .write })
        await session.end()
    }
    @Test("Each layout is explicit; all controls retain a full safety preflight before their single write")
    func layoutsAndControl() async throws {
        for layout in [MiioCommunicationPolicy.Layout.full, .adaptive, .single] {
            let p = MiioCommunicationPolicy(socket: .stable, layout: layout, hello: .periodic, stamp: .helloAnchored)
            let (session, transport, time, _) = make(.real, policy: p)
            _ = try await session.poll(); time.advance(.seconds(30)); _ = try await session.poll()
            let old = await transport.layouts
            if layout == .single { #expect(old.count == 10 && old.allSatisfy { $0.count == 1 }) }
            if layout == .full { #expect(old == [[2,3,4,9,10], [2,3,4,9,10]]) }
            if layout == .adaptive { #expect(old == [[2,3,4,9,10], [2,3]]) }
            let result = try await session.manual(.position(64))
            #expect(result.confirmed && result.position == 64)
            await session.end()
        }
    }
    @Test("Compact reads never authorize a write without a fresh full check, and periodic full checks retain fault errors")
    func fullCheckFailure() async throws {
        for attemptControl in [false, true] {
            let (session, transport, time, journal) = make(.real)
            _ = try await session.poll()
            for _ in 0..<3 { time.advance(.seconds(10)); _ = try await session.poll() }
            await transport.injectFault()
            // A compact query can remain valid, but must not make a subsequent control bypass fault checks.
            time.advance(.seconds(10)); _ = try await session.poll()
            if attemptControl {
                await #expect(throws: (any Error).self) { try await session.manual(.position(64)) }
            } else {
                time.advance(.seconds(300))
                await #expect(throws: (any Error).self) { try await session.poll() }
            }
            let failure = await session.snapshot()
            #expect(await transport.layouts.last == [2,3,4,9,10], "control=\(attemptControl) reason=\(String(describing: failure.failureReason))")
            #expect(await transport.writeCount() == 0)
            #expect(journal.snapshot().contains { $0.outcome == .responseCode && $0.piid == 9 && $0.code == -4004 })
            #expect(journal.snapshot().contains { $0.outcome == .observedValue && $0.piid == 3 && $0.value == 29 })
            let before = await transport.calls
            await #expect(throws: (any Error).self) { try await session.poll() }
            #expect(await transport.calls == before)
            await session.end()
        }
    }
    @Test("Read-only experiment sessions cannot issue a motor or position write through public control methods")
    func readOnlySession() async throws {
        let time = PolicyTime(), transport = ClockReplyTransport(time: time, model: .real)
        let device = LocalDevice(did: "123", name: "Synthetic", model: CurtainValidationSession.model,
            host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let journal = DeviceEventLog(scope: .offlineTest)
        let client = MiioClient(host: device.host, token: Data(repeating: 0, count: 16), transport: transport,
            knownModel: device.model, policy: .revised, expectedDeviceID: 123, time: .init(now: { time.now }))
        let session = CurtainControlSession(device: device, client: client,
            scheduler: CurtainRequestScheduler(clock: time.sessionClock), clock: time.sessionClock,
            isCurrent: { true }, journal: journal, allowWrites: false)
        _ = try await session.poll()
        await #expect(throws: (any Error).self) { try await session.manual(.position(64)) }
        await #expect(throws: (any Error).self) { try await session.stop() }
        #expect(await transport.writeCount() == 0)
        #expect(!journal.snapshot().contains { $0.kind == .write && $0.outcome == .sent })
        await session.end()
    }
    @Test("The legacy hello axis can be selected independently without changing the anchored stamp axis")
    func legacyHelloAxis() async throws {
        let policy = MiioCommunicationPolicy(socket: .stable, layout: .adaptive, hello: .silence, stamp: .helloAnchored)
        let (session, transport, time, _) = make(.real, policy: policy)
        for _ in 0..<20 { time.advance(.seconds(30)); _ = try await session.poll() }
        #expect(await transport.hellos == 1)
        await session.end()
    }
}
