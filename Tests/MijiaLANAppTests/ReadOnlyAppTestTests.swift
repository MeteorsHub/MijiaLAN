import Foundation
import MijiaCore
import MijiaLAN
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import MijiaLAN
@testable import MijiaLANApp

#if DEBUG
private struct ReadOnlyLaunchFixture {
    let root: URL
    let seed: URL
    let device = LocalDevice(did: "123", name: "Private fixture name", model: CurtainValidationSession.model,
        host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-launch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        seed = root.appendingPathComponent("seed.json")
        try LocalHomeConfig(devices: [device]).encoded()!.write(to: seed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.path)
    }
    var environment: [String: String] {
        [ReadOnlyAppTest.flag: "1", "MIJIALAN_EPHEMERAL": "1", "MIJIALAN_SEED_CONFIG": seed.path,
         ReadOnlyAppTest.directoryKey: root.appendingPathComponent("new-log").path, ReadOnlyAppTest.durationKey: "14400"]
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private final class ReadOnlySessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.value } }, sleep: { delay in
        try Task.checkCancellation(); self.lock.withLock { self.value += delay }; await Task.yield()
    }) }
}
private actor ReadOnlyPreview: MiioTransport {
    private let preview = ControlCenterPreviewTransport(failReadback: false)
    private let fail: Bool
    private(set) var count = 0
    init(fail: Bool = false) { self.fail = fail }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        count += 1
        let reply = try await preview.exchange(packet, host: host, port: port, timeout: timeout)
        guard fail, packet != MiioPacket.hello else { return reply }
        let token = Data(repeating: 0, count: 16)
        let (_, requestBytes) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: requestBytes.prefix { $0 != 0 })
        guard case .object(let requestFields) = request, requestFields["method"] == .string("get_properties") else { return reply }
        let (header, responseBytes) = try MiioPacket.decode(reply, token: token)
        guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: responseBytes.prefix { $0 != 0 }),
              case .array(let rows) = fields["result"] else { return reply }
        fields["result"] = .array(rows.map { row in
            guard case .object(var entry) = row, entry["piid"] == .number(9) else { return row }
            entry["code"] = .number(-4004); entry["value"] = nil; return .object(entry)
        })
        return try MiioPacket.encode(Data(JSONValue.object(fields).compactJSONString.utf8) + [0], token: token, deviceID: header.deviceID, stamp: header.stamp)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        Issue.record("Read-only App test must not discover"); return []
    }
}

