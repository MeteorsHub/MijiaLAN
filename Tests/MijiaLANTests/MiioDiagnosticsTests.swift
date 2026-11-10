import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class IncidentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.time } }, sleep: { delay in
        try Task.checkCancellation(); self.lock.withLock { self.time += delay }; await Task.yield()
    }) }
}
struct MiioDiagnosticsTests {
    @Test("Clock policy follows true clock replies but can drift with echoed stamps; the model is not a firmware diagnosis")
    func clockModels() {
        let base: UInt32 = 100_000
        var echo = base, trueReply = base
        var maximumTrueLead = 0
        for index in 1...38 {
            let trueNow = base + UInt32(index * 29_400 / 1_000)
            let trueRequest = MiioClient.outgoingStamp(base: trueReply, elapsed: .milliseconds(29_400))
            maximumTrueLead = max(maximumTrueLead, Int(trueRequest) - Int(trueNow))
            trueReply = trueNow
            echo = MiioClient.outgoingStamp(base: echo, elapsed: .milliseconds(29_400))
        }
        #expect(maximumTrueLead <= 1)
        #expect(Int(echo) - Int(base + UInt32(38 * 29_400 / 1_000)) == 23)
        #expect(MiioClient.outgoingStamp(base: .max, elapsed: .zero) == 0)
    }
    @Test("Real loopback client diagnostics correlate sockets, IDs and authenticated header stamps without identifiers")
    func packetMetadata() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1")
        let token = Data(repeating: 0, count: 16)
        let fake = FakeMiioNetwork.Device(host: "127.0.0.1", token: token, deviceID: 987_654_321)
        let responder = loopbackResponder {
            for index in 0...40 {
                guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
                let response: Data
                if request.data == MiioPacket.hello { response = FakeMiioNetwork.helloReply(fake) }
                else {
                    let (_, payload) = try MiioPacket.decode(request.data, token: token)
                    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 }) else { throw MiioError.malformedPacket }
                    let body = JSONValue.object(["id": fields["id"] ?? .null, "result": .object(["model": .string("test-only-model")])])
                    response = try MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: fake.deviceID, stamp: 5_000 + UInt32(index))
                }
                try server.send(response, to: "127.0.0.1", port: request.port)
            }
        }
        let journal = DeviceEventLog(scope: .offlineTest)
        let client = MiioClient(host: "127.0.0.1", token: token, port: server.localPort, retries: 0, events: journal, eventIdentifier: "private-device-id")
        for _ in 0..<40 { _ = try await client.info() }
        try await responder.value
        let checks = journal.snapshot().filter { $0.outcome == .packetChecked && $0.kind == .info }
        #expect(checks.count == 40)
        let packets = checks.compactMap(\.packet)
        #expect(packets.first?.clockBasis == .hello && packets.last?.clockBasis == .reply)
        #expect(packets.allSatisfy { $0.authenticated == true && $0.rpcIDMatches == true && $0.headerIdentityMatches == true && $0.clockUpdated == true })
        #expect(packets.map(\.responseStamp) == (1...40).map { UInt32(5_000 + $0) })
        #expect(Set(packets.compactMap(\.socket)).count == 40)
        #expect(packets.allSatisfy { $0.requestID == $0.responseID && $0.localPort != nil && $0.peerEndpointMatches == true && $0.helloAgeMilliseconds != nil })
        for packet in packets {
            let stamp = try #require(packet.clockBaseStamp), age = try #require(packet.clockBaseAgeMilliseconds)
            #expect(packet.requestStamp == MiioClient.outgoingStamp(base: stamp, elapsed: .milliseconds(age)))
        }
        let text = journal.exportText()
        for secret in ["127.0.0.1", "987654321", "private-device-id", String(repeating: "0", count: 32), "test-only-model"] { #expect(!text.contains(secret)) }
    }
    @Test("Reported 37 good reads then partial -4004 retains safe values before throwing, pauses and never writes")
    func partialFailureEvidence() async throws {
        struct Row: Decodable { let piid: Int; let code: Int }
        struct Corpus: Decodable { let valuesAvailable: Bool; let firstFailureCodes: [Row]; let followupCodes: [Row] }
        let url = try #require(Bundle.module.url(forResource: "dooya-continuous-read-2026-11-09", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(!corpus.valuesAvailable)
        for codes in [corpus.firstFailureCodes, corpus.followupCodes] {
            let network = FakeMiioNetwork(), journal = DeviceEventLog(scope: .offlineTest)
            let token = Data(repeating: 0, count: 16), deviceID = "987654321"
            let device = LocalDevice(did: deviceID, name: "Synthetic fixture", model: CurtainValidationSession.model,
                host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
            // Values were NOT present in the field summary; these are explicitly synthetic safe inputs.
            let fake = network.add(host: device.host, token: device.token, deviceID: 987_654_321,
                props: ["2.2": .number(1), "2.3": .number(29), "2.4": .number(29), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
            fake.model = device.model; fake.firmware = "1.1.3"
            let client = MiioClient(host: device.host, token: token, transport: network, knownModel: device.model, policy: .legacy)
            let time = IncidentClock()
            let session = CurtainControlSession(device: device, client: client, scheduler: CurtainRequestScheduler(clock: time.clock), clock: time.clock, isCurrent: { true }, journal: journal, allowWrites: false, readProfile: .diagnosticSix)
            for _ in 0..<37 { _ = try await session.poll() }
            for row in codes where row.code != 0 { fake.propertyErrors["2.\(row.piid)"] = row.code }
            let id = UUID()
            await #expect(throws: (any Error).self) { try await session.poll(operationID: id) }
            let events = journal.snapshot().filter { $0.operation == id }
            for row in codes {
                #expect(events.contains { $0.outcome == .responseCode && $0.piid == row.piid && $0.code == row.code && $0.packet?.rpcIDMatches == true })
            }
            #expect(events.contains { $0.outcome == .observedValue && $0.piid == 2 && $0.code == 0 && $0.value == 1 && $0.valueType == .number })
            if codes.first(where: { $0.piid == 5 })?.code == 0 {
                #expect(events.contains { $0.outcome == .observedValue && $0.piid == 5 && $0.valueType == .boolean && $0.booleanValue == false })
            }
            #expect(!events.contains { $0.outcome == .sample })
            let state = await session.snapshot()
            #expect(state.position == nil && state.failureReason == .propertyError && state.lastKnownPosition == 29)
            let before = network.exchangeCount
            await #expect(throws: (any Error).self) { try await session.poll() }
            #expect(network.exchangeCount == before && fake.receivedWrites.isEmpty)
            #expect(fake.receivedMethods.filter { $0 == "get_properties" }.count == 38)
        }
    }
    @Test("Overnight bad full batch retains code-zero numeric motor-reverse and rejects it without normalizing")
    func overnightBadType() throws {
        let url = try #require(Bundle.module.url(forResource: "dooya-overnight-2026-11-10", withExtension: "json"))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let failure = try #require(json["failure"])
        let rows = try #require(failure.arrayValue)
        let reverse = rows.first { $0["piid"] == .number(5) }
        #expect(reverse?["value"] == .number(2))
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(failure, profile: .diagnosticSix) }
        // Even if the two negative codes are removed synthetically, the independently wrong type must fail.
        let typeOnly = JSONValue.array((failure.arrayValue ?? []).map { row in
            guard case .object(var fields) = row else { return row }
            if fields["piid"] == .number(9) { fields["code"] = .number(0); fields["value"] = .number(0) }
            if fields["piid"] == .number(10) { fields["code"] = .number(0); fields["value"] = .bool(false) }
            return .object(fields)
        })
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(typeOnly, profile: .diagnosticSix) }
    }

}
