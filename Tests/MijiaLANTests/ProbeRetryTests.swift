import Foundation
import Observation
import Synchronization
import Testing
import MijiaCore
@testable import MijiaLAN

struct ProbeRetryPolicyTests {
    private func device(_ id: String) -> LocalDevice {
        LocalDevice(did: id, name: id, model: "dmaker.fan.p28", host: id, token: String(repeating: "0", count: 32))
    }

    @Test("Every exponential interval and jitter boundary stays within 20 seconds and 24 hours")
    func intervals() {
        let policy = ProbeRetryPolicy()
        let expected: [Double] = [20, 40, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20480, 40960, 81920, 86400]
        for (index, value) in expected.enumerated() {
            #expect(policy.interval(afterFailures: index + 1, jitter: 1) == value)
            for jitter in [0.9, 1.1] {
                let interval = policy.interval(afterFailures: index + 1, jitter: jitter)
                #expect(interval >= 20 && interval <= 86400)
            }
        }
        #expect(policy.interval(afterFailures: 1_000_000, jitter: 1) == 86400)
    }

    @Test("Startup caps concurrency at eight; background caps at four and manual retries jump the queue")
    func concurrencyAndPriority() throws {
        var scheduler = ProbeScheduler()
        let now = Date(timeIntervalSince1970: 0)
        let devices = (0..<12).map { device(String($0)) }
        _ = scheduler.configure(devices)
        var running = scheduler.startReady(now: now)
        #expect(running.count == 8)
        #expect(scheduler.startReady(now: now).isEmpty)
        for job in running { scheduler.complete(job, succeeded: true, now: now, jitter: 1) }
        running = scheduler.startReady(now: now)
        #expect(running.count == 4)
        for job in running { scheduler.complete(job, succeeded: true, now: now, jitter: 1) }
        for device in devices { scheduler.markOffline(device.did, now: now) }
        running = scheduler.startReady(now: now)
        #expect(running.count == 4)
        scheduler.enqueue("11", priority: .manual)
        scheduler.complete(try #require(running.first), succeeded: false, now: now, jitter: 1)
        let next = scheduler.startReady(now: now)
        #expect(next.map(\.device.did) == ["11"])
        #expect(next.first?.priority == .manual)
    }

    @Test("Discovery failure advances existing backoff, authenticated recovery resets it, restart starts fresh")
    func recoveryAndRestart() throws {
        var scheduler = ProbeScheduler()
        let now = Date(timeIntervalSince1970: 0)
        _ = scheduler.configure([device("1")])
        let first = try #require(scheduler.startReady(now: now).first)
        scheduler.complete(first, succeeded: false, now: now, jitter: 1)
        #expect(scheduler.retryStates["1"]?.consecutiveFailures == 1)
        #expect(scheduler.startReady(now: now.addingTimeInterval(19)).isEmpty)
        scheduler.enqueue("1", priority: .discovery)
        let discovery = try #require(scheduler.startReady(now: now.addingTimeInterval(1)).first)
        scheduler.complete(discovery, succeeded: false, now: now.addingTimeInterval(1), jitter: 1)
        #expect(scheduler.retryStates["1"]?.consecutiveFailures == 2)
        #expect(scheduler.retryStates["1"]?.nextRetryAt == now.addingTimeInterval(41))
        scheduler.enqueue("1", priority: .manual)
        let manual = try #require(scheduler.startReady(now: now.addingTimeInterval(2)).first)
        scheduler.complete(manual, succeeded: true, now: now, jitter: 1)
        #expect(scheduler.retryStates["1"] == ProbeRetryState())
        #expect(scheduler.nextDeadline == nil)
        var restarted = ProbeScheduler()
        _ = restarted.configure([device("1")])
        #expect(restarted.startReady(now: now).count == 1)
        #expect(restarted.retryStates["1"]?.consecutiveFailures == 0)
    }

    @Test("Endpoint generation rejects late A to B to A results and removed devices are pruned", arguments: ["host", "token", "model"])
    func generations(change: String) throws {
        var scheduler = ProbeScheduler()
        let original = device("1")
        let now = Date(timeIntervalSince1970: 0)
        _ = scheduler.configure([original])
        let old = try #require(scheduler.startReady(now: now).first)
        var changed = original
        switch change {
        case "host": changed.host = "other-host"
        case "token": changed.token = String(repeating: "1", count: 32)
        default: changed.model = "cuco.plug.v3"
        }
        #expect(scheduler.configure([changed]) == [old.id])
        _ = scheduler.configure([original])
        let fresh = try #require(scheduler.startReady(now: now).first)
        let accepted = scheduler.complete(old, succeeded: true, now: now, jitter: 1)
        #expect(!accepted)
        #expect(scheduler.isCurrent(fresh))
        #expect(scheduler.configure([]) == [fresh.id])
        #expect(scheduler.retryStates.isEmpty && scheduler.nextDeadline == nil)
    }

    @Test("Thirty offline minutes use seven rounds instead of ninety, without waiting in real time")
    func thirtyMinuteSimulation() throws {
        var scheduler = ProbeScheduler()
        _ = scheduler.configure([device("1")])
        var now = Date(timeIntervalSince1970: 0)
        var rounds = 0
        while now.timeIntervalSince1970 < 1800 {
            for job in scheduler.startReady(now: now) {
                rounds += 1
                scheduler.complete(job, succeeded: false, now: now, jitter: 1)
            }
            now = try #require(scheduler.nextDeadline)
        }
        #expect(rounds == 7)
        #expect(Double(rounds) / 90 < 0.3)
        print("OFFLINE_30M_SIMULATION old_rounds=90 new_rounds=\(rounds) reduction_percent=\(100 * (1 - Double(rounds) / 90))")
    }
}

struct ProbeSchedulingIntegrationTests {
    @Test("The injected timer retries exactly once per round, and passive device-list reads do not reset backoff")
    func timerAndPassiveReads() async throws {
        let fixture = ProbeFixture()
        await fixture.transport.setSilent(true, host: "1")
        _ = try await fixture.api.deviceList()
        #expect(await fixture.api.retryStates()["1"]?.consecutiveFailures == 1)
        #expect(await fixture.transport.packetCount("1") == 2) // MiioClient retries twice inside this one round.
        for _ in 0..<10 { _ = try await fixture.api.deviceList() }
        #expect(await fixture.transport.packetCount("1") == 2)
        fixture.clock.advance(by: 20)
        try await eventually { await fixture.api.retryStates()["1"]?.consecutiveFailures == 2 }
        #expect(await fixture.transport.packetCount("1") == 4)
        #expect(await fixture.api.retryStates()["1"]?.nextRetryAt == fixture.clock.now.addingTimeInterval(40))
        await fixture.api.shutdown()
        #expect(fixture.clock.pendingSleeps == 0)
    }

