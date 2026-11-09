import Foundation

/// Bounded, typed local journal. No arbitrary strings, identifiers, addresses, credentials or payloads.
public final class DeviceEventLog: @unchecked Sendable {
    public static let defaultFileLimit = 16 * 1_024 * 1_024
    public static let defaultTrafficCapacity = 4 * defaultFileLimit
    public static let importantCapacity = 4 * 1_024 * 1_024
    public enum Source: String, Codable, Sendable {
        case preference, startup, manualRead, manualPosition, manualOpen, manualClose, manualStop
        case postWriteRead, idleBackground, legacyProbe, discovery, lifecycle
        case backgroundPoll, userControl, homeKit, matter, manualAdd, experiment, other
    }
    public enum Stage: String, Codable, Sendable { case idle, requested, waiting, hello, info, preflight, write, confirmation, finished }
    public enum Outcome: String, Codable, Sendable { case noPacket, queued, attempt, sent, received, packetChecked, discarded, closed, responseCode, observedValue, validated, sample, acknowledged, confirmed, paused, cancelled }
    public enum Reason: String, Codable, Sendable {
        case manualOnly, timeout, propertyError, invalidReply, identity, firmware, cancelled, unconfirmed, deadline, busy, configuration, transport, deduplicated, untrustedReading, unexpectedPeer, clockDiscontinuity
    }
    public enum Kind: String, Codable, Sendable { case hello, info, read, write, action, legacyRead, legacyWrite, broadcast, other }
    public enum ValueType: String, Codable, Sendable { case number, boolean, string, object, array, null }
    public enum Scope: String, Codable, Sendable { case app, simulation, offlineTest, experiment }
    public struct Event: Codable, Equatable, Sendable {
        public let run: UUID
        public let sequence: Int
        public let timestamp: Date
        public let milliseconds: Int64
        public let device: Int
        public let operation: UUID?
        public let source: Source
        public let stage: Stage
        public let outcome: Outcome
        public let reason: Reason?
        public let code: Int?
        public let kind: Kind?
        public let siid: Int?
        public let aiid: Int?
        public let piid: Int?
        public let value: Int?
        public let valueType: ValueType?
        public let booleanValue: Bool?
        public let target: Int?
        public let position: Int?
        public let motorStatus: Int?
        public let elapsedMilliseconds: Int64?
        public let writeAttempted: Bool?
        public let writeSent: Bool?
        public let writeAcknowledged: Bool?
        public let packet: MiioPacketDiagnostics?
        public let scope: Scope
    }
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MijiaLAN/Diagnostics/device-events.jsonl")
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MijiaLAN.curtain-journal", qos: .utility)
    private let fileURL: URL?
    private let maxEvents: Int
    private let scope: Scope
    private let run = UUID()
    private let origin = ContinuousClock.now
    private var aliases: [String: Int] = [:] // Only memory; never encoded.
    private var events: [Event] = []
    private var sequence = 0
    private var important: [Event] = []
    private var hosts: [String: String] = [:]
    private let fileLimit: Int
    private var lastBackgroundArchive: [String: Int64] = [:]
    private var failedStorage = false
    public var storageFailed: Bool { lock.withLock { failedStorage } }

