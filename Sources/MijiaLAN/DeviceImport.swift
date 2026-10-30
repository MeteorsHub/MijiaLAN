import Foundation
import MijiaCore

public struct CloudImportResult: Equatable, Sendable {
    public var devices: [LocalDevice]
    public var skipped: [SkippedDevice]
    /// The server region the devices were found on.
    public var region: String

    public init(devices: [LocalDevice], skipped: [SkippedDevice], region: String) {
        self.devices = devices
        self.skipped = skipped
        self.region = region
    }
}

/// The only place the Xiaomi cloud is used: one device-list read for tokens and LAN IPs, plus the room names.
/// The caller passes a fresh `MiSession` and drops it afterwards; nothing here stores it.
public enum CloudTokenImport {
    /// Server regions, most common first. A device list is per region, so an empty one means "try the next".
    public static let regions = ["cn", "de", "us", "sg", "ru", "i2"]

    public static func fetch(
        session: MiSession,
        transport: any MiHTTPTransport = URLSessionMiTransport(),
        tryOtherRegions: Bool = true
    ) async throws -> CloudImportResult {
        let order = [session.region] + (tryOtherRegions ? regions.filter { $0 != session.region } : [])
        var lastError: (any Error)?
        for region in order {
            var scoped = session
            scoped.region = region
            let client = MiCloudClient(session: scoped, transport: transport)
            do {
                // `home/device_list` carries `token` and `localip`; the paged v2 list does not.
                let list = try await client.request("home/device_list", data: .object([
                    "getVirtualModel": .bool(false),
                    "getHuamiDevices": .number(0),
                    "get_split_device": .bool(false),
                    "support_smart_home": .bool(true),
                ]))
                guard !(list["list"]?.arrayValue ?? []).isEmpty else { continue }
                let rooms = (try? await client.homeRooms()) ?? []
                return parse(list, rooms: rooms, region: region)
            } catch MiCloudError.sessionExpired {
                throw MiCloudError.sessionExpired
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return CloudImportResult(devices: [], skipped: [], region: session.region)
    }

    public static func parse(_ result: JSONValue, rooms: [MiRoom], region: String) -> CloudImportResult {
        var roomByDid: [String: String] = [:]
        for room in rooms where !room.name.isEmpty {
            for did in room.dids { roomByDid[did] = room.name }
        }
        var devices: [LocalDevice] = []
        var skipped: [SkippedDevice] = []
        for item in result["list"]?.arrayValue ?? [] {
            guard let did = item["did"]?.idString, let model = item["model"]?.stringValue else { continue }
            let name = item["name"]?.stringValue ?? model
            let token = item["token"]?.stringValue ?? ""
            let host = item["localip"]?.stringValue ?? ""
            let parent = item["parent_id"]?.idString ?? ""

            let reason: String?
            if did.hasPrefix("blt.") {
                reason = "蓝牙设备，局域网协议够不到"
            } else if did.hasPrefix("group.") {
                reason = "云端灯组"
            } else if !parent.isEmpty {
                reason = "网关子设备（Zigbee / 蓝牙 Mesh）"
            } else if !MiioToken.isValid(token) {
                reason = "云端没有给出局域网 token"
            } else if !isIPv4(host) {
                reason = "云端没有局域网 IP（设备可能离线）"
            } else {
                reason = nil
            }
            if let reason {
                skipped.append(SkippedDevice(did: did, name: name, model: model, reason: reason))
                continue
            }
            devices.append(LocalDevice(
                did: did, name: name, model: model, host: host,
                token: token.lowercased(),
                mac: item["mac"]?.stringValue,
                specType: item["spec_type"]?.stringValue,
                roomName: roomByDid[did]
            ))
        }
        return CloudImportResult(devices: devices, skipped: skipped, region: region)
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && text != "0.0.0.0"
    }
}

/// Adds a device from its IP and a token the user already has (another tool, an old backup), with no cloud at all.
public enum ManualDeviceProbe {
    /// `miIO.info` both names the model and proves the token: a wrong token fails the checksum.
    /// `specSource` resolves the MIoT spec once (miot-spec.org, no account) so later starts are fully offline.
    public static func probe(
        host: String,
        token: String,
        name: String? = nil,
        specSource: (any MiotSpecSource)? = nil,
        transport: any MiioTransport = UDPMiioTransport(),
        port: UInt16 = MiioPacket.port
    ) async throws -> LocalDevice {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CloudTokenImport.isIPv4(host) else { throw MiioError.socket("不是有效的 IPv4 地址：\(host)") }
        guard let tokenData = MiioToken.parse(token) else { throw MiioError.invalidToken }
        let client = MiioClient(host: host, token: tokenData, port: port, transport: transport, timeout: .seconds(2), retries: 1)
        let header = try await client.handshake()
        let info = try await client.info()
        let spec = try? await specSource?.spec(model: info.model, specType: nil)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LocalDevice(
            did: String(header.deviceID),
            name: trimmedName.isEmpty ? info.model : trimmedName,
            model: info.model,
            host: host,
            token: MiioToken.hex(tokenData),
            mac: info.mac,
            specType: spec?.type
        )
    }
}

extension LocalHomeConfig {
    /// DHCP can move a device; a broadcast hello finds it again by device ID. Returns true when an IP changed.
    @discardableResult
    public mutating func updateHosts(from discovered: [MiioDiscoveredDevice]) -> Bool {
        var changed = false
        for found in discovered {
            guard let index = devices.firstIndex(where: { $0.did == found.did }), devices[index].host != found.host else { continue }
            devices[index].host = found.host
            changed = true
        }
        return changed
    }
}
