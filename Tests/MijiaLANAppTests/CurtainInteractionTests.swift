import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN
@testable import MijiaLANApp

private final class InteractionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    var clock: CurtainValidationSession.Clock { .init(now: { self.lock.withLock { self.value } }, sleep: { delay in
        try Task.checkCancellation(); self.lock.withLock { self.value += delay }; await Task.yield()
    }) }
}
/// Holds exactly one already-started read. Releasing it can produce either a valid or poisoned reply.
private actor InteractionTransport: MiioTransport {
    private let preview = ControlCenterPreviewTransport(failReadback: false)
    private var holdRead = false
    private var held: CheckedContinuation<Void, Never>?
    private var poison = false
    private var externalPosition: Int?
    private(set) var methods: [String] = []
    private(set) var writes: [JSONValue] = []
    var isHeld: Bool { held != nil }
    func holdNextRead(poison: Bool = false, position: Int? = nil) {
        holdRead = true; self.poison = poison; externalPosition = position
    }
    func release() { let pending = held; held = nil; pending?.resume() }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if packet == MiioPacket.hello { return try await preview.exchange(packet, host: host, port: port, timeout: timeout) }
        let token = Data(repeating: 0, count: 16)
        let (_, body) = try MiioPacket.decode(packet, token: token)
        guard case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 }) else { throw MiioError.malformedPacket }
        let method = request["method"]?.stringValue ?? ""
        methods.append(method)
        if method == "set_properties", case .array(let values) = request["params"] { writes += values }
        let wasHeld = method == "get_properties" && holdRead
        if wasHeld { holdRead = false; await withCheckedContinuation { held = $0 } }
        let response = try await preview.exchange(packet, host: host, port: port, timeout: timeout)
        guard wasHeld, poison || externalPosition != nil else { return response }
        let (_, responseBody) = try MiioPacket.decode(response, token: token)
        guard case .object(var reply) = try JSONDecoder().decode(JSONValue.self, from: responseBody.prefix { $0 != 0 }),
              case .array(let rows) = reply["result"] else { throw MiioError.malformedPacket }
        reply["result"] = .array(rows.map { row in
            guard case .object(var fields) = row else { return row }
            if poison { fields["value"] = .number(14) }
            else if fields["piid"] == .number(3) || fields["piid"] == .number(4) { fields["value"] = .number(Double(externalPosition!)) }
            return .object(fields)
        })
        poison = false; externalPosition = nil
        return try MiioPacket.encode(Data(JSONValue.object(reply).compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}

@MainActor struct CurtainInteractionTests {
    private let did = "123"
    @MainActor private struct Fixture {
        let controller: CurtainControlController
        let api: LANMiotAPI
        let transport: InteractionTransport
        let defaults: UserDefaults
        let suite: String
        func stop() async { controller.shutdown(); await api.shutdown(); defaults.removePersistentDomain(forName: suite) }
    }
    private func make() async throws -> Fixture {
        let suite = "curtain-interaction-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let device = LocalDevice(did: did, name: "Simulated", model: CurtainValidationSession.model,
            host: "192.0.2.12", token: String(repeating: "0", count: 32), specType: CurtainValidationSession.specification)
        let config = LocalHomeConfig(devices: [device]), transport = InteractionTransport()
        let api = LANMiotAPI(config: { config }, transport: transport, curtainEvents: DeviceEventLog(scope: .offlineTest))
        let clock = InteractionClock(), scheduler = CurtainRequestScheduler(clock: clock.clock)
        let controller = CurtainControlController(api: api, defaults: defaults, makeSession: {
            try await api.beginCurtainControl(did: $0, scheduler: scheduler, clock: clock.clock)
        })
        controller.reconcile([device]); controller.read(did)
        try await idle(controller)
        #expect(controller.states[did]?.position == 29)
        return Fixture(controller: controller, api: api, transport: transport, defaults: defaults, suite: suite)
    }
    private func idle(_ controller: CurtainControlController) async throws {
        let deadline = Date().addingTimeInterval(3)
        while controller.isWorking(did), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!controller.isWorking(did))
    }
    private func held(_ transport: InteractionTransport) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await transport.isHeld), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await transport.isHeld)
    }
    @Test("A read finishing during a drag updates actual state quietly, preserves the gesture and sends one released target")
    func finishDuringDrag() async throws {
        let f = try await make(), c = f.controller, editor = UUID()
        let previousStage = c.states[did]?.stage, previousSummary = c.summary(did), previousMessage = c.states[did]?.message
        await f.transport.holdNextRead(position: 40)
        let poll = Task { await c.pollConfigured() }
        try await held(f.transport)
        #expect(!c.isWorking(did) && c.backgroundReading.contains(did))
        #expect(c.summary(did) == previousSummary && c.states[did]?.stage == previousStage)
        c.setEditing(did, editor: editor, active: true)
        var draft = CurtainPositionDraft(); draft.receive(29); draft.setDragging(true); draft.drag(67)
        await f.transport.release(); await poll.value
        draft.receive(c.states[did]?.position)
        #expect(draft.slider == 67 && draft.text == "67" && draft.actual == 40)
        #expect(c.states[did]?.stage == previousStage && c.states[did]?.message == previousMessage)
        #expect(!c.isWorking(did) && !c.backgroundReading.contains(did))
        let before = await f.transport.methods
        await c.pollConfigured() // Editing defers the next ordinary read without cancelling the old one.
        #expect(await f.transport.methods == before)
        draft.setDragging(false)
        #expect(c.send(did, .position(67))); draft.submitted()
        c.setEditing(did, editor: editor, active: false)
        try await idle(c)
        draft.receive(c.states[did]?.position); draft.finishedSubmission(succeeded: true)
        #expect(draft.slider == 67 && draft.text == "67")
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.count == 1)
        await f.stop()
    }
    @Test("A release before the in-flight read finishes is accepted once, waits without cancellation, and preserves its target draft")
    func releaseBeforeRead() async throws {
        let f = try await make(), c = f.controller
        await f.transport.holdNextRead(position: 40)
        let poll = Task { await c.pollConfigured() }
        try await held(f.transport)
        var draft = CurtainPositionDraft(); draft.receive(29); draft.setDragging(true); draft.drag(67); draft.setDragging(false)
        #expect(c.send(did, .position(67))); draft.submitted()
        #expect(c.send(did, .position(67))) // Same pending request joins, never queues another write.
        #expect(c.submissions[did]?.phase == .waiting && c.isWorking(did))
        #expect(await f.transport.isHeld)
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.isEmpty)
        draft.receive(40); draft.focus(false)
        #expect(draft.slider == 67 && draft.text == "67")
        await f.transport.release(); await poll.value; try await idle(c)
        #expect(c.submissions[did]?.phase == .succeeded && c.states[did]?.position == 67)
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.count == 1)
        await f.stop()
    }
    @Test("A poisoned preceding read fails a queued position explicitly, sends no write and backs off polling without blocking a new user request")
    func failedPrecedingRead() async throws {
        let f = try await make(), c = f.controller
        await f.transport.holdNextRead(poison: true)
        let poll = Task { await c.pollConfigured() }
        try await held(f.transport)
        #expect(c.send(did, .position(64)))
        await f.transport.release(); await poll.value; try await idle(c)
        #expect(c.submissions[did]?.phase == .failed && c.errors[did] != nil)
        #expect(c.readFailures[did] == .untrustedReading && c.states[did]?.position == nil)
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.isEmpty)
        #expect(c.events.snapshot().contains { $0.source == .manualPosition && $0.outcome == .noPacket && $0.writeAttempted == false && $0.reason == .untrustedReading })
        let before = await f.transport.methods
        await c.pollConfigured()
        #expect(await f.transport.methods == before)
        #expect(c.send(did, .position(64))) // A fresh user action performs its own full preflight, with no manual unlock.
        try await idle(c)
        #expect(c.states[did]?.position == 64 && c.readFailures[did] == nil)
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.count == 1)
        await f.stop()
    }
    @Test("Stop supersedes a queued position, drains the in-flight read, and sends only one priority motor Stop")
    func stopSupersedesPendingPosition() async throws {
        let f = try await make(), c = f.controller
        await f.transport.holdNextRead()
        let poll = Task { await c.pollConfigured() }
        try await held(f.transport)
        #expect(c.send(did, .position(67)))
        #expect(c.send(did, .stop))
        #expect(c.submissions[did]?.command == .stop)
        await f.transport.release(); await poll.value; try await idle(c)
        let writes = await f.transport.writes
        #expect(writes.count == 1)
        guard case .object(let fields) = try #require(writes.first) else { Issue.record("Expected a stop write"); await f.stop(); return }
        #expect(fields["piid"] == .number(1) && fields["value"] == .number(1))
        #expect(c.readFailures[did] == nil)
        await f.stop()
    }
    @Test("A different request received while a user request is queued is explicitly rejected, not silently lost")
    func busyRejection() async throws {
        let f = try await make(), c = f.controller
        await f.transport.holdNextRead()
        let poll = Task { await c.pollConfigured() }
        try await held(f.transport)
        #expect(c.send(did, .position(67)))
        #expect(!c.send(did, .position(90)))
        #expect(c.errors[did] != nil)
        #expect(c.events.snapshot().contains { $0.source == .manualPosition && $0.target == 90 && $0.reason == .busy && $0.outcome == .noPacket })
        await f.transport.release(); await poll.value; try await idle(c)
        #expect(c.states[did]?.position == 67 && c.errors[did] != nil)
        #expect(await f.transport.methods.filter { $0 == "set_properties" }.count == 1)
        await f.stop()
    }
}
