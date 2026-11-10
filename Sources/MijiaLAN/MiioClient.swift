import Foundation
import MijiaCore

/// One miIO device on the LAN. Calls are serialized per device (the actor), which is also what the firmware expects.
///
/// The device drops packets whose stamp is older than its clock, so the client learns the clock from a hello and
/// advances it locally; it hellos again after a timeout or when the last contact is old.
public actor MiioClient {
    public nonisolated let host: String
    public nonisolated let port: UInt16
    private let token: Data
    private let transport: any MiioTransport
    private let timeout: Duration
    private let retries: Int
    private let events: DeviceEventLog?
    private let eventIdentifier: String
    public nonisolated let policy: MiioCommunicationPolicy
    private let time: MiioTimeSource
    private let expectedDeviceID: UInt32?
    private var lastReplyAt: Duration?
    private var queueWaitMilliseconds: Int64 = 0
    private var ended = false
    private var diagnosticModel: String?

    private var propertyRequestRestriction: String?
    private var deviceID: UInt32?
    private var clock: (stamp: UInt32, at: Duration)?
    private var helloAnchor: (stamp: UInt32, at: Duration)?
    private let diagnosticClientID = UUID()
    private var diagnosticSequence: UInt64 = 0
    private let sentCounters = MiioSentCounters()
    private var lastHelloAt: Duration?
    private var clockBasis: MiioPacketDiagnostics.ClockBasis?
    private var nextRequestID = Int.random(in: 1...9_000)
    private var calling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !calling { calling = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { calling = false } else { waiters.removeFirst().resume() }
    }

    /// Re-hello after this much silence; some firmware resets its clock when it reconnects to Wi-Fi.
    static let clockMaxAge: Duration = .seconds(120)
    /// "User ack timeout": a request ID the device already used, or (pre-MIoT firmware) a method it does not know.
    static let userAckTimeoutCode = -9999

    public init(
        host: String,
        token: Data,
        port: UInt16 = MiioPacket.port,
        transport: any MiioTransport = UDPMiioTransport(),
        timeout: Duration = .seconds(2),
        retries: Int = 2,
        knownModel: String? = nil,
        events: DeviceEventLog? = nil, eventIdentifier: String? = nil,
        policy: MiioCommunicationPolicy? = nil, expectedDeviceID: UInt32? = nil, time: MiioTimeSource = .init()
    ) {
        self.host = host
        self.events = events
        self.eventIdentifier = eventIdentifier ?? events?.identifier(forHost: host) ?? UUID().uuidString
        self.port = port
        self.token = token
        let selected = policy ?? (knownModel == CurtainValidationSession.model ? .revised : .legacy)
        self.policy = selected; self.time = time; self.expectedDeviceID = expectedDeviceID
        self.diagnosticModel = knownModel
        self.transport = transport.sessionTransport(policy: selected.socket)
        self.timeout = timeout
        self.retries = max(0, retries)
        self.propertyRequestRestriction = knownModel.flatMap { DeviceLANPolicy.restriction(for: $0) }
        var opening = MiioPacketDiagnostics(); opening.client = diagnosticClientID; opening.policy = selected
        events?.record(self.eventIdentifier, source: .startup, stage: .idle, outcome: .noPacket, reason: .configuration, packet: opening)
    }

    /// The hello reply's header: device ID and clock. Does not prove the token is right.
    @discardableResult
    public func handshake(timeout: Duration? = nil) async throws -> MiioPacket.Header {
        let queuedAt = time.now()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        queueWaitMilliseconds = Self.milliseconds(time.now() - queuedAt)
        let operation = DeviceCommunicationContext.operation ?? UUID()
        do { return try await DeviceCommunicationContext.$operation.withValue(operation) { try await observedHandshake(timeout: timeout) } }
        catch {
            events?.record(eventIdentifier, operation: operation, source: DeviceCommunicationContext.source ?? .legacyProbe, stage: .hello,
                           outcome: .paused, reason: DeviceEventLog.reason(error), code: DeviceEventLog.code(error), kind: .hello)
            throw error
        }
    }
    func observedHandshake(timeout: Duration? = nil, wire: (@Sendable (CurtainWireEvent) -> Void)? = nil) async throws -> MiioPacket.Header {
        guard !ended else { throw CancellationError() }
        let wire = wire ?? events?.wire(eventIdentifier, operation: DeviceCommunicationContext.operation ?? UUID(),
            source: DeviceCommunicationContext.source ?? .legacyProbe, stage: .hello, kind: .hello)
        let exchange = try await exchangePacket(MiioPacket.hello, timeout: timeout ?? self.timeout, wire: wire)
        let header = try MiioPacket.parseHeader(exchange.reply)
        var diagnostic = exchange.diagnostic
        diagnostic.responseStamp = header.stamp; diagnostic.authenticated = false
        diagnostic.headerIdentityMatches = deviceID.map { $0 == header.deviceID }
        diagnostic.clockUpdated = true
        wire?(.checked(diagnostic))
        deviceID = header.deviceID
        clock = (header.stamp, time.now())
        helloAnchor = clock
        lastHelloAt = time.now(); clockBasis = .hello
        return header
    }

    /// Sends `{"id", "method", "params"}` and returns `result`.
    /// A device drops a packet it cannot verify instead of answering, so "hello answered, request never" is how a
    /// wrong token shows up; that case throws `MiioError.noEncryptedReply` rather than `.timeout`.
    /// `timeout` overrides the client's per-attempt wait for this call.
    public func call(_ method: String, params: JSONValue = .array([]), timeout: Duration? = nil, retryCount: Int? = nil) async throws -> JSONValue {
        let operation = DeviceCommunicationContext.operation ?? UUID()
        let kind: DeviceEventLog.Kind
        switch method {
        case "miIO.info": kind = .info
        case "get_properties": kind = .read
        case "set_properties": kind = .write
        case "action": kind = .action
        case "get_prop": kind = .legacyRead
        default: kind = method.hasPrefix("set_") ? .legacyWrite : .other
        }
        let writing = [.write, .legacyWrite, .action].contains(kind)
        let source = DeviceCommunicationContext.source ?? (writing ? .userControl : .backgroundPoll)
        let stage: DeviceEventLog.Stage = kind == .info ? .info : (writing ? .write : .preflight)
        let wire = events?.wire(eventIdentifier, operation: operation, source: source, stage: stage, kind: kind)
        let metadata: [String: JSONValue]
        if case .object(let fields) = params { metadata = fields }
        else if case .array(let items) = params, items.count == 1, case .object(let fields) = items[0] { metadata = fields }
        else { metadata = [:] }
        events?.record(eventIdentifier, operation: operation, source: source, stage: .requested, outcome: .queued, kind: kind,
                       siid: Self.address(metadata["siid"]), aiid: Self.address(metadata["aiid"]), piid: Self.address(metadata["piid"]), valueType: Self.valueType(metadata["value"]))
        do {
            let result = try await DeviceCommunicationContext.$source.withValue(source) {
                try await DeviceCommunicationContext.$operation.withValue(operation) {
                    try await performCall(method, params: params, timeout: timeout, retryCount: retryCount, validation: false, wire: wire)
                }
            }
            recordResult(result, operation: operation, source: source, stage: stage, kind: kind)
            events?.record(eventIdentifier, operation: operation, source: source, stage: .finished, outcome: .received, kind: kind)
            return result
        } catch {
            let blocked = propertyRequestRestriction != nil && method != "miIO.info"
            events?.record(eventIdentifier, operation: operation, source: source, stage: stage, outcome: blocked ? .noPacket : .paused,
                           reason: blocked ? .manualOnly : DeviceEventLog.reason(error), code: DeviceEventLog.code(error), kind: kind)
            throw error
        }
    }
    private func recordResult(_ result: JSONValue, operation: UUID, source: DeviceEventLog.Source, stage: DeviceEventLog.Stage, kind: DeviceEventLog.Kind) {
        let rows: [JSONValue]
        if case .array(let items) = result { rows = items } else { rows = [result] }
        for row in rows {
            guard case .object(let fields) = row, case .number(let raw) = fields["code"], let code = Int(exactly: raw) else { continue }
            let siid = Self.address(fields["siid"]), piid = Self.address(fields["piid"])
            events?.record(eventIdentifier, operation: operation, source: source, stage: stage, outcome: .responseCode,
                           code: code, kind: kind, siid: siid, aiid: Self.address(fields["aiid"]), piid: piid)
        }
    }
    private static func valueType(_ value: JSONValue?) -> DeviceEventLog.ValueType? {
        guard let value else { return nil }
        switch value { case .number: return .number; case .bool: return .boolean; case .string: return .string; case .object: return .object; case .array: return .array; case .null: return .null }
    }
    private static func address(_ value: JSONValue?) -> Int? {
        guard case .number(let raw) = value, let id = Int(exactly: raw), (1...65_535).contains(id) else { return nil }
        return id
    }

    // Only dedicated curtain sessions can use these typed operations; generic routes remain locked.
    enum CurtainRequest: Sendable {
        case info
        case read(did: String, confirmation: Bool)
        case selectedRead(did: String, ids: [Int], confirmation: Bool = false)
        case position(did: String, target: Int)
        case motor(did: String, value: Int)
    }
    func curtainNeedsHandshake() -> Bool {
        if policy.hello == .periodic, let lastHelloAt, time.now() - lastHelloAt >= Self.clockMaxAge - .seconds(10) { return true }
        return needsHandshake
    }
    func curtainPeriodicOnly() -> Bool {
        guard policy.hello == .periodic, deviceID != nil, let lastHelloAt, let lastReplyAt else { return false }
        return time.now() - lastHelloAt >= Self.clockMaxAge - .seconds(10) && time.now() - lastReplyAt <= Self.clockMaxAge
    }
    func waitUntilIdle() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
    }
    func curtainRequest(_ request: CurtainRequest, timeout: Duration = .seconds(2), isCurrent: @escaping @Sendable () -> Bool, wire: (@Sendable (CurtainWireEvent) -> Void)? = nil) async throws -> JSONValue {
        let method: String
        let params: JSONValue
        switch request {
        case .info: method = "miIO.info"; params = .array([])
        case .read(let did, let confirmation):
            method = "get_properties"
            let ids = confirmation ? [3, 2] : CurtainReadProfile.normalFive.propertyIDs
            params = .array(ids.map { .object(["did": .string(did), "siid": .number(2), "piid": .number(Double($0))]) })
        case .selectedRead(let did, let ids, _):
            guard !ids.isEmpty, ids.count <= 6, ids.allSatisfy({ [2,3,4,5,9,10].contains($0) }) else { throw DeviceControlError.unsupported("Read whitelist") }
            method = "get_properties"
            params = .array(ids.map { .object(["did": .string(did), "siid": .number(2), "piid": .number(Double($0))]) })
        case .position(let did, let target):
            guard (0...100).contains(target) else { throw DeviceControlError.invalidValue("position") }
            method = "set_properties"
            params = .array([.object(["did": .string(did), "siid": .number(2), "piid": .number(4), "value": .number(Double(target))])])
        case .motor(let did, let value):
            guard (0...2).contains(value) else { throw DeviceControlError.invalidValue("motor-control") }
            method = "set_properties"
            params = .array([.object(["did": .string(did), "siid": .number(2), "piid": .number(1), "value": .number(Double(value))])])
        }
        let kind: DeviceEventLog.Kind = method == "miIO.info" ? .info : (method == "get_properties" ? .read : .write)
        let confirmation: Bool
        switch request { case .read(_, let value), .selectedRead(_, _, let value): confirmation = value; default: confirmation = false }
        let stage: DeviceEventLog.Stage = confirmation ? .confirmation : (kind == .info ? .info : (kind == .write ? .write : .preflight))
        let observed = wire ?? events?.wire(eventIdentifier, operation: DeviceCommunicationContext.operation ?? UUID(),
            source: DeviceCommunicationContext.source ?? (confirmation ? .postWriteRead : (kind == .write ? .userControl : .manualRead)), stage: stage, kind: kind)
        return try await performCall(method, params: params, timeout: timeout, retryCount: 0, validation: true, validationCheck: isCurrent, wire: observed)
    }

    private func performCall(_ method: String, params: JSONValue, timeout: Duration?, retryCount: Int?, validation: Bool, validationCheck: (@Sendable () -> Bool)? = nil, wire: (@Sendable (CurtainWireEvent) -> Void)? = nil) async throws -> JSONValue {
        let enqueuedAt = time.now()
        await acquire()
        defer { release() }
        queueWaitMilliseconds = Self.milliseconds(time.now() - enqueuedAt)
        guard !ended else { throw CancellationError() }
        if validation, validationCheck?() != true { throw DeviceControlError.wrongDevice }
        if !validation, let reason = propertyRequestRestriction, method != "miIO.info" {
            throw DeviceControlError.unsupported(reason)
        }
        try Task.checkCancellation()
        var lastError: any Error = MiioError.timeout
        var helloAnswered = false
        let attempts = method == "action" ? 0 : max(0, retryCount ?? retries)
        for _ in 0...attempts {
            try Task.checkCancellation()
            do {
                if needsHandshake {
                    // Validation handshakes are separately scheduled; never hide a second packet here.
                    if validation { throw DeviceControlError.unavailable("Handshake expired") }
                    _ = try await observedHandshake(timeout: timeout)
                    helloAnswered = true
                }
                try Task.checkCancellation()
                let result = try await send(method, params: params, timeout: timeout ?? self.timeout, strictResponse: validation, wire: wire)
                if method == "miIO.info", let model = result["model"]?.stringValue,
                   let reason = DeviceLANPolicy.restriction(for: model) { propertyRequestRestriction = reason; diagnosticModel = model }
                return result
            } catch MiioError.timeout {
                lastError = MiioError.timeout
                deviceID = nil
            } catch MiioError.deviceError(let code, let message) where code == Self.userAckTimeoutCode {
                lastError = MiioError.deviceError(code: code, message: message)
                nextRequestID += 100
            }
        }
        if helloAnswered, case MiioError.timeout = lastError { throw MiioError.noEncryptedReply }
        throw lastError
    }

    private var needsHandshake: Bool {
        guard deviceID != nil, let clock else { return true }
        let now = time.now()
        if policy.hello == .periodic, let lastHelloAt, now - lastHelloAt >= Self.clockMaxAge { return true }
        // A fresh hello is a new clock/contact anchor even when the preceding RPC was hours ago.
        // Keep lastReplyAt untouched for diagnostics; it must not expire the newly established clock.
        return now - max(lastReplyAt ?? clock.at, clock.at) > Self.clockMaxAge
    }

    private func send(_ method: String, params: JSONValue, timeout: Duration, strictResponse: Bool, wire: (@Sendable (CurtainWireEvent) -> Void)? = nil) async throws -> JSONValue {
        guard let deviceID, let clock else { throw MiioError.timeout }
        let id = takeRequestID()
        let body = JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": params])
        let age = time.now() - clock.at
        let stamp = policy.stamp == .helloAnchored ? Self.anchoredStamp(base: clock.stamp, elapsed: age) : Self.outgoingStamp(base: clock.stamp, elapsed: age)
        var diagnostic = MiioPacketDiagnostics()
        diagnostic.requestID = UInt16(id); diagnostic.requestStamp = stamp
        diagnostic.method = MiioPacketDiagnostics.Method(rawValue: method) ?? (method.hasPrefix("set_") ? .legacyWrite : .other)
        if case .array(let rows) = params {
            diagnostic.addresses = rows.prefix(15).compactMap { row in
                guard let siid = Self.address(row["siid"]), let piid = Self.address(row["piid"]) else { return nil }
                return MiioPropertyAddress(siid: UInt16(siid), piid: UInt16(piid))
            }
        }
        diagnostic.clockBaseStamp = clock.stamp; diagnostic.clockBaseAgeMilliseconds = Self.milliseconds(age)
        diagnostic.clockBasis = clockBasis
        if method == "get_properties", case .array(let rows) = params { diagnostic.propertyCount = UInt16(clamping: rows.count) }
        // NUL-terminated like python-miio, the implementation most firmware has been tested against.
        let request = Data(body.compactJSONString.utf8) + [0]
        let packet = try MiioPacket.encode(request, token: token, deviceID: deviceID, stamp: stamp)

        let exchange = try await exchangePacket(packet, timeout: timeout, wire: wire, diagnostic: diagnostic)
        diagnostic = exchange.diagnostic
        let header: MiioPacket.Header, payload: Data
        do { (header, payload) = try MiioPacket.decode(exchange.reply, token: token) }
        catch {
            diagnostic.authenticated = false; diagnostic.clockUpdated = false
            wire?(.checked(diagnostic)); throw error
        }
        diagnostic.authenticated = true; diagnostic.responseStamp = header.stamp
        diagnostic.headerIdentityMatches = header.deviceID == deviceID
        guard let json = Self.parseJSON(payload) else {
            diagnostic.clockUpdated = false; diagnostic.rpcIDMatches = false; wire?(.checked(diagnostic))
            throw MiioError.badResponse(L10n.tr("无法解析 JSON", "Could not parse JSON."))
        }
        if case .number(let raw) = json["id"], let value = UInt16(exactly: raw), (1...9_999).contains(value) { diagnostic.responseID = value }
        diagnostic.rpcIDMatches = json["id"] == .number(Double(id))
        diagnostic.clockUpdated = !strictResponse || (diagnostic.headerIdentityMatches == true && diagnostic.rpcIDMatches == true)
        if let anchor = helloAnchor {
            let expected = Self.anchoredStamp(base: anchor.stamp, elapsed: time.now() - anchor.at)
            let delta = Int64(Int32(bitPattern: header.stamp &- expected))
            diagnostic.estimatedClockSkewSeconds = delta
            if policy.stamp == .helloAnchored {
                diagnostic.clockAccepted = abs(delta) <= 5
                diagnostic.clockUpdated = false // The anchor changes only after hello.
            }
        }
        wire?(.checked(diagnostic))
        if diagnosticModel == CurtainValidationSession.model, method == "get_properties" { logSafeRows(json["result"], diagnostic: diagnostic, wire: wire) }
        if strictResponse {
            guard header.deviceID == deviceID, json["id"] == .number(Double(id)) else {
                throw MiioError.badResponse("Response identity mismatch")
            }
        }
        lastReplyAt = time.now()
        if policy.stamp == .helloAnchored {
            guard diagnostic.clockAccepted != false else { self.deviceID = nil; throw MiioClockDiscontinuity() }
        } else { self.clock = (header.stamp, time.now()); clockBasis = .reply }
        if let error = json["error"] {
            throw MiioError.deviceError(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")
        }
        return json["result"] ?? .null
    }

    private func exchangePacket(_ packet: Data, timeout: Duration, wire: (@Sendable (CurtainWireEvent) -> Void)?, diagnostic original: MiioPacketDiagnostics = .init()) async throws -> (reply: Data, diagnostic: MiioPacketDiagnostics) {
        var diagnostic = original
        diagnosticSequence &+= 1
        diagnostic.remotePort = port; diagnostic.policy = policy; diagnostic.queueWaitMilliseconds = queueWaitMilliseconds
        diagnostic.requestTimeoutMilliseconds = Self.milliseconds(timeout)
        if packet == MiioPacket.hello { diagnostic.method = .hello }
        if packet == MiioPacket.hello {
            if lastHelloAt == nil { diagnostic.helloReason = .initial }
            else if deviceID == nil { diagnostic.helloReason = .recovery }
            else if time.now() - (lastReplyAt ?? .zero) > Self.clockMaxAge { diagnostic.helloReason = .silence }
            else if policy.hello == .periodic { diagnostic.helloReason = .periodic }
            else { diagnostic.helloReason = .explicit }
        }
        if let lastReplyAt { diagnostic.lastReplyAgeMilliseconds = Self.milliseconds(time.now() - lastReplyAt) }
        diagnostic.client = diagnosticClientID; diagnostic.clientSequence = diagnosticSequence
        if let lastHelloAt { diagnostic.helloAgeMilliseconds = Self.milliseconds(time.now() - lastHelloAt) }
        sentCounters.apply(to: &diagnostic, sent: false)
        let trace = MiioPacketTrace(diagnostic)
        let counts = sentCounters
        wire?(.attempt(diagnostic))
        do {
            let token = token, expectedID = deviceID ?? expectedDeviceID, rpcID = diagnostic.requestID
            let reply = try await transport.exchangeValidated(packet, host: host, port: port, timeout: timeout, observe: { event in
                trace.observe(event)
                switch event.boundary {
                case .sent: trace.didSend(counts); wire?(.sent(trace.snapshot))
                case .discarded: wire?(.discarded(event.reason ?? .unexpectedPeer, trace.snapshot))
                case .closed: wire?(.closed(event.reason ?? .configuration, trace.snapshot))
                default: break
                }
            }, accept: { data in
                var diagnostic = trace.snapshot
                do {
                    if packet == MiioPacket.hello {
                        let header = try MiioPacket.parseHeader(data)
                        let accepted = data.count == MiioPacket.headerLength && (expectedID == nil || expectedID == header.deviceID)
                        if !accepted {
                            diagnostic.authenticated = false; diagnostic.responseStamp = header.stamp
                            diagnostic.headerIdentityMatches = expectedID.map { $0 == header.deviceID }; diagnostic.clockUpdated = false
                            wire?(.checked(diagnostic))
                        }
                        return accepted
                    }
                    let (header, body) = try MiioPacket.decode(data, token: token)
                    diagnostic.authenticated = true; diagnostic.responseStamp = header.stamp
                    let json = Self.parseJSON(body)
                    if case .number(let raw) = json?["id"], let id = UInt16(exactly: raw), (1...9_999).contains(id) { diagnostic.responseID = id }
                    diagnostic.headerIdentityMatches = expectedID == header.deviceID
                    diagnostic.rpcIDMatches = json?["id"] == rpcID.map { .number(Double($0)) }
                    if diagnostic.headerIdentityMatches == true, diagnostic.rpcIDMatches == true { return true }
                    diagnostic.clockUpdated = false; wire?(.checked(diagnostic)); return false
                } catch { diagnostic.authenticated = false; diagnostic.clockUpdated = false; wire?(.checked(diagnostic)); return false }
            })
            wire?(.received(trace.snapshot))
            return (reply, trace.snapshot)
        } catch {
            wire?(.failed(DeviceEventLog.reason(error), DeviceEventLog.code(error), trace.snapshot))
            throw error
        }
    }

    public func close() async {
        ended = true; deviceID = nil; clock = nil
        let wire = events?.wire(eventIdentifier, operation: UUID(), source: .lifecycle, stage: .finished, kind: .other)
        var diagnostic = MiioPacketDiagnostics(); diagnostic.client = diagnosticClientID; diagnostic.policy = policy
        let trace = MiioPacketTrace(diagnostic)
        await transport.closeSession { event in trace.observe(event); wire?(.closed(event.reason ?? .configuration, trace.snapshot)) }
    }
    static func anchoredStamp(base: UInt32, elapsed: Duration) -> UInt32 { base &+ UInt32(clamping: elapsed.components.seconds) }
    private func logSafeRows(_ result: JSONValue?, diagnostic: MiioPacketDiagnostics, wire: (@Sendable (CurtainWireEvent) -> Void)?) {
        guard case .array(let rows) = result else { return }
        for row in rows.prefix(15) {
            guard let siid = Self.address(row["siid"]), let piid = Self.address(row["piid"]), siid == 2, [2,3,4,5,9,10].contains(piid) else { continue }
            let code: Int?
            if case .number(let n) = row["code"] { code = Int(exactly: n) } else { code = nil }
            let value = row["value"]
            let number: Int?
            if case .number(let n) = value { number = Int(exactly: n).flatMap { (0...100).contains($0) ? $0 : nil } } else { number = nil }
            wire?(.property(.init(siid: siid, piid: piid, code: code, type: Self.valueType(value), number: number, boolean: value?.boolValue, hasValue: value != nil), diagnostic))
        }
    }
    /// Existing clock policy, extracted unchanged for deterministic offline drift/wrap checks.
    static func outgoingStamp(base: UInt32, elapsed: Duration) -> UInt32 {
        base &+ UInt32(clamping: elapsed.components.seconds) &+ 1
    }
    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private func takeRequestID() -> Int {
        nextRequestID = nextRequestID >= 9_999 ? 1 : nextRequestID + 1
        return nextRequestID
    }

    /// Replies end in a NUL, and some firmware sends malformed JSON; the fixes are python-miio's quirk list.
    static func parseJSON(_ payload: Data) -> JSONValue? {
        var bytes = [UInt8](payload)
        while let last = bytes.last, last == 0 || last == 0x20 || last == 0x0A || last == 0x0D { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        let candidates = [
            text,
            // Power strips offline from the cloud.
            text.replacingOccurrences(of: ",,\"otu_stat\"", with: ",\"otu_stat\""),
            // Junk after an embedded NUL.
            text.firstIndex(of: "\0").map { String(text[..<$0]) } ?? text,
            // Some curtain motors send `"value":00`.
            text.replacingOccurrences(of: "\"value\":00", with: "\"value\":0"),
        ]
        for candidate in candidates {
            if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8)), case .object = json { return json }
        }
        return nil
    }
}

