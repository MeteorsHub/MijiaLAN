import MijiaCore
import Darwin
import Foundation

public struct MiioDatagram: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var data: Data

    public init(host: String, port: UInt16 = MiioPacket.port, data: Data) {
        self.host = host
        self.port = port
        self.data = data
    }
}

/// The UDP seam, so the client and discovery can be tested against an in-memory device.
public protocol MiioTransport: Sendable {
    /// Sends `packet` to `host:port` and returns the first datagram that comes back from that host.
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data
    /// Sends `packet` to every IPv4 broadcast address (`rounds` times, spread over `duration`) and collects replies.
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram]
}

/// BSD sockets rather than Network.framework: broadcast discovery needs `SO_BROADCAST`, and a fresh socket per
/// exchange means a late reply to an earlier request can never be taken for the current one.
/// Blocking calls run on a dispatch queue so they never hold a Swift concurrency thread.
public struct UDPMiioTransport: MiioTransport {
    private static let queue = DispatchQueue(label: "MijiaLAN.udp", qos: .userInitiated, attributes: .concurrent)

    public init() {}

    public func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        try await Self.run {
            let socket = try UDPSocket()
            try socket.send(packet, to: host, port: port)
            let deadline = Date().addingTimeInterval(timeout.timeInterval)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0, let datagram = try socket.receive(timeout: remaining) else { throw MiioError.timeout }
                if datagram.host == host { return datagram.data }
            }
        }
    }

    public func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] {
        try await Self.run {
            let socket = try UDPSocket(broadcast: true)
            let targets = Self.broadcastAddresses()
            let total = duration.timeInterval
            let rounds = max(1, rounds)
            let start = Date()
            var replies: [MiioDatagram] = []
            for round in 0..<rounds {
                var sentAny = false
                for target in targets {
                    // One interface without a route must not stop the others.
                    if (try? socket.send(packet, to: target, port: port)) != nil { sentAny = true }
                }
                if round == 0 && !sentAny {
                    throw MiioError.socket(L10n.tr("无法发送局域网广播（检查「本地网络」权限和 Wi-Fi 连接）", "Could not broadcast on the LAN. Check Local Network access and your Wi-Fi connection."))
                }
                let roundEnd = start.addingTimeInterval(total * Double(round + 1) / Double(rounds))
                while true {
                    let remaining = roundEnd.timeIntervalSinceNow
                    guard remaining > 0, let datagram = try socket.receive(timeout: remaining) else { break }
                    replies.append(datagram)
                }
            }
            return replies
        }
    }

    /// Each up IPv4 interface's broadcast address (e.g. 192.168.1.255), then the limited broadcast address, which
    /// macOS sends out of the primary interface only.
    static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                let flags = Int32(entry.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                      let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                      let broadcast = entry.ifa_dstaddr, let text = UDPSocket.hostString(broadcast) else { continue }
                if !result.contains(text) { result.append(text) }
            }
        }
        result.append("255.255.255.255")
        return result
    }

    private static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// A plain file descriptor; the calls it makes are safe from any thread.
final class UDPSocket: @unchecked Sendable {
    private let fd: Int32

    init(broadcast: Bool = false, bindHost: String? = nil, bindPort: UInt16 = 0) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiioError.socket(Self.errnoText()) }
        if broadcast {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        if let bindHost {
            var address = try Self.address(bindHost, port: bindPort)
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else {
                let message = Self.errnoText()
                close(fd)
                throw MiioError.socket(message)
            }
        }
    }

    deinit { close(fd) }

    /// The port this socket is bound to (tests bind port 0 and ask).
    var localPort: UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        var address = try Self.address(host, port: port)
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else {
            // An on-link IP whose ARP lookup failed, which is what a powered-off or moved device looks like.
            if [EHOSTUNREACH, EHOSTDOWN].contains(errno) { throw MiioError.hostUnreachable }
            throw MiioError.socket(Self.errnoText())
        }
    }

    /// nil when nothing arrived within `timeout` seconds.
    func receive(timeout: TimeInterval) throws -> MiioDatagram? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000, 60_000)))
        let ready = poll(&descriptor, 1, milliseconds)
        if ready == 0 || (ready < 0 && errno == EINTR) { return nil }
        guard ready > 0 else { throw MiioError.socket(Self.errnoText()) }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let capacity = buffer.count
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, capacity, 0, $0, &length) }
        }
        guard count >= 0 else { throw MiioError.socket(Self.errnoText()) }
        let (host, port) = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { (Self.hostString($0), Self.port($0)) }
        }
        return MiioDatagram(host: host ?? "", port: port, data: Data(buffer[0..<count]))
    }

    static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw MiioError.socket(L10n.tr("不是有效的 IPv4 地址：\(host)", "Invalid IPv4 address: \(host)")) }
        return address
    }

    static func hostString(_ address: UnsafePointer<sockaddr>) -> String? {
        guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var inAddr = pointer.pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inAddr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
    }

    static func port(_ address: UnsafePointer<sockaddr>) -> UInt16 {
        guard address.pointee.sa_family == sa_family_t(AF_INET) else { return 0 }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
