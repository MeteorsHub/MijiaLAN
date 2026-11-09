import Foundation
import MijiaCore
import os

/// How a device looks from the LAN right now, for the panel.
public struct LANDeviceHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unknown
        case online
        case offline
        /// It answers, but nothing verifies with the stored token.
        case tokenRejected
        /// The token works, but the device only speaks the pre-MIoT dialect and there is no table for its model.
        case unsupported
    }

    public var state: State = .unknown
    public var lastError: String?
    public var lastSeen: Date?

    public init(state: State = .unknown, lastError: String? = nil, lastSeen: Date? = nil) {
        self.state = state
        self.lastError = lastError
        self.lastSeen = lastSeen
    }
}

/// `MiCloudAPI` served entirely from the LAN, so `MiCloudProvider` (spec loading, synthesis, polling, command
/// mapping) runs unchanged without a Xiaomi account. The device list and rooms come from the stored config.
/// Pre-MIoT models go through their `LegacyMiioProfile` instead of `get_properties` / `set_properties`.
///
/// A device that stops answering is reported offline instead of failing the whole poll, and is probed with
/// authenticated probes on an independent, bounded exponential-backoff scheduler until it answers again.
public actor LANMiotAPI: MiCloudAPI {
    private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "LAN")
    let config: @Sendable () -> LocalHomeConfig
    private let transport: any MiioTransport
    private let port: UInt16
    private let probeTimeout: Duration
    private let commandTimeout: Duration
    private var clients: [String: (device: LocalDevice, client: MiioClient)] = [:]
    private var health: [String: LANDeviceHealth] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var healthObserver: (@Sendable ([String: LANDeviceHealth]) -> Void)?
    private let clock: ProbeClock
    private let jitter: @Sendable () -> Double
    private var probes = ProbeScheduler()
    private var probeTasks: [UUID: Task<Void, Never>] = [:]
    private var probeTimer: Task<Void, Never>?
    private var timerDeadline: Date?
    private var timerGeneration = UUID()
    private var probeWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var healthContinuations: [UUID: AsyncStream<LANHealthUpdate>.Continuation] = [:]
    private var lastPublishedHealth: LANHealthUpdate?
    private var configuredDevices: [LocalDevice]?
    private var isShutdown = false
    public nonisolated let curtainEvents: CurtainEventLog
    private let curtainScheduler = CurtainRequestScheduler()
    private var dailyCurtains: [String: (device: LocalDevice, lease: CurtainValidationLease, session: CurtainControlSession)] = [:]
    private var dailyStarting: Set<String> = []
    private var curtainStarting = false
    private var curtainGeneration = UUID()
    private var curtainSession: (id: UUID, device: LocalDevice, lease: CurtainValidationLease, session: CurtainValidationSession)?

    /// Properties MijiaCore does not ask for but the app shows (a climate device's swing and power draw). They are
    /// read in the same request as the rest of their device, so they cost no extra round trip.
    private var companions: [String: [MiotPropKey]] = [:]
    private var latest: [MiotPropKey: JSONValue] = [:]

    /// Misses in a row before an online device is shown offline; one lost UDP packet is not an outage.
    static let failuresBeforeOffline = 2

    /// - Parameters:
    ///   - probeTimeout: per attempt for the `miIO.info` probe. Devices in Wi-Fi power save take up to ~2 s.
    ///   - commandTimeout: per attempt for reads and writes.
    public init(
        config: @escaping @Sendable () -> LocalHomeConfig,
        transport: any MiioTransport = UDPMiioTransport(),
        port: UInt16 = MiioPacket.port,
        probeTimeout: Duration = .milliseconds(2500),
        commandTimeout: Duration = .seconds(5),
        curtainEvents: CurtainEventLog = .init()
    ) {
        self.init(config: config, transport: transport, port: port, probeTimeout: probeTimeout,
                  commandTimeout: commandTimeout, clock: ProbeClock(), curtainEvents: curtainEvents, jitter: { Double.random(in: 0.9...1.1) })
    }

    init(config: @escaping @Sendable () -> LocalHomeConfig, transport: any MiioTransport,
         port: UInt16 = MiioPacket.port, probeTimeout: Duration = .milliseconds(2500),
         commandTimeout: Duration = .seconds(5), clock: ProbeClock, curtainEvents: CurtainEventLog = .init(), jitter: @escaping @Sendable () -> Double) {
        self.config = config
        self.curtainEvents = curtainEvents
        curtainEvents.registerDevices(config().devices)
        self.transport = transport
        self.port = port
        self.probeTimeout = probeTimeout
        self.commandTimeout = commandTimeout
        self.clock = clock
        self.jitter = jitter
    }

    public func observeHealth(_ observer: @escaping @Sendable ([String: LANDeviceHealth]) -> Void) {
        healthObserver = observer
        observer(health)
    }

    public func currentHealth() -> [String: LANDeviceHealth] { health }
    public func retryStates() -> [String: ProbeRetryState] { probes.retryStates }

    public func healthEvents() -> AsyncStream<LANHealthUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            healthContinuations[id] = continuation
            continuation.yield(LANHealthUpdate(health: health, retries: probes.retryStates))
            continuation.onTermination = { [weak self] _ in Task { await self?.removeHealthContinuation(id) } }
        }
    }

    private func removeHealthContinuation(_ id: UUID) { healthContinuations[id] = nil }

    /// Starts/reschedules probes without making online property reads wait for offline timeouts.
    public func startProbing() {
        guard !isShutdown else { return }
        synchronizeConfiguration()
        publishHealth()
    }

    /// Session-only, one selected curtain. The ordinary property/control policy remains closed.
    public func beginCurtainValidation(did: String) async throws -> CurtainValidationSession {
        try await beginCurtainValidation(did: did, clock: CurtainValidationSession.Clock())
    }

    func beginCurtainValidation(did: String, clock: CurtainValidationSession.Clock) async throws -> CurtainValidationSession {
        guard !isShutdown, !curtainStarting, dailyCurtains.isEmpty, dailyStarting.isEmpty else { throw DeviceControlError.busy }
        let device = try localDevice(forDid: did)
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification else {
            throw DeviceControlError.unsupported("Curtain model/specification")
        }
        curtainStarting = true
        defer { curtainStarting = false }
        let generation = UUID()
        curtainGeneration = generation
        let previous = curtainSession
        curtainSession = nil
        previous?.lease.invalidate()
        if let previous { await previous.session.end() }
        // Cancel automatic metadata probes for all curtains before the selected session starts.
        // Keep them suspended for this API lifetime, including when validation pauses or is disabled.
        configuredDevices = nil
        synchronizeConfiguration()
        for existing in clients.values where existing.device.model == CurtainValidationSession.model {
            try await existing.client.waitUntilIdle()
        }
        try Task.checkCancellation()
        guard curtainGeneration == generation, !isShutdown,
              config().devices.contains(where: { ProbeScheduler.sameEndpoint($0, device) && $0.specType == device.specType }) else {
            throw DeviceControlError.wrongDevice
        }
        let lease = CurtainValidationLease()
        let source = config
        let session = CurtainValidationSession(device: device, client: client(for: device), clock: clock, isCurrent: {
            lease.isValid && source().devices.contains { ProbeScheduler.sameEndpoint($0, device) && $0.specType == device.specType }
        }, onInfo: { [weak self] in await self?.curtainInfoReceived(device: device, generation: generation) })
        curtainSession = (generation, device, lease, session)
        return session
    }

    /// App controls are opt-in; unified read-only polling uses this same verified per-device session.
    public func beginCurtainControl(did: String) async throws -> CurtainControlSession {
        try await beginCurtainControl(did: did, scheduler: curtainScheduler, clock: .init())
    }
    func beginCurtainControl(did: String, scheduler: CurtainRequestScheduler, clock: CurtainValidationSession.Clock) async throws -> CurtainControlSession {
        guard !isShutdown, curtainSession == nil, !curtainStarting, !dailyStarting.contains(did) else { throw DeviceControlError.busy }
        let device = try localDevice(forDid: did)
        guard device.model == CurtainValidationSession.model, device.specType == CurtainValidationSession.specification else {
            throw DeviceControlError.unsupported("Curtain model/specification")
        }
        if let existing = dailyCurtains[did], ProbeScheduler.sameEndpoint(existing.device, device), existing.device.specType == device.specType {
            return existing.session
        }
        dailyStarting.insert(did)
        defer { dailyStarting.remove(did) }
        configuredDevices = nil
        synchronizeConfiguration()
        // Quiesce legacy metadata paths before any managed session can send packets.
        for existing in clients.values where existing.device.model == CurtainValidationSession.model {
            try await existing.client.waitUntilIdle()
        }
        try Task.checkCancellation()
        guard !isShutdown, config().devices.contains(where: { ProbeScheduler.sameEndpoint($0, device) && $0.specType == device.specType }) else {
            throw DeviceControlError.wrongDevice
        }
        let lease = CurtainValidationLease(), source = config
        let session = CurtainControlSession(device: device, client: client(for: device), scheduler: scheduler, clock: clock, isCurrent: {
            lease.isValid && source().devices.contains { ProbeScheduler.sameEndpoint($0, device) && $0.specType == device.specType }
        }, onInfo: { [weak self] in await self?.dailyCurtainInfoReceived(device) }, journal: curtainEvents)
        dailyCurtains[did] = (device, lease, session)
        return session
    }
    public func endCurtainControl(did: String) async {
        guard let previous = dailyCurtains.removeValue(forKey: did) else { return }
        previous.lease.invalidate()
        await previous.session.end()
    }
    private func dailyCurtainInfoReceived(_ device: LocalDevice) {
        guard !isShutdown, let active = dailyCurtains[device.did], active.lease.isValid,
              ProbeScheduler.sameEndpoint(active.device, device) else { return }
        record(device.did, .online, error: nil); publishHealth()
    }

    public func endCurtainValidation() async {
        curtainGeneration = UUID()
        let previous = curtainSession
        curtainSession = nil
        previous?.lease.invalidate()
        if let previous { await previous.session.end() }
    }

    private func curtainInfoReceived(device: LocalDevice, generation: UUID) {
        guard curtainSession?.id == generation, !isShutdown,
              config().devices.contains(where: { ProbeScheduler.sameEndpoint($0, device) }) else { return }
        record(device.did, .online, error: nil)
        publishHealth()
    }

    /// An explicit UI retry probes this device immediately, independently of the background retry interval.
    public func retryDevice(did: String) async {
        guard !isShutdown else { return }
        synchronizeConfiguration()
        guard config().devices.contains(where: { $0.did == did }) else { return }
        probes.enqueue(did, priority: .manual)
        publishHealth()
        await waitForProbe(did)
    }

    /// One opportunistic authenticated verification per known offline responder in this discovery round.
    public func retryDiscoveredDevices(_ dids: Set<String>) {
        guard !isShutdown else { return }
        synchronizeConfiguration()
        for did in dids where health[did]?.state != .online && health[did]?.state != .unsupported {
            probes.enqueue(did, priority: .discovery)
        }
        publishHealth()
    }

    public func setCompanions(_ keys: [MiotPropKey], for did: String) {
        companions[did] = keys.isEmpty ? nil : keys
    }

    /// The last value actually read from the device, companions included.
    public func latestValue(_ key: MiotPropKey) -> JSONValue? {
        guard let device = config().devices.first(where: { $0.did == key.did }),
              DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { return nil }
        return latest[key]
    }

    // MARK: MiCloudAPI

    public func deviceList() async throws -> [MiDeviceRecord] {
        guard !isShutdown else { throw CancellationError() }
        synchronizeConfiguration()
        publishHealth()
        // Compatibility for MiCloudAPI callers. The capability controller uses startProbing instead.
        let pending = config().devices.map(\.did).filter { probes.hasPendingProbe($0) }
        await withTaskGroup(of: Void.self) { group in
            for did in pending { group.addTask { await self.waitForProbe(did) } }
        }
        return config().devices.map {
            MiDeviceRecord(did: $0.did, name: $0.name, model: $0.model,
                           isOnline: health[$0.did]?.state == .online, specType: $0.specType)
        }
    }

    public func homeRooms() async throws -> [MiRoom] {
        var order: [String] = []
        var dids: [String: [String]] = [:]
        for device in config().devices {
            let room = device.roomName ?? ""
            if dids[room] == nil { order.append(room) }
            dids[room, default: []].append(device.did)
        }
        // The empty room name puts devices in 全屋.
        return order.map { MiRoom(id: "room:\($0)", name: $0, dids: dids[$0] ?? []) }
    }

    /// Never throws for one device: the rest of the home still updates and the silent one is marked offline.
    public func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        let devices = Dictionary(config().devices.map { ($0.did, $0) }, uniquingKeysWith: { first, _ in first })
        let requested = Set(keys)
        let byDid = Dictionary(grouping: keys, by: \.did)
        var values: [MiotPropKey: JSONValue] = [:]
        await withTaskGroup(of: (LocalDevice, MiioClient, Result<[MiotPropKey: JSONValue], any Error>).self) { group in
            for (did, keys) in byDid {
                guard let device = devices[did], DeviceLANPolicy.allowsPropertyRequests(for: device.model) else { continue }
                let client = client(for: device)
                let legacy = LegacyMiioProfile.forModel(device.model)
                let extra = (companions[did] ?? []).filter { !requested.contains($0) }
                let props = (keys + extra).map { (siid: $0.siid, piid: $0.piid) }
                group.addTask {
                    do {
                        let fresh = if let legacy {
                            try await client.getProperties(did: did, props, legacy: legacy)
                        } else {
                            try await client.getProperties(did: did, props)
                        }
                        return (device, client, .success(fresh))
                    } catch {
                        return (device, client, .failure(error))
                    }
                }
            }
            for await (device, client, outcome) in group {
                guard isCurrent(device, client: client) else { continue }
                let did = device.did
                switch outcome {
                case .success(let fresh):
                    latest.merge(fresh) { _, new in new }
                    values.merge(fresh.filter { requested.contains($0.key) }) { _, new in new }
                    record(did, .online, error: nil)
                case .failure(let error):
                    recordFailure(did, error, model: devices[did]?.model)
                }
            }
        }
        publishHealth()
        return values
    }

    public func setProps(_ writes: [MiotPropWrite]) async throws {
        // Validate the entire batch before any device receives a write.
        for did in Set(writes.map(\.did)) {
            let device = try localDevice(forDid: did)
            if let reason = DeviceLANPolicy.restriction(for: device.model) { throw DeviceControlError.unsupported(reason) }
        }
        for (did, group) in Dictionary(grouping: writes, by: \.did) {
            let (device, client) = try client(forDid: did)
            do {
                if let legacy = LegacyMiioProfile.forModel(device.model) {
                    try await client.setProperties(group, legacy: legacy)
                } else {
                    try await client.setProperties(group)
                }
                guard isCurrent(device, client: client) else { throw CancellationError() }
                record(did, .online, error: nil)
            } catch {
                guard isCurrent(device, client: client) else { throw CancellationError() }
                if error as? MiioError != .unsupportedByLegacyDevice { recordFailure(did, error, model: device.model) }
                publishHealth()
                throw error
            }
        }
        publishHealth()
    }

    public func action(_ call: MiotActionCall) async throws {
        let device = try localDevice(forDid: call.did)
        if let reason = DeviceLANPolicy.restriction(for: device.model) { throw DeviceControlError.unsupported(reason) }
        let client = client(for: device)
        guard LegacyMiioProfile.forModel(device.model) == nil else { throw MiioError.unsupportedByLegacyDevice }
        do {
            try await client.action(call)
            guard isCurrent(device, client: client) else { throw CancellationError() }
            record(call.did, .online, error: nil)
        } catch {
            guard isCurrent(device, client: client) else { throw CancellationError() }
            recordFailure(call.did, error, model: device.model)
            publishHealth()
            throw error
        }
        publishHealth()
    }

    // MARK: Clients & Health

    public func readCapabilities(did: String, capabilities: [DeviceCapability]) async -> [String: DeviceReading] {
        var endpoint: (LocalDevice, MiioClient)?
        do {
            let device = try localDevice(forDid: did)
            if let reason = DeviceLANPolicy.restriction(for: device.model) {
                return Dictionary(uniqueKeysWithValues: capabilities.filter(\.readable).map {
                    ($0.id, DeviceReading(error: reason))
                })
            }
            let client = client(for: device)
            endpoint = (device, client)
            let props = capabilities.filter { $0.readable }.map { (siid: $0.siid, piid: $0.iid) }
            let readings: [MiotPropKey: DeviceReading]
            if let legacy = LegacyMiioProfile.forModel(device.model) {
                let values = try await client.getProperties(did: did, props, legacy: legacy)
                readings = Dictionary(uniqueKeysWithValues: props.map { p in
                    let key = MiotPropKey(did: did, siid: p.siid, piid: p.piid)
                    return (key, DeviceReading(value: values[key], updatedAt: Date(), code: values[key] == nil ? nil : 0,
                                              error: values[key] == nil ? L10n.tr("未返回有效读数", "No valid reading was returned.") : nil))
                })
            } else {
                readings = try await client.readProperties(did: did, props)
            }
            guard isCurrent(device, client: client) else { return [:] }
            for (key, reading) in readings where reading.isAvailable { latest[key] = reading.value }
            record(did, .online, error: nil)
            publishHealth()
            return Dictionary(uniqueKeysWithValues: readings.map { (DeviceCapability.propertyID($0.key.siid, $0.key.piid), $0.value) })
        } catch {
            if let (device, client) = endpoint, !isCurrent(device, client: client) { return [:] }
            recordFailure(did, error, model: nil)
            publishHealth()
            return Dictionary(uniqueKeysWithValues: capabilities.filter(\.readable).map { ($0.id, DeviceReading(error: Self.describe(error))) })
        }
    }

    private func client(for device: LocalDevice) -> MiioClient {
        if let existing = clients[device.did], ProbeScheduler.sameEndpoint(existing.device, device) {
            return existing.client
        }
        if clients[device.did] != nil {
            // New IP or token (re-import): judge it afresh.
            health[device.did] = nil
            consecutiveFailures[device.did] = 0
        }
        let client = MiioClient(host: device.host, token: MiioToken.parse(device.token) ?? Data(),
                                port: port, transport: transport, timeout: commandTimeout, retries: 1, knownModel: device.model, events: curtainEvents, eventIdentifier: device.did)
        clients[device.did] = (device, client)
        return client
    }

    private func localDevice(forDid did: String) throws -> LocalDevice {
        guard let device = config().devices.first(where: { $0.did == did }) else {
            throw MiioError.badResponse(L10n.tr("设备 \(did) 不在本地清单里", "Device \(did) is not in the local list."))
        }
        return device
    }

    private func client(forDid did: String) throws -> (LocalDevice, MiioClient) {
        let device = try localDevice(forDid: did)
        return (device, client(for: device))
    }

    private func record(_ did: String, _ state: LANDeviceHealth.State, error: (any Error)?) {
        record(did, state, message: error.map(Self.describe))
    }

    private func record(_ did: String, _ state: LANDeviceHealth.State, message: String?) {
        var entry = health[did] ?? LANDeviceHealth()
        if entry.state != state {
            logger.info("\(did, privacy: .private) → \(String(describing: state), privacy: .public)")
        }
        entry.state = state
        entry.lastError = message
        if state == .online {
            entry.lastSeen = clock.now()
            consecutiveFailures[did] = 0
            if let cancelled = probes.markOnline(did) { cancelProbe(cancelled, did: did) }
        } else if state == .offline || state == .tokenRejected {
            probes.markOffline(did, now: clock.now())
        }
        health[did] = entry
    }

    /// A failed read or write. `miIO.info` has already proved the token by now, so silence here is not a token
    /// problem: a pre-MIoT device without a table answers `get_properties` with `-9999` (or not in time).
    private func recordFailure(_ did: String, _ error: any Error, model: String?) {
        guard !(error is CancellationError) else { return }
        let miio = error as? MiioError
        if case .deviceError(let code, _) = miio, code != MiioClient.userAckTimeoutCode {
            // A rejected property proves the transport works; it does not mean the entire device is offline.
            record(did, .online, error: error)
            return
        }
        if miio == .checksumMismatch {
            record(did, .tokenRejected, error: error)
            return
        }
        if miio == .hostUnreachable {
            record(did, .offline, error: error)
            return
        }
        let failures = (consecutiveFailures[did] ?? 0) + 1
        consecutiveFailures[did] = failures
        guard failures >= Self.failuresBeforeOffline || health[did]?.state != .online else {
            health[did]?.lastError = Self.describe(error)
            return
        }
        // Silence is not evidence of a legacy dialect. Retry offline devices instead of permanently excluding them.
        record(did, .offline, error: error)
    }

    private func publishHealth() {
        guard !isShutdown else { return }
        runReadyProbes()
        let update = LANHealthUpdate(health: health, retries: probes.retryStates)
        guard !update.hasSameState(as: lastPublishedHealth) else { return }
        lastPublishedHealth = update
        healthObserver?(health)
        for continuation in healthContinuations.values { continuation.yield(update) }
    }

    private func synchronizeConfiguration() {
        let devices = config().devices
        guard devices != configuredDevices else { return }
        for old in configuredDevices ?? [] where !devices.contains(where: { ProbeScheduler.sameEndpoint($0, old) }) {
            resumeProbeWaiters(old.did)
        }
        if let active = curtainSession, !devices.contains(where: { ProbeScheduler.sameEndpoint($0, active.device) && $0.specType == active.device.specType }) {
            active.lease.invalidate()
            curtainSession = nil
            curtainGeneration = UUID()
            Task { await active.session.end() }
        }
        for (did, active) in dailyCurtains where !devices.contains(where: { ProbeScheduler.sameEndpoint($0, active.device) && $0.specType == active.device.specType }) {
            active.lease.invalidate()
            dailyCurtains[did] = nil
            Task { await active.session.end() }
        }
        for device in devices where device.model == CurtainValidationSession.model {
            curtainEvents.record(device.did, source: .legacyProbe, stage: .idle, outcome: .noPacket, reason: .manualOnly)
        }
        curtainEvents.registerDevices(devices)
        configuredDevices = devices
        let known = Set(devices.map(\.did))
        for (did, existing) in clients where !devices.contains(where: { ProbeScheduler.sameEndpoint($0, existing.device) }) {
            clients[did] = nil; health[did] = nil; consecutiveFailures[did] = nil
            companions[did] = nil
        }
        health = health.filter { known.contains($0.key) }
        latest = latest.filter { known.contains($0.key.did) && clients[$0.key.did] != nil }
        for id in probes.configure(devices.filter { $0.model != CurtainValidationSession.model }) { cancelProbe(id) }
    }

    private func isCurrent(_ device: LocalDevice, client: MiioClient) -> Bool {
        !isShutdown && clients[device.did]?.client === client && config().devices.contains { ProbeScheduler.sameEndpoint($0, device) }
    }

    private func runReadyProbes() {
        for job in probes.startReady(now: clock.now()) {
            let client = client(for: job.device)
            let timeout = probeTimeout
            probeTasks[job.id] = Task { [weak self] in
                let result: Result<Void, any Error>
                do {
                    let source: DeviceEventLog.Source = job.priority == .discovery ? .discovery : (job.priority == .manual ? .manualRead : .legacyProbe)
                    _ = try await DeviceCommunicationContext.$source.withValue(source) {
                        try await DeviceCommunicationContext.$operation.withValue(job.id) { try await client.info(timeout: timeout) }
                    }
                    result = .success(())
                }
                catch { result = .failure(error) }
                guard !Task.isCancelled else { return }
                await self?.finishProbe(job, client: client, result: result)
            }
        }
        let deadline = probes.nextDeadline
        guard deadline != timerDeadline else { return }
        probeTimer?.cancel(); probeTimer = nil; timerDeadline = deadline
        timerGeneration = UUID()
        guard let deadline else { return }
        let generation = timerGeneration
        let clock = clock
        probeTimer = Task { [weak self] in
            do { try await clock.sleep(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.probeTimerFired(generation)
        }
    }

    private func probeTimerFired(_ generation: UUID) {
        guard generation == timerGeneration else { return }
        timerDeadline = nil; probeTimer = nil
        synchronizeConfiguration()
        publishHealth()
    }

    private func finishProbe(_ job: ProbeScheduler.Job, client: MiioClient, result: Result<Void, any Error>) {
        probeTasks[job.id] = nil
        guard !isShutdown else { return }
        guard isCurrent(job.device, client: client) else {
            synchronizeConfiguration(); publishHealth(); return
        }
        let succeeded: Bool
        switch result { case .success: succeeded = true; case .failure: succeeded = false }
        guard probes.complete(job, succeeded: succeeded, now: clock.now(), jitter: jitter()) else { return }
        switch result {
        case .success: record(job.device.did, .online, error: nil)
        case .failure(let error): record(job.device.did, Self.isTokenProblem(error) ? .tokenRejected : .offline, error: error)
        }
        resumeProbeWaiters(job.device.did)
        publishHealth()
    }

    private func waitForProbe(_ did: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, probes.hasPendingProbe(did) else { continuation.resume(); return }
                probeWaiters[did, default: [:]][id] = continuation
            }
        } onCancel: { Task { await self.cancelProbeWaiter(did, id: id) } }
    }

    private func cancelProbeWaiter(_ did: String, id: UUID) {
        probeWaiters[did]?.removeValue(forKey: id)?.resume()
        if probeWaiters[did]?.isEmpty == true { probeWaiters[did] = nil }
    }

    private func resumeProbeWaiters(_ did: String) {
        for waiter in probeWaiters.removeValue(forKey: did)?.values ?? [:].values { waiter.resume() }
    }

    private func cancelProbe(_ id: UUID, did: String? = nil) {
        probeTasks.removeValue(forKey: id)?.cancel()
        if let did { resumeProbeWaiters(did) }
        // Endpoint replacement/removal resolves old callers as well as discarding the late result.
        for key in Array(probeWaiters.keys) where !probes.hasPendingProbe(key) { resumeProbeWaiters(key) }
    }

    public func shutdown() {
        for active in dailyCurtains.values {
            active.lease.invalidate()
            Task { await active.session.end() }
        }
        dailyCurtains = [:]
        if let active = curtainSession {
            active.lease.invalidate()
            curtainSession = nil
            Task { await active.session.end() }
        }
        curtainGeneration = UUID()

        isShutdown = true
        probeTimer?.cancel(); probeTimer = nil; timerDeadline = nil
        for task in probeTasks.values { task.cancel() }; probeTasks = [:]
        for did in Array(probeWaiters.keys) { resumeProbeWaiters(did) }
        for continuation in healthContinuations.values { continuation.finish() }; healthContinuations = [:]
        probes = ProbeScheduler()
        clients = [:]; latest = [:]; companions = [:]
    }

    /// Only for the `miIO.info` probe, which every miIO device answers.
    static func isTokenProblem(_ error: any Error) -> Bool {
        guard let error = error as? MiioError else { return false }
        return error == .checksumMismatch || error == .noEncryptedReply
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

public struct LANHealthUpdate: Sendable {
    public var health: [String: LANDeviceHealth]
    public var retries: [String: ProbeRetryState]

    func hasSameState(as previous: LANHealthUpdate?) -> Bool {
        guard let previous, retries == previous.retries, health.count == previous.health.count else { return false }
        return health.allSatisfy { did, value in
            value.state == previous.health[did]?.state && value.lastError == previous.health[did]?.lastError
        }
    }
}
