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

    private var deviceID: UInt32?
    private var clock: (stamp: UInt32, at: ContinuousClock.Instant)?
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
        retries: Int = 2
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.transport = transport
        self.timeout = timeout
        self.retries = max(0, retries)
    }

    /// The hello reply's header: device ID and clock. Does not prove the token is right.
    @discardableResult
    public func handshake(timeout: Duration? = nil) async throws -> MiioPacket.Header {
        let reply = try await transport.exchange(MiioPacket.hello, host: host, port: port, timeout: timeout ?? self.timeout)
        let header = try MiioPacket.parseHeader(reply)
        deviceID = header.deviceID
        clock = (header.stamp, .now)
        return header
    }

    /// Sends `{"id", "method", "params"}` and returns `result`.
    /// A device drops a packet it cannot verify instead of answering, so "hello answered, request never" is how a
    /// wrong token shows up; that case throws `MiioError.noEncryptedReply` rather than `.timeout`.
    /// `timeout` overrides the client's per-attempt wait for this call.
    public func call(_ method: String, params: JSONValue = .array([]), timeout: Duration? = nil, retryCount: Int? = nil) async throws -> JSONValue {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var lastError: any Error = MiioError.timeout
        var helloAnswered = false
        let attempts = method == "action" ? 0 : max(0, retryCount ?? retries)
        for _ in 0...attempts {
            try Task.checkCancellation()
            do {
                if needsHandshake {
                    try await handshake(timeout: timeout)
                    helloAnswered = true
                }
                try Task.checkCancellation()
                return try await send(method, params: params, timeout: timeout ?? self.timeout)
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
        return ContinuousClock.now - clock.at > Self.clockMaxAge
    }

    private func send(_ method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let deviceID, let clock else { throw MiioError.timeout }
        let id = takeRequestID()
        let body = JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": params])
        let elapsed = UInt32(clamping: (ContinuousClock.now - clock.at).components.seconds)
        let stamp = clock.stamp &+ elapsed &+ 1
        // NUL-terminated like python-miio, the implementation most firmware has been tested against.
        let request = Data(body.compactJSONString.utf8) + [0]
        let packet = try MiioPacket.encode(request, token: token, deviceID: deviceID, stamp: stamp)

        let reply = try await transport.exchange(packet, host: host, port: port, timeout: timeout)
        let (header, payload) = try MiioPacket.decode(reply, token: token)
        self.clock = (header.stamp, .now)
        guard let json = Self.parseJSON(payload) else { throw MiioError.badResponse(L10n.tr("无法解析 JSON", "Could not parse JSON.")) }
        if let error = json["error"] {
            throw MiioError.deviceError(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")
        }
        return json["result"] ?? .null
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
