import Foundation
import MijiaCore
import MijiaLAN

/// Explicitly limited diagnostic RPCs. Credentials arrive only on stdin and never enter output or argv.
enum ReadOnlyDiagnostics {
    static let properties: [String: [(Int, Int)]] = [
        "dooya.motor.dc1545": [(2, 2), (2, 3), (2, 4), (2, 5), (2, 9), (2, 10)],
        "xiaomi.pet_waterer.70m2": [(2, 1), (2, 3), (2, 4), (2, 7), (2, 10), (2, 11)],
        "giot.heater.v13daf": [(2, 1), (2, 2), (2, 3), (3, 1), (3, 2)],
        "xiaomi.derh.13l": [(2, 1), (2, 2), (2, 3), (2, 5), (3, 1), (3, 2)],
        "iot.tow_w.jd015": [(2, 1), (2, 2), (2, 3), (2, 4), (2, 5), (2, 6)],
        // Only published readable status attributes. Vendor switches require their exact cached specification first.
        "xiaomi.feeder.pi2001": [(2, 1), (2, 6), (2, 10), (2, 11), (2, 13), (2, 15), (2, 26), (2, 28), (2, 29), (2, 31), (2, 32)],
    ]
    static func firmware(_ result: JSONValue) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for key in ["model", "fw_ver", "mcu_fw_ver", "miio_ver", "hw_ver"] {
            guard let value = result[key] else { continue }
            switch value {
            case .string(let text) where text.count <= 96: fields[key] = value
            case .number(let number) where number.isFinite: fields[key] = value
            default: break
            }
        }
        return fields
    }
    static func reading(_ result: JSONValue, siid: Int, piid: Int) -> [String: JSONValue] {
        var output: [String: JSONValue] = ["method": .string("get_properties"), "siid": .number(Double(siid)), "piid": .number(Double(piid))]
        guard let item = result.arrayValue?.first(where: { $0["siid"]?.intValue == siid && $0["piid"]?.intValue == piid }) else {
            output["error"] = .string("requested_property_missing"); return output
        }
        output["code"] = item["code"]?.intValue.map { .number(Double($0)) } ?? .null
        output["hasValue"] = .bool(item["value"] != nil)
        let value = item["value"] ?? .null
        switch value {
        case .bool: output["rawType"] = .string("boolean"); output["rawValue"] = value
        case .number: output["rawType"] = .string("number"); output["rawValue"] = value
        case .string(let text): output["rawType"] = .string("string"); output["rawValue"] = .string(String(text.prefix(96)))
        case .null: output["rawType"] = .string("null"); output["rawValue"] = .null
        case .array: output["rawType"] = .string("array"); output["valueOmitted"] = .bool(true)
        case .object: output["rawType"] = .string("object"); output["valueOmitted"] = .bool(true)
        }
        return output
    }
    static func run(_ input: Data, port: UInt16) async throws {
        guard let config = LocalHomeConfig.decode(input) else { throw MiioError.badResponse("Invalid diagnostic input") }
        var reports: [JSONValue] = []
        for (index, device) in config.devices.filter({ properties[$0.model] != nil }).prefix(12).enumerated() {
            guard let props = properties[device.model] else { continue }
            var report: [String: JSONValue] = ["slot": .number(Double(index)), "configuredModel": .string(device.model),
                "specification": .string(device.specType?.hasPrefix("urn:miot-spec-v2:device:") == true ? device.specType! : "not recorded")]
            do {
                guard let token = MiioToken.parse(device.token) else { throw MiioError.invalidToken }
                let client = MiioClient(host: device.host, token: token, port: port, timeout: .seconds(2), retries: 0)
                let info = try await client.call("miIO.info", retryCount: 0)
                report["firmware"] = .object(firmware(info))
                guard info["model"]?.stringValue == device.model else { throw MiioError.badResponse("Model mismatch") }
                var readings: [JSONValue] = []
                for (siid, piid) in props {
                    let params: JSONValue = .array([.object(["did": .string(device.did), "siid": .number(Double(siid)), "piid": .number(Double(piid))])])
                    do {
                        let result = try await client.call("get_properties", params: params, retryCount: 0)
                        readings.append(.object(reading(result, siid: siid, piid: piid)))
                    } catch {
                        var row: [String: JSONValue] = ["siid": .number(Double(siid)), "piid": .number(Double(piid)), "method": .string("get_properties"), "error": .string("rpc_failed")]
                        if case MiioError.deviceError(let code, _) = error { row["code"] = .number(Double(code)) }
                        readings.append(.object(row))
                    }
                }
                report["readings"] = .array(readings)
            } catch { report["error"] = .string("info_or_identity_check_failed") }
            reports.append(.object(report))
        }
        let data = try JSONEncoder().encode(JSONValue.object(["devices": .array(reports)]))
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
