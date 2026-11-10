import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class NormalProfileClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var now: Duration { lock.withLock { value } }
    func advance(_ amount: Duration) { lock.withLock { value += amount } }
    var clock: CurtainValidationSession.Clock { .init(now: { self.now }, sleep: { try Task.checkCancellation(); self.advance($0); await Task.yield() }) }
}
private actor NormalProfileTransport: MiioTransport {
    let clock: NormalProfileClock
    let network = FakeMiioNetwork()
    let fake: FakeMiioNetwork.Device
    var reads: [[Int]] = []
    var timeouts: [Duration] = []
    init(clock: NormalProfileClock) {
        self.clock = clock
        fake = network.add(host: "192.0.2.12", token: String(repeating: "0", count: 32), deviceID: 123,
            props: ["2.2": .number(1), "2.3": .number(0), "2.4": .number(0), "2.5": .number(2), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = CurtainValidationSession.model; fake.firmware = "1.1.3"; fake.simulateCurtainMovement = true
        // If a hidden normal path requests motor-reverse, it must fail rather than look healthy.
        fake.propertyErrors["2.5"] = -4004
    }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        fake.stamp = 5_000 + UInt32(clock.now.components.seconds)
        timeouts.append(timeout)
        if packet != MiioPacket.hello {
            let (_, body) = try MiioPacket.decode(packet, token: Data(repeating: 0, count: 16))
            let json = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 })
            if json["method"] == .string("get_properties") { reads.append((json["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue }) }
        }
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func exchangeObserved(_ packet: Data, host: String, port: UInt16, timeout: Duration, onSent: @escaping @Sendable () -> Void) async throws -> Data {
        onSent(); return try await exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { Issue.record("Normal curtain broadcast"); return [] }
}
private final class NormalLoopStop: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.withLock { value } }
    func stop() { lock.withLock { value = true } }
}
struct CurtainNormalProfileTests {
    private func device(host: String = "192.0.2.12") -> LocalDevice {
        .init(did: "123", name: "Synthetic normal curtain", model: CurtainValidationSession.model,
              host: host, token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
    }
    @Test("Normal adaptive, manual and every control preflight never query motor-reverse across 512 polls")
    func normalLongRun() async throws {
        let time = NormalProfileClock(), network = NormalProfileTransport(clock: time), journal = DeviceEventLog(scope: .offlineTest)
        let d = device()
        let client = MiioClient(host: d.host, token: Data(repeating: 0, count: 16), transport: network, knownModel: d.model,
            events: journal, time: .init(now: { time.now }))
        let session = CurtainControlSession(device: d, client: client, scheduler: CurtainRequestScheduler(clock: time.clock),
            clock: time.clock, isCurrent: { true }, journal: journal)
        _ = try await session.start()
        for _ in 0..<512 { time.advance(.seconds(30)); _ = try await session.poll() }
        _ = try await session.refresh(); _ = try await session.manual()
        for command in [CurtainControlSession.Command.position(64), .open, .close, .stop] {
            #expect(try await session.manual(command).confirmed)
        }
        let reads = await network.reads
        #expect(reads.filter { $0 == [2,3,4,9,10] }.count >= 38)
        #expect(reads.contains([2,3]) && reads.contains([3,2]))
        #expect(reads.allSatisfy { !$0.contains(5) && Set($0).isSubset(of: Set([2,3,4,9,10])) })
        #expect(await network.timeouts.allSatisfy { $0 == .seconds(2) })
        #expect(journal.snapshot().filter { $0.kind == .read && $0.outcome == .sent }.allSatisfy { $0.packet?.curtainReadProfile == .normalFive && $0.packet?.addresses?.contains(where: { $0.piid == 5 }) == false })
        await session.end()
    }
    @Test("Legacy validation start/refresh/move keeps five-property preflight and unchanged two-property confirmation")
    func legacyValidation() async throws {
        let time = NormalProfileClock(), network = NormalProfileTransport(clock: time), d = device(), journal = DeviceEventLog(scope: .offlineTest)
        let client = MiioClient(host: d.host, token: Data(repeating: 0, count: 16), transport: network, knownModel: d.model, events: journal, time: .init(now: { time.now }))
        let session = CurtainValidationSession(device: d, client: client, clock: time.clock)
        _ = try await session.start()
        for _ in 0..<48 { time.advance(.seconds(30)); _ = try await session.refresh() }
        #expect(try await session.move(to: 5).confirmed)
        let reads = await network.reads
        #expect(reads.filter { $0 == [2,3,4,9,10] }.count == 50)
        #expect(reads.last == [3,2] && reads.allSatisfy { !$0.contains(5) })
        #expect(journal.snapshot().contains { $0.kind == .read && $0.outcome == .sent && $0.packet?.propertyCount == 5 })
        await session.end()
    }
    @Test("All remaining normal fields reject bad codes/types/ranges and unsolicited motor-reverse is not silently ignored")
    func strictFive() throws {
        let values: [Int: JSONValue] = [2:.number(1),3:.number(0),4:.number(0),9:.number(0),10:.bool(false)]
        func rows(_ badID: Int? = nil, value: JSONValue? = nil, code: Int = 0) -> [JSONValue] {
            [2,3,4,9,10].map { id in .object(["siid": .number(2), "piid": .number(Double(id)), "code": .number(Double(id == badID ? code : 0)), "value": id == badID ? (value ?? .null) : values[id]!]) }
        }
        #expect(try CurtainControlSession.preflight(.array(rows())).status == 1)
        for (id, value) in [(2,JSONValue.number(99)), (3,.number(101)), (4,.number(-1)), (9,.number(1)), (10,.number(0))] {
            #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(rows(id, value: value))) }
            #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(rows(id, value: .string("invalid")))) }
            #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(rows(id, value: values[id], code: -4004))) }
        }
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(Array(rows().dropLast()))) }
        let extra = rows() + [.object(["siid":.number(2),"piid":.number(5),"code":.number(0),"value":.bool(true)])]
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(extra)) }
    }
    @Test("Actual UDP normal daily and old validation paths both cross 48 full checks without PIID5", arguments: [false, true])
    func loopbackNormal(_ legacy: Bool) async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), token = Data(repeating: 0, count: 16), time = NormalProfileClock(), stop = NormalLoopStop()
        defer { stop.stop() }
        let responder = loopbackResponder { () throws -> ([[Int]], [UInt16]) in
            let fake = FakeMiioNetwork.Device(host: "127.0.0.1", token: token, deviceID: 123)
            var reads: [[Int]] = [], ports: [UInt16] = [], position = 0
            while !stop.stopped {
                guard let request = try server.receive(timeout: 0.05) else { continue }
                ports.append(request.port); fake.stamp = 5_000 + UInt32(time.now.components.seconds)
                if request.data == MiioPacket.hello { try server.send(FakeMiioNetwork.helloReply(fake), to: "127.0.0.1", port: request.port); continue }
                let (_, body) = try MiioPacket.decode(request.data, token: token)
                let json = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 })
                let result: JSONValue
                switch json["method"]?.stringValue {
                case "miIO.info": result = .object(["model": .string(CurtainValidationSession.model), "fw_ver": .string("1.1.3")])
                case "get_properties":
                    let ids = (json["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue }; reads.append(ids)
                    result = .array(ids.map { id in .object(["siid": .number(2), "piid": .number(Double(id)), "code": .number(id == 5 ? -4004 : 0), "value": id == 10 ? .bool(false) : .number(Double(id == 2 ? 1 : (id == 3 || id == 4 ? position : 0)))]) })
                case "set_properties":
                    guard let row = json["params"]?.arrayValue?.first, row["piid"] == .number(4), let value = row["value"]?.intValue else { throw MiioError.badResponse("Unexpected fixture write") }
                    position = value; result = .array([.object(["code": .number(0)])])
                default: throw MiioError.badResponse("Unexpected fixture method")
                }
                let response = JSONValue.object(["id": json["id"] ?? .null, "result": result])
                try server.send(MiioPacket.encode(Data(response.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: fake.stamp), to: "127.0.0.1", port: request.port)
            }
            return (reads, ports)
        }
        let d = device(host: "127.0.0.1"), journal = DeviceEventLog(scope: .offlineTest)
        let client = MiioClient(host: d.host, token: token, port: server.localPort, knownModel: d.model, events: journal, expectedDeviceID: 123, time: .init(now: { time.now }))
        if legacy {
            let session = CurtainValidationSession(device: d, client: client, clock: time.clock)
            _ = try await session.start()
            for _ in 0..<48 { time.advance(.seconds(30)); _ = try await session.refresh() }
            #expect(try await session.move(to: 5).confirmed)
            await session.end()
        } else {
            let session = CurtainControlSession(device: d, client: client, scheduler: CurtainRequestScheduler(clock: time.clock), clock: time.clock, isCurrent: { true }, journal: journal)
            _ = try await session.start()
            for _ in 0..<48 { time.advance(.seconds(30)); _ = try await session.refresh() }
            #expect(try await session.manual(.position(64)).confirmed)
            await session.end()
        }
        stop.stop(); let (reads, ports) = try await responder.value
        #expect(reads.filter { $0 == [2,3,4,9,10] }.count >= 50)
        #expect(reads.allSatisfy { !$0.contains(5) } && reads.last == [3,2])
        #expect(Set(ports).count == 1)
    }
}
