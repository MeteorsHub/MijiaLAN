import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct MatterPetStatusTests {
    private let water = "xiaomi.pet_waterer.70m2"
    private let food = "xiaomi.feeder.pi2001"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ model: String) throws -> DeviceSnapshot {
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return DeviceSnapshot(device: LocalDevice(did: model, name: "Pet fixture", model: model, host: "test", token: "private"),
            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model), health: LANDeviceHealth(state: .online))
    }
    private func plan(_ snapshot: DeviceSnapshot, age: TimeInterval = 120) throws -> MatterDevicePlan.Entry {
        try #require(MatterDevicePlan.entries([snapshot], now: now, cacheMaxAge: age).first)
    }

    @Test("Reviewed shortage attributes preserve physical identity and map false/0 to normal and true/1 to shortage")
    func reviewedSemantics() throws {
        for (model, address, kind) in [(water, "p:2:10", "waterShortage"), (food, "p:2:6", "foodShortage")] {
            var s = try snapshot(model)
            for shortage in [false, true] {
                let raw: JSONValue = model == water ? .bool(shortage) : .number(shortage ? 1 : 0)
                s.readings[address] = DeviceReading(value: raw, updatedAt: now, code: 0)
                // An unrelated, unresolved property cannot substitute for the reviewed source.
                s.readings["p:2:31"] = DeviceReading(value: .number(shortage ? 0 : 1), updatedAt: now)
                let entry = try plan(s)
                #expect(entry.device.kind == kind && entry.device.reachable)
                #expect(entry.device.attributes == [kind: .bool(shortage)])
                #expect(entry.bindings[kind]?.id == address && entry.bindings[kind]?.readable == true)
                #expect(entry.device.did == model + ":" + kind)
                #expect(entry.sourceID == model && entry.device.sourceID == model && entry.device.sourceName == s.device.name)
                #expect(entry.device.on == nil)
                let bytes = try JSONEncoder().encode(entry.device)
                #expect(!String(decoding: bytes, as: UTF8.self).contains("private"))
            }
        }
    }

    @Test("Missing, failed, stale, offline and wrong-type shortage readings remain unavailable, never synthesized as normal")
    func invalidReadings() throws {
        for (model, address, kind) in [(water, "p:2:10", "waterShortage"), (food, "p:2:6", "foodShortage")] {
            var s = try snapshot(model)
            let good: JSONValue = model == water ? .bool(false) : .number(0)
            let badValues: [JSONValue] = model == water ? [.number(0), .number(1), .string("false"), .null]
                : [.bool(false), .string("0"), .number(2), .number(-1), .number(0.5), .null]
            var failures = badValues.map { DeviceReading(value: $0, updatedAt: now, code: 0) }
            failures += [DeviceReading(), DeviceReading(value: good),
                DeviceReading(value: good, updatedAt: now, code: -4001),
                DeviceReading(value: good, updatedAt: now, error: "timeout"),
                DeviceReading(value: good, updatedAt: now.addingTimeInterval(-121)),
                DeviceReading(value: good, updatedAt: now.addingTimeInterval(1))]
            for reading in failures {
                s.readings[address] = reading
                let entry = try plan(s)
                #expect(!entry.device.reachable && entry.device.attributes[kind] == nil)
            }
            s.readings[address] = DeviceReading(value: good, updatedAt: now.addingTimeInterval(-121))
            #expect(try plan(s, age: 180).device.reachable)
            s.health.state = .offline
            #expect(try plan(s, age: 180).device.reachable == false)
        }
    }

    @Test("The pet allowlist requires the exact model, address, semantics, readable permission, type and food enum")
    func exactAllowlist() throws {
        for (model, address) in [(water, "p:2:10"), (food, "p:2:6")] {
            let original = try snapshot(model)
            var other = original
            other.device.model = "test.similar.pet"
            #expect(MatterDevicePlan.entries([other]).isEmpty)
            for mutation in 0..<6 {
                var s = original
                let index = try #require(s.capabilities.firstIndex { $0.id == address })
                switch mutation {
                case 0: s.capabilities[index].iid = 31
                case 1: s.capabilities[index].siid = 5
                case 2: s.capabilities[index].name = "status"
                case 3: s.capabilities[index].service = "vendor-custom"
                case 4: s.capabilities[index].readable = false
                default: s.capabilities[index].format = model == water ? "uint8" : "bool"
                }
                #expect(MatterDevicePlan.entries([s]).isEmpty)
            }
            if model == food {
                var s = original
                let index = try #require(s.capabilities.firstIndex { $0.id == address })
                s.capabilities[index].options = []
                #expect(MatterDevicePlan.entries([s]).isEmpty)
            }
        }
    }

    @MainActor @Test("Native write execution rejects every pet shortage endpoint before any LAN transport even if a future spec declares write")
    func readOnlyNativeBoundary() async throws {
        for (model, kind, address) in [(water, "waterShortage", 10), (food, "foodShortage", 6)] {
            var s = try snapshot(model)
            // Avoid shared schema-cache collisions with concurrent tests.
            s.schema.type += ":readonly-test-\(UUID().uuidString)"
            for si in s.schema.services.indices {
                for pi in s.schema.services[si].properties.indices where s.schema.services[si].iid == 2 && s.schema.services[si].properties[pi].iid == address {
                    s.schema.services[si].properties[pi].access.append("write")
                }
            }
            s.device.specType = s.schema.type
            let folder = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(s.schema.type.replacingOccurrences(of: ":", with: "_") + ".json")
            try JSONEncoder().encode(s.schema).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let config = LocalHomeConfig(devices: [s.device]), network = PetNoNetwork()
            let api = LANMiotAPI(config: { config }, transport: network)
            let controller = DeviceController(api: api, config: { config })
            defer { controller.shutdown() }
            #expect(MatterDevicePlan.entries(Array(controller.snapshots.values)).first?.bindings[kind]?.writable == true)
            for property in [kind, "on", "mode", "feed"] {
                await #expect(throws: DeviceControlError.self) {
                    try await MatterDevicePlan.execute(controller: controller, endpoint: model + ":" + kind, property: property, value: .bool(true))
                }
            }
            #expect(await network.calls == 0)
        }
    }
}

private actor PetNoNetwork: MiioTransport {
    private(set) var calls = 0
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data { calls += 1; throw MiioError.timeout }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { calls += 1; return [] }
}
