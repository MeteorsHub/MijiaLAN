import Foundation

/// Backoff counts authenticated probe rounds, not the UDP attempts inside a round.
public struct ProbeRetryPolicy: Sendable {
    public static let maximumFailures = 14
    public static let maximumInterval: TimeInterval = 24 * 60 * 60

    public init() {}

    public func interval(afterFailures failures: Int, jitter: Double) -> TimeInterval {
        let n = min(Self.maximumFailures, max(1, failures))
        let nominal = min(Self.maximumInterval, 20 * pow(2, Double(n - 1)))
        let boundedJitter = jitter.isFinite ? min(1.1, max(0.9, jitter)) : 1
        return min(Self.maximumInterval, max(20, nominal * boundedJitter))
    }
}

public struct ProbeRetryState: Equatable, Sendable {
    public var consecutiveFailures: Int
    public var nextRetryAt: Date?
    public var isProbing: Bool

    public init(consecutiveFailures: Int = 0, nextRetryAt: Date? = nil, isProbing: Bool = false) {
        self.consecutiveFailures = consecutiveFailures
        self.nextRetryAt = nextRetryAt
        self.isProbing = isProbing
    }
}

/// Inject both halves of the clock so tests never need to wait for real backoff deadlines.
struct ProbeClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (Date) async throws -> Void = {
        try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow)), tolerance: .seconds(1))
    }
}

/// Pure scheduling state, owned by LANMiotAPI's actor. One API timer serves every device.
/// Keeping network tasks outside this type makes concurrency, priority and races deterministic to test.
struct ProbeScheduler: Sendable {
    enum Priority: Int, Sendable { case manual, discovery, startup, background }
    struct Job: Sendable {
        let id: UUID
        let generation: UUID
        let device: LocalDevice
        let priority: Priority
    }
    private struct Entry: Sendable {
        var device: LocalDevice
        let generation: UUID
        var online = false
        var retry = ProbeRetryState()
        var queued: Priority? = .startup
        var sequence: UInt64
        var job: Job?
    }
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    let policy: ProbeRetryPolicy

    init(policy: ProbeRetryPolicy = ProbeRetryPolicy()) { self.policy = policy }

    static func sameEndpoint(_ a: LocalDevice, _ b: LocalDevice) -> Bool {
        a.did == b.did && a.host == b.host && a.token == b.token && a.model == b.model
    }

    /// Returns obsolete jobs to cancel. A fresh generation also rejects A → B → A late replies.
    mutating func configure(_ devices: [LocalDevice]) -> [UUID] {
        let byID = Dictionary(devices.map { ($0.did, $0) }, uniquingKeysWith: { first, _ in first })
        var cancelled: [UUID] = []
        for (did, entry) in entries where byID[did].map({ Self.sameEndpoint(entry.device, $0) }) != true {
            if let job = entry.job { cancelled.append(job.id) }
            entries[did] = nil
        }
        for device in devices {
            if entries[device.did] != nil {
                entries[device.did]?.device = device
            } else {
                sequence &+= 1
                entries[device.did] = Entry(device: device, generation: UUID(), sequence: sequence)
            }
        }
        return cancelled
    }

    var retryStates: [String: ProbeRetryState] { entries.mapValues(\.retry) }
    var runningIDs: [UUID] { entries.values.compactMap { $0.job?.id } }
    func isCurrent(_ job: Job) -> Bool {
        entries[job.device.did]?.generation == job.generation && entries[job.device.did]?.job?.id == job.id
    }

    mutating func enqueue(_ did: String, priority: Priority) {
        guard var entry = entries[did] else { return }
        // A manual request joins an active job, including an active background job.
        guard entry.job == nil else { return }
        if priority != .manual && entry.online { return }
        if entry.queued == nil || priority.rawValue < entry.queued!.rawValue { entry.queued = priority }
        entries[did] = entry
    }

    mutating func markOffline(_ did: String, now: Date) {
        guard var entry = entries[did], entry.online else { return }
        entry.online = false
        entry.retry.nextRetryAt = now
        entries[did] = entry
    }

    /// A successful authenticated read/write also restores an offline device without waiting for its timer.
    @discardableResult mutating func markOnline(_ did: String) -> UUID? {
        guard var entry = entries[did] else { return nil }
        let cancelled = entry.job?.id
        entry.online = true
        entry.retry = ProbeRetryState()
        entry.queued = nil
        entry.job = nil
        entries[did] = entry
        return cancelled
    }

    mutating func startReady(now: Date) -> [Job] {
        for (did, entry) in entries where !entry.online && entry.job == nil && entry.queued == nil {
            if let deadline = entry.retry.nextRetryAt, deadline <= now { enqueue(did, priority: .background) }
        }
        let starting = entries.values.contains { $0.queued == .startup || $0.job?.priority == .startup }
        let limit = starting ? 8 : 4
        let slots = max(0, limit - runningIDs.count)
        let ready = entries.values.filter { $0.job == nil && $0.queued != nil }.sorted {
            let l = $0.queued!.rawValue, r = $1.queued!.rawValue
            return l == r ? $0.sequence < $1.sequence : l < r
        }
        return ready.prefix(slots).map { entry in
            let job = Job(id: UUID(), generation: entry.generation, device: entry.device, priority: entry.queued!)
            entries[entry.device.did]?.queued = nil
            entries[entry.device.did]?.job = job
            entries[entry.device.did]?.retry.isProbing = true
            entries[entry.device.did]?.retry.nextRetryAt = nil
            return job
        }
    }

    @discardableResult mutating func complete(_ job: Job, succeeded: Bool, now: Date, jitter: Double) -> Bool {
        guard isCurrent(job), var entry = entries[job.device.did] else { return false }
        entry.job = nil
        entry.online = succeeded
        if succeeded {
            entry.retry = ProbeRetryState()
        } else {
            let failures = min(ProbeRetryPolicy.maximumFailures, entry.retry.consecutiveFailures + 1)
            entry.retry = ProbeRetryState(consecutiveFailures: failures,
                nextRetryAt: now.addingTimeInterval(policy.interval(afterFailures: failures, jitter: jitter)))
        }
        entries[job.device.did] = entry
        return true
    }

    var nextDeadline: Date? {
        entries.values.filter { !$0.online && $0.job == nil && $0.queued == nil }
            .compactMap { $0.retry.nextRetryAt }.min()
    }

    func hasPendingProbe(_ did: String) -> Bool { entries[did].map { $0.job != nil || $0.queued != nil } ?? false }
}
