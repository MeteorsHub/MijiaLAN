import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import mijia_lan

private func diagnosticObject(_ value: JSONValue?) -> [String: JSONValue] {
    guard let value, case .object(let fields) = value else { return [:] }
    return fields
}

private func diagnosticArray(_ value: JSONValue?) -> [JSONValue] {
    guard let value, case .array(let items) = value else { return [] }
    return items
}

struct ReadOnlyDiagnosticsTests {
    @Test("Diagnostics keep raw scalar types and codes without serializing device credentials")
    func projection() throws {
        let raw: JSONValue = .array([.object(["did": .string("private-device-id"), "token": .string("private-token"),
            "siid": .number(2), "piid": .number(3), "code": .number(-4004), "value": .number(1)])])
        let row = ReadOnlyDiagnostics.reading(raw, siid: 2, piid: 3)
        #expect(row["rawType"] == .string("number"))
        #expect(row["rawValue"] == .number(1))
        #expect(row["code"] == .number(-4004))
        let encoded = try JSONEncoder().encode(row)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-"))
        let info = ReadOnlyDiagnostics.firmware(.object(["model": .string("dooya.motor.dc1545"), "fw_ver": .string("1.0"),
            "token": .string("private-token"), "mac": .string("private-mac")]))
        #expect(Set(info.keys) == ["model", "fw_ver"])
    }
    @Test("Curtain diagnostic allowlist excludes its write-only motor-control property")
    func allowlist() throws {
        let props = try #require(ReadOnlyDiagnostics.properties["dooya.motor.dc1545"])
        #expect(!props.contains { $0 == 2 && $1 == 1 })
        #expect(props.contains { $0 == 2 && $1 == 3 })
        #expect(ReadOnlyDiagnostics.properties["unknown.model"] == nil)
    }

    private actor Script {
        var requests: [(String, JSONValue)] = []
        var model: String
        init(model: String) { self.model = model }
        func call(_ method: String, _ params: JSONValue) throws -> JSONValue {
            requests.append((method, params))
            if method == "miIO.info" {
                return .object(["model": .string(model), "fw_ver": .string("1.2.3"), "token": .string("private-token")])
            }
            let row = diagnosticObject(diagnosticArray(params).first)
            if row["piid"] == .number(1) { throw MiioError.deviceError(code: -4004, message: "private-error-payload") }
            return .array([.object(["siid": row["siid"] ?? .null, "piid": row["piid"] ?? .null,
                                   "code": .number(0), "value": .number(27.5)])])
        }
    }

    private var curtain: LocalDevice {
        LocalDevice(did: "private-did", name: "private-name", model: "dooya.motor.dc1545",
                    host: "192.0.2.55", token: "private-token", specType: "urn:miot-spec-v2:device:motor-controller:0000A01D:dooya-dc1545:1")
    }

    private var dehumidifier: LocalDevice {
        LocalDevice(did: "private-did", name: "private-name", model: "xiaomi.derh.13l",
                    host: "192.0.2.55", token: "private-token")
    }

