import Foundation
import MijiaCore

/// Manual, session-only validation. It never changes DeviceLANPolicy or exports bridge attributes.
public actor CurtainValidationSession {
    public static let model = "dooya.motor.dc1545"
    public static let specification = "urn:miot-spec-v2:device:motor-controller:0000A01D:dooya-dc1545:1"
    public enum Phase: String, Sendable { case disabled, checking, ready, moving, unconfirmed, paused }
    public struct State: Equatable, Sendable {
        public var phase: Phase = .disabled
        public var position: Int?
        public var motorStatus: Int?
        public var requestedTarget: Int?
        public var writeAccepted = false
        public var confirmed = false
        public var sampledAt: Date?
        public var message: String?
    }
    struct Clock: Sendable {
        var now: @Sendable () -> Duration
        var sleep: @Sendable (Duration) async throws -> Void
        init() {
            let origin = ContinuousClock.now
            now = { origin.duration(to: .now) }
            sleep = { try await Task.sleep(for: $0) }
        }
        init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
            self.now = now; self.sleep = sleep
        }
    }
    private let device: LocalDevice
    private let client: MiioClient
    private let clock: Clock
    private let isCurrent: @Sendable () -> Bool
    private let onInfo: @Sendable () async -> Void
    private var enabled = true
    private var lastCompletion: Duration?
    private var state = State()
    private var operation: (id: UUID, target: Int?, task: Task<State, any Error>)?
    private var started = false

    init(device: LocalDevice, client: MiioClient, clock: Clock = Clock(),
         isCurrent: @escaping @Sendable () -> Bool = { true }, onInfo: @escaping @Sendable () async -> Void = {}) {
        self.device = device; self.client = client; self.clock = clock; self.isCurrent = isCurrent; self.onInfo = onInfo
    }
    public func snapshot() -> State { state }

    public func start() async throws -> State {
        guard !started else { throw DeviceControlError.busy }
        started = true
        guard device.model == Self.model, device.specType == Self.specification else {
            pause(); throw DeviceControlError.unsupported("Curtain model/specification")
        }
        return try await run(target: nil) {
            // Drain cancelled background metadata calls, then leave a full gap before the first packet.
            try await self.client.waitUntilIdle()
            await self.markDrained()
            try await self.connectIfNeeded(force: true)
            return try await self.readState()
        }
    }
    private func markDrained() { lastCompletion = clock.now() }

    public func refresh() async throws -> State {
        try checkCurrent()
        guard state.phase == .ready else { throw DeviceControlError.unavailable("Validation is paused") }
        return try await run(target: nil) { try await self.readState() }
    }
    public func move(to target: Int) async throws -> State {
        try checkCurrent()
        if let operation {
            guard operation.target == target else { throw DeviceControlError.busy }
            return try await operation.task.value
        }
        if state.confirmed, state.requestedTarget == target, state.position == target { return state }
        guard state.phase == .ready, (1...99).contains(target) else { throw DeviceControlError.invalidValue("position") }
        // Reject large/stale requests before sending any packet, and recheck after the fresh read.
        guard let current = state.position, abs(target - current) <= 5 else { throw DeviceControlError.invalidValue("Maximum 5 percentage points") }
        return try await run(target: target) { try await self.performMove(target) }
    }
    public func confirmPendingMove() async throws -> State {
        try checkCurrent()
        guard let target = state.requestedTarget, !state.confirmed, operation == nil else { throw DeviceControlError.busy }
        return try await run(target: target) {
            try await self.connectIfNeeded()
            return try await self.confirm(target)
        }
    }
    /// Ends validation scheduling; this never sends the motor Stop/Pause command.
    public func end() async {
        enabled = false
        let task = operation?.task
        task?.cancel()
        _ = await task?.result
        state.phase = .disabled
        state.position = nil; state.motorStatus = nil
    }

    private func run(target: Int?, body: @escaping @Sendable () async throws -> State) async throws -> State {
        try Task.checkCancellation()
        try checkCurrent()
        if let operation {
            if target == nil { return try await operation.task.value }
            throw DeviceControlError.busy
        }
        let id = UUID()
        let task = Task { try await body() }
        operation = (id, target, task)
        defer { if operation?.id == id { operation = nil } }
        do { return try await task.value }
        catch {
            // User input/motion-state errors do not invalidate a good read. No request is retried.
            if state.phase != .ready && state.phase != .unconfirmed { pause() }
            throw error
        }
    }
    private func checkCurrent() throws {
        guard enabled else { throw DeviceControlError.unavailable("Validation ended") }
        guard isCurrent() else { pause(); throw DeviceControlError.wrongDevice }
    }
    private func pause() {
        state.phase = !enabled ? .disabled : (state.requestedTarget != nil && !state.confirmed ? .unconfirmed : .paused)
        state.position = nil; state.motorStatus = nil; state.sampledAt = nil
        state.message = enabled ? L10n.tr("结果未确认，已暂停自动请求。请先核对设备。", "Result unconfirmed. Automatic requests are paused. Check the device first.") : nil
    }
    private func gap() async throws {
        try Task.checkCancellation()
        guard enabled, isCurrent() else { throw DeviceControlError.wrongDevice }
        if let lastCompletion {
            let remaining = Duration.seconds(5) - (clock.now() - lastCompletion)
            if remaining > .zero { try await clock.sleep(remaining) }
        }
        try Task.checkCancellation()
        guard enabled, isCurrent() else { throw DeviceControlError.wrongDevice }
    }
    private func hello() async throws {
        try await gap()
        defer { lastCompletion = clock.now() }
        let header = try await client.handshake(timeout: .seconds(2))
        guard UInt32(device.did) == header.deviceID else { throw DeviceControlError.wrongDevice }
    }
    private func rpc(_ request: MiioClient.CurtainRequest) async throws -> JSONValue {
        try await gap()
        defer { lastCompletion = clock.now() }
        return try await client.curtainRequest(request, isCurrent: isCurrent)
    }
    private func connectIfNeeded(force: Bool = false) async throws {
        let needed = await client.curtainNeedsHandshake()
        if force || needed {
            state.phase = .checking
            try await hello()
            let info = try await rpc(.info)
            guard case .object(let fields) = info, fields["model"] == .string(Self.model), fields["fw_ver"] == .string("1.1.3") else {
                throw DeviceControlError.unsupported("Unverified curtain firmware")
            }
            await onInfo()
        }
    }

    static func values(_ result: JSONValue, expected: Set<Int>) throws -> [Int: JSONValue] {
        guard case .array(let rows) = result, rows.count == expected.count else { throw DeviceControlError.notConfirmed }
        var values: [Int: JSONValue] = [:]
        for row in rows {
            guard case .object(let fields) = row, fields["siid"] == .number(2),
                  case .number(let n) = fields["piid"], n.isFinite, let id = Int(exactly: n), expected.contains(id),
                  values[id] == nil, fields["code"] == .number(0), let value = fields["value"] else {
                throw DeviceControlError.notConfirmed
            }
            values[id] = value
        }
        return values
    }
    static func integer(_ value: JSONValue?, range: ClosedRange<Int>) throws -> Int {
        guard case .number(let n) = value, n.isFinite, let number = Int(exactly: n), range.contains(number) else {
            throw DeviceControlError.notConfirmed
        }
        return number
    }
    private func readState() async throws -> State {
        state.phase = .checking
        try await connectIfNeeded()
        let values = try Self.values(await rpc(.read(did: device.did, confirmation: false)), expected: [2,3,4,5,9,10])
        let status = try Self.integer(values[2], range: 0...4)
        let position = try Self.integer(values[3], range: 0...100)
        _ = try Self.integer(values[4], range: 0...100)
        guard values[9] == .number(0), case .bool = values[5], case .bool = values[10] else { throw DeviceControlError.notConfirmed }
        if state.confirmed, state.requestedTarget != position { state.requestedTarget = nil; state.confirmed = false; state.writeAccepted = false }
        state.position = position; state.motorStatus = status; state.sampledAt = Date(); state.phase = .ready; state.message = nil
        return state
    }
    private func performMove(_ target: Int) async throws -> State {
        _ = try await readState()
        guard state.motorStatus == 1 else { throw DeviceControlError.busy }
        guard let position = state.position, abs(position - target) <= 5 else { throw DeviceControlError.invalidValue("Maximum 5 percentage points") }
        state.requestedTarget = target; state.confirmed = false; state.writeAccepted = false
        if position == target { state.confirmed = true; return state }
        state.phase = .moving
        do {
            let response = try await rpc(.position(did: device.did, target: target))
            guard case .array(let rows) = response, rows.count == 1, case .object(let ack) = rows[0], ack["code"] == .number(0),
                  (ack["siid"] == nil || ack["siid"] == .number(2)), (ack["piid"] == nil || ack["piid"] == .number(4)) else {
                throw DeviceControlError.notConfirmed
            }
            state.writeAccepted = true
            return try await confirm(target)
        } catch {
            pause()
            throw DeviceControlError.notConfirmed
        }
    }
    private func confirm(_ target: Int) async throws -> State {
        state.phase = .checking
        let values = try Self.values(await rpc(.read(did: device.did, confirmation: true)), expected: [2,3])
        let position = try Self.integer(values[3], range: 0...100)
        let status = try Self.integer(values[2], range: 0...4)
        guard position == target, status == 1 else { throw DeviceControlError.notConfirmed }
        state.position = position; state.motorStatus = status; state.sampledAt = Date()
        state.confirmed = true; state.phase = .ready
        state.message = L10n.tr("当前位置和停止状态已回读确认", "Current position and stopped state confirmed.")
        return state
    }
}

/// Synchronous invalidation closes the window while the API awaits an in-flight operation.
final class CurtainValidationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}
