import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class ProbeBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var now: Duration { lock.withLock { value } }
    var clock: CurtainValidationSession.Clock { .init(now: { self.now }, sleep: { delay in
        try Task.checkCancellation(); self.lock.withLock { self.value += delay }; await Task.yield()
    }) }
}
struct CurtainProbeTimeoutTests {
    @Test("Old attribute plans decode with the original two-second budget")
    func oldPlan() throws {
        let data = Data(#"{"properties":[9],"layout":"single","phase":"probe","rounds":1,"intervalSeconds":5}"#.utf8)
        #expect(try JSONDecoder().decode(CurtainAttributePlan.self, from: data).rpcTimeoutSeconds == 2)
    }
    @Test("Real UDP accepts a reply after three seconds only with an explicit five-second budget; silence stops before the next attribute", arguments: [2,5,0])
    func delayedOrMissing(_ mode: Int) async throws {
        let budget = mode == 0 ? 5 : mode
        let server = try UDPSocket(bindHost: "127.0.0.1"), token = Data(repeating: 0, count: 16), clock = ProbeBudgetClock()
        let responder = loopbackResponder { () throws -> [[Int]] in
            let fake = FakeMiioNetwork.Device(host: "127.0.0.1", token: token, deviceID: 123)
            var reads: [[Int]] = []
            while reads.count < (mode == 5 ? 2 : 1) {
                guard let request = try server.receive(timeout: 6) else { throw MiioError.timeout }
                fake.stamp = 5_000 + UInt32(clock.now.components.seconds)
                if request.data == MiioPacket.hello { try server.send(FakeMiioNetwork.helloReply(fake), to: "127.0.0.1", port: request.port); continue }
                let (_, bytes) = try MiioPacket.decode(request.data, token: token)
                let json = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
                let result: JSONValue
                if json["method"] == .string("miIO.info") { result = .object(["model": .string(CurtainValidationSession.model), "fw_ver": .string("1.1.3")]) }
                else {
                    guard json["method"] == .string("get_properties") else { throw MiioError.badResponse("Unexpected budget-test method") }
                    let ids = (json["params"]?.arrayValue ?? []).compactMap { $0["piid"]?.intValue }; reads.append(ids)
                    if mode == 0 { return reads } // One read, deliberately no answer and no retry target.
                    if reads.count == 1 { Thread.sleep(forTimeInterval: 3) }
                    result = .array(ids.map { .object(["siid": .number(2), "piid": .number(Double($0)), "code": .number(0), "value": .number(0)]) })
                }
                let body = JSONValue.object(["id": json["id"] ?? .null, "result": result])
                try server.send(MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: fake.stamp), to: "127.0.0.1", port: request.port)
            }
            return reads
        }
        let device = LocalDevice(did: "123", name: "Budget fixture", model: CurtainValidationSession.model, host: "127.0.0.1", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let plan = try CurtainAttributePlan(properties: [3,4], layout: .single, phase: .probe, rounds: 2, intervalSeconds: 5, rpcTimeoutSeconds: budget)
        let journal = DeviceEventLog(scope: .offlineTest)
        let probe = try CurtainAttributeProbe(device: device, plan: plan, journal: journal, port: server.localPort,
            clock: clock.clock, time: .init(now: { clock.now }))
        if mode == 5 { try await probe.readRound() }
        else {
            await #expect(throws: MiioError.timeout) { try await probe.readRound() }
            await #expect(throws: (any Error).self) { try await probe.readRound() }
        }
        await probe.end()
        let reads = try await responder.value
        #expect(reads == (mode == 5 ? [[3],[4]] : [[3]]))
        let exposure = await probe.exposure()
        #expect(exposure.hello == 1 && exposure.info == 1 && exposure.reads == UInt64(mode == 5 ? 2 : 1) && exposure.writes == 0)
        let packets = journal.snapshot().filter { $0.kind == .read && $0.outcome == .sent }
        #expect(packets.allSatisfy { $0.packet?.requestTimeoutMilliseconds == Int64(budget * 1_000) && $0.packet?.attributePlan?.rpcTimeoutSeconds == budget })
        let extra = try await loopbackResponder { try server.receive(timeout: 0.05) }.value
        #expect(extra == nil)
    }
}
