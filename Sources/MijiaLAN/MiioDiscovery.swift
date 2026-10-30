import Foundation

/// A device that answered the broadcast hello. Discovery needs no token, so it finds IPs and device IDs only.
public struct MiioDiscoveredDevice: Equatable, Sendable, Identifiable {
    public var host: String
    public var deviceID: UInt32
    /// Only unprovisioned or very old firmware reveals it.
    public var revealedToken: String?

    public var id: UInt32 { deviceID }
    /// For Wi-Fi devices this is the cloud did.
    public var did: String { String(deviceID) }
}

public enum MiioDiscovery {
    /// Broadcasts the hello three times over `duration` and returns one entry per device ID, sorted by IP.
    public static func discover(
        duration: Duration = .seconds(3),
        transport: any MiioTransport = UDPMiioTransport()
    ) async throws -> [MiioDiscoveredDevice] {
        let replies = try await transport.broadcast(MiioPacket.hello, port: MiioPacket.port, duration: duration, rounds: 3)
        return devices(from: replies)
    }

    static func devices(from replies: [MiioDatagram]) -> [MiioDiscoveredDevice] {
        var byID: [UInt32: MiioDiscoveredDevice] = [:]
        for reply in replies {
            // Our own broadcast comes back too; it is a bare hello with the 0xFFFFFFFF device ID.
            guard reply.data.count == MiioPacket.headerLength,
                  let header = try? MiioPacket.parseHeader(reply.data),
                  header.deviceID != 0xFFFF_FFFF, header.deviceID != 0 else { continue }
            byID[header.deviceID] = MiioDiscoveredDevice(host: reply.host, deviceID: header.deviceID, revealedToken: header.revealedToken)
        }
        return byID.values.sorted { ipSortKey($0.host).lexicographicallyPrecedes(ipSortKey($1.host)) }
    }

    static func ipSortKey(_ host: String) -> [Int] {
        host.split(separator: ".").map { Int($0) ?? 0 }
    }
}