    @Test("Two manual callers join one active probe and discovery authenticates before reporting online")
    func joinedManualAndDiscovery() async throws {
        let fixture = ProbeFixture()
        await fixture.transport.setSilent(true, host: "1")
        _ = try await fixture.api.deviceList()
        await fixture.transport.setSilent(false, host: "1")
        await fixture.transport.hold("1")
        let first = Task { await fixture.api.retryDevice(did: "1") }
        try await eventually { await fixture.transport.heldCount > 0 }
        let second = Task { await fixture.api.retryDevice(did: "1") }
        await Task.yield()
        let before = await fixture.transport.packetCount("1")
        await fixture.transport.release("1")
        await first.value; await second.value
        #expect(await fixture.transport.packetCount("1") == before + 1) // the single authenticated info request
        #expect(await fixture.api.currentHealth()["1"]?.state == .online)
        #expect(await fixture.api.retryStates()["1"] == ProbeRetryState())
        await fixture.transport.setSilent(true, host: "1")
        await fixture.api.retryDevice(did: "1")
        let failures = await fixture.api.retryStates()["1"]?.consecutiveFailures
        await fixture.api.retryDiscoveredDevices(["1"])
        try await eventually { await fixture.api.retryStates()["1"]?.consecutiveFailures == (failures ?? 0) + 1 }
        #expect(await fixture.api.currentHealth()["1"]?.state == .offline)
        await fixture.transport.setSilent(false, host: "1")
        await fixture.api.retryDiscoveredDevices(["1"])
        try await eventually { await fixture.api.currentHealth()["1"]?.state == .online }
        await fixture.api.shutdown()
    }

    @Test("Replacing a blocked endpoint ignores its late reply, cancels old jobs, and allows the new endpoint")
    func staleNetworkReply() async throws {
        let fixture = ProbeFixture()
        await fixture.transport.hold("1")
        await fixture.api.startProbing()
        try await eventually { await fixture.transport.heldCount > 0 }
        fixture.config.update { $0.devices[0].host = "2" }
        await fixture.api.startProbing()
        try await eventually { await fixture.api.currentHealth()["1"]?.state == .online }
        await fixture.transport.release("1")
        for _ in 0..<20 { await Task.yield() }
        #expect(await fixture.api.currentHealth()["1"]?.state == .online)
        #expect(await fixture.api.retryStates()["1"] == ProbeRetryState())
        fixture.config.update { $0.devices = [] }
        await fixture.api.startProbing()
        #expect(await fixture.api.currentHealth().isEmpty)
        #expect(await fixture.api.retryStates().isEmpty)
        await fixture.api.shutdown()
    }

