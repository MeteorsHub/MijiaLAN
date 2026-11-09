import Foundation

final class SocketCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}

/// One endpoint/client, one serial queue and one bound socket. It never sends a retry.
final class StableMiioTransport: MiioTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MijiaLAN.udp-session", qos: .userInitiated)
    private let session = UUID()
    private var socket: UDPSocket?
    private var socketID: UUID?
    private var endpoint: (String, UInt16)?
    private var ended = false
    func sessionTransport(policy: MiioCommunicationPolicy.Socket) -> any MiioTransport {
        policy == .stable ? StableMiioTransport() : UDPMiioTransport()
    }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await exchangeDiagnosed(packet, host: host, port: port, timeout: timeout, observe: { _ in })
    }
    func exchangeObserved(_ packet: Data, host: String, port: UInt16, timeout: Duration, onSent: @escaping @Sendable () -> Void) async throws -> Data {
        try await exchangeDiagnosed(packet, host: host, port: port, timeout: timeout) { if case .sent = $0.boundary { onSent() } }
    }
    func exchangeDiagnosed(_ packet: Data, host: String, port: UInt16, timeout: Duration, observe: @escaping @Sendable (MiioTransportObservation) -> Void) async throws -> Data {
        try await exchangeValidated(packet, host: host, port: port, timeout: timeout, observe: observe, accept: { _ in true })
    }
    func exchangeValidated(_ packet: Data, host: String, port: UInt16, timeout: Duration, observe: @escaping @Sendable (MiioTransportObservation) -> Void, accept: @escaping @Sendable (Data) -> Bool) async throws -> Data {
        let cancellation = SocketCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !self.ended, !cancellation.cancelled else { throw CancellationError() }
                        if let endpoint = self.endpoint, endpoint.0 != host || endpoint.1 != port { self.release(reason: .configuration, observe: observe) }
                        if self.socket == nil {
                            self.socket = try UDPSocket(bindHost: "0.0.0.0", reuseAddress: false)
                            self.socketID = UUID(); self.endpoint = (host, port)
                            observe(.init(.opened, socket: self.socketID, localPort: self.socket?.localPort, session: self.session))
                        }
                        guard let socket = self.socket, let id = self.socketID else { throw MiioError.timeout }
                        let result = try SocketExchange.run(socket: socket, identity: id, session: self.session,
                            packet: packet, host: host, port: port, timeout: timeout, observe: observe, accept: accept, cancelled: { cancellation.cancelled })
                        continuation.resume(returning: result)
                    } catch {
                        self.release(reason: DeviceEventLog.reason(error), observe: observe)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func release(reason: DeviceEventLog.Reason, observe: @Sendable (MiioTransportObservation) -> Void) {
        if let socket { observe(.init(.closed, socket: socketID, localPort: socket.localPort, session: session, reason: reason)); socket.invalidate() }
        socket = nil; socketID = nil; endpoint = nil
    }
    func closeSession(observe: @escaping @Sendable (MiioTransportObservation) -> Void) async {
        await withCheckedContinuation { continuation in queue.async {
            self.ended = true; self.release(reason: .configuration, observe: observe); continuation.resume()
        } }
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        throw MiioError.badResponse("A device session cannot broadcast")
    }
}

enum SocketExchange {
    static func run(socket: UDPSocket, identity: UUID, session: UUID?, packet: Data, host: String, port: UInt16,
                    timeout: Duration, observe: @Sendable (MiioTransportObservation) -> Void,
                    accept: @Sendable (Data) -> Bool, cancelled: @Sendable () -> Bool) throws -> Data {
        // Old datagrams cannot be answers to a request that has not been sent yet. Bound draining.
        for index in 0..<64 {
            guard !cancelled() else { throw CancellationError() }
            guard let stale = try socket.receive(timeout: 0.0001) else { break }
            if stale.host == host, stale.port == port { _ = accept(stale.data) }
            observe(.init(.discarded, socket: identity, localPort: socket.localPort, session: session, reason: .invalidReply))
            if index == 63 { throw MiioError.badResponse("UDP pending queue exceeded its bound") }
        }
        guard !cancelled() else { throw CancellationError() }
        try socket.send(packet, to: host, port: port)
        observe(.init(.sent, socket: identity, localPort: socket.localPort, session: session))
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var discarded = 0
        while true {
            guard !cancelled() else { throw CancellationError() }
            let remaining = (deadline - ContinuousClock.now).timeInterval
            guard remaining > 0 else { throw MiioError.timeout }
            guard let datagram = try socket.receive(timeout: min(remaining, 0.05)) else { continue }
            if datagram.host == host, datagram.port == port {
                observe(.init(.candidate, socket: identity, localPort: socket.localPort, session: session))
                if accept(datagram.data) {
                    observe(.init(.received, socket: identity, localPort: socket.localPort, session: session))
                    return datagram.data
                }
                observe(.init(.discarded, socket: identity, localPort: socket.localPort, session: session, reason: .invalidReply))
            } else {
                observe(.init(.discarded, socket: identity, localPort: socket.localPort, session: session, reason: .unexpectedPeer))
            }
            discarded += 1
            if discarded >= 64 { throw MiioError.badResponse("UDP rejected reply limit reached") }
        }
    }
}
