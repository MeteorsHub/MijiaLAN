import Foundation
import MijiaCore

/// Verified daily App control. Generic capabilities and HomeKit/Matter remain protected.
public actor CurtainControlSession {
    public enum Command: Equatable, Sendable {
        case position(Int), open, close, stop
        public var target: Int? {
            switch self { case .position(let value): value; case .open: 100; case .close: 0; case .stop: nil }
        }
        var write: (piid: Int, value: Int) {
            switch self { case .position(let value): (4, value); case .open: (1, 2); case .close: (1, 0); case .stop: (1, 1) }
        }
    }
    public enum Phase: String, Sendable { case disabled, connecting, ready, moving, stopping, paused, unconfirmed }
    public struct State: Equatable, Sendable {
        public var phase: Phase = .disabled
        public var position: Int?
        public var motorStatus: Int?
        public var command: Command?
        public var writeAccepted = false
        public var writeAttempted = false
        public var writeSent: Bool? = false
        public var confirmed = false
        public var canStop = false
        public var source: CurtainEventLog.Source = .manualRead
        public var operationID: UUID?
        public var stage: CurtainEventLog.Stage = .idle
        public var failureReason: CurtainEventLog.Reason?
        public var lastKnownPosition: Int?
        public var lastKnownMotorStatus: Int?
        public var lastKnownAt: Date?
        public var sampledAt: Date?
        public var message: String?
    }
    private let device: LocalDevice
    private let client: MiioClient
    private let policy: MiioCommunicationPolicy
    private let allowWrites: Bool
    private var lastFullCheck: Duration?
    private var compactRounds = 0
    private var readRound: UInt64 = 0
    private let fullCheckMaxAge = Duration.seconds(300)
    private let scheduler: CurtainRequestScheduler
    private let clock: CurtainValidationSession.Clock
    private let isCurrent: @Sendable () -> Bool
    private let journal: CurtainEventLog
    private var traceID = UUID()
    private var source: CurtainEventLog.Source = .manualRead
    private var writeTrace = CurtainWriteTrace()
    private let onInfo: @Sendable () async -> Void
    private var enabled = true
    private var verified = false
    private var started = false
    private var stopping = false
    private var state = State()
    private var lastCompletion: Duration?
    private var lastConfirmed: Duration?
    private var operation: (id: UUID, command: Command?, task: Task<State, any Error>)?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    init(device: LocalDevice, client: MiioClient, scheduler: CurtainRequestScheduler,
         clock: CurtainValidationSession.Clock = .init(), isCurrent: @escaping @Sendable () -> Bool,
         onInfo: @escaping @Sendable () async -> Void = {}, journal: CurtainEventLog = .init(), allowWrites: Bool = true) {
        self.device = device; self.client = client; self.scheduler = scheduler; self.clock = clock
        self.policy = client.policy
        self.allowWrites = allowWrites
        self.isCurrent = isCurrent; self.onInfo = onInfo; self.journal = journal
    }
    public func snapshot() -> State { state }
    /// Constructs no socket until explicitly invoked; intended for one-device, read-only CLI experiments.
    public static func experiment(device: LocalDevice, policy: MiioCommunicationPolicy, journal: DeviceEventLog,
                                  transport: any MiioTransport = UDPMiioTransport(), port: UInt16 = MiioPacket.port) throws -> CurtainControlSession {
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification,
              let token = MiioToken.parse(device.token), let identity = UInt32(device.did) else { throw DeviceControlError.wrongDevice }
        let client = MiioClient(host: device.host, token: token, port: port, transport: transport, retries: 0,
            knownModel: device.model, events: journal, eventIdentifier: device.did, policy: policy, expectedDeviceID: identity)
        return CurtainControlSession(device: device, client: client, scheduler: CurtainRequestScheduler(), isCurrent: { true }, journal: journal, allowWrites: false)
    }
    public func updates() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() { for observer in observers.values { observer.yield(state) } }
    private func current() throws {
        try Task.checkCancellation()
        guard enabled, isCurrent() else { throw DeviceControlError.wrongDevice }
    }
    private func pause(_ error: any Error) {
        state.phase = enabled ? (writeTrace.attempted && state.command != nil && !state.confirmed ? .unconfirmed : .paused) : .disabled
        state.position = nil; state.motorStatus = nil; state.sampledAt = nil
        let reason = CurtainEventLog.reason(error)
        state.failureReason = reason
        state.writeAttempted = writeTrace.attempted; state.writeSent = writeTrace.sent
        var detail: String
        switch reason {
        case .timeout: detail = L10n.tr("请求超时", "Request timed out")
        case .propertyError: detail = MiotPropertyStatus.description(CurtainEventLog.code(error))
        case .firmware: detail = L10n.tr("型号或固件未通过验证", "Model or firmware not verified")
        case .identity: detail = L10n.tr("设备身份已变化", "Device identity changed")
        case .untrustedReading: detail = L10n.tr("不可信读数", "Untrusted readings")
        case .invalidReply: detail = L10n.tr("应答缺值或未通过校验", "Reply is missing values or failed validation")
        case .deadline: detail = L10n.tr("回读已达次数或时间上限", "Readback limit reached")
        case .busy: detail = L10n.tr("电机未停稳或已有操作", "Motor is moving or another operation is active")
        case .clockDiscontinuity: detail = L10n.tr("设备时钟偏差超出验证容差", "Device clock differs beyond the validated tolerance")
        case .cancelled: detail = L10n.tr("请求已取消", "Request cancelled")
        default: detail = L10n.tr("读数或操作结果未确认", "Readings or operation unconfirmed")
        }
        if [.manualPosition, .manualOpen, .manualClose, .manualStop].contains(source), state.command != nil, !writeTrace.attempted {
            detail += L10n.tr("；写入未发", "; write was not attempted")
        }
        state.message = detail + L10n.tr("；已停止后续请求，不会自动重发或重连。", "; further requests stopped. No automatic retry or reconnect.")
        publish()
    }
    private func run(_ command: Command?, operationID: UUID? = nil, source override: CurtainEventLog.Source? = nil, body: @escaping @Sendable () async throws -> State) async throws -> State {
        try current()
        guard operation == nil else { throw DeviceControlError.busy }
        let id = operationID ?? UUID()
        let requestSource: CurtainEventLog.Source
        switch command {
        case .position: requestSource = .manualPosition
        case .open: requestSource = .manualOpen
        case .close: requestSource = .manualClose
        case .stop: requestSource = .manualStop
        case nil: requestSource = .manualRead
        }
        let effectiveSource = override ?? requestSource
        return try await runOperation(command, id: id, requestSource: effectiveSource, body: body)
    }
    private func runOperation(_ command: Command?, id: UUID, requestSource: CurtainEventLog.Source, body: @escaping @Sendable () async throws -> State) async throws -> State {
        traceID = id; source = requestSource; state.source = requestSource; state.operationID = id
        let writeTrace = CurtainWriteTrace(); self.writeTrace = writeTrace
        state.writeAttempted = false; state.writeSent = false
        if let command { state.command = command; state.confirmed = false; state.writeAccepted = false }
        state.stage = .requested; state.failureReason = nil; state.message = nil; publish()
        journal.record(device.did, operation: id, source: requestSource, stage: .requested, outcome: .noPacket, target: command?.target)
        let task = Task {
            do { return try await body() }
            catch {
                journal.record(device.did, operation: id, source: requestSource, stage: state.stage,
                               outcome: error is CancellationError ? .cancelled : .paused,
                               reason: CurtainEventLog.reason(error), code: CurtainEventLog.code(error),
                               position: state.lastKnownPosition, motorStatus: state.lastKnownMotorStatus, writeAttempted: writeTrace.attempted, writeSent: writeTrace.sent, writeAcknowledged: writeTrace.acknowledged)
                if command != nil, !writeTrace.attempted {
                    journal.record(device.did, operation: id, source: requestSource, stage: .write, outcome: .noPacket,
                                   reason: CurtainEventLog.reason(error), target: command?.target,
                                   writeAttempted: false, writeSent: false, writeAcknowledged: false)
                }
                throw error
            }
        }
        operation = (id, command, task)
        defer { if operation?.id == id { operation = nil; publish() } }
        do {
            let result = try await task.value
            if operation?.id == id { state.stage = .finished; publish() }
            journal.record(device.did, operation: id, source: requestSource, stage: .finished, outcome: command != nil && result.confirmed ? .confirmed : .validated,
                           position: result.position, motorStatus: result.motorStatus, writeAttempted: writeTrace.attempted,
                           writeSent: writeTrace.sent, writeAcknowledged: command == nil ? nil : writeTrace.acknowledged)
            return result
        } catch {
            if operation?.id == id { pause(error) }
            throw error
        }
    }
    private func packet(_ stage: CurtainEventLog.Stage, piid: Int? = nil, target: Int? = nil, capture: MiioPacketTrace? = nil) -> @Sendable (CurtainWireEvent) -> Void {
        let journal = journal, did = device.did, operation = traceID, round = readRound
        let packetSource: CurtainEventLog.Source = stage == .confirmation ? .postWriteRead : source
        let value = stage == .write ? state.command?.write.value : nil
        let writeTrace = writeTrace
        let queuedAt = clock.now(), clock = clock
        let timer = CurtainPacketTimer()
        return { event in
            var diagnostic = event.packet; diagnostic.readRound = round
            if case .attempt = event {
                let wait = (clock.now() - queuedAt).components
                diagnostic.schedulerWaitMilliseconds = wait.seconds * 1_000 + wait.attoseconds / 1_000_000_000_000_000
            }
            if case .checked = event { capture?.replace(diagnostic) }
            if case .property(let row, _) = event {
                journal.recordProperty(did, operation: operation, source: packetSource, stage: stage, row: row, packet: diagnostic)
                return
            }
            if case .attempt = event { timer.start() }
            if stage == .write { writeTrace.note(event) }
            journal.record(did, operation: operation, source: packetSource, stage: stage, outcome: event.outcome, reason: event.reason, code: event.code,
                           kind: stage == .hello ? .hello : (stage == .info ? .info : (stage == .write ? .write : .read)), siid: piid == nil ? nil : 2, piid: piid, value: value, target: target, elapsedMilliseconds: timer.elapsed, packet: diagnostic)
        }
    }
    private func stage(_ value: CurtainEventLog.Stage) { state.stage = value; publish() }
    private func gap(urgent: Bool) async throws {
        try current()
        if !urgent, let lastCompletion {
            // Conservative ordinary cadence, not a firmware requirement. Stop bypasses this wait.
            let remaining = Duration.seconds(5) - (clock.now() - lastCompletion)
            if remaining > .zero { try await clock.sleep(remaining) }
        }
        try current()
    }
    private func hello(urgent: Bool) async throws {
        stage(.hello)
        try await gap(urgent: urgent)
        defer { lastCompletion = clock.now() }
        let client = client, wire = packet(.hello)
        let header = try await scheduler.perform(priority: urgent ? .stop : .ordinary) {
            try await client.observedHandshake(timeout: .seconds(2), wire: wire)
        }
        try current()
        guard UInt32(device.did) == header.deviceID else { throw DeviceControlError.wrongDevice }
    }
    private func rpc(_ request: MiioClient.CurtainRequest, urgent: Bool = false, notAfter deadline: Duration? = nil) async throws -> JSONValue {
        let requestStage: CurtainEventLog.Stage
        let piid: Int?, target: Int?
        switch request {
        case .info: requestStage = .info; piid = nil; target = nil
        case .selectedRead(_, _, let confirmation): requestStage = confirmation ? .confirmation : .preflight; piid = nil; target = nil
        case .read(_, let confirmation): requestStage = confirmation ? .confirmation : .preflight; piid = nil; target = nil
        case .position(_, let value): requestStage = .write; piid = 4; target = value
        case .motor: requestStage = .write; piid = 1; target = state.command?.target
        }
        stage(requestStage)
        try await gap(urgent: urgent)
        defer { lastCompletion = clock.now() }
        let capture = MiioPacketTrace(.init())
        let client = client, check = isCurrent, samplingClock = clock, wire = packet(requestStage, piid: piid, target: target, capture: capture)
        if let deadline, clock.now() >= deadline { throw CurtainReadbackLimit() }
        let result = try await scheduler.perform(priority: urgent ? .stop : .ordinary) {
            if let deadline, samplingClock.now() >= deadline { throw CurtainReadbackLimit() }
            return try await client.curtainRequest(request, isCurrent: check, wire: wire)
        }
        try current()
        try recordCodes(result, stage: requestStage, diagnostic: capture.snapshot)
        return result
    }
    private func recordCodes(_ result: JSONValue, stage: CurtainEventLog.Stage, diagnostic: MiioPacketDiagnostics? = nil) throws {
        guard case .array(let rows) = result else { return }
        var failure: Int?
        for row in rows {
            guard case .object(let fields) = row, case .number(let raw) = fields["code"], let code = Int(exactly: raw) else { continue }
            let piid: Int?
            if case .number(let number) = fields["piid"] { piid = Int(exactly: number) } else { piid = nil }
            if stage == .write {
                journal.record(device.did, operation: traceID, source: source, stage: stage, outcome: .responseCode, code: code,
                               siid: Self.exactInt(fields["siid"]), piid: piid, packet: diagnostic)
            }
            if code != 0, failure == nil { failure = code }
        }
        if let failure { throw MiioError.deviceError(code: failure, message: MiotPropertyStatus.description(failure)) }
    }
    private func connect(force: Bool = false, urgent: Bool = false) async throws {
        let needsHandshake = await client.curtainNeedsHandshake()
        let periodicOnly = await client.curtainPeriodicOnly()
        if force || needsHandshake {
            try await hello(urgent: urgent)
            // An already verified session may re-hello for Stop without waiting for metadata/position reads.
            if !verified || (!urgent && !periodicOnly) {
                let info = try await rpc(.info, urgent: urgent)
                guard case .object(let fields) = info,
                      fields["model"] == .string(CurtainValidationSession.model), fields["fw_ver"] == .string("1.1.3") else {
                    throw DeviceControlError.unsupported("Unverified curtain model/firmware")
                }
                verified = true; state.canStop = true; publish()
                journal.record(device.did, operation: traceID, source: source, stage: .info, outcome: .validated)
                await onInfo()
            }
        }
    }
    /// The App calls this only for a new explicit user action, never for startup or idle.
    public func manual(_ command: Command? = nil, operationID: UUID = UUID()) async throws -> State {
        if let target = command?.target, !(0...100).contains(target) { throw DeviceControlError.invalidValue("position") }
        if started, !verified, operation == nil { started = false } // Only this explicit user action may try identity again.
        if started {
            if let command { return try await perform(command, operationID: operationID) }
            return try await confirmByReading(operationID: operationID)
        }
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification else {
            throw DeviceControlError.unsupported("Curtain model/specification")
        }
        started = true
        return try await run(command, operationID: operationID) {
            await self.beginConnecting()
            try await self.client.waitUntilIdle()
            await self.markDrained()
            try await self.connect(force: true)
            if command == .stop { return try await self.writeAndConfirm(.stop) }
            let reading = try await self.readFull()
            if let command { return try await self.writeAndConfirm(command) }
            return reading
        }
    }
    public func start() async throws -> State {
        guard !started, device.model == CurtainValidationSession.model,
              device.specType == CurtainValidationSession.specification else { throw DeviceControlError.unsupported("Curtain model/specification") }
        started = true
        return try await run(nil) {
            await self.beginConnecting()
            try await self.client.waitUntilIdle()
            await self.markDrained()
            try await self.connect(force: true)
            return try await self.readFull()
        }
    }
    private func beginConnecting() { state.phase = .connecting; publish() }
    private func markDrained() { lastCompletion = clock.now() }
    public func refresh() async throws -> State {
        try current()
        guard verified, !stopping, operation == nil, state.phase == .ready || state.phase == .moving else { throw DeviceControlError.busy }
        return try await run(nil) { try await self.readFull() }
    }
    /// One read-only turn in the App's unified poll. A paused session cannot reconnect itself.
    public func poll(operationID: UUID = UUID(), source: DeviceEventLog.Source = .backgroundPoll) async throws -> State {
        try current()
        guard operation == nil, !stopping, state.failureReason == nil else { throw DeviceControlError.busy }
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification else {
            throw DeviceControlError.unsupported("Curtain model/specification")
        }
        let cold = !started
        started = true
        return try await run(nil, operationID: operationID, source: source) {
            if cold {
                await self.beginConnecting()
                try await self.client.waitUntilIdle()
                await self.markDrained()
                try await self.connect(force: true)
            }
            return try await self.readScheduled()
        }
    }
    private func readScheduled() async throws -> State {
        guard policy.layout == .adaptive, let lastFullCheck, compactRounds < 10,
              clock.now() - lastFullCheck < fullCheckMaxAge else { return try await readFull() }
        readRound &+= 1
        try await connect()
        let raw = try await rpc(.selectedRead(did: device.did, ids: [2,3]))
        let values = try Self.readValues(raw, expected: [2,3])
        try sample(values); compactRounds += 1
        state.phase = state.motorStatus == 1 ? .ready : .moving; state.message = nil; publish()
        return state
    }
    private func readFull() async throws -> State {
        readRound &+= 1
        try await connect()
        let raw = try await readLayout(ids: [2,3,4,5,9,10], confirmation: false)
        let reading = try Self.preflight(raw)
        try sample([2: .number(Double(reading.status)), 3: .number(Double(reading.position))])
        if state.confirmed, let goal = state.command?.target, state.position != goal {
            state.command = nil; state.confirmed = false; state.writeAccepted = false
        }
        state.phase = state.motorStatus == 1 ? .ready : .moving
        lastFullCheck = clock.now(); compactRounds = 0
        state.message = nil; publish()
        return state
    }
    private func readLayout(ids: [Int], confirmation: Bool) async throws -> JSONValue {
        guard policy.layout == .single else { return try await rpc(.selectedRead(did: device.did, ids: ids, confirmation: confirmation)) }
        var rows: [JSONValue] = []
        for id in ids {
            try await connect()
            let result = try await rpc(.selectedRead(did: device.did, ids: [id], confirmation: confirmation))
            guard case .array(let returned) = result else { throw CurtainInvalidReading() }
            rows += returned
        }
        return .array(rows)
    }
    /// Shared by the production preflight and offline batch/single-response evaluation.
    static func preflight(_ result: JSONValue) throws -> (position: Int, status: Int) {
        let values = try readValues(result, expected: [2,3,4,5,9,10])
        _ = try number(values[4], range: 0...100)
        guard values[9] == .number(0), case .bool = values[5], case .bool = values[10] else { throw CurtainInvalidReading() }
        return (try number(values[3], range: 0...100), try number(values[2], range: 0...4))
    }
    private static func exactInt(_ value: JSONValue?) -> Int? {
        if case .number(let raw) = value { return Int(exactly: raw) }
        return nil
    }
    private static func readValues(_ result: JSONValue, expected: Set<Int>) throws -> [Int: JSONValue] {
        do { return try CurtainValidationSession.values(result, expected: expected) }
        catch { throw CurtainInvalidReading() }
    }
    private static func number(_ value: JSONValue?, range: ClosedRange<Int>) throws -> Int {
        do { return try CurtainValidationSession.integer(value, range: range) }
        catch { throw CurtainInvalidReading() }
    }
    private func sample(_ values: [Int: JSONValue]) throws {
        let position = try Self.number(values[3], range: 0...100)
        let status = try Self.number(values[2], range: 0...4)
        state.position = position; state.motorStatus = status; state.sampledAt = Date()
        state.lastKnownPosition = position; state.lastKnownMotorStatus = status; state.lastKnownAt = state.sampledAt
        journal.record(device.did, operation: traceID, source: state.stage == .confirmation ? .postWriteRead : source,
                       stage: state.stage, outcome: .sample, position: position, motorStatus: status)
    }
    public func perform(_ command: Command, operationID: UUID? = nil) async throws -> State {
        if command == .stop { return try await stop(operationID: operationID) }
        try current()
        guard !stopping, verified else { throw DeviceControlError.busy }
        if let operation {
            guard operation.command == command else { throw DeviceControlError.busy }
            return try await operation.task.value
        }
        if state.confirmed, state.command == command, state.position == command.target,
           let lastConfirmed, clock.now() - lastConfirmed < .seconds(2) {
            journal.record(device.did, operation: operationID, source: sourceFor(command), stage: .finished, outcome: .noPacket,
                           reason: .deduplicated, target: command.target)
            return state
        }
        guard state.phase == .ready else { throw DeviceControlError.unavailable("Read to confirm before controlling") }
        if let target = command.target, !(0...100).contains(target) { throw DeviceControlError.invalidValue("position") }
        return try await run(command, operationID: operationID) {
            _ = try await self.readFull()
            return try await self.writeAndConfirm(command)
        }
    }
    private func sourceFor(_ command: Command) -> DeviceEventLog.Source {
        switch command { case .position: .manualPosition; case .open: .manualOpen; case .close: .manualClose; case .stop: .manualStop }
    }
    private func writeAndConfirm(_ command: Command) async throws -> State {
        guard allowWrites else { throw DeviceControlError.unsupported("Read-only experiment session") }
        if command != .stop, state.motorStatus != 1 { throw DeviceControlError.busy }
        state.command = command; state.confirmed = false; state.writeAccepted = false
        state.phase = command == .stop ? .stopping : .moving
        state.message = nil; publish()
        let write = command.write
        let request: MiioClient.CurtainRequest = write.piid == 4 ? .position(did: device.did, target: write.value) : .motor(did: device.did, value: write.value)
        // Exactly one write; failures never enter a retry or automatic confirmation loop.
        let reply = command == .stop ? try await stopReply() : try await rpc(request)
        if command == .stop { try recordCodes(reply, stage: .write) }
        guard case .array(let rows) = reply, rows.count == 1, case .object(let ack) = rows[0], ack["code"] == .number(0),
              (ack["siid"] == nil || ack["siid"] == .number(2)),
              (ack["piid"] == nil || ack["piid"] == .number(Double(write.piid))) else { throw DeviceControlError.notConfirmed }
        writeTrace.acknowledge()
        state.writeAttempted = writeTrace.attempted; state.writeSent = writeTrace.sent
        state.writeAccepted = true
        journal.record(device.did, operation: traceID, source: source, stage: .write, outcome: .acknowledged, code: 0, piid: write.piid, target: command.target)
        state.message = command == .stop
            ? L10n.tr("停止命令已应答，等待实际停止状态", "Stop acknowledged; awaiting actual stopped state.")
            : L10n.tr("指令已应答，正在回读实际位置", "Command acknowledged; reading actual position.")
        publish()
        return try await confirm(command)
    }
    private func stopReply() async throws -> JSONValue {
        try current()
        defer { lastCompletion = clock.now() }
        stage(.write)
        let client = client, check = isCurrent, did = device.did, wire = packet(.write, piid: 1), helloWire = packet(.hello)
        let reply = try await scheduler.perform(priority: .stop) {
            guard check() else { throw DeviceControlError.wrongDevice }
            if await client.curtainNeedsHandshake() {
                let header = try await client.observedHandshake(timeout: .seconds(2), wire: helloWire)
                guard UInt32(did) == header.deviceID else { throw DeviceControlError.wrongDevice }
            }
            try Task.checkCancellation()
            // Hold the shared permit through a necessary re-hello and the single Stop write.
            return try await client.curtainRequest(.motor(did: did, value: 1), isCurrent: check, wire: wire)
        }
        try current()
        return reply
    }
    private func confirm(_ command: Command) async throws -> State {
        let deadline = clock.now() + .seconds(command == .stop ? 30 : 120)
        let limit = command == .stop ? 6 : 24
        for _ in 0..<limit {
            guard clock.now() < deadline else { break }
            try await connect()
            let values = try Self.readValues(await rpc(.read(did: device.did, confirmation: true), notAfter: deadline), expected: [2,3])
            try sample(values)
            if state.motorStatus == 1 {
                guard command == .stop || state.position == command.target else { throw DeviceControlError.notConfirmed }
                state.phase = .ready; state.confirmed = true; lastConfirmed = clock.now()
                state.message = L10n.tr("实际位置和停止状态已确认", "Actual position and stopped state confirmed.")
                publish(); return state
            }
            // A valid moving sample is progress, not a failure or a reason to resend the target.
            state.phase = command == .stop ? .stopping : .moving
            publish()
        }
        throw CurtainReadbackLimit()
    }
    /// Explicit recovery only. It never resends a target/motor command.
    public func confirmByReading(operationID: UUID? = nil) async throws -> State {
        try current()
        guard verified, !stopping, operation == nil else { throw DeviceControlError.busy }
        return try await run(nil, operationID: operationID) {
            try await self.connect()
            _ = try await self.readFull()
            await self.confirmSingleReading()
            return await self.snapshot()
        }
    }
    private func confirmSingleReading() {
        if let command = state.command, state.motorStatus == 1, command == .stop || state.position == command.target {
            state.confirmed = true; lastConfirmed = clock.now()
        }
        publish()
    }
    public func stop(operationID: UUID? = nil) async throws -> State {
        try current()
        guard verified else { throw DeviceControlError.unavailable("Identity not verified") }
        if let operation, operation.command == .stop { return try await operation.task.value }
        guard !stopping else { throw DeviceControlError.busy }
        stopping = true
        defer { stopping = false }
        // Cancel the movement's sleep/queued reads, not the physical motor. Drain only an in-flight packet.
        let previous = operation?.task
        operation = nil
        previous?.cancel()
        _ = await previous?.result
        try current()
        return try await run(.stop, operationID: operationID) {
            return try await self.writeAndConfirm(.stop)
        }
    }
    /// Disables scheduling; does not send a physical Stop command.
    public func end() async {
        enabled = false
        let previous = operation?.task
        operation = nil
        previous?.cancel()
        _ = await previous?.result
        state.phase = .disabled; state.canStop = false; state.position = nil; state.motorStatus = nil; publish()
        for observer in observers.values { observer.finish() }; observers = [:]
        await client.close()
    }
}

private final class CurtainPacketTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?
    func start() { lock.withLock { instant = .now } }
    var elapsed: Int64? { lock.withLock {
        guard let instant else { return nil }
        let c = instant.duration(to: .now).components
        return c.seconds * 1_000 + c.attoseconds / 1_000_000_000_000_000
    } }
}

private final class CurtainWriteTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptedValue = false
    private var sentValue = false
    private var acknowledgedValue = false
    var attempted: Bool { lock.withLock { attemptedValue } }
    var sent: Bool? { lock.withLock { attemptedValue ? (sentValue ? true : nil) : false } }
    var acknowledged: Bool { lock.withLock { acknowledgedValue } }
    func acknowledge() { lock.withLock { acknowledgedValue = true } }
    func note(_ event: CurtainWireEvent) { lock.withLock {
        switch event { case .attempt: attemptedValue = true; case .sent: sentValue = true; default: break }
    } }
}