// MARK: - MIoT over miIO

/// What `miIO.info` reports; enough to add a device by IP and token.
public struct MiioInfo: Equatable, Sendable {
    public var model: String
    public var mac: String?
    public var firmware: String?

    public init(model: String, mac: String? = nil, firmware: String? = nil) {
        self.model = model
        self.mac = mac
        self.firmware = firmware
    }
}

extension MiioClient {
    /// Firmware rejects long property lists; 15 is what the Mi Home app sends.
    public static let propertiesPerRequest = 15

    public func info(timeout: Duration? = nil) async throws -> MiioInfo {
        let result = try await call("miIO.info", timeout: timeout)
        guard let model = result["model"]?.stringValue, !model.isEmpty else { throw MiioError.badResponse(L10n.tr("miIO.info 没有 model", "miIO.info did not include a model.")) }
        return MiioInfo(model: model, mac: result["mac"]?.stringValue, firmware: result["fw_ver"]?.stringValue)
    }

    /// Values keyed by `did` (as passed in), siid and piid. Properties the device reports as failed are left out.
    /// Results are matched to the request by siid/piid: some firmware echoes its own did instead of ours.
    public func getProperties(did: String, _ props: [(siid: Int, piid: Int)]) async throws -> [MiotPropKey: JSONValue] {
        try await readProperties(did: did, props).compactMapValues { $0.isAvailable ? $0.value : nil }
    }