    public init(fileURL: URL? = nil, maxEvents: Int = 2_048, scope: Scope = .app, fileLimit: Int = DeviceEventLog.defaultFileLimit) {
        self.fileURL = fileURL; self.maxEvents = min(2_048, max(1, maxEvents)); self.scope = scope
        self.fileLimit = min(Self.defaultFileLimit, max(1_024, fileLimit))
        if let fileURL {
            events = Self.loadRecent(Self.files(fileURL), count: self.maxEvents, limit: self.fileLimit)
            important = Self.loadRecent(Self.files(fileURL.appendingPathExtension("important")), count: self.maxEvents, limit: min(self.fileLimit, 1_048_576))
        }
    }
    public func registerDevices(_ devices: [LocalDevice]) {
        register(devices.map(\.did))
        lock.withLock { for device in devices { hosts[device.host] = device.did } }
    }
    /// Unknown responders receive a random in-memory key. Neither address nor key is exported.
    func identifier(forHost host: String) -> String {
        lock.withLock {
            if let existing = hosts[host] { return existing }
            let key = UUID().uuidString; hosts[host] = key; return key
        }
    }
    public func register(_ identifiers: [String]) {
        lock.withLock {
            for identifier in identifiers.sorted() where aliases[identifier] == nil { aliases[identifier] = aliases.count + 1 }
        }
    }
    public func alias(for identifier: String) -> Int {
        if identifier == "application" { return 0 }
        return lock.withLock {
            if let value = aliases[identifier] { return value }
            let value = aliases.count + 1; aliases[identifier] = value; return value
        }
    }
    private var milliseconds: Int64 {
        let duration = origin.duration(to: .now).components
        return duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
    }
    public func record(_ identifier: String, operation: UUID? = nil, source: Source, stage: Stage, outcome: Outcome,
                       reason: Reason? = nil, code: Int? = nil, kind: Kind? = nil, siid: Int? = nil, aiid: Int? = nil, piid: Int? = nil, value: Int? = nil, valueType: ValueType? = nil, booleanValue: Bool? = nil, target: Int? = nil,
                       position: Int? = nil, motorStatus: Int? = nil, elapsedMilliseconds: Int64? = nil, writeAttempted: Bool? = nil, writeSent: Bool? = nil, writeAcknowledged: Bool? = nil, packet: MiioPacketDiagnostics? = nil) {
        let device = alias(for: identifier)
        lock.withLock {
            sequence += 1
            let event = Event(run: run, sequence: sequence, timestamp: Date(), milliseconds: milliseconds, device: device,
                operation: operation, source: source, stage: stage, outcome: outcome, reason: reason,
                code: code,
                kind: kind, siid: siid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                aiid: aiid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                piid: piid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                value: value.flatMap { (0...100).contains($0) ? $0 : nil }, valueType: valueType, booleanValue: booleanValue, target: target.flatMap { (0...100).contains($0) ? $0 : nil },
                position: position.flatMap { (0...100).contains($0) ? $0 : nil }, motorStatus: motorStatus.flatMap { (0...4).contains($0) ? $0 : nil },
                elapsedMilliseconds: elapsedMilliseconds, writeAttempted: writeAttempted, writeSent: writeSent, writeAcknowledged: writeAcknowledged, packet: packet, scope: scope)
            events.append(event)
            if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
            var keep = Self.isImportant(event)
            let background: Set<Source> = [.backgroundPoll, .legacyProbe, .idleBackground, .discovery]
            if keep, background.contains(event.source), event.outcome == .paused || (event.code != nil && event.code != 0) {
                let signature = "\(event.device):\(event.stage):\(event.kind?.rawValue ?? "-"):\(event.siid ?? 0):\(event.piid ?? 0):\(event.code ?? 0):\(event.reason?.rawValue ?? "-")"
                if let last = lastBackgroundArchive[signature], event.milliseconds - last < 1_800_000 { keep = false }
                else {
                    if lastBackgroundArchive.count >= 512 { lastBackgroundArchive = [:] }
                    lastBackgroundArchive[signature] = event.milliseconds
                }
            }
            var critical: [Event] = []
            if keep {
                let batch: [Event]
                if event.outcome == .paused || (event.code != nil && event.code != 0), let operation = event.operation {
                    // Preserve the matching request/sent/reply context before normal polling rolls it out.
                    batch = events.filter { $0.run == event.run && $0.operation == operation }
                } else { batch = [event] }
                var seen = Set(important.map { $0.run.uuidString + ":" + String($0.sequence) })
                for row in batch where seen.insert(row.run.uuidString + ":" + String(row.sequence)).inserted { critical.append(row) }
                important += critical
                if important.count > maxEvents { important.removeFirst(important.count - maxEvents) }
            }
            if let fileURL {
                let retained = critical
                queue.async {
                    do {
                        try Self.append(Self.encode([event]), to: fileURL, limit: self.fileLimit)
                        for row in retained { try Self.append(Self.encode([row]), to: fileURL.appendingPathExtension("important"), limit: min(self.fileLimit, 1_048_576)) }
                    } catch { self.lock.withLock { self.failedStorage = true } }
                }
            }
        }
    }
    public func snapshot() -> [Event] { lock.withLock { events } }
    public func recentText(importantOnly: Bool = false) -> String {
        let copy = lock.withLock { importantOnly ? important : events }
        return String(decoding: Self.encode(Array(copy.suffix(200))), as: UTF8.self)
    }
    /// Bounded in-memory convenience. Full on-disk history uses streaming export(to:).
    public func exportData() -> Data {
        let copy = lock.withLock { events + important }
        var seen: Set<String> = []
        return Self.encode(copy.filter { seen.insert($0.run.uuidString + ":" + String($0.sequence)).inserted }
            .sorted { $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp })
    }

