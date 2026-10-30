import Foundation

/// A Wi-Fi device the bridge talks to directly. `token` is the LAN secret; the whole config lives in the Keychain.
public struct LocalDevice: Codable, Equatable, Sendable, Identifiable {
    /// The cloud did; for Wi-Fi devices it is the miIO device ID in decimal.
    public var did: String
    public var name: String
    public var model: String
    public var host: String
    /// 32 hex characters.
    public var token: String
    public var mac: String?
    /// The MIoT spec URN; stored so a restart never needs to look the model up online.
    public var specType: String?
    public var roomName: String?

    public var id: String { did }

    public init(did: String, name: String, model: String, host: String, token: String,
                mac: String? = nil, specType: String? = nil, roomName: String? = nil) {
        self.did = did
        self.name = name
        self.model = model
        self.host = host
        self.token = token
        self.mac = mac
        self.specType = specType
        self.roomName = roomName
    }
}

/// A device the import found but cannot reach over the LAN (Bluetooth, Zigbee, Mesh, no token).
public struct SkippedDevice: Codable, Equatable, Sendable, Identifiable {
    public var did: String
    public var name: String
    public var model: String
    public var reason: String

    public var id: String { did }

    public init(did: String, name: String, model: String, reason: String) {
        self.did = did
        self.name = name
        self.model = model
        self.reason = reason
    }
}

public struct LocalHomeConfig: Codable, Equatable, Sendable {
    public var devices: [LocalDevice] = []
    public var skipped: [SkippedDevice] = []
    public var importedAt: Date?

    public init(devices: [LocalDevice] = [], skipped: [SkippedDevice] = [], importedAt: Date? = nil) {
        self.devices = devices
        self.skipped = skipped
        self.importedAt = importedAt
    }

    /// Adds or replaces devices by did. Room and name the user already has are kept when the new entry has none.
    public mutating func merge(_ incoming: [LocalDevice]) {
        for var device in incoming {
            if let index = devices.firstIndex(where: { $0.did == device.did }) {
                device.roomName = device.roomName ?? devices[index].roomName
                device.specType = device.specType ?? devices[index].specType
                devices[index] = device
            } else {
                devices.append(device)
            }
        }
        let added = Set(incoming.map(\.did))
        skipped.removeAll { added.contains($0.did) }
    }

    public mutating func remove(did: String) {
        devices.removeAll { $0.did == did }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> LocalHomeConfig? { try? JSONDecoder().decode(Self.self, from: data) }
}
