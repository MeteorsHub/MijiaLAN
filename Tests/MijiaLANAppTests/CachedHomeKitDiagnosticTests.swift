import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor struct CachedHomeKitDiagnosticTests {
    @Test("Cached summary preserves codes and value types without exporting identifiers, payloads or credentials")
    func privacyAndFailures() throws {
        let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
        let device = LocalDevice(did: "private-fixture-did", name: "private-fixture-name", model: "yeelink.light.lamp4",
                                 host: "192.0.2.245", token: String(repeating: "c", count: 32))
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: device.model)
        let property = try #require(caps.first(where: \.readable))
        var snapshot = DeviceSnapshot(device: device, schema: schema, capabilities: caps)
        snapshot.readings[property.id] = DeviceReading(code: -4004, error: "private-error", rawValue: .string("private-payload"))
        let failures = [HomeKitBridgeController.ReadFailure(deviceID: device.did, service: "43", characteristic: "25",
                                                          source: "private-binding", status: -70402)]
        let data = try #require(CachedHomeKitDiagnostics.data(snapshots: [snapshot], failures: failures, aliases: [device.did: 8]))
        let text = String(decoding: data, as: UTF8.self)
        for secret in [device.did, device.name, device.host, device.token, "private-error", "private-payload", "private-binding"] {
            #expect(!text.contains(secret))
        }
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "cache")
        let row = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(row["device"] as? String == "C8")
        let entries = try #require(row["properties"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["property"] as? String == property.id })
        #expect(entry["code"] as? Int == -4004 && entry["observedType"] as? String == "string")
        #expect((row["homeKitReadFailures"] as? [[String: Any]])?.first?["status"] as? Int == -70402)
    }

    @Test("A device without an assigned local alias is omitted rather than using its DID as a fallback")
    func noIdentityFallback() throws {
        let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
        let device = LocalDevice(did: "never-export-this", name: "fixture", model: "yeelink.light.lamp4", host: "192.0.2.245", token: "fixture")
        let snapshot = DeviceSnapshot(device: device, schema: schema, capabilities: [])
        let data = try #require(CachedHomeKitDiagnostics.data(snapshots: [snapshot], failures: [], aliases: [:]))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["devices"] as? [[String: Any]])?.isEmpty == true)
    }
}