    public struct Coverage: Sendable {
        public let oldest: Date?
        public let newest: Date?
        public let bytes: UInt64
    }
    public struct History: Sendable {
        public let traffic: Coverage
        public let important: Coverage
    }
    /// Metadata and edge records only; never decodes the full archive to show its time bounds.
    public func history() async -> History {
        await withCheckedContinuation { continuation in
            queue.async {
                func coverage(_ url: URL?, memory: [Event], limit: Int) -> Coverage {
                    guard let url else { return Coverage(oldest: memory.first?.timestamp, newest: memory.last?.timestamp, bytes: 0) }
                    var oldest: Date?, newest: Date?, bytes: UInt64 = 0
                    for path in Self.files(url) {
                        guard let reader = try? DeviceLogHistoryReader(path, limit: limit) else { continue }
                        bytes += reader.length
                        let first = try? reader.next()
                        let last = Self.loadRecent([path], count: 1, limit: limit).last
                        if let time = first?.timestamp { oldest = min(oldest ?? time, time) }
                        if let time = last?.timestamp { newest = max(newest ?? time, time) }
                    }
                    return Coverage(oldest: oldest, newest: newest, bytes: bytes)
                }
                let memory = self.lock.withLock { (self.events, self.important) }
                continuation.resume(returning: History(
                    traffic: coverage(self.fileURL, memory: memory.0, limit: self.fileLimit),
                    important: coverage(self.fileURL?.appendingPathExtension("important"), memory: memory.1, limit: min(self.fileLimit, 1_048_576))))
            }
        }
    }
    /// File handles and lengths are captured before rotation can change paths. Decode/encode one row at a
    /// time off the main actor; open descriptors survive concurrent rotation without blocking log writes.
    /// Traffic and the separately retained important archive are both included. Their overlap may repeat
    /// (run, sequence); export preserves history without an unbounded in-memory deduplication index.
    public func export(to destination: URL) async throws {
        try await Task.detached(priority: .utility) { try self.writeHistory(to: destination) }.value
    }
    private func writeHistory(to destination: URL) throws {
        let captured: ([DeviceLogHistoryReader], [Event]) = try queue.sync {
            var readers: [DeviceLogHistoryReader] = []
            if let fileURL {
                let paths = Self.files(fileURL) + Self.files(fileURL.appendingPathExtension("important"))
                guard !paths.contains(where: { $0.standardizedFileURL == destination.standardizedFileURL }) else { throw CocoaError(.fileWriteInvalidFileName) }
                for path in paths where FileManager.default.fileExists(atPath: path.path) {
                    let limit = path.lastPathComponent.contains("important") ? min(fileLimit, 1_048_576) : fileLimit
                    readers.append(try DeviceLogHistoryReader(path, limit: limit))
                }
            }
            return (readers, lock.withLock { events + important })
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".MijiaLAN-export-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            for reader in captured.0 {
                while let event = try reader.next() { try output.write(contentsOf: Self.encode([event])) }
            }
            // Also preserve current memory records when disk storage failed or is disabled (bounded).
            if captured.0.isEmpty || storageFailed { try output.write(contentsOf: Self.encode(captured.1)) }
            try output.close()
        } catch { try? output.close(); throw error }
        try DeviceLogHistoryReader.replace(temporary, destination)
    }
    public func exportText() -> String { String(decoding: exportData(), as: UTF8.self) }
    public func flush() { queue.sync {} }
    private static func isImportant(_ event: Event) -> Bool {
        let manual: Set<Source> = [.preference, .startup, .experiment, .manualRead, .manualPosition, .manualOpen, .manualClose, .manualStop, .postWriteRead, .userControl, .homeKit, .matter, .manualAdd]
        return manual.contains(event.source) || (event.code != nil && event.code != 0) || event.outcome == .paused || event.outcome == .cancelled || event.kind == .write || event.kind == .legacyWrite || event.kind == .action
    }
    private static func encode(_ events: [Event]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return events.reduce(into: Data()) { if let line = try? encoder.encode($1) { $0.append(line); $0.append(10) } }
    }
    private static func files(_ url: URL) -> [URL] {
        (1...3).reversed().map { url.appendingPathExtension(String($0)) } + [url]
    }
    private static func loadRecent(_ paths: [URL], count: Int, limit: Int) -> [Event] {
        var result: [Event] = []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // At most 2 MiB per file, newest files first. The UI retains at most 2,048 decoded events.
        for path in paths.reversed() where result.count < count {
            guard let size = try? freshFileSize(path), size <= UInt64(limit),
                  let file = try? FileHandle(forReadingFrom: path) else { continue }
            defer { try? file.close() }
            let start = size > 2_097_152 ? size - 2_097_152 : 0
            guard (try? file.seek(toOffset: start)) != nil,
                  let data = try? file.read(upToCount: Int(size - start)) else { continue }
            let lines = data.split(separator: 10)
            let complete = start == 0 ? lines[...] : lines.dropFirst()
            var rows: [Event] = []
            for line in complete.reversed() {
                if line.count <= DeviceLogHistoryReader.maximumLineBytes,
                   let event = try? decoder.decode(Event.self, from: Data(line)) { rows.append(event) }
                if rows.count == count - result.count { break }
            }
            result = rows.reversed() + result
        }
        return Array(result.suffix(count))
    }
    /// URL resource values can cache the pre-append size on macOS, including across rotation.
    private static func freshFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return size.uint64Value
    }
    private static func append(_ data: Data, to url: URL, limit: Int) throws {
        guard data.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let size = fm.fileExists(atPath: url.path) ? try freshFileSize(url) : 0
        if size > UInt64(limit) || UInt64(data.count) > UInt64(limit) - size {
            let oldest = url.appendingPathExtension("3")
            if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
            for index in (0...2).reversed() {
                let source = index == 0 ? url : url.appendingPathExtension(String(index))
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: url.appendingPathExtension(String(index + 1))) }
            }
        }
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    func wire(_ identifier: String, operation: UUID, source: Source, stage: Stage, kind: Kind) -> @Sendable (CurtainWireEvent) -> Void {
        let timer = DevicePacketTimer()
        return { event in
            if case .attempt = event { timer.start() }
            if case .property(let row, let packet) = event {
                self.recordProperty(identifier, operation: operation, source: source, stage: stage, row: row, packet: packet)
                return
            }
            self.record(identifier, operation: operation, source: source, stage: stage, outcome: event.outcome,
                        reason: event.reason, code: event.code, kind: kind, elapsedMilliseconds: timer.elapsed, packet: event.packet)
        }
    }
    func recordProperty(_ identifier: String, operation: UUID, source: Source, stage: Stage, row: SafeMiioProperty, packet: MiioPacketDiagnostics) {
        record(identifier, operation: operation, source: source, stage: stage, outcome: .responseCode, code: row.code,
               kind: .read, siid: row.siid, piid: row.piid, packet: packet)
        if row.hasValue {
            record(identifier, operation: operation, source: source, stage: stage, outcome: .observedValue, code: row.code,
                   kind: .read, siid: row.siid, piid: row.piid, value: row.number, valueType: row.type, booleanValue: row.boolean, packet: packet)
        }
    }
    public static func reason(_ error: any Error) -> Reason {
        if error is CancellationError { return .cancelled }
        switch error {
        case MiioError.timeout, MiioError.noEncryptedReply: return .timeout
        case MiioError.deviceError: return .propertyError
        case MiioError.badResponse, MiioError.checksumMismatch: return .invalidReply
        case is CurtainInvalidReading: return .untrustedReading
        case DeviceControlError.wrongDevice: return .identity
        case DeviceControlError.unsupported: return .firmware
        case DeviceControlError.busy: return .busy
        case is MiioClockDiscontinuity: return .clockDiscontinuity
        case is CurtainReadbackLimit: return .deadline
        case DeviceControlError.notConfirmed: return .unconfirmed
        default: return .transport
        }
    }
    public static func code(_ error: any Error) -> Int? { if case MiioError.deviceError(let code, _) = error { return code }; return nil }
}

