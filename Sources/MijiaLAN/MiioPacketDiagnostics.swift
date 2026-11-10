import Foundation

/// Protocol counters and ephemeral local socket metadata only; never an address, DID, token or payload.
public struct MiioPacketDiagnostics: Codable, Equatable, Sendable {
    public enum ClockBasis: String, Codable, Sendable { case hello, reply }
    public internal(set) var exchange = UUID()
    public internal(set) var client: UUID?
    public internal(set) var clientSequence: UInt64?
    public internal(set) var socket: UUID?
    public internal(set) var session: UUID?
    public internal(set) var localPort: UInt16?
    public internal(set) var remotePort: UInt16?
    public internal(set) var method: Method?
    public enum Method: String, Codable, Sendable { case hello, info = "miIO.info", read = "get_properties", write = "set_properties", action, legacyRead = "get_prop", legacyWrite, other }
    public internal(set) var addresses: [MiioPropertyAddress]?
    public internal(set) var policy: MiioCommunicationPolicy?
    public internal(set) var queueWaitMilliseconds: Int64?
    public internal(set) var schedulerWaitMilliseconds: Int64?
    public internal(set) var helloReason: HelloReason?
    public enum HelloReason: String, Codable, Sendable { case initial, periodic, silence, recovery, explicit }
    public internal(set) var lastReplyAgeMilliseconds: Int64?
    public internal(set) var estimatedClockSkewSeconds: Int64?
    public internal(set) var clockAccepted: Bool?
    public internal(set) var readRound: UInt64?
    public internal(set) var helloSent: UInt64?
    public internal(set) var infoSent: UInt64?
    public internal(set) var readSent: UInt64?
    public internal(set) var writeSent: UInt64?
    public internal(set) var actionSent: UInt64?
    public internal(set) var requestID: UInt16?
    public internal(set) var responseID: UInt16?
    public internal(set) var requestStamp: UInt32?
    public internal(set) var responseStamp: UInt32?
    public internal(set) var clockBaseStamp: UInt32?
    public internal(set) var clockBaseAgeMilliseconds: Int64?
    public internal(set) var helloAgeMilliseconds: Int64?
    public internal(set) var clockBasis: ClockBasis?
    public internal(set) var clockUpdated: Bool?
    public internal(set) var authenticated: Bool?
    public internal(set) var headerIdentityMatches: Bool?
    public internal(set) var rpcIDMatches: Bool?
    public internal(set) var peerEndpointMatches: Bool?
    public internal(set) var propertyCount: UInt16?
    public internal(set) var requestTimeoutMilliseconds: Int64?
    public internal(set) var curtainReadProfile: CurtainReadProfile?
    public internal(set) var attributePlan: CurtainAttributePlan?
    public internal(set) var attributeRound: UInt64?
    public internal(set) var attributeExposure: CurtainAttributeExposure?
    public init() {}
}

public struct MiioTransportObservation: Sendable {
    public enum Boundary: Sendable { case opened, sent, candidate, received, discarded, closed }
    public let boundary: Boundary
    public let socket: UUID?
    public let localPort: UInt16?
    public let session: UUID?
    public let reason: DeviceEventLog.Reason?
    public init(_ boundary: Boundary, socket: UUID? = nil, localPort: UInt16? = nil, session: UUID? = nil, reason: DeviceEventLog.Reason? = nil) {
        self.boundary = boundary; self.socket = socket; self.localPort = localPort
        self.session = session; self.reason = reason
    }
}

/// The dispatch-queue send boundary and the client actor both contribute to one packet's diagnostics.
final class MiioPacketTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MiioPacketDiagnostics
    private var sent = false
    init(_ value: MiioPacketDiagnostics) { self.value = value }
    var snapshot: MiioPacketDiagnostics { lock.withLock { value } }
    func replace(_ value: MiioPacketDiagnostics) { lock.withLock { self.value = value } }
    func didSend(_ counts: MiioSentCounters) {
        lock.withLock { guard !sent else { return }; sent = true; counts.apply(to: &value, sent: true) }
    }
    func observe(_ observation: MiioTransportObservation) {
        lock.withLock {
            if let socket = observation.socket { value.socket = socket }
            if let session = observation.session { value.session = session }
            if let port = observation.localPort, port != 0 { value.localPort = port }
            switch observation.boundary {
            case .candidate, .received: value.peerEndpointMatches = true
            case .discarded where observation.reason == .unexpectedPeer: value.peerEndpointMatches = false
            default: break
            }
        }
    }
}

struct SafeMiioProperty: Sendable {
    let siid: Int
    let piid: Int
    let code: Int?
    let type: DeviceEventLog.ValueType?
    let number: Int?
    let boolean: Bool?
    let hasValue: Bool
}

final class MiioSentCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [MiioPacketDiagnostics.Method: UInt64] = [:]
    func apply(to packet: inout MiioPacketDiagnostics, sent: Bool) {
        lock.withLock {
            if sent, let method = packet.method { counts[method, default: 0] &+= 1 }
            packet.helloSent = counts[.hello, default: 0]; packet.infoSent = counts[.info, default: 0]
            packet.readSent = counts[.read, default: 0]; packet.writeSent = counts[.write, default: 0]
            packet.actionSent = counts[.action, default: 0]
        }
    }
}