    /// Every requested property has a result, including omissions and negative return codes.
    public func readProperties(did: String, _ props: [(siid: Int, piid: Int)]) async throws -> [MiotPropKey: DeviceReading] {
        var values: [MiotPropKey: DeviceReading] = [:]
        var start = 0
        while start < props.count {
            try Task.checkCancellation()
            let chunk = props[start..<min(start + Self.propertiesPerRequest, props.count)]
            start += Self.propertiesPerRequest
            let params = JSONValue.array(chunk.map {
                .object(["did": .string(did), "siid": .number(Double($0.siid)), "piid": .number(Double($0.piid))])
            })
            let result = try await call("get_properties", params: params)
            for p in chunk {
                values[MiotPropKey(did: did, siid: p.siid, piid: p.piid)] = DeviceReading(error: L10n.tr("设备未返回此属性", "The device did not return this property."))
            }
            for item in result.arrayValue ?? [] {
                guard let siid = item["siid"]?.intValue, let piid = item["piid"]?.intValue,
                      chunk.contains(where: { $0.siid == siid && $0.piid == piid }) else { continue }
                let code = item["code"]?.intValue
                let value = item["value"]
                values[MiotPropKey(did: did, siid: siid, piid: piid)] = DeviceReading(
                    value: code == 0 ? value : nil, updatedAt: Date(), code: code,
                    error: code == 0 && value != nil ? nil : Self.propertyError(code))
            }
        }
        return values
    }

