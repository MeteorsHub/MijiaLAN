import Foundation
import MijiaCore

/// Separate from CurtainControlSession: there is no startup/full/periodic property sweep here.
public struct CurtainAttributePlan: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable { case batch, single }
    public enum Phase: String, Codable, Sendable { case baselineBefore = "baseline-before", probe, baselineAfter = "baseline-after" }
    public static let whitelist = [2, 3, 4, 5, 9, 10]
    public let properties: [Int]
    public let layout: Layout
    public let phase: Phase
    public let rounds: Int
    public let intervalSeconds: Int
    public let rpcTimeoutSeconds: Int
    private enum CodingKeys: String, CodingKey { case properties, layout, phase, rounds, intervalSeconds, rpcTimeoutSeconds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(properties: c.decode([Int].self, forKey: .properties), layout: c.decode(Layout.self, forKey: .layout),
            phase: c.decode(Phase.self, forKey: .phase), rounds: c.decode(Int.self, forKey: .rounds),
            intervalSeconds: c.decode(Int.self, forKey: .intervalSeconds), rpcTimeoutSeconds: c.decodeIfPresent(Int.self, forKey: .rpcTimeoutSeconds) ?? 2)
    }
    public init(properties: [Int], layout: Layout, phase: Phase, rounds: Int, intervalSeconds: Int, rpcTimeoutSeconds: Int = 2) throws {
        guard !properties.isEmpty, properties.count <= 6, Set(properties).count == properties.count,
              properties.allSatisfy(Self.whitelist.contains), (1...48).contains(rounds), (5...300).contains(intervalSeconds), (1...30).contains(rpcTimeoutSeconds),
              phase == .probe || (properties == Self.whitelist && layout == .batch && rounds == 1)
        else { throw DeviceControlError.invalidValue("Explicit attribute plan") }
        self.properties = properties; self.layout = layout; self.phase = phase
        self.rounds = rounds; self.intervalSeconds = intervalSeconds; self.rpcTimeoutSeconds = rpcTimeoutSeconds
    }
}

/// Counts actual Mac sends for this probe instance only, never a firmware/global counter.
public struct CurtainAttributeExposure: Codable, Equatable, Sendable {
    public struct Address: Codable, Equatable, Sendable {
        public let siid: Int
        public let piid: Int
        public let requested: UInt64
    }
    public internal(set) var packets: UInt64 = 0
    public internal(set) var hello: UInt64 = 0
    public internal(set) var info: UInt64 = 0
    public internal(set) var reads: UInt64 = 0
    public internal(set) var writes: UInt64 = 0
    public internal(set) var other: UInt64 = 0
    public internal(set) var sixAddressPackets: UInt64 = 0
    public internal(set) var corePairPackets: UInt64 = 0
    public internal(set) var addresses: [Address] = CurtainAttributePlan.whitelist.map { Address(siid: 2, piid: $0, requested: 0) }
    public init() {}
}
private final class AttributeWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var exposure = CurtainAttributeExposure()
    private var sent: Set<UUID> = []
    private var discarded = false
    private var packet = MiioPacketDiagnostics()
    func annotate(_ event: CurtainWireEvent, plan: CurtainAttributePlan, round: UInt64) -> MiioPacketDiagnostics {
        lock.withLock {
            var value = event.packet
            if case .sent = event, sent.insert(value.exchange).inserted {
                exposure.packets += 1
                switch value.method {
                case .hello: exposure.hello += 1
                case .info: exposure.info += 1
                case .read:
                    exposure.reads += 1
                    let ids = (value.addresses ?? []).filter { $0.siid == 2 }.map { Int($0.piid) }
                    // Construct by address, preserving separate actual-send exposure for every requested entry.
                    exposure.addresses = CurtainAttributePlan.whitelist.map { id in
                        let old = exposure.addresses.first { $0.piid == id }?.requested ?? 0
                        return .init(siid: 2, piid: id, requested: old + UInt64(ids.filter { $0 == id }.count))
                    }
                    if ids.count == 6 && Set(ids) == Set(CurtainAttributePlan.whitelist) { exposure.sixAddressPackets += 1 }
                    if ids.count == 2 && Set(ids) == Set([2,3]) { exposure.corePairPackets += 1 }
                case .write, .action, .legacyWrite: exposure.writes += 1
                default: exposure.other += 1
                }
            }
            if case .discarded = event { discarded = true }
            value.attributePlan = plan; value.attributeRound = round; value.attributeExposure = exposure
            packet = value
            return value
        }
    }
    var counts: CurtainAttributeExposure { lock.withLock { exposure } }
    var hasDiscard: Bool { lock.withLock { discarded } }
    var lastPacket: MiioPacketDiagnostics { lock.withLock { packet } }
}
private final class AttributePacketTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var start: ContinuousClock.Instant?
    func begin() { lock.withLock { start = .now } }
    var elapsed: Int64? { lock.withLock {
        guard let start else { return nil }
        let d = start.duration(to: .now).components
        return d.seconds * 1_000 + d.attoseconds / 1_000_000_000_000_000
    } }
}