    @Test("Actual diagnostic collection is one property per read, preserves errors and performs no writes")
    func collection() async throws {
        let script = Script(model: dehumidifier.model)
        let collected = await ReadOnlyDiagnostics.collect(device: dehumidifier, slot: 0) { try await script.call($0, $1) }
        let report = diagnosticObject(collected)
        let requests = await script.requests
        #expect(requests.map(\.0) == ["miIO.info"] + Array(repeating: "get_properties", count: 6))
        #expect(requests.dropFirst().allSatisfy { diagnosticArray($0.1).count == 1 })
        let readings = diagnosticArray(report["readings"])
        try #require(readings.count == 6)
        #expect(diagnosticObject(readings[0])["code"] == .number(-4004))
        #expect(diagnosticObject(readings[1])["rawValue"] == .number(27.5))
        #expect(report["specificationSource"] == .string("imported_config"))
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!text.contains("private-"))
        #expect(!text.contains(dehumidifier.host))
    }

    @Test("A mismatched device stops after info without querying properties")
    func mismatch() async {
        let script = Script(model: "other.model")
        let collected = await ReadOnlyDiagnostics.collect(device: dehumidifier, slot: 0) { try await script.call($0, $1) }
        let report = diagnosticObject(collected)
        #expect(report["error"] == .string("model_mismatch_no_properties_queried"))
        #expect(await script.requests.count == 1)
    }

    @Test("Malformed codes and property identifiers cannot be rounded into valid addresses")
    func malformed() {
        let raw: JSONValue = .array([.object(["siid": .number(2), "piid": .number(3), "code": .number(1e100)])])
        #expect(ReadOnlyDiagnostics.reading(raw, siid: 2, piid: 3)["code"] == .number(1e100))
        let fractional: JSONValue = .array([.object(["siid": .number(2.1), "piid": .number(3), "code": .number(0)])])
        #expect(ReadOnlyDiagnostics.reading(fractional, siid: 2, piid: 3)["error"] == .string("requested_property_missing"))
    }

    @Test("Only matching cached schemas are read, with access metadata and no network fetch")
    func cache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instances = directory.appendingPathComponent("instances")
        try FileManager.default.createDirectory(at: instances, withIntermediateDirectories: true)
        let type = try #require(curtain.specType)
        let file = instances.appendingPathComponent(type.replacingOccurrences(of: ":", with: "_") + ".json")
        let json = """
        {"type":"\(type)","services":[{"iid":2,"type":"motor-controller","properties":[
        {"iid":1,"type":"motor-control","format":"uint8","access":["write"],"value-list":[{"value":1,"description":"Stop"}]},
        {"iid":3,"type":"current-position","format":"uint8","access":["read"],"value-range":[0,100,1]}]}]}
        """
        try Data(json.utf8).write(to: file)
        try Data("private-config".utf8).write(to: directory.appendingPathComponent("home_config_v1"))
        let cached = ReadOnlyDiagnostics.cachedSpecifications(model: curtain.model, directory: directory)
        try #require(cached.count == 1)
        let schema = diagnosticObject(cached[0])
        #expect(schema["type"] == .string(type))
        let service = diagnosticObject(diagnosticArray(schema["services"]).first)
        let props = diagnosticArray(service["properties"])
        let firstProp = try #require(props.first)
        #expect(diagnosticObject(firstProp)["access"] == .array([.string("write")]))
        #expect(ReadOnlyDiagnostics.cachedSpecifications(model: "unknown.model", directory: directory).isEmpty)
        #expect(ReadOnlyDiagnostics.cachedSpecifications(model: "xiaomi.feeder.pi2001", directory: directory).isEmpty)
    }

    private actor FollowupScript {
        var requests: [(String, JSONValue)] = []
        let model: String
        init(model: String) { self.model = model }
        func call(_ method: String, _ params: JSONValue) -> JSONValue {
            requests.append((method, params))
            if method == "miIO.info" { return .object(["model": .string(model), "fw_ver": .string("fixture")]) }
            let row = diagnosticObject(diagnosticArray(params).first)
            let alias = row["did"]?.stringValue ?? ""
            var reply: [String: JSONValue] = ["did": .string("private-echo-did"),
                "siid": row["siid"] ?? .null, "piid": row["piid"] ?? .null]
            if alias.hasPrefix("prop.") || model == "xiaomi.feeder.pi2001" {
                reply["code"] = .number(0)
                reply["value"] = model == "xiaomi.feeder.pi2001" ? .number(1) : .number(25)
            } else { reply["code"] = .number(-4004) }
            return .array([.object(reply)])
        }
    }

    @Test("Paused curtain diagnostics and follow-up emit no hello, info or property calls")
    func curtainPaused() async {
        let script = FollowupScript(model: curtain.model)
        let collected = await ReadOnlyDiagnostics.collect(device: curtain, slot: 0) { await script.call($0, $1) }
        let followup = await ReadOnlyDiagnostics.collectFollowup(device: curtain, slot: 0, protocolDID: "private-handshake-id") {
            await script.call($0, $1)
        }
        #expect(diagnosticObject(collected)["error"] == .string("property_requests_paused"))
        #expect(diagnosticObject(followup)["propertyRequestsSent"] == .number(0))
        #expect(await script.requests.isEmpty)
        #expect(ReadOnlyDiagnostics.followupProbes(device: curtain, protocolDID: curtain.did).isEmpty)
    }

    @Test("Feeder follow-up reads only the three reported bool fields, preserving numeric/boolean conflicts")
    func feederFollowup() async throws {
        let device = LocalDevice(did: "private-feeder", name: "private-name", model: "xiaomi.feeder.pi2001",
            host: "192.0.2.9", token: "private-token")
        let script = FollowupScript(model: device.model)
        let collected = await ReadOnlyDiagnostics.collectFollowup(device: device, slot: 1, protocolDID: nil) {
            await script.call($0, $1)
        }
        let report = diagnosticObject(collected)
        let rows = diagnosticArray(report["readings"]).map(diagnosticObject)
        #expect(rows.count == 3)
        #expect(Set(rows.compactMap { $0["piid"]?.doubleValue }) == [3, 4, 6])
        #expect(rows.allSatisfy { $0["siid"] == .number(5) && $0["rawType"] == .string("number") && $0["rawValue"] == .number(1) })
        #expect(await script.requests.count == 4)
    }

    @Test("Follow-up identity mismatch stops before any property query")
    func followupMismatch() async {
        let script = FollowupScript(model: "other.model")
        let device = LocalDevice(did: "private", name: "private", model: "xiaomi.feeder.pi2001", host: "192.0.2.1", token: "private")
        let report = await ReadOnlyDiagnostics.collectFollowup(device: device, slot: 0, protocolDID: nil) {
            await script.call($0, $1)
        }
        #expect(diagnosticObject(report)["error"] == .string("model_mismatch_no_properties_queried"))
        #expect(await script.requests.count == 1)
    }
}
