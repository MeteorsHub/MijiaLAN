import Foundation

/// Bounded, typed local journal. No arbitrary strings, identifiers, addresses, credentials or payloads.
public final class DeviceEventLog: @unchecked Sendable {
    public enum Source: String, Codable, Sendable {
        case preference, startup, manualRead, manualPosition, manualOpen, manualClose, manualStop
        case postWriteRead, idleBackground, legacyProbe, discovery, lifecycle
        case backgroundPoll, userControl, homeKit, matter, manualAdd, other
    }
    public enum Stage: String, Codable, Sendable { case idle, requested, waiting, hello, info, preflight, write, confirmation, finished }
    public enum Outcome: String, Codable, Sendable { case noPacket, queued, attempt, sent, received, responseCode, observedValue, validated, sample, acknowledged, confirmed, paused, cancelled }
    public enum Reason: String, Codable, Sendable {
        case manualOnly, timeout, propertyError, invalidReply, identity, firmware, cancelled, unconfirmed, deadline, busy, configuration, transport, deduplicated, untrustedReading
    }
    public enum Kind: String, Codable, Sendable { case hello, info, read, write, action, legacyRead, legacyWrite, broadcast, other }
    public enum ValueType: String, Codable, Sendable { case number, boolean, string, object, array, null }
    public enum Scope: String, Codable, Sendable { case app, simulation, offlineTest }
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
        public let target: Int?
        public let position: Int?
        public let motorStatus: Int?
        public let elapsedMilliseconds: Int64?
        public let writeAttempted: Bool?
        public let writeSent: Bool?
        public let writeAcknowledged: Bool?
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

    public init(fileURL: URL? = nil, maxEvents: Int = 2_048, scope: Scope = .app, fileLimit: Int = 4_194_304) {
        self.fileURL = fileURL; self.maxEvents = min(2_048, max(1, maxEvents)); self.scope = scope
        self.fileLimit = min(4_194_304, max(1_024, fileLimit))
        if let fileURL {
            events = Array(Self.load(fileURL).suffix(self.maxEvents))
            important = Array(Self.files(fileURL.appendingPathExtension("important")).flatMap(Self.load).suffix(self.maxEvents))
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
                       reason: Reason? = nil, code: Int? = nil, kind: Kind? = nil, siid: Int? = nil, aiid: Int? = nil, piid: Int? = nil, value: Int? = nil, valueType: ValueType? = nil, target: Int? = nil,
                       position: Int? = nil, motorStatus: Int? = nil, elapsedMilliseconds: Int64? = nil, writeAttempted: Bool? = nil, writeSent: Bool? = nil, writeAcknowledged: Bool? = nil) {
        let device = alias(for: identifier)
        lock.withLock {
            sequence += 1
            let event = Event(run: run, sequence: sequence, timestamp: Date(), milliseconds: milliseconds, device: device,
                operation: operation, source: source, stage: stage, outcome: outcome, reason: reason,
                code: code,
                kind: kind, siid: siid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                aiid: aiid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                piid: piid.flatMap { (1...65_535).contains($0) ? $0 : nil },
                value: value.flatMap { (0...100).contains($0) ? $0 : nil }, valueType: valueType, target: target.flatMap { (0...100).contains($0) ? $0 : nil },
                position: position.flatMap { (0...100).contains($0) ? $0 : nil }, motorStatus: motorStatus.flatMap { (0...4).contains($0) ? $0 : nil },
                elapsedMilliseconds: elapsedMilliseconds, writeAttempted: writeAttempted, writeSent: writeSent, writeAcknowledged: writeAcknowledged, scope: scope)
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
    public func exportData() -> Data {
        flush()
        var copy = lock.withLock { events + important }
        if let fileURL {
            copy += Self.files(fileURL).flatMap(Self.load)
            copy += Self.files(fileURL.appendingPathExtension("important")).flatMap(Self.load)
        }
        var seen: Set<String> = []
        copy = copy.filter { seen.insert($0.run.uuidString + ":" + String($0.sequence)).inserted }
        copy.sort { a, b in a.timestamp == b.timestamp ? (a.run == b.run ? a.sequence < b.sequence : a.run.uuidString < b.run.uuidString) : a.timestamp < b.timestamp }
        return Self.encode(copy)
    }
    public func exportText() -> String { String(decoding: exportData(), as: UTF8.self) }
    public func flush() { queue.sync {} }
    private static func isImportant(_ event: Event) -> Bool {
        let manual: Set<Source> = [.manualRead, .manualPosition, .manualOpen, .manualClose, .manualStop, .postWriteRead, .userControl, .homeKit, .matter, .manualAdd]
        return manual.contains(event.source) || (event.code != nil && event.code != 0) || event.outcome == .paused || event.outcome == .cancelled || event.kind == .write || event.kind == .legacyWrite || event.kind == .action
    }
    private static func encode(_ events: [Event]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return events.reduce(into: Data()) { if let line = try? encoder.encode($1) { $0.append(line); $0.append(10) } }
    }
    private static func files(_ url: URL) -> [URL] {
        (1...3).reversed().map { url.appendingPathExtension(String($0)) } + [url]
    }
    private static func load(_ url: URL) -> [Event] {
        guard let size = try? freshFileSize(url), size <= 4_195_328,
              let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        // Bound the read as well: the file may grow after the fresh size check.
        guard let data = try? file.read(upToCount: 4_195_329), data.count <= 4_195_328 else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 10).compactMap { try? decoder.decode(Event.self, from: Data($0)) }
    }
    /// URL resource values can cache the pre-append size on macOS, including across rotation.
    private static func freshFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return size.uint64Value
    }
    private static func append(_ data: Data, to url: URL, limit: Int) throws {
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
            let outcome: Outcome
            switch event { case .attempt: outcome = .attempt; case .sent: outcome = .sent; case .received: outcome = .received; case .failed: outcome = .paused }
            let reason: Reason?, code: Int?
            if case .failed(let failure, let status) = event { reason = failure; code = status } else { reason = nil; code = nil }
            self.record(identifier, operation: operation, source: source, stage: stage, outcome: outcome, reason: reason, code: code, kind: kind, elapsedMilliseconds: timer.elapsed)
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
        case is CurtainReadbackLimit: return .deadline
        case DeviceControlError.notConfirmed: return .unconfirmed
        default: return .transport
        }
    }
    public static func code(_ error: any Error) -> Int? { if case MiioError.deviceError(let code, _) = error { return code }; return nil }
}

// A client reports attempt and received; a transport that knows its send boundary reports sent.
enum CurtainWireEvent: Sendable { case attempt, sent, received, failed(DeviceEventLog.Reason, Int?) }

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