/// Read-only whitelist probe, fixed stable/periodic/helloAnchored. No control APIs or hidden property reads.
public actor CurtainAttributeProbe {
    public nonisolated let plan: CurtainAttributePlan
    private let device: LocalDevice
    private let client: MiioClient
    private let journal: DeviceEventLog
    private let clock: CurtainValidationSession.Clock
    private let wireState = AttributeWireState()
    private var lastCompletion: Duration
    private var round: UInt64 = 0
    private var operation = UUID()
    private var busy = false
    private var ended = false
    private var failed = false
    private var verified = false

    public init(device: LocalDevice, plan: CurtainAttributePlan, journal: DeviceEventLog,
                transport: any MiioTransport = UDPMiioTransport(), port: UInt16 = MiioPacket.port) throws {
        try self.init(device: device, plan: plan, journal: journal, transport: transport, port: port, clock: .init(), time: .init())
    }
    init(device: LocalDevice, plan: CurtainAttributePlan, journal: DeviceEventLog,
         transport: any MiioTransport = UDPMiioTransport(), port: UInt16 = MiioPacket.port,
         clock: CurtainValidationSession.Clock, time: MiioTimeSource) throws {
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification,
              let token = MiioToken.parse(device.token), let did = UInt32(device.did), did > 0 else { throw DeviceControlError.wrongDevice }
        let checked = try CurtainAttributePlan(properties: plan.properties, layout: plan.layout, phase: plan.phase, rounds: plan.rounds, intervalSeconds: plan.intervalSeconds, rpcTimeoutSeconds: plan.rpcTimeoutSeconds)
        self.device = device; self.plan = checked; self.journal = journal; self.clock = clock
        lastCompletion = clock.now()
        client = MiioClient(host: device.host, token: token, port: port, transport: transport, retries: 0,
            knownModel: device.model, events: journal, eventIdentifier: device.did,
            policy: .init(socket: .stable, layout: plan.layout == .batch ? .full : .single, hello: .periodic, stamp: .helloAnchored),
            expectedDeviceID: did, time: time)
    }
    public func exposure() -> CurtainAttributeExposure { wireState.counts }
    private func current() throws {
        try Task.checkCancellation()
        guard !ended, !failed else { throw DeviceControlError.unavailable("Attribute probe has stopped") }
    }
    private func gap() async throws {
        try current()
        let wait = Duration.seconds(5) - (clock.now() - lastCompletion)
        if wait > .zero { try await clock.sleep(wait) }
        try current()
    }
    private func wire(_ stage: DeviceEventLog.Stage, kind: DeviceEventLog.Kind) -> @Sendable (CurtainWireEvent) -> Void {
        let state = wireState, plan = plan, round = round, operation = operation, journal = journal, did = device.did
        let timer = AttributePacketTimer()
        return { event in
            let packet = state.annotate(event, plan: plan, round: round)
            if case .attempt = event { timer.begin() }
            if case .property(let row, _) = event {
                journal.recordProperty(did, operation: operation, source: .experiment, stage: stage, row: row, packet: packet)
            } else {
                journal.record(did, operation: operation, source: .experiment, stage: stage, outcome: event.outcome,
                    reason: event.reason, code: event.code, kind: kind, elapsedMilliseconds: timer.elapsed, packet: packet)
            }
        }
    }
    private func checkWire() throws {
        try current()
        guard !wireState.hasDiscard else { throw MiioError.badResponse("Attribute probe discarded a datagram; no further requests") }
        guard wireState.counts.writes == 0, wireState.counts.other == 0 else { throw DeviceControlError.unsupported("Read-only attribute probe") }
    }
    private func rpc(_ request: MiioClient.CurtainRequest, info: Bool = false) async throws -> JSONValue {
        try await gap()
        defer { lastCompletion = clock.now() }
        let result = try await client.curtainRequest(request, timeout: .seconds(plan.rpcTimeoutSeconds), isCurrent: { true }, wire: wire(info ? .info : .preflight, kind: info ? .info : .read))
        try checkWire()
        return result
    }
    private func connect() async throws {
        if await client.curtainNeedsHandshake() {
            try await gap()
            let header = try await client.observedHandshake(timeout: .seconds(2), wire: wire(.hello, kind: .hello))
            lastCompletion = clock.now()
            try checkWire()
            guard UInt32(device.did) == header.deviceID else { throw DeviceControlError.wrongDevice }
        }
        if !verified {
            let info = try await rpc(.info, info: true)
            guard case .object(let fields) = info, fields["model"] == .string(CurtainValidationSession.model), fields["fw_ver"] == .string("1.1.3") else {
                throw DeviceControlError.unsupported("Unverified curtain identity/firmware")
            }
            verified = true
        }
    }
    public func readRound() async throws {
        try current()
        guard !busy, round < UInt64(plan.rounds) else { throw DeviceControlError.busy }
        busy = true; defer { busy = false }
        round += 1; operation = UUID()
        do {
            let groups = plan.layout == .batch ? [plan.properties] : plan.properties.map { [$0] }
            for ids in groups {
                try await connect()
                let result = try await rpc(.selectedRead(did: device.did, ids: ids))
                try Self.validate(result, ids: ids)
            }
            journal.record(device.did, operation: operation, source: .experiment, stage: .finished, outcome: .validated, packet: wireState.lastPacket)
        } catch {
            failed = true
            journal.record(device.did, operation: operation, source: .experiment, stage: .finished, outcome: .paused,
                reason: DeviceEventLog.reason(error), code: DeviceEventLog.code(error), packet: wireState.lastPacket)
            throw error
        }
    }
    static func validate(_ result: JSONValue, ids: [Int]) throws {
        // MiioClient has already logged every returned code/type/safe scalar, including the bad batch.
        if case .array(let rows) = result {
            for row in rows {
                if case .number(let raw) = row["code"], let code = Int(exactly: raw), code != 0 {
                    throw MiioError.deviceError(code: code, message: MiotPropertyStatus.description(code))
                }
            }
        }
        let values: [Int: JSONValue]
        do { values = try CurtainValidationSession.values(result, expected: Set(ids)) } catch { throw CurtainInvalidReading() }
        for id in ids {
            switch id {
            case 5, 10: guard case .bool = values[id] else { throw CurtainInvalidReading() }
            case 9: guard values[id] == .number(0) else { throw CurtainInvalidReading() }
            case 2: guard case .number(let n) = values[id], let v = Int(exactly: n), (0...4).contains(v) else { throw CurtainInvalidReading() }
            case 3, 4: guard case .number(let n) = values[id], let v = Int(exactly: n), (0...100).contains(v) else { throw CurtainInvalidReading() }
            default: throw CurtainInvalidReading()
            }
        }
    }
    public func end() async { ended = true; await client.close(); journal.flush() }
}