    @Test("Cancelling a retry waiter leaves shared work intact and shutdown cancels its timer")
    func cancellation() async throws {
        let fixture = ProbeFixture()
        await fixture.transport.hold("1")
        let request = Task { await fixture.api.retryDevice(did: "1") }
        try await eventually { await fixture.transport.heldCount > 0 }
        request.cancel()
        await request.value
        await fixture.transport.release("1")
        try await eventually { await fixture.api.currentHealth()["1"]?.state == .online }
        await fixture.api.shutdown()
    }

    @Test("An online startup device is read before an unrelated blocked probe completes")
    @MainActor
    func independentOnlineReads() async throws {
        let fixture = ProbeFixture(includeSecond: true)
        await fixture.transport.hold("2")
        let controller = DeviceController(api: fixture.api, config: { fixture.config.value })
        let refresh = Task { await controller.refreshNow() }
        try await eventually { await fixture.transport.methodCount("get_properties", host: "1") > 0 }
        #expect(await fixture.transport.heldCount > 0)
        await fixture.transport.release("2")
        await refresh.value
        #expect(controller.snapshots["1"]?.value("p:2:1") == .bool(true))
        controller.shutdown()
        await fixture.api.shutdown()
    }

    @Test("Timestamp-only refreshes retain accurate readings without publishing revisions or waking hidden views")
    @MainActor
    func semanticPublication() async throws {
        let fixture = ProbeFixture()
        let controller = DeviceController(api: fixture.api, config: { fixture.config.value })
        await controller.refreshNow()
        for _ in 0..<10 { await Task.yield() }
        let old = try #require(controller.snapshots["1"]?.readings["p:2:1"]?.updatedAt)
        let structure = controller.structureRevision, values = controller.valuesRevision
        let notices = Mutex(0)
        withObservationTracking { _ = controller.snapshots } onChange: { notices.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(2))
        await controller.refreshNow()
        #expect(controller.structureRevision == structure && controller.valuesRevision == values)
        #expect(controller.snapshots["1"]?.readings["p:2:1"]?.updatedAt ?? .distantPast > old)
        #expect(notices.withLock { $0 } == 0)
        var context = PollingContext(); context.panelVisible = true
        controller.setPollingContext(context)
        #expect(notices.withLock { $0 } == 1)
        controller.shutdown()
        await fixture.api.shutdown()
    }

    @Test("A late property read cannot overwrite readings from a replacement endpoint")
    @MainActor
    func stalePropertyRead() async throws {
        let fixture = ProbeFixture()
        let controller = DeviceController(api: fixture.api, config: { fixture.config.value })
        await controller.refreshNow()
        #expect(controller.snapshots["1"]?.value("p:2:1") == .bool(true))
        await fixture.transport.hold("1")
        let stale = Task { await controller.refreshNow() }
        try await eventually { await fixture.transport.heldCount > 0 }
        fixture.config.update { $0.devices[0].host = "2" }
        controller.reconcileConfiguration()
        await fixture.api.startProbing()
        try await eventually { controller.snapshots["1"]?.value("p:2:1") == .bool(false) }
        await fixture.transport.release("1")
        await stale.value
        #expect(controller.snapshots["1"]?.device.host == "2")
        #expect(controller.snapshots["1"]?.value("p:2:1") == .bool(false))
        controller.shutdown()
        await fixture.api.shutdown()
    }

    @Test("Language/spec changes rebuild derived data and preserve readings; removed or unknown models release snapshots")
    @MainActor
    func schemaInvalidation() async throws {
        let fixture = ProbeFixture()
        let controller = L10n.$overrideLanguage.withValue(.zhHans) {
            DeviceController(api: fixture.api, config: { fixture.config.value })
        }
        await controller.refreshNow()
        let before = try #require(controller.snapshots["1"])
        let structure = controller.structureRevision
        L10n.$overrideLanguage.withValue(.en) { controller.reconcileConfiguration() }
        let english = try #require(controller.snapshots["1"])
        #expect(controller.structureRevision > structure)
        #expect(english.readings == before.readings && english.health == before.health)
        #expect(english.capabilitiesByID["p:2:1"]?.title == "Power")
        #expect(english.coreSpec == english.schema.coreSpec)
        fixture.config.update { $0.devices[0].model = "unknown.model.without.schema"; $0.devices[0].specType = nil }
        controller.reconcileConfiguration()
        #expect(controller.snapshots.isEmpty)
        fixture.config.update { $0.devices = [] }
        controller.reconcileConfiguration()
        #expect(controller.synthesizedHome().devices.isEmpty)
        controller.shutdown()
        await fixture.api.shutdown()
    }

