import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct FieldTelemetryReplayTests {
    private struct Sample: Decodable {
        let model: String
        let specification: String
        let readings: [Row]
    }
    private struct Row: Decodable {
        let siid: Int
        let piid: Int
        let code: Int
        let hasValue: Bool
        let value: JSONValue?
    }
    private struct Corpus: Decodable { let devices: [Sample] }
    private func load(_ model: String) throws -> DeviceSnapshot {
        let corpusURL = try #require(Bundle.module.url(forResource: "household-readings-2026-11-06", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        let sample = try #require(corpus.devices.first { $0.model == model })
        let schemaURL = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: schemaURL))
        // The general dehumidifier fixture is v2. Its identical selected temperature definition
        // is separately verified below with the household's exact, narrowly projected v1 schema.
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        var snapshot = DeviceSnapshot(device: LocalDevice(did: "test", name: "Replay", model: model,
            host: "192.0.2.1", token: "fixture-only", specType: sample.specification), schema: schema, capabilities: caps,
            health: LANDeviceHealth(state: .online))
        for row in sample.readings {
            let id = DeviceCapability.propertyID(row.siid, row.piid)
            let cap = try #require(snapshot.capabilitiesByID[id])
            let reading = DeviceReading(value: row.code == 0 && row.hasValue ? row.value : nil, code: row.code,
                error: row.code == 0 && row.hasValue ? nil : MiotPropertyStatus.description(row.code))
            snapshot.readings[id] = cap.checkedReading(reading)
        }
        return snapshot
    }

    @Test("Fountain's bool fault stays invalid; valid status and water shortage remain independent")
    func fountain() throws {
        let snapshot = try load("xiaomi.pet_waterer.70m2")
        #expect(snapshot.isOnline)
        #expect(snapshot.value("p:2:1") == nil)
        #expect(snapshot.readings["p:2:1"]?.rawValue == .bool(true))
        #expect(snapshot.readings["p:2:1"]?.error != nil)
        #expect(snapshot.value("p:2:3") == .number(1))
        #expect(snapshot.value("p:2:10") == .bool(false))
        #expect(snapshot.value("p:2:7") == .number(60))
        #expect(snapshot.readings["p:2:11"]?.code == -4001)
        let failed = try #require(snapshot.capabilitiesByID["p:2:11"])
        let valid = try #require(snapshot.capabilitiesByID["p:2:7"])
        #expect(snapshot.controlUnavailableReason(failed) != nil)
        #expect(snapshot.controlUnavailableReason(valid) == nil)
    }

    @Test("Curtain's structured -4004 results do not make it offline or supply guessed positions")
    func curtain() throws {
        let snapshot = try load("dooya.motor.dc1545")
        #expect(snapshot.isOnline)
        for reading in snapshot.readings.values {
            #expect(!reading.isAvailable)
            #expect(reading.code == -4004)
        }
        let motor = try #require(snapshot.capability("motor-controller", "motor-control"))
        #expect(snapshot.controlUnavailableReason(motor) != nil)
        #expect(snapshot.value("motor-controller", "current-position") == nil)
    }

    @Test("Read samples retain heater/light power and towel power/status as separate meanings")
    func heating() throws {
        let fireplace = try load("giot.heater.v13daf")
        let main = try #require(fireplace.primaryPower)
        #expect(fireplace.value(main.id) == .bool(false))
        #expect(fireplace.value("light", "on") == .bool(true))
        #expect(fireplace.value("heater", "heat-level") == .number(8))
        let towel = try load("iot.tow_w.jd015")
        #expect(towel.value("towel-rack", "on") == .bool(true))
        #expect(towel.value("towel-rack", "status") == .number(3))
        #expect(towel.value("towel-rack", "target-temperature") == .number(65))
        #expect(towel.value("towel-rack", "temperature") == .number(59))
    }

    @Test("Dehumidifier's observed 22.1 sample passes its exact cached v1 float declaration")
    func temperatureV1() throws {
        let url = try #require(Bundle.module.url(forResource: "xiaomi.derh.13l.v1", withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        #expect(schema.type == "urn:miot-spec-v2:device:dehumidifier:0000A02D:xiaomi-13l:1")
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: "xiaomi.derh.13l")
        let temperature = try #require(caps.first { $0.id == "p:3:2" })
        #expect(temperature.checkedReading(DeviceReading(value: .number(22.1), code: 0)).isAvailable)
        let replay = try load("xiaomi.derh.13l")
        #expect(replay.value("p:3:2") == .number(22.1))
        #expect(replay.value("p:2:5") == .number(50))
        #expect(replay.value("p:3:1") == .number(45))
    }

    @Test("Feeder's number readings and 100 percent progress are preserved without triggering actions")
    func feeder() throws {
        let snapshot = try load("xiaomi.feeder.pi2001")
        #expect(snapshot.readings.count == 11)
        #expect(snapshot.readings.values.allSatisfy { $0.isAvailable })
        #expect(snapshot.value("p:2:29") == .number(100))
        #expect(snapshot.capabilities.filter { $0.kind == .action }.allSatisfy { !$0.writable })
    }

    @Test("MIoT property errors retain their documented per-property meaning")
    func codes() {
        L10n.$overrideLanguage.withValue(.en) {
            #expect(MiotPropertyStatus.description(-4001).contains("not readable"))
            #expect(MiotPropertyStatus.description(-4003).contains("does not exist"))
            #expect(MiotPropertyStatus.description(-4004).contains("internal error"))
            #expect(!MiotPropertyStatus.description(-4004).contains("Invalid arguments"))
            #expect(MiotPropertyStatus.description(-4007).contains("DID"))
        }
    }
}

#if os(macOS)
struct FieldTelemetryLANTests {
    @Test("Structured -4004 errors keep the actual LAN API online and do not retry or write")
    func curtainErrorsStayLocal() async throws {
        let model = "dooya.motor.dc1545"
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        let token = "00112233445566778899aabbccddeeff"
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        fake.propertyErrors = Dictionary(uniqueKeysWithValues: caps.filter(\.readable).map { ("\($0.siid).\($0.iid)", -4004) })
        let device = LocalDevice(did: "123", name: "Test", model: model, host: "test", token: token)
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: network)
        let readings = await api.readCapabilities(did: device.did, capabilities: caps)
        let health = await api.currentHealth()
        #expect(health[device.did]?.state == .online)
        #expect(readings.count == 6)
        #expect(readings.values.allSatisfy { $0.code == -4004 && !$0.isAvailable })
        #expect(fake.receivedMethods == ["get_properties"])
        #expect(fake.receivedWrites.isEmpty)
        for data in fake.receivedPayloads {
            let json = try JSONDecoder().decode(JSONValue.self, from: data.prefix { $0 != 0 })
            guard case .object(let object) = json, case .array(let params) = object["params"] else { continue }
            for case .object(let prop) in params { #expect(prop["piid"] != .number(1)) }
        }
    }
}
#endif
