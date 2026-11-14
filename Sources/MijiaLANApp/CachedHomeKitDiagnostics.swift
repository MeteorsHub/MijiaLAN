import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN

/// A shareable snapshot of cached state. No API, device refresh or mail transport is available here.
@MainActor
enum CachedHomeKitDiagnostics {
    static func data(snapshots: [DeviceSnapshot], failures: [HomeKitBridgeController.ReadFailure],
                     aliases: [String: Int], now: Date = Date()) -> Data? {
        let rows: [[String: Any]] = snapshots.compactMap { snapshot in
            guard let alias = aliases[snapshot.id] else { return nil }
            let properties: [[String: Any]] = snapshot.capabilities.filter(\.readable).map { capability in
                let reading = snapshot.readings[capability.id]
                var item: [String: Any] = ["property": capability.id, "expectedType": capability.format,
                                         "available": reading?.isAvailable ?? false]
                item["code"] = reading?.code
                item["observedType"] = type(reading?.rawValue ?? reading?.value)
                item["updatedAt"] = reading?.updatedAt?.ISO8601Format()
                return item
            }
            // Do not export names, DID, endpoints, arbitrary error text, raw values or binding descriptions.
            return ["device": "C\(alias)", "model": snapshot.device.model, "specification": snapshot.schema.type,
                    "health": String(describing: snapshot.health.state),
                    "homeKitSupported": CapabilityHomeKitMapper.mapsToHome(snapshot), "properties": properties,
                    "homeKitReadFailures": failures.filter { $0.deviceID == snapshot.id }.map {
                        ["service": $0.service, "characteristic": $0.characteristic, "status": $0.status] as [String: Any]
                    }]
        }
        let output: [String: Any] = ["recordedAt": now.ISO8601Format(), "source": "cache", "devices": rows]
        return try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }

    private static func type(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        case .null: return "null"
        }
    }
}