// A client reports attempt and received; a transport that knows its send boundary reports sent.
enum CurtainWireEvent: Sendable {
    case attempt(MiioPacketDiagnostics), sent(MiioPacketDiagnostics), received(MiioPacketDiagnostics)
    case checked(MiioPacketDiagnostics), discarded(DeviceEventLog.Reason, MiioPacketDiagnostics)
    case failed(DeviceEventLog.Reason, Int?, MiioPacketDiagnostics)
    case closed(DeviceEventLog.Reason, MiioPacketDiagnostics)
    case property(SafeMiioProperty, MiioPacketDiagnostics)
    var packet: MiioPacketDiagnostics {
        switch self {
        case .attempt(let p), .sent(let p), .received(let p), .checked(let p), .discarded(_, let p), .failed(_, _, let p), .closed(_, let p), .property(_, let p): p
        }
    }
    var outcome: DeviceEventLog.Outcome {
        switch self { case .attempt: .attempt; case .sent: .sent; case .received: .received; case .checked: .packetChecked; case .discarded: .discarded; case .failed: .paused; case .closed: .closed; case .property: .observedValue }
    }
    var reason: DeviceEventLog.Reason? {
        switch self { case .failed(let reason, _, _), .closed(let reason, _): reason; case .discarded(let reason, _): reason; default: nil }
    }
    var code: Int? { if case .failed(_, let code, _) = self { code } else { nil } }
}

struct CurtainReadbackLimit: Error {}

public typealias CurtainEventLog = DeviceEventLog
public enum DeviceCommunicationContext {
    @TaskLocal public static var source: DeviceEventLog.Source?
    @TaskLocal public static var operation: UUID?
}
private final class DevicePacketTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?
    func start() { lock.withLock { instant = .now } }
    var elapsed: Int64? { lock.withLock {
        guard let instant else { return nil }
        let c = instant.duration(to: .now).components
        return c.seconds * 1_000 + c.attoseconds / 1_000_000_000_000_000
    } }
}

struct CurtainInvalidReading: Error {}
