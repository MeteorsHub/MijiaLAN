import Foundation
import MijiaLAN
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit development-only launch contract. Parsing/seed validation precede AppModel, vaults and LAN APIs.
struct ReadOnlyAppTest {
    static let flag = "MIJIALAN_READ_ONLY_APP_TEST"
    static let directoryKey = "MIJIALAN_READ_ONLY_APP_TEST_LOG_DIRECTORY"
    static let durationKey = "MIJIALAN_READ_ONLY_APP_TEST_SECONDS"
    static let portKey = "MIJIALAN_READ_ONLY_APP_TEST_PORT"
    let config: LocalHomeConfig
    let directory: URL
    let seconds: Int
    let port: UInt16
    let defaultsSuite: String
    private init(config: LocalHomeConfig, directory: URL, seconds: Int, port: UInt16) {
        self.config = config; self.directory = directory; self.seconds = seconds; self.port = port
        defaultsSuite = "com.mijialan.MijiaLAN.read-only-test." + UUID().uuidString
    }
    struct Rejected: LocalizedError {
        var errorDescription: String? { "Read-only App test rejected: require DEBUG, explicit EPHEMERAL and test flags, one supported curtain seed, a new private log directory and 1...43200 seconds. No App/vault/device initialization occurred." }
    }
    static func isRequested(_ environment: [String: String]) -> Bool {
        [flag, directoryKey, durationKey, portKey].contains { environment[$0] != nil }
    }
    static func prepare(_ environment: [String: String], seedTimeout: TimeInterval = 30) throws -> Self? {
        guard isRequested(environment) else { return nil }
        #if DEBUG
        guard environment[flag] == "1", environment["MIJIALAN_EPHEMERAL"] == "1",
              environment["MIJIALAN_UI_PREVIEW"] != "1", environment["MIJIALAN_SNAPSHOT"] == nil,
              environment["MIJIALAN_PANEL_OPEN_ON_LAUNCH"] != "1",
              let seed = environment["MIJIALAN_SEED_CONFIG"], seed.hasPrefix("/"),
              let path = environment[directoryKey], path.hasPrefix("/"),
              let seconds = environment[durationKey].flatMap(Int.init), (1...43_200).contains(seconds),
              environment[portKey] == nil || environment[portKey].flatMap(UInt16.init).map({ $0 >= 1_024 }) == true
        else { throw Rejected() }
        let port = environment[portKey].flatMap(UInt16.init) ?? MiioPacket.port
        let data = try readSeed(seed, timeout: seedTimeout)
        guard let input = LocalHomeConfig.decode(data), input.devices.count == 1, input.skipped.isEmpty,
              let device = input.devices.first, device.model == CurtainValidationSession.model,
              device.specType == CurtainValidationSession.specification,
              UInt32(device.did).map({ $0 > 0 }) == true, MiioToken.parse(device.token) != nil,
              validHost(device.host) else { throw Rejected() }
        // mkdir is atomic: an existing directory (including another run's) is never reused or chmod'ed.
        guard mkdir(path, 0o700) == 0 else { throw Rejected() }
        let manifest: [String: Any] = ["mode": "readOnlyAppTest", "scope": "experiment", "deviceCount": 1,
            "seconds": seconds, "backgroundSeconds": 30, "foregroundSeconds": 10, "remotePort": port,
            "socket": "stable", "layout": "adaptive", "hello": "periodic", "stamp": "helloAnchored"]
        do {
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path).appendingPathComponent("plan.json"), options: .atomic)
        } catch { throw Rejected() }
        return Self(config: .init(devices: [device]), directory: URL(fileURLWithPath: path, isDirectory: true), seconds: seconds, port: port)
        #else
        throw Rejected()
        #endif
    }
    private static func validHost(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1 && address.s_addr != 0 && address.s_addr != UInt32.max
    }
    /// FileManager.contents may reject FIFOs. Nonblocking open/read handles a private regular file or FIFO,
    /// bounded to 256 KiB and a monotonic deadline. It never prints a path, payload or underlying OS error.
    static func readSeed(_ path: String, timeout: TimeInterval = 30) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Rejected() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else { throw Rejected() }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFIFO) || kind == mode_t(S_IFREG) else { throw Rejected() }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(max(0, min(30, timeout)) * 1_000)))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while ContinuousClock.now < deadline {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard data.count + count <= 262_144 else { throw Rejected() }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                if !data.isEmpty { return data }
                if kind == mode_t(S_IFREG) { throw Rejected() }
                Thread.sleep(forTimeInterval: 0.01) // FIFO writer has not connected (or supplied data) yet.
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 50)
            } else { throw Rejected() }
        }
        throw Rejected()
    }
    @MainActor func configure(_ defaults: UserDefaults) {
        defaults.set([config.devices[0].did], forKey: CurtainControlController.preferenceKey)
        DevicePollingIntervals(foregroundSeconds: 10, backgroundSeconds: 30).save(to: defaults)
        defaults.set(false, forKey: "homekit_bridge_enabled")
        defaults.set(false, forKey: "homekit_bridge_keep_awake")
        defaults.set(false, forKey: "matter.enabled")
        defaults.set(false, forKey: "matter.awake")
        defaults.set(false, forKey: "automatically_checks_for_updates")
    }
}

/// Only a deadline, never a device read timer. Failure is signalled by the normal unified poll callback.
@MainActor
final class ReadOnlyAppTestLifetime {
    private var timer: Task<Void, Never>?
    private(set) var finished = false
    private let finish: @MainActor (DeviceEventLog.Reason) async -> Void
    init(seconds: Int, finish: @escaping @MainActor (DeviceEventLog.Reason) async -> Void) {
        self.finish = finish
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous); await self?.stop(.deadline) } catch { }
        }
    }
    func stop(_ reason: DeviceEventLog.Reason) async {
        guard !finished else { return }
        finished = true; timer?.cancel(); timer = nil
        await finish(reason)
    }
}
