import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class JournalTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.value } }, sleep: { delay in
        try Task.checkCancellation(); self.lock.withLock { self.value += delay }; await Task.yield()
    }) }
    func advanceHours() { lock.withLock { value += .seconds(86_400) } }
}
private struct JournalTransport: MiioTransport {
    let network: FakeMiioNetwork
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func exchangeObserved(_ packet: Data, host: String, port: UInt16, timeout: Duration, onSent: @escaping @Sendable () -> Void) async throws -> Data {
        onSent() // Simulated socket acceptance only; every test journal is marked offlineTest.
        return try await exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        try await network.broadcast(packet, port: port, duration: duration, rounds: rounds)
    }
}
struct DeviceCommunicationJournalTests {
    private let token = "00112233445566778899aabbccddeeff"
    private func device() -> LocalDevice {
        LocalDevice(did: "987654321", name: "private-name-not-for-logs", model: CurtainValidationSession.model,
                    host: "192.0.2.123", token: token, specType: CurtainValidationSession.specification)
    }
    private func setup(_ journal: DeviceEventLog) throws -> (FakeMiioNetwork, FakeMiioNetwork.Device, CurtainControlSession, JournalTime) {
        let device = device(), network = FakeMiioNetwork(), time = JournalTime()
        let fake = network.add(host: device.host, token: token, deviceID: UInt32(device.did)!, props: [
            "2.2": .number(1), "2.3": .number(29), "2.4": .number(29), "2.5": .bool(false), "2.9": .number(0), "2.10": .bool(false)])
        fake.model = device.model; fake.firmware = "1.1.3"; fake.simulateCurtainMovement = true
        journal.registerDevices([device])
        let client = MiioClient(host: device.host, token: try #require(MiioToken.parse(token)), transport: JournalTransport(network: network), knownModel: device.model)
        let session = CurtainControlSession(device: device, client: client, scheduler: CurtainRequestScheduler(clock: time.clock), clock: time.clock, isCurrent: { true }, journal: journal)
        return (network, fake, session, time)
    }
    @Test("One explicit cold position command has one preflight, one write and bounded readback, then stays silent for a simulated day")
    func successfulManualFlow() async throws {
        let journal = DeviceEventLog(scope: .offlineTest)
        let (network, fake, session, time) = try setup(journal)
        #expect(network.exchangeCount == 0)
        let operation = UUID()
        let result = try await session.manual(.position(64), operationID: operation)
        #expect(result.confirmed && result.position == 64 && result.motorStatus == 1)
        #expect(fake.receivedMethods == ["miIO.info", "get_properties", "set_properties", "get_properties"])
        #expect(fake.receivedWrites.count == 1)
        let count = network.exchangeCount
        time.advanceHours(); for _ in 0..<100 { await Task.yield() }
        #expect(network.exchangeCount == count)
        let rows = journal.snapshot()
        #expect(rows.allSatisfy { $0.operation == operation && $0.scope == .offlineTest })
        #expect(rows.contains { $0.source == .manualPosition && $0.stage == .write && $0.outcome == .sent && $0.target == 64 })
        #expect(rows.contains { $0.source == .postWriteRead && $0.outcome == .sample && $0.position == 64 && $0.motorStatus == 1 })
        #expect(rows.contains { $0.outcome == .acknowledged && $0.code == 0 })
        #expect(rows.contains { $0.outcome == .confirmed })
        #expect(rows.contains { $0.outcome == .received && $0.elapsedMilliseconds != nil })
    }
    @Test("A readback property failure records its code and stage, expires the old sample, and never retries a write or read")
    func failedReadback() async throws {
        let journal = DeviceEventLog(scope: .offlineTest)
        let (network, fake, session, time) = try setup(journal)
        fake.failCurtainReadback = true
        let operation = UUID()
        await #expect(throws: (any Error).self) { try await session.manual(.position(64), operationID: operation) }
        let state = await session.snapshot()
        #expect(state.phase == .unconfirmed && state.stage == .confirmation && state.failureReason == .propertyError)
        #expect(state.position == nil && state.motorStatus == nil)
        #expect(state.lastKnownPosition == 29 && state.lastKnownMotorStatus == 1)
        #expect(state.writeAccepted && !state.confirmed && state.message != nil)
        let before = network.exchangeCount
        time.advanceHours(); for _ in 0..<100 { await Task.yield() }
        await #expect(throws: (any Error).self) { try await session.refresh() }
        #expect(network.exchangeCount == before && fake.receivedWrites.count == 1)
        let rows = journal.snapshot()
        #expect(rows.contains { $0.source == .postWriteRead && $0.code == -4004 })
        #expect(rows.contains { $0.stage == .confirmation && $0.reason == .propertyError && $0.outcome == .paused })
        #expect(!rows.contains { $0.outcome == .confirmed })
    }
    @Test("Cold handshake timeout sends no write and leaves no automatic recovery operation")
    func coldTimeout() async throws {
        let journal = DeviceEventLog(scope: .offlineTest)
        let (network, fake, session, time) = try setup(journal)
        fake.offline = true
        await #expect(throws: (any Error).self) { try await session.manual(.position(64)) }
        #expect(network.exchangeCount == 1 && fake.receivedWrites.isEmpty)
        let state = await session.snapshot()
        #expect(state.stage == .hello && state.failureReason == .timeout && state.message != nil)
        time.advanceHours(); for _ in 0..<100 { await Task.yield() }
        #expect(network.exchangeCount == 1)
    }
    @Test("Invalid scalar samples are rejected with an explicit reason and never copied into the journal")
    func invalidReadingPrivacy() async throws {
        let journal = DeviceEventLog(scope: .offlineTest)
        let (_, fake, session, _) = try setup(journal)
        fake.props["2.3"] = .string("private-invalid-value-never-log")
        await #expect(throws: (any Error).self) { try await session.manual() }
        #expect(await session.snapshot().failureReason == .untrustedReading)
        #expect(!journal.exportText().contains("private-invalid-value-never-log"))
        #expect(fake.receivedWrites.isEmpty)
    }

    @Test("Reported all-14 batch and individual responses remain untrusted; code-zero position alone cannot authorize a write")
    func repeatedFourteen() async throws {
        let url = try #require(Bundle.module.url(forResource: "dooya-repeated-value-2026-11-08", withExtension: "json"))
        struct Fixture: Decodable { let batch: JSONValue; let singleResponses: [[JSONValue]] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(fixture.batch) }
        let individualRows = fixture.singleResponses.flatMap { $0 }
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(individualRows)) }
        let positionOnly = individualRows.filter { $0["piid"] == .number(3) }
        #expect(throws: (any Error).self) { try CurtainControlSession.preflight(.array(positionOnly)) }
        let journal = DeviceEventLog(scope: .offlineTest)
        let (_, fake, session, _) = try setup(journal)
        for piid in [2,3,4,5,9,10] { fake.props["2.\(piid)"] = .number(14) }
        await #expect(throws: (any Error).self) { try await session.manual(.position(19)) }
        let state = await session.snapshot()
        #expect(state.failureReason == .untrustedReading && state.stage == .preflight)
        #expect(!state.writeAttempted && state.writeSent == false && !state.writeAccepted)
        #expect(state.position == nil && fake.receivedWrites.isEmpty)
        #expect(journal.snapshot().contains { $0.outcome == .noPacket && $0.stage == .write && $0.reason == .untrustedReading && $0.writeAttempted == false })
        #expect(!journal.snapshot().contains { $0.stage == .write && ($0.outcome == .attempt || $0.outcome == .sent) })
        #expect(journal.snapshot().filter { $0.outcome == .observedValue && $0.value == 14 }.count == 6)
    }

    @Test("Code-zero target-zero acknowledgement is not motion completion; synthetic unchanged position remains unconfirmed")
    func acknowledgementIsNotMotion() async throws {
        let journal = DeviceEventLog(scope: .offlineTest)
        let (_, fake, session, _) = try setup(journal)
        // 29 is a synthetic fixture only; the supervised field write's initial physical position was unknown.
        fake.simulateCurtainMovement = false
        await #expect(throws: (any Error).self) { try await session.manual(.position(0)) }
        let state = await session.snapshot()
        #expect(state.writeAccepted && !state.confirmed && state.writeAttempted)
        #expect(fake.receivedWrites.count == 1)
        #expect(journal.snapshot().contains { $0.outcome == .acknowledged && $0.code == 0 && $0.target == 0 })
        #expect(!journal.snapshot().contains { $0.outcome == .confirmed })
        #expect(journal.snapshot().contains { $0.outcome == .paused && $0.writeAcknowledged == true && $0.writeSent == true })
    }

    @Test("Successful and failed flows survive close/reopen and local export without triggering network traffic")
    func persistedAndPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let journal = DeviceEventLog(fileURL: file, scope: .offlineTest)
        let (network, fake, session, _) = try setup(journal)
        _ = try await session.manual(.position(64))
        fake.failCurtainReadback = true
        await #expect(throws: (any Error).self) { try await session.manual(.position(80)) }
        journal.flush()
        let count = network.exchangeCount
        let reopened = DeviceEventLog(fileURL: file, scope: .offlineTest)
        let exported = reopened.exportData()
        let rows = try decode(exported)
        #expect(rows.contains { $0.outcome == .confirmed && $0.position == 64 })
        #expect(rows.contains { $0.outcome == .paused && $0.code == -4004 })
        let text = String(decoding: exported, as: UTF8.self)
        for secret in [token, device().host, device().did, device().name, "AA:BB:CC:00:11:22", "fw_ver", "get_properties"] { #expect(!text.contains(secret)) }
        #expect(network.exchangeCount == count)
        let destination = directory.appendingPathComponent("export.jsonl")
        try exported.write(to: destination)
        #expect(try Data(contentsOf: destination) == exported)
        #expect(network.exchangeCount == count)
    }
    @Test("Rolling traffic files are bounded and do not erase separately retained control/error history")
    func boundedRollingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let journal = DeviceEventLog(fileURL: file, maxEvents: 8, scope: .offlineTest, fileLimit: 2_048)
        journal.record("private-identifier", source: .manualPosition, stage: .write, outcome: .acknowledged, target: 64)
        journal.flush()
        // Deliberately prime the exact URL's resource cache before repeated appends/rotations.
        _ = try file.resourceValues(forKeys: [.fileSizeKey])
        // A persisted event from a prior day is not removed by an age cutoff.
        let criticalFile = file.appendingPathExtension("important")
        let bytes = try Data(contentsOf: criticalFile)
        var row = try #require(JSONSerialization.jsonObject(with: Data(bytes.split(separator: 10)[0])) as? [String: Any])
        row["timestamp"] = "2020-01-01T00:00:00Z"
        var older = try JSONSerialization.data(withJSONObject: row); older.append(10)
        try older.write(to: criticalFile)
        for _ in 0..<200 { journal.record("private-identifier", source: .backgroundPoll, stage: .preflight, outcome: .received) }
        journal.flush()
        #expect(journal.snapshot().count == 8)
        let reopened = DeviceEventLog(fileURL: file, maxEvents: 8, scope: .offlineTest, fileLimit: 2_048)
        #expect(try decode(reopened.exportData()).contains { $0.source == .manualPosition && $0.target == 64 && $0.timestamp < Date().addingTimeInterval(-86_400) })
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count <= 8)
        for url in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try #require((attributes[.size] as? NSNumber)?.uint64Value)
            #expect(size <= 2_048)
            #expect(try UInt64(Data(contentsOf: url).count) == size)
        }
    }
    @Test("A file grown past the load bound is rejected even when the reused URL cached its earlier small size")
    func freshSizeBeforeLoading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let journal = DeviceEventLog(fileURL: file, scope: .offlineTest)
        // Background traffic does not create a separate important file for this load-bound test.
        journal.record("private-key", source: .backgroundPoll, stage: .preflight, outcome: .received)
        journal.flush()
        let initialSize = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(initialSize < 4_195_329)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 4_195_329)
        try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? NSNumber)?.uint64Value == 4_195_329)
        let reopened = DeviceEventLog(fileURL: file, scope: .offlineTest)
        #expect(reopened.snapshot().isEmpty)
        #expect(reopened.exportData().isEmpty)
    }

    @Test("A background failure retains its request/sent context in the critical archive after ordinary traffic rotates")
    func backgroundFailureContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let journal = DeviceEventLog(fileURL: file, maxEvents: 8, scope: .offlineTest, fileLimit: 2_048)
        let operation = UUID()
        journal.record("private-key", operation: operation, source: .backgroundPoll, stage: .preflight, outcome: .attempt, kind: .read)
        journal.record("private-key", operation: operation, source: .backgroundPoll, stage: .preflight, outcome: .sent, kind: .read)
        journal.record("private-key", operation: operation, source: .backgroundPoll, stage: .preflight, outcome: .responseCode, code: -4004, kind: .read, siid: 2, piid: 3)
        for _ in 0..<200 { journal.record("private-key", source: .backgroundPoll, stage: .preflight, outcome: .received) }
        journal.flush()
        let reopened = DeviceEventLog(fileURL: file, maxEvents: 8, scope: .offlineTest, fileLimit: 2_048)
        let rows = try decode(reopened.exportData()).filter { $0.operation == operation }
        #expect(rows.contains { $0.outcome == .sent })
        #expect(rows.contains { $0.code == -4004 })
    }

    @Test("Generic info, properties, writes, actions, legacy commands and discovery are captured with source and without raw secrets")
    func allCommunicationKinds() async throws {
        let journal = DeviceEventLog(scope: .offlineTest), network = FakeMiioNetwork()
        let device = LocalDevice(did: "987654321", name: "private-name", model: "yeelink.light.fake1", host: "192.0.2.123", token: token)
        journal.registerDevices([device])
        let fake = network.add(host: device.host, token: token, deviceID: 987654321, props: ["2.1": .bool(true)])
        let client = MiioClient(host: device.host, token: try #require(MiioToken.parse(token)), transport: JournalTransport(network: network), events: journal, eventIdentifier: device.did)
        _ = try await client.info()
        _ = try await client.readProperties(did: device.did, [(2,1)])
        try await DeviceCommunicationContext.$source.withValue(.homeKit) { try await client.setProperties([MiotPropWrite(did: device.did, siid: 2, piid: 1, value: .bool(false))]) }
        try await DeviceCommunicationContext.$source.withValue(.matter) { try await client.action(MiotActionCall(did: device.did, siid: 2, aiid: 1)) }
        fake.legacyProps = ["power": .string("on")]
        _ = try await client.call("get_prop", params: .array([.string("power")]))
        _ = try await client.call("set_power", params: .array([.string("off")]))
        _ = try await MiioDiscovery.discover(duration: .milliseconds(1), transport: JournalTransport(network: network), events: journal)
        await #expect(throws: (any Error).self) { try await client.call("secret-method-never-log", params: .string("secret-parameters-never-log")) }
        let events = journal.snapshot()
        for kind in [DeviceEventLog.Kind.hello, .info, .read, .write, .action, .legacyRead, .legacyWrite, .broadcast, .other] {
            #expect(events.contains { $0.kind == kind })
        }
        #expect(events.contains { $0.source == .homeKit && $0.kind == .write })
        #expect(events.contains { $0.source == .matter && $0.kind == .action })
        #expect(events.contains { $0.source == .discovery && $0.outcome == .received })
        let text = journal.exportText()
        for secret in [token, device.host, device.did, device.name, "AA:BB:CC:00:11:22", "secret-method-never-log", "secret-parameters-never-log"] { #expect(!text.contains(secret)) }
    }
    @Test("A configured curtain disables default discovery and generic probes even when control is not enabled")
    func startupAndIdleSilence() async throws {
        let device = device(), network = FakeMiioNetwork(), journal = DeviceEventLog(scope: .offlineTest)
        network.add(host: device.host, token: token, deviceID: 987654321)
        let config = LocalHomeConfig(devices: [device])
        #expect(!DeviceLANPolicy.allowsAutomaticDiscovery(for: config.devices))
        #expect(DeviceLANPolicy.allowsAutomaticDiscovery(for: []))
        let api = LANMiotAPI(config: { config }, transport: network, curtainEvents: journal)
        for _ in 0..<3 { await api.startProbing(); _ = try await api.deviceList(); await api.retryDevice(did: device.did) }
        #expect(network.exchangeCount == 0)
        #expect(await api.retryStates().isEmpty)
        #expect(journal.snapshot().allSatisfy { $0.outcome == .noPacket })
        await api.shutdown()
    }
    private func decode(_ data: Data) throws -> [DeviceEventLog.Event] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 10).map { try decoder.decode(DeviceEventLog.Event.self, from: Data($0)) }
    }
}