    @Test("Unchanged refreshes do not emit replacement homes to provider consumers")
    @MainActor
    func noDuplicateHomeEvents() async throws {
        let fixture = ProbeFixture()
        let controller = DeviceController(api: fixture.api, config: { fixture.config.value })
        await controller.refreshNow()
        let received = Mutex(0)
        let stream = controller.events()
        let consumer = Task {
            for await event in stream {
                if case .snapshotUpdated = event { received.withLock { $0 += 1 } }
            }
        }
        try await eventually { received.withLock { $0 } == 1 }
        for _ in 0..<20 { await controller.refreshNow() }
        for _ in 0..<10 { await Task.yield() }
        #expect(received.withLock { $0 } == 1)
        consumer.cancel()
        controller.shutdown()
        await fixture.api.shutdown()
    }
}

private struct ProbeFixture: Sendable {
    let clock: ManualProbeClock
    let config: ProbeConfig
    let transport: ProbeTestTransport
    let api: LANMiotAPI

    init(includeSecond: Bool = false) {
        clock = ManualProbeClock()
        let token = "00112233445566778899aabbccddeeff"
        var devices = [LocalDevice(did: "1", name: "Fan", model: "dmaker.fan.p28", host: "1", token: token)]
        if includeSecond { devices.append(LocalDevice(did: "2", name: "Fan 2", model: "dmaker.fan.p28", host: "2", token: token)) }
        config = ProbeConfig(LocalHomeConfig(devices: devices))
        let network = FakeMiioNetwork()
        network.add(host: "1", token: token, deviceID: 1, props: ["2.1": .bool(true), "8.1": .number(50)])
        network.add(host: "2", token: token, deviceID: 2, props: ["2.1": .bool(false), "8.1": .number(30)])
        transport = ProbeTestTransport(network: network, token: MiioToken.parse(token)!)
        let config = config
        api = LANMiotAPI(config: { config.value }, transport: transport, clock: clock.clock, jitter: { 1 })
    }
}

private final class ProbeConfig: Sendable {
    private let storage: Mutex<LocalHomeConfig>
    init(_ value: LocalHomeConfig) { storage = Mutex(value) }
    var value: LocalHomeConfig { storage.withLock { $0 } }
    func update(_ change: (inout LocalHomeConfig) -> Void) { storage.withLock { change(&$0) } }
}

private final class ManualProbeClock: Sendable {
    private struct Sleeper { var deadline: Date; var reply: CheckedContinuation<Void, any Error> }
    private struct State { var now = Date(timeIntervalSince1970: 0); var sleepers: [UUID: Sleeper] = [:] }
    private let state = Mutex(State())
    var now: Date { state.withLock { $0.now } }
    var pendingSleeps: Int { state.withLock { $0.sleepers.count } }
    var clock: ProbeClock { ProbeClock(now: { self.now }, sleep: { try await self.sleep($0) }) }
    func advance(by interval: TimeInterval) {
        let replies = state.withLock { state in
            state.now.addTimeInterval(interval)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.reply)
        }
        for reply in replies { reply.resume() }
    }
    private func sleep(_ deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    if Task.isCancelled { reply.resume(throwing: CancellationError()) }
                    else if deadline <= state.now { reply.resume() }
                    else { state.sleepers[id] = Sleeper(deadline: deadline, reply: reply) }
                }
            }
        } onCancel: {
            let reply = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.reply }
            reply?.resume(throwing: CancellationError())
        }
    }
}

private actor ProbeTestTransport: MiioTransport {
    let network: FakeMiioNetwork
    let token: Data
    private var silent: Set<String> = []
    private var holds: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var packets: [String: Int] = [:]
    private var methods: [String: [String]] = [:]
    init(network: FakeMiioNetwork, token: Data) { self.network = network; self.token = token }
    func setSilent(_ value: Bool, host: String) { if value { silent.insert(host) } else { silent.remove(host) } }
    func hold(_ host: String) { holds.insert(host) }
    var heldCount: Int { waiters.values.reduce(0) { $0 + $1.count } }
    func release(_ host: String) {
        holds.remove(host)
        for reply in waiters.removeValue(forKey: host) ?? [] { reply.resume() }
    }
    func packetCount(_ host: String) -> Int { packets[host] ?? 0 }
    func methodCount(_ method: String, host: String) -> Int { methods[host, default: []].filter { $0 == method }.count }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        packets[host, default: 0] += 1
        if packet != MiioPacket.hello {
            let (_, data) = try MiioPacket.decode(packet, token: token)
            let json = try JSONDecoder().decode(JSONValue.self, from: data.prefix { $0 != 0 })
            methods[host, default: []].append(json["method"]?.stringValue ?? "")
        }
        if holds.contains(host) { await withCheckedContinuation { waiters[host, default: []].append($0) } }
        if silent.contains(host) { throw MiioError.timeout }
        return try await network.exchange(packet, host: host, port: port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}

private func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw MiioError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}
