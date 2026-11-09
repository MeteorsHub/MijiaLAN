import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class AttributeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var now: Duration { lock.withLock { value } }
    func advance(_ amount: Duration) { lock.withLock { value += amount } }
    var clock: CurtainValidationSession.Clock { .init(now: { self.now }, sleep: { try Task.checkCancellation(); self.advance($0); await Task.yield() }) }
}
private actor AttributeTestTransport: MiioTransport {
    let network = FakeMiioNetwork()
    let fake: FakeMiioNetwork.Device
    let clock: AttributeTestClock
    var layouts: [[Int]] = []
    var fullCount = 0
    let failFull38: Bool
    let typeOnly: Bool
    let discardFirst: Bool
    init(clock: AttributeTestClock, failFull38: Bool = false, typeOnly: Bool = false, discardFirst: Bool = false) {
        self.clock = clock; self.failFull38 = failFull38; self.typeOnly = typeOnly; self.discardFirst = discardFirst
        fake = network.add(host: "192.0.2.12", token: String(repeating: "0", count: 32), deviceID: 123,
            props: ["2.2": .number(1), "2.3": .number(0), "2.4": .number(0), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = CurtainValidationSession.model; fake.firmware = "1.1.3"
    }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        fake.stamp = 5_000 + UInt32(clock.now.components.seconds)
        if packet != MiioPacket.hello {
            let (_, bytes) = try MiioPacket.decode(packet, token: Data(repeating: 0, count: 16))
            let request = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
            if request["method"] == .string("get_properties") {
                let ids = (request["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue }
                layouts.append(ids)
                if ids.count == 6 { fullCount += 1 }
                if (failFull38 && fullCount == 38) || typeOnly {
                    fake.props["2.5"] = .number(2)
                    if !typeOnly { fake.propertyErrors["2.9"] = -4004; fake.propertyErrors["2.10"] = -4004 }
                }
            }
        }
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func exchangeValidated(_ packet: Data, host: String, port: UInt16, timeout: Duration,
                           observe: @escaping @Sendable (MiioTransportObservation) -> Void,
                           accept: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        observe(.init(.sent))
        let reply = try await exchange(packet, host: host, port: port, timeout: timeout)
        if discardFirst, layouts.count == 1, packet != MiioPacket.hello {
            let token = Data(repeating: 0, count: 16)
            let (header, body) = try MiioPacket.decode(reply, token: token)
            guard case .object(var json) = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 }) else { throw MiioError.malformedPacket }
            json["id"] = .number(Double((json["id"]?.intValue ?? 1) % 9_999 + 1))
            let bad = try MiioPacket.encode(Data(JSONValue.object(json).compactJSONString.utf8) + [0], token: token, deviceID: header.deviceID, stamp: header.stamp)
            _ = accept(bad); observe(.init(.discarded, reason: .invalidReply))
        }
        guard accept(reply) else { throw MiioError.badResponse("Fixture identity mismatch") }
        return reply
    }
    func goOffline() { fake.offline = true }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { Issue.record("Attribute probe broadcast"); return [] }
}
struct CurtainAttributeProbeTests {
    private func device(host: String = "192.0.2.12") -> LocalDevice {
        .init(did: "123", name: "Private fixture", model: CurtainValidationSession.model,
            host: host, token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
    }
    private func make(_ ids: [Int], layout: CurtainAttributePlan.Layout, rounds: Int = 48,
                      failFull38: Bool = false, typeOnly: Bool = false, discardFirst: Bool = false) throws -> (CurtainAttributeProbe, AttributeTestTransport, AttributeTestClock, DeviceEventLog) {
        let clock = AttributeTestClock(), journal = DeviceEventLog(maxEvents: 16_384, scope: .offlineTest)
        let transport = AttributeTestTransport(clock: clock, failFull38: failFull38, typeOnly: typeOnly, discardFirst: discardFirst)
        let plan = try CurtainAttributePlan(properties: ids, layout: layout, phase: .probe, rounds: rounds, intervalSeconds: 30)
        let probe = try CurtainAttributeProbe(device: device(), plan: plan, journal: journal, transport: transport,
            clock: clock.clock, time: .init(now: { clock.now }))
        return (probe, transport, clock, journal)
    }
    @Test("Explicit ordered subsets are the entire property request stream, even across 300 seconds and hello periods")
    func exactReads() async throws {
        for ids in [[5], [10,4,3], [2,3], CurtainAttributePlan.whitelist] {
            for layout in [CurtainAttributePlan.Layout.batch, .single] {
                let (probe, transport, clock, journal) = try make(ids, layout: layout, rounds: 2)
                try await probe.readRound(); clock.advance(.seconds(310)); try await probe.readRound()
                let expected = layout == .batch ? [ids, ids] : (ids + ids).map { [$0] }
                #expect(await transport.layouts == expected)
                let exposure = await probe.exposure()
                #expect(exposure.reads == UInt64(expected.count) && exposure.writes == 0 && exposure.other == 0)
                for row in exposure.addresses { #expect(row.requested == (ids.contains(row.piid) ? 2 : 0)) }
                let sent = journal.snapshot().filter { $0.outcome == .sent && $0.kind == .read }
                #expect(sent.count == expected.count)
                #expect(sent.last?.packet?.attributeExposure == exposure)
                #expect(sent.allSatisfy { $0.packet?.attributePlan?.properties == ids })
                #expect(!journal.snapshot().contains { $0.outcome == .sample }) // Subsets never become a product state/cache.
                await probe.end()
            }
        }
    }
    @Test("A discarded wrong RPC followed by a valid reply stops single layout before its next selected property")
    func perRPCDiscard() async throws {
        let (probe, transport, _, journal) = try make([5,3,9], layout: .single, discardFirst: true)
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        #expect(await transport.layouts == [[5]])
        #expect(await probe.exposure().reads == 1)
        let before = transport.network.exchangeCount
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        #expect(transport.network.exchangeCount == before)
        #expect(journal.snapshot().contains { $0.outcome == .discarded })
        #expect(journal.snapshot().contains { $0.packet?.rpcIDMatches == false })
        await probe.end()
    }
    @Test("A cold hello timeout sends exactly once, with no info/read/retry or subsequent round")
    func helloTimeout() async throws {
        let (probe, transport, _, _) = try make([5], layout: .single)
        await transport.goOffline()
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        let exposure = await probe.exposure()
        #expect(exposure.packets == 1 && exposure.hello == 1 && exposure.info == 0 && exposure.reads == 0)
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        #expect(transport.network.exchangeCount == 1)
        await probe.end()
    }
    @Test("Synthetic cumulative-full fault model preserves number-2/code0 before both errors and stops at the first bad packet")
    func syntheticFull38() async throws {
        let (probe, transport, clock, journal) = try make(CurtainAttributePlan.whitelist, layout: .batch, failFull38: true)
        for _ in 0..<37 { try await probe.readRound(); clock.advance(.seconds(30)) }
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        let exposure = await probe.exposure()
        #expect(exposure.sixAddressPackets == 38 && exposure.reads == 38)
        #expect(exposure.addresses.allSatisfy { $0.requested == 38 })
        let reverse = journal.snapshot().filter { $0.packet?.attributeRound == 38 && $0.piid == 5 && $0.outcome == .observedValue }
        #expect(reverse.count == 1 && reverse[0].code == 0 && reverse[0].valueType == .number && reverse[0].value == 2)
        for id in [9,10] { #expect(journal.snapshot().contains { $0.packet?.attributeRound == 38 && $0.piid == id && $0.code == -4004 }) }
        let before = transport.network.exchangeCount
        await #expect(throws: (any Error).self) { try await probe.readRound() }
        #expect(transport.network.exchangeCount == before)
        await probe.end()
    }
    @Test("All-code-zero motor-reverse corruption remains untrusted and no second request is sent")
    func typeOnlyCorruption() async throws {
        let (probe, transport, _, journal) = try make([5,3], layout: .single, typeOnly: true)
        await #expect(throws: CurtainInvalidReading.self) { try await probe.readRound() }
        #expect(await transport.layouts == [[5]])
        #expect(journal.snapshot().contains { $0.reason == .untrustedReading })
        #expect(journal.snapshot().contains { $0.piid == 5 && $0.code == 0 && $0.value == 2 && $0.valueType == .number })
        await probe.end()
    }
    @Test("Real UDP selected reads preserve order and a stable port; late wrong RPC prevents the next property", arguments: [false, true])
    func udpSelected(_ wrongRPC: Bool) async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), token = Data(repeating: 0, count: 16), clock = AttributeTestClock()
        let target = wrongRPC ? 1 : 6
        let responder = loopbackResponder { () throws -> ([[Int]], [UInt16]) in
            let fake = FakeMiioNetwork.Device(host: "127.0.0.1", token: token, deviceID: 123)
            var reads: [[Int]] = [], ports: [UInt16] = []
            while reads.count < target {
                guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
                ports.append(request.port); fake.stamp = 5_000 + UInt32(clock.now.components.seconds)
                if request.data == MiioPacket.hello { try server.send(FakeMiioNetwork.helloReply(fake), to: "127.0.0.1", port: request.port); continue }
                let (_, bytes) = try MiioPacket.decode(request.data, token: token)
                let json = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
                let method = json["method"]?.stringValue
                let result: JSONValue
                if method == "miIO.info" { result = .object(["model": .string(CurtainValidationSession.model), "fw_ver": .string("1.1.3")]) }
                else {
                    guard method == "get_properties" else { throw MiioError.badResponse("Unexpected test method") }
                    let ids = (json["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue }; reads.append(ids)
                    result = .array(ids.map { id in .object(["siid": .number(2), "piid": .number(Double(id)), "code": .number(0), "value": id == 5 ? .bool(false) : .number(0)]) })
                }
                let id = json["id"]?.intValue ?? 1
                if wrongRPC, method == "get_properties" {
                    let bad = JSONValue.object(["id": .number(Double(id % 9_999 + 1)), "result": result])
                    try server.send(MiioPacket.encode(Data(bad.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: fake.stamp), to: "127.0.0.1", port: request.port)
                }
                let body = JSONValue.object(["id": .number(Double(id)), "result": result])
                try server.send(MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: fake.stamp), to: "127.0.0.1", port: request.port)
            }
            return (reads, ports)
        }
        let plan = try CurtainAttributePlan(properties: [5,3,9], layout: .single, phase: .probe, rounds: 2, intervalSeconds: 30)
        let journal = DeviceEventLog(scope: .offlineTest)
        let probe = try CurtainAttributeProbe(device: device(host: "127.0.0.1"), plan: plan, journal: journal, port: server.localPort,
            clock: clock.clock, time: .init(now: { clock.now }))
        if wrongRPC { await #expect(throws: (any Error).self) { try await probe.readRound() } }
        else { try await probe.readRound(); clock.advance(.seconds(310)); try await probe.readRound() }
        await probe.end()
        let (reads, ports) = try await responder.value
        #expect(reads == (wrongRPC ? [[5]] : [[5],[3],[9],[5],[3],[9]]))
        #expect(Set(ports).count == 1)
        let exposure = await probe.exposure()
        #expect(exposure.reads == UInt64(target) && exposure.writes == 0)
        let unexpected = try await loopbackResponder { try server.receive(timeout: 0.05) }.value
        #expect(unexpected == nil)
        let export = journal.exportText()
        for secret in ["127.0.0.1", "Private fixture", String(repeating: "0", count: 32)] { #expect(!export.contains(secret)) }
    }
}
