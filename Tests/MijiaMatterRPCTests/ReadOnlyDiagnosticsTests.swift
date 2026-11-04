import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import mijia_lan

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
            let row = params.arrayValue?.first ?? .null
            if row["piid"] == .number(2) { throw MiioError.deviceError(code: -4004, message: "private-error-payload") }
            return .array([.object(["siid": row["siid"] ?? .null, "piid": row["piid"] ?? .null,
                                   "code": .number(0), "value": .number(27.5)])])
        }
    }

    private var curtain: LocalDevice {
        LocalDevice(did: "private-did", name: "private-name", model: "dooya.motor.dc1545",
                    host: "192.0.2.55", token: "private-token", specType: "urn:miot-spec-v2:device:motor-controller:0000A01D:dooya-dc1545:1")
    }

    @Test("Actual diagnostic collection is one property per read, preserves errors and performs no writes")
    func collection() async throws {
        let script = Script(model: curtain.model)
        let report = await ReadOnlyDiagnostics.collect(device: curtain, slot: 0) { try await script.call($0, $1) }
        let requests = await script.requests
        #expect(requests.map(\.0) == ["miIO.info"] + Array(repeating: "get_properties", count: 6))
        #expect(requests.dropFirst().allSatisfy { $0.1.arrayValue?.count == 1 })
        let readings = try #require(report["readings"]?.arrayValue)
        #expect(readings.count == 6)
        #expect(readings[0]["code"] == .number(-4004))
        #expect(readings[1]["rawValue"] == .number(27.5))
        #expect(report["specificationSource"] == .string("imported_config"))
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!text.contains("private-"))
        #expect(!text.contains(curtain.host))
    }

    @Test("A mismatched device stops after info without querying properties")
    func mismatch() async {
        let script = Script(model: "other.model")
        let report = await ReadOnlyDiagnostics.collect(device: curtain, slot: 0) { try await script.call($0, $1) }
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
        #expect(cached.count == 1)
        #expect(cached[0]["type"] == .string(type))
        let props = try #require(cached[0]["services"]?.arrayValue?.first?["properties"]?.arrayValue)
        #expect(props[0]["access"] == .array([.string("write")]))
        #expect(ReadOnlyDiagnostics.cachedSpecifications(model: "unknown.model", directory: directory).isEmpty)
        #expect(ReadOnlyDiagnostics.cachedSpecifications(model: "xiaomi.feeder.pi2001", directory: directory).isEmpty)
    }
}
