import Foundation

/// A second, typed privacy boundary for the sidecar's diagnostic JSON. Unknown fields never persist.
public struct MatterDiagnosticsRecord: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case started, layout, layoutChanged, configuration, snapshot, attributeInput, attributeCommitted
        case readRequest, subscribeRequest, subscriptionEstablished, subscriptionAttached, subscriptionResumed, subscriptionClosed
        case reportQueued, reportSent, transportAck, statusAck, exchangeClosed, protocolFailure
        case rpcRequest, rpcResult, commandFailed, commandConfirmed
    }
    public enum Reason: String, Codable, Sendable { case unavailable, timeout, cancelled, transport, removed, layout, unchanged, missingCluster }
    public var event: Event
    public var run: UUID?
    public var sequence: Int?
    public var milliseconds: Int?
    public var snapshot: Int?
    public var device: Int?
    public var endpoint: Int?
    public var parent: Int?
    public var cluster: Int?
    public var attribute: Int?
    public var dataVersion: Int?
    public var configurationVersion: Int?
    public var previousVersion: Int?
    public var previousEndpoint: Int?
    public var session: Int?
    public var exchange: Int?
    public var subscription: Int?
    public var message: Int?
    public var ackedMessage: Int?
    public var retry: Int?
    public var status: Int?
    public var minSeconds: Int?
    public var maxSeconds: Int?
    public var request: Int?
    public var count: Int?
    public var messageType: Int?
    public var value: Double?
    public var boolean: Bool?
    public var isNull: Bool?
    public var reachable: Bool?
    public var caseSession: Bool?
    public var duplicate: Bool?
    public var changed: Bool?
    public var native: Bool?
    public var messageBoundary: Bool?
    public var deviceTypes: [Int]?
    public var parts: [Int]?
    public var numbers: [Int]?
    public var signature: String?
    public var reason: Reason?
    public init(event: Event) { self.event = event }
    public var isImportant: Bool {
        [.started, .layout, .layoutChanged, .configuration, .subscriptionEstablished, .subscriptionAttached, .subscriptionResumed, .subscriptionClosed,
         .protocolFailure, .commandFailed, .commandConfirmed].contains(event) || status.map { $0 != 0 } == true
    }
    public func validated() -> Self? {
        let values = [sequence, milliseconds, snapshot, device, endpoint, parent, cluster, attribute, dataVersion,
            configurationVersion, previousVersion, previousEndpoint, session, exchange, subscription, message,
            ackedMessage, retry, status, minSeconds, maxSeconds, request, count, messageType].compactMap { $0 }
        guard values.allSatisfy({ (0...4_294_967_295).contains($0) }),
              value.map({ $0.isFinite && abs($0) <= 4_294_967_295 }) ?? true,
              numbers.map({ $0.count <= 64 && $0.allSatisfy { (0...4_294_967_295).contains($0) } }) ?? true,
              [deviceTypes, parts].compactMap { $0 }.allSatisfy({ $0.count <= 64 && $0.allSatisfy { (0...4_294_967_295).contains($0) } }),
              signature.map({ $0.utf8.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true else { return nil }
        return self
    }
}