@MainActor struct ReadOnlyAppTestTests {
    @Test("Missing mode is inert; incomplete, conflicting or invalid flags reject before reading a seed")
    func gates() throws {
        #expect(try ReadOnlyAppTest.prepare([:]) == nil)
        #expect(try ReadOnlyAppTest.prepare(["MIJIALAN_EPHEMERAL": "1", "MIJIALAN_SEED_CONFIG": "/not-read"]) == nil)
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        for (key, value) in [(ReadOnlyAppTest.flag, "0"), ("MIJIALAN_EPHEMERAL", "0"),
                             (ReadOnlyAppTest.durationKey, "0"), (ReadOnlyAppTest.durationKey, "43201"),
                             (ReadOnlyAppTest.portKey, "0"), (ReadOnlyAppTest.portKey, "65536"),
                             ("MIJIALAN_UI_PREVIEW", "1"), ("MIJIALAN_SNAPSHOT", "/not-read")] {
            var env = f.environment; env[key] = value
            #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.prepare(env) }
        }
        var partial = f.environment; partial[ReadOnlyAppTest.flag] = nil
        #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.prepare(partial) }
        #expect(!FileManager.default.fileExists(atPath: f.environment[ReadOnlyAppTest.directoryKey]!))
    }
    @Test("A validated single-device 4-hour launch creates a fresh 0700 directory, isolated opt-in and explicit 10/30 settings")
    func validated() throws {
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        let prepared = try ReadOnlyAppTest.prepare(f.environment)
        let test = try #require(prepared)
        #expect(test.seconds == 14_400 && test.port == MiioPacket.port && test.config.devices.count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: test.directory.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let defaults = try #require(UserDefaults(suiteName: test.defaultsSuite))
        defer { defaults.removePersistentDomain(forName: test.defaultsSuite) }
        test.configure(defaults)
        #expect(defaults.stringArray(forKey: CurtainControlController.preferenceKey) == ["123"])
        #expect(DevicePollingIntervals.load(from: defaults) == .init(foregroundSeconds: 10, backgroundSeconds: 30))
        #expect(!defaults.bool(forKey: "homekit_bridge_enabled") && !defaults.bool(forKey: "matter.enabled"))
        #expect(defaults.dictionary(forKey: CurtainControlController.pausedKey) == nil)
        #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.prepare(f.environment) }
        let manifest = try String(contentsOf: test.directory.appendingPathComponent("plan.json"), encoding: .utf8)
        #expect(!manifest.contains(f.device.token) && !manifest.contains(f.device.name) && !manifest.contains(f.device.host))
    }
    @Test("Invalid, multiple-device, unsupported and insecure seeds never create logs or a fallback configuration")
    func invalidSeeds() throws {
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        var unsupported = f.device; unsupported.model = "other.model"
        for data in [Data("invalid".utf8), LocalHomeConfig().encoded()!,
                     LocalHomeConfig(devices: [f.device, f.device]).encoded()!, LocalHomeConfig(devices: [unsupported]).encoded()!] {
            try data.write(to: f.seed)
            #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.prepare(f.environment) }
        }
        try LocalHomeConfig(devices: [f.device]).encoded()!.write(to: f.seed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.seed.path)
        #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.prepare(f.environment) }
        #expect(!FileManager.default.fileExists(atPath: f.environment[ReadOnlyAppTest.directoryKey]!))
    }
    @Test("A private FIFO supplies fake credentials once; no writer times out and symlinks are rejected")
    func fifo() async throws {
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        let fifo = f.root.appendingPathComponent("seed.fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let data = f.configData
        let writer = Task.detached {
            await withCheckedContinuation { continuation in DispatchQueue.global().async {
                let fd = open(fifo, O_WRONLY)
                if fd >= 0 { _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }; close(fd) }
                continuation.resume()
            } }
        }
        let actual = try ReadOnlyAppTest.readSeed(fifo, timeout: 1)
        await writer.value
        #expect(actual == data)
        let start = ContinuousClock.now
        #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.readSeed(fifo, timeout: 0.05) }
        #expect(start.duration(to: .now) < .seconds(1))
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.seed)
        #expect(throws: ReadOnlyAppTest.Rejected.self) { try ReadOnlyAppTest.readSeed(link.path, timeout: 0.1) }
    }
    @Test("The actual controller rejects position/open/close/stop and the API refuses writes/actions before sending")
    func writeBarriers() async throws {
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        let prepared = try ReadOnlyAppTest.prepare(f.environment)
        let test = try #require(prepared), network = ReadOnlyPreview()
        let journal = DeviceEventLog(fileURL: test.directory.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        let api = LANMiotAPI(config: { test.config }, transport: network, curtainEvents: journal, allowsDeviceWrites: false)
        let defaults = try #require(UserDefaults(suiteName: test.defaultsSuite)); test.configure(defaults)
        defer { defaults.removePersistentDomain(forName: test.defaultsSuite) }
        let clock = ReadOnlySessionClock()
        let scheduler = CurtainRequestScheduler(clock: clock.clock)
        let curtains = CurtainControlController(api: api, defaults: defaults, readOnly: true, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        curtains.reconcile(test.config.devices)
        for command in [CurtainControlSession.Command.position(64), .open, .close, .stop] { #expect(!curtains.send("123", command)) }
        await #expect(throws: (any Error).self) { try await api.setProps([MiotPropWrite(did: "123", siid: 2, piid: 4, value: .number(64))]) }
        await #expect(throws: (any Error).self) { try await api.action(MiotActionCall(did: "123", siid: 2, aiid: 1, inputs: [])) }
        await #expect(throws: (any Error).self) { try await api.beginCurtainValidation(did: "123") }
        #expect(await network.count == 0)
        let devices = DeviceController(api: api, config: { test.config }, pollingDefaults: defaults)
        devices.refreshCurtains = { await curtains.pollConfigured() }
        await devices.refreshNow()
        #expect(curtains.states["123"]?.position == 29)
        let session = try await api.beginCurtainControl(did: "123")
        await #expect(throws: (any Error).self) { try await session.manual(.position(64)) }
        #expect(!journal.snapshot().contains { $0.kind == .write || $0.kind == .action })
        await curtains.shutdownAndWait(); devices.shutdown(); await api.shutdown(); journal.flush()
        let before = await network.count
        await devices.refreshNow()
        #expect(await network.count == before)
        let reopened = DeviceEventLog(fileURL: test.directory.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        #expect(reopened.snapshot().contains { $0.outcome == .sample && $0.position == 29 && $0.scope == .experiment })
    }
    @Test("A bounded deadline completes once; failure from the real unified poll closes and retains the paused log")
    func lifetimeAndFailure() async throws {
        var reasons: [DeviceEventLog.Reason] = []
        let deadline = ReadOnlyAppTestLifetime(seconds: 1) { reasons.append($0) }
        try await Task.sleep(for: .milliseconds(1_100))
        await deadline.stop(.propertyError)
        #expect(reasons == [.deadline] && deadline.finished)
        let f = try ReadOnlyLaunchFixture(); defer { f.remove() }
        let prepared = try ReadOnlyAppTest.prepare(f.environment)
        let test = try #require(prepared), network = ReadOnlyPreview(fail: true)
        let journal = DeviceEventLog(fileURL: test.directory.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        let api = LANMiotAPI(config: { test.config }, transport: network, curtainEvents: journal, allowsDeviceWrites: false)
        let defaults = try #require(UserDefaults(suiteName: test.defaultsSuite)); test.configure(defaults)
        defer { defaults.removePersistentDomain(forName: test.defaultsSuite) }
        let clock = ReadOnlySessionClock(), scheduler = CurtainRequestScheduler(clock: clock.clock)
        let curtains = CurtainControlController(api: api, defaults: defaults, readOnly: true, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        curtains.reconcile(test.config.devices)
        let devices = DeviceController(api: api, config: { test.config }, pollingDefaults: defaults)
        let lifetime = ReadOnlyAppTestLifetime(seconds: 30) { reason in
            reasons.append(reason); await curtains.shutdownAndWait()
        }
        devices.refreshCurtains = {
            await curtains.pollConfigured()
            if let reason = curtains.pausedPolling.values.first { await lifetime.stop(reason) }
        }
        await devices.refreshNow()
        #expect(lifetime.finished && reasons == [.deadline, .propertyError])
        let before = await network.count
        for _ in 0..<3 { await devices.refreshNow() }
        #expect(await network.count == before)
        devices.shutdown(); await api.shutdown(); journal.flush()
        let reopened = DeviceEventLog(fileURL: test.directory.appendingPathComponent("traffic.jsonl"), scope: .experiment)
        #expect(reopened.snapshot().contains { $0.code == -4004 })
        #expect(!reopened.snapshot().contains { $0.kind == .write && $0.outcome == .sent })
    }
}
private extension ReadOnlyLaunchFixture { var configData: Data { LocalHomeConfig(devices: [device]).encoded()! } }

#else
struct ReadOnlyAppTestReleaseTests {
    @Test("Release rejects explicit read-only test options")
    func disabled() {
        #expect(throws: ReadOnlyAppTest.Rejected.self) {
            try ReadOnlyAppTest.prepare([ReadOnlyAppTest.flag: "1", "MIJIALAN_EPHEMERAL": "1"])
        }
    }
}
#endif