    /// Throws `MiioError.deviceError` with the first negative per-item code.
    public func setProperties(_ writes: [MiotPropWrite]) async throws {
        let params = JSONValue.array(writes.map {
            .object(["did": .string($0.did), "siid": .number(Double($0.siid)), "piid": .number(Double($0.piid)), "value": $0.value])
        })
        let result = try await call("set_properties", params: params)
        guard let items = result.arrayValue, items.count == writes.count else { throw MiioError.badResponse(L10n.tr("写入结果数量不符", "The number of write results does not match.")) }
        try Self.checkCodes(items)
    }

    public func action(_ call: MiotActionCall) async throws {
        let result = try await self.call("action", params: .object([
            "did": .string(call.did), "siid": .number(Double(call.siid)),
            "aiid": .number(Double(call.aiid)), "in": .array(call.inputs),
        ]), retryCount: 0)
        try Self.checkCodes([result])
    }

    /// MIoT per-item codes: 0 done, 1 accepted; negatives are property/action errors.
    static func checkCodes(_ items: [JSONValue]) throws {
        for item in items {
            guard let code = item["code"]?.intValue else { throw MiioError.badResponse(L10n.tr("响应缺少返回码", "The response is missing a result code.")) }
            if code != 0 && code != 1 { throw MiioError.deviceError(code: code, message: Self.propertyError(code)) }
        }
    }

    static func propertyError(_ code: Int?) -> String {
        MiotPropertyStatus.description(code)
    }
}

// MARK: - JSONValue access

// MijiaCore keeps its accessors internal; the LAN layer needs the same three.
extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// Mi APIs send ids as numbers or strings.
    var idString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
}
