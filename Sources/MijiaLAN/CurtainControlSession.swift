import Foundation
import MijiaCore

/// Opt-in daily App control. Generic capabilities and HomeKit/Matter remain protected.
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
        public var confirmed = false
        public var canStop = false
        public var sampledAt: Date?
        public var message: String?
    }
    private let device: LocalDevice
    private let client: MiioClient
    private let scheduler: CurtainRequestScheduler
    private let clock: CurtainValidationSession.Clock
    private let isCurrent: @Sendable () -> Bool
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
         onInfo: @escaping @Sendable () async -> Void = {}) {
        self.device = device; self.client = client; self.scheduler = scheduler; self.clock = clock
        self.isCurrent = isCurrent; self.onInfo = onInfo
    }
    public func snapshot() -> State { state }
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
    private func pause() {
        state.phase = enabled ? (state.command != nil && !state.confirmed ? .unconfirmed : .paused) : .disabled
        state.position = nil; state.motorStatus = nil; state.sampledAt = nil
        state.message = verified
            ? L10n.tr("读数或操作结果未确认，后台读取已暂停。可仅回读确认；停止仍可单独发送。", "Readings or operation unconfirmed. Background reads are paused. You may read to confirm; Stop remains available.")
            : L10n.tr("连接或设备身份尚未确认，后台读取已暂停。请检查设备后重新连接。", "Connection or device identity is unconfirmed. Background reads are paused. Check the device before reconnecting.")
        publish()
    }
    private func run(_ command: Command?, body: @escaping @Sendable () async throws -> State) async throws -> State {
        try current()
        guard operation == nil else { throw DeviceControlError.busy }
        let id = UUID()
        let task = Task { try await body() }
        operation = (id, command, task)
        defer { if operation?.id == id { operation = nil } }
        do { return try await task.value }
        catch {
            if operation?.id == id, !Task.isCancelled { pause() }
            throw error
        }
    }
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
        try await gap(urgent: urgent)
        defer { lastCompletion = clock.now() }
        let client = client
        let header = try await scheduler.perform(priority: urgent ? .stop : .ordinary) {
            try await client.handshake(timeout: .seconds(2))
        }
        try current()
        guard UInt32(device.did) == header.deviceID else { throw DeviceControlError.wrongDevice }
    }
    private func rpc(_ request: MiioClient.CurtainRequest, urgent: Bool = false, notAfter deadline: Duration? = nil) async throws -> JSONValue {
        try await gap(urgent: urgent)
        defer { lastCompletion = clock.now() }
        let client = client, check = isCurrent, samplingClock = clock
        if let deadline, clock.now() >= deadline { throw DeviceControlError.notConfirmed }
        let result = try await scheduler.perform(priority: urgent ? .stop : .ordinary) {
            if let deadline, samplingClock.now() >= deadline { throw DeviceControlError.notConfirmed }
            return try await client.curtainRequest(request, isCurrent: check)
        }
        try current()
        return result
    }
    private func connect(force: Bool = false, urgent: Bool = false) async throws {
        let needsHandshake = await client.curtainNeedsHandshake()
        if force || needsHandshake {
            try await hello(urgent: urgent)
            // An already verified session may re-hello for Stop without waiting for metadata/position reads.
            if !urgent || !verified {
                let info = try await rpc(.info, urgent: urgent)
                guard case .object(let fields) = info,
                      fields["model"] == .string(CurtainValidationSession.model), fields["fw_ver"] == .string("1.1.3") else {
                    throw DeviceControlError.unsupported("Unverified curtain model/firmware")
                }
                verified = true; state.canStop = true; publish()
                await onInfo()
            }
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
    private func readFull() async throws -> State {
        try await connect()
        let values = try CurtainValidationSession.values(await rpc(.read(did: device.did, confirmation: false)), expected: [2,3,4,5,9,10])
        _ = try CurtainValidationSession.integer(values[4], range: 0...100)
        guard values[9] == .number(0), case .bool = values[5], case .bool = values[10] else { throw DeviceControlError.notConfirmed }
        try sample(values)
        if state.confirmed, let goal = state.command?.target, state.position != goal {
            state.command = nil; state.confirmed = false; state.writeAccepted = false
        }
        state.phase = state.motorStatus == 1 ? .ready : .moving
        state.message = nil; publish()
        return state
    }
    private func sample(_ values: [Int: JSONValue]) throws {
        let position = try CurtainValidationSession.integer(values[3], range: 0...100)
        let status = try CurtainValidationSession.integer(values[2], range: 0...4)
        state.position = position; state.motorStatus = status; state.sampledAt = Date()
    }
    public func perform(_ command: Command) async throws -> State {
        if command == .stop { return try await stop() }
        try current()
        guard !stopping, verified else { throw DeviceControlError.busy }
        if let operation {
            guard operation.command == command else { throw DeviceControlError.busy }
            return try await operation.task.value
        }
        if state.confirmed, state.command == command, state.position == command.target,
           let lastConfirmed, clock.now() - lastConfirmed < .seconds(2) { return state }
        guard state.phase == .ready else { throw DeviceControlError.unavailable("Read to confirm before controlling") }
        if let target = command.target, !(0...100).contains(target) { throw DeviceControlError.invalidValue("position") }
        return try await run(command) {
            _ = try await self.readFull()
            return try await self.writeAndConfirm(command)
        }
    }
    private func writeAndConfirm(_ command: Command) async throws -> State {
        if command != .stop, state.motorStatus != 1 { throw DeviceControlError.busy }
        state.command = command; state.confirmed = false; state.writeAccepted = false
        state.phase = command == .stop ? .stopping : .moving
        state.message = nil; publish()
        let write = command.write
        let request: MiioClient.CurtainRequest = write.piid == 4 ? .position(did: device.did, target: write.value) : .motor(did: device.did, value: write.value)
        // Exactly one write; failures never enter a retry or automatic confirmation loop.
        let reply = command == .stop ? try await stopReply() : try await rpc(request)
        guard case .array(let rows) = reply, rows.count == 1, case .object(let ack) = rows[0], ack["code"] == .number(0),
              (ack["siid"] == nil || ack["siid"] == .number(2)),
              (ack["piid"] == nil || ack["piid"] == .number(Double(write.piid))) else { throw DeviceControlError.notConfirmed }
        state.writeAccepted = true
        state.message = command == .stop
            ? L10n.tr("停止命令已应答，等待实际停止状态", "Stop acknowledged; awaiting actual stopped state.")
            : L10n.tr("指令已应答，正在回读实际位置", "Command acknowledged; reading actual position.")
        publish()
        return try await confirm(command)
    }
    private func stopReply() async throws -> JSONValue {
        try current()
        defer { lastCompletion = clock.now() }
        let client = client, check = isCurrent, did = device.did
        let reply = try await scheduler.perform(priority: .stop) {
            guard check() else { throw DeviceControlError.wrongDevice }
            if await client.curtainNeedsHandshake() {
                let header = try await client.handshake(timeout: .seconds(2))
                guard UInt32(did) == header.deviceID else { throw DeviceControlError.wrongDevice }
            }
            try Task.checkCancellation()
            // Hold the shared permit through a necessary re-hello and the single Stop write.
            return try await client.curtainRequest(.motor(did: did, value: 1), isCurrent: check)
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
            let values = try CurtainValidationSession.values(await rpc(.read(did: device.did, confirmation: true), notAfter: deadline), expected: [2,3])
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
        throw DeviceControlError.notConfirmed
    }
    /// Explicit recovery only. It never resends a target/motor command.
    public func confirmByReading() async throws -> State {
        try current()
        guard verified, !stopping, operation == nil else { throw DeviceControlError.busy }
        return try await run(nil) {
            try await self.connect()
            if let command = await self.state.command, !(await self.state.confirmed) {
                return try await self.confirm(command)
            }
            return try await self.readFull()
        }
    }
    public func stop() async throws -> State {
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
        return try await run(.stop) {
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
    }
}
