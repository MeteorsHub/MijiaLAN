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
/// `miIO.info` on every device-list refresh until it answers again.
public actor LANMiotAPI: MiCloudAPI {
    private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "LAN")
    private let config: @Sendable () -> LocalHomeConfig
    private let transport: any MiioTransport
    private let port: UInt16
    private let probeTimeout: Duration
    private let commandTimeout: Duration
    private var clients: [String: (device: LocalDevice, client: MiioClient)] = [:]
    private var health: [String: LANDeviceHealth] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var healthObserver: (@Sendable ([String: LANDeviceHealth]) -> Void)?

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
        commandTimeout: Duration = .seconds(5)
    ) {
        self.config = config
        self.transport = transport
        self.port = port
        self.probeTimeout = probeTimeout
        self.commandTimeout = commandTimeout
    }

    public func observeHealth(_ observer: @escaping @Sendable ([String: LANDeviceHealth]) -> Void) {
        healthObserver = observer
        observer(health)
    }

    public func currentHealth() -> [String: LANDeviceHealth] { health }

    // MARK: MiCloudAPI

    public func deviceList() async throws -> [MiDeviceRecord] {
        let devices = config().devices
        let known = Set(devices.map(\.did))
        health = health.filter { known.contains($0.key) }
        clients = clients.filter { known.contains($0.key) }

        // `miIO.info` rather than a bare hello: it also proves the token, so a device whose token was rejected
        // comes back by itself once it answers again. An unsupported device stays put until its config changes.
        let toProbe = devices.filter { ![.online, .unsupported].contains(health[$0.did]?.state) }
        let probeTimeout = probeTimeout
        await withTaskGroup(of: (String, Result<Void, any Error>).self) { group in
            for device in toProbe {
                let client = client(for: device)
                group.addTask {
                    do {
                        _ = try await client.info(timeout: probeTimeout)
                        return (device.did, .success(()))
                    } catch {
                        return (device.did, .failure(error))
                    }
                }
            }
            for await (did, outcome) in group {
                switch outcome {
                case .success: record(did, .online, error: nil)
                case .failure(let error): record(did, Self.isTokenProblem(error) ? .tokenRejected : .offline, error: error)
                }
            }
        }
        publishHealth()
        return devices.map {
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
        let byDid = Dictionary(grouping: keys, by: \.did)
        var values: [MiotPropKey: JSONValue] = [:]
        await withTaskGroup(of: (String, Result<[MiotPropKey: JSONValue], any Error>).self) { group in
            for (did, keys) in byDid {
                guard let device = devices[did] else { continue }
                let client = client(for: device)
                let legacy = LegacyMiioProfile.forModel(device.model)
                let props = keys.map { (siid: $0.siid, piid: $0.piid) }
                group.addTask {
                    do {
                        let fresh = if let legacy {
                            try await client.getProperties(did: did, props, legacy: legacy)
                        } else {
                            try await client.getProperties(did: did, props)
                        }
                        return (did, .success(fresh))
                    } catch {
                        return (did, .failure(error))
                    }
                }
            }
            for await (did, outcome) in group {
                switch outcome {
                case .success(let fresh):
                    values.merge(fresh) { _, new in new }
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
        for (did, group) in Dictionary(grouping: writes, by: \.did) {
            let (device, client) = try client(forDid: did)
            do {
                if let legacy = LegacyMiioProfile.forModel(device.model) {
                    try await client.setProperties(group, legacy: legacy)
                } else {
                    try await client.setProperties(group)
                }
                record(did, .online, error: nil)
            } catch {
                if error as? MiioError != .unsupportedByLegacyDevice { recordFailure(did, error, model: device.model) }
                publishHealth()
                throw error
            }
        }
        publishHealth()
    }

    public func action(_ call: MiotActionCall) async throws {
        let (device, client) = try client(forDid: call.did)
        guard LegacyMiioProfile.forModel(device.model) == nil else { throw MiioError.unsupportedByLegacyDevice }
        do {
            try await client.action(call)
            record(call.did, .online, error: nil)
        } catch {
            recordFailure(call.did, error, model: device.model)
            publishHealth()
            throw error
        }
        publishHealth()
    }

    // MARK: Clients & Health

    private func client(for device: LocalDevice) -> MiioClient {
        if let existing = clients[device.did], existing.device.host == device.host, existing.device.token == device.token {
            return existing.client
        }
        if clients[device.did] != nil {
            // New IP or token (re-import): judge it afresh.
            health[device.did] = nil
            consecutiveFailures[device.did] = 0
        }
        let client = MiioClient(host: device.host, token: MiioToken.parse(device.token) ?? Data(),
                                port: port, transport: transport, timeout: commandTimeout, retries: 1)
        clients[device.did] = (device, client)
        return client
    }

    private func client(forDid did: String) throws -> (LocalDevice, MiioClient) {
        guard let device = config().devices.first(where: { $0.did == did }) else {
            throw MiioError.badResponse("设备 \(did) 不在本地清单里")
        }
        return (device, client(for: device))
    }

    private func record(_ did: String, _ state: LANDeviceHealth.State, error: (any Error)?) {
        record(did, state, message: error.map(Self.describe))
    }

    private func record(_ did: String, _ state: LANDeviceHealth.State, message: String?) {
        var entry = health[did] ?? LANDeviceHealth()
        if entry.state != state {
            logger.info("\(did, privacy: .public) → \(String(describing: state), privacy: .public)")
        }
        entry.state = state
        entry.lastError = message
        if state == .online {
            entry.lastSeen = Date()
            consecutiveFailures[did] = 0
        }
        health[did] = entry
    }

    /// A failed read or write. `miIO.info` has already proved the token by now, so silence here is not a token
    /// problem: a pre-MIoT device without a table answers `get_properties` with `-9999` (or not in time).
    private func recordFailure(_ did: String, _ error: any Error, model: String?) {
        let miio = error as? MiioError
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
        var notMiot = miio == .noEncryptedReply
        if case .deviceError(let code, _) = miio, code == MiioClient.userAckTimeoutCode { notMiot = true }
        guard failures >= Self.failuresBeforeOffline || health[did]?.state != .online else {
            health[did]?.lastError = Self.describe(error)
            return
        }
        if notMiot, let model, LegacyMiioProfile.forModel(model) == nil {
            record(did, .unsupported, message: "这款设备在局域网里只认旧版 miIO 指令，MijiaLAN 还没有 \(model) 的翻译表")
        } else {
            record(did, .offline, error: error)
        }
    }

    private func publishHealth() {
        healthObserver?(health)
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
