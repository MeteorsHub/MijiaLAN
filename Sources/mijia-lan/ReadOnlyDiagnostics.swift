import Foundation
import MijiaCore
import MijiaLAN

/// Explicitly limited diagnostic RPCs. Credentials arrive only on stdin and never enter output or argv.
enum ReadOnlyDiagnostics {
    // Model-specific URN prefixes reviewed against the public specification pages. Version suffix varies.
    static let specificationPrefixes = [
        "dooya.motor.dc1545": "urn:miot-spec-v2:device:motor-controller:0000A01D:dooya-dc1545:",
        "xiaomi.pet_waterer.70m2": "urn:miot-spec-v2:device:pet-drinking-fountain:0000A067:xiaomi-70m2:",
        "giot.heater.v13daf": "urn:miot-spec-v2:device:heater:0000A01A:giot-v13daf:",
        "xiaomi.derh.13l": "urn:miot-spec-v2:device:dehumidifier:0000A02D:xiaomi-13l:",
        "iot.tow_w.jd015": "urn:miot-spec-v2:device:towel-rack:0000A09A:iot-jd015:",
        "xiaomi.feeder.pi2001": "urn:miot-spec-v2:device:pet-feeder:0000A06C:xiaomi-pi2001:",
    ]
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
        guard case .object(let info) = result else { return [:] }
        var fields: [String: JSONValue] = [:]
        for key in ["model", "fw_ver", "mcu_fw_ver", "miio_ver", "hw_ver"] {
            guard let value = info[key] else { continue }
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
        // Match public enum cases instead of MijiaCore's internal subscript/arrayValue conveniences.
        var matched: [String: JSONValue]?
        if case .array(let items) = result {
            for case .object(let candidate) in items {
                guard candidate["siid"] == .number(Double(siid)),
                      candidate["piid"] == .number(Double(piid)) else { continue }
                matched = candidate
                break
            }
        }
        guard let item = matched else {
            output["error"] = .string("requested_property_missing"); return output
        }
        // Avoid JSONValue.intValue: it rounds strings/fractions and can trap on enormous doubles.
        if case .number(let code) = item["code"], code.isFinite, code.rounded() == code {
            output["code"] = .number(code)
        } else { output["code"] = .null }
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
    typealias Call = @Sendable (String, JSONValue) async throws -> JSONValue

    struct Probe: Sendable {
        let siid: Int
        let piid: Int
        let didForm: String
        let wireDID: String
        var params: JSONValue {
            .array([.object(["did": .string(wireDID), "siid": .number(Double(siid)), "piid": .number(Double(piid))])])
        }
    }

    /// Fixed, explicit follow-up only. It does not change production addressing or try arbitrary methods.
    static func followupProbes(device: LocalDevice, protocolDID: String?) -> [Probe] {
        switch device.model {
        case "dooya.motor.dc1545":
            return [2, 3, 4].flatMap { piid -> [Probe] in
                var forms = [("configured", device.did)]
                if let protocolDID, protocolDID != device.did { forms.append(("handshake", protocolDID)) }
                // Read-only addressing patterns used by the referenced upstream implementations.
                forms.append(("pythonMiioAlias", "2-\(piid)"))
                forms.append(("hassMiotAlias", "prop.2.\(piid)"))
                return forms.map { Probe(siid: 2, piid: piid, didForm: $0.0, wireDID: $0.1) }
            }
        case "xiaomi.feeder.pi2001":
            // Addresses and bool/read access verified against the household Mac's cache report.
            // 5.1 feeding schedules and all feeding actions are deliberately absent.
            return [3, 4, 6].map { Probe(siid: 5, piid: $0, didForm: "configured", wireDID: device.did) }
        default: return []
        }
    }

    static func collectFollowup(device: LocalDevice, slot: Int, protocolDID: String?, call: Call) async -> JSONValue {
        let probes = followupProbes(device: device, protocolDID: protocolDID)
        guard !probes.isEmpty else { return .object(["error": .string("model_not_allowlisted")]) }
        var report: [String: JSONValue] = ["slot": .number(Double(slot)), "configuredModel": .string(device.model)]
        do {
            let info = try await call("miIO.info", .array([]))
            report["firmware"] = .object(firmware(info))
            guard case .object(let fields) = info, fields["model"] == .string(device.model) else {
                report["error"] = .string("model_mismatch_no_properties_queried")
                return .object(report)
            }
            if let protocolDID { report["configuredDidMatchesHandshake"] = .bool(protocolDID == device.did) }
            var readings: [JSONValue] = []
            for probe in probes {
                var row: [String: JSONValue]
                do {
                    let result = try await call("get_properties", probe.params)
                    row = reading(result, siid: probe.siid, piid: probe.piid)
                } catch {
                    row = ["siid": .number(Double(probe.siid)), "piid": .number(Double(probe.piid)),
                           "method": .string("get_properties"), "error": .string("rpc_failed")]
                    if case MiioError.deviceError(let code, _) = error { row["code"] = .number(Double(code)) }
                }
                // Preserve only the addressing category, never an actual configured/handshake/echoed DID.
                row["requestDidForm"] = .string(probe.didForm)
                readings.append(.object(row))
            }
            report["readings"] = .array(readings)
        } catch {
            report["error"] = .string("info_failed_no_properties_queried")
            if case MiioError.deviceError(let code, _) = error { report["code"] = .number(Double(code)) }
        }
        return .object(report)
    }

    /// Reads only model-matched specification cache files, never an account/config/pairing directory.
    /// These are cached candidates, not proof of the running App's currently loaded schema version.
    static func cachedSpecifications(model: String, directory: URL) -> [JSONValue] {
        guard let prefix = specificationPrefixes[model] else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("instances"),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter {
            $0.lastPathComponent.hasPrefix(prefix.replacingOccurrences(of: ":", with: "_")) && $0.pathExtension == "json"
        }.prefix(8).compactMap { file in
            guard let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 1_048_576,
                  let data = try? Data(contentsOf: file),
                  let schema = try? JSONDecoder().decode(DeviceSchema.self, from: data),
                  schema.type.hasPrefix(prefix), (schema.model == nil || schema.model == model) else { return nil }
            let services = schema.services.map { service -> JSONValue in
                .object(["siid": .number(Double(service.iid)), "type": .string(service.type), "properties": .array(service.properties.map { p in
                    var prop: [String: JSONValue] = ["piid": .number(Double(p.iid)), "type": .string(p.type),
                        "format": .string(p.format), "access": .array(p.access.map(JSONValue.string))]
                    if let description = p.description { prop["description"] = .string(description) }
                    if let comment = p.comment { prop["comment"] = .string(comment) }
                    if let range = p.valueRange { prop["range"] = .array(range.map(JSONValue.number)) }
                    if let options = p.valueList { prop["options"] = .array(options.map { .object(["value": .number(Double($0.value)), "description": .string($0.description)]) }) }
                    return .object(prop)
                })])
            }
            return .object(["type": .string(schema.type), "services": .array(services)])
        }
    }

    /// Shared by the actual RPC path and scripted tests. The caller never receives a write method.
    static func collect(device: LocalDevice, slot: Int, call: Call) async -> JSONValue {
        guard let props = properties[device.model] else { return .object(["error": .string("model_not_allowlisted")]) }
        var report: [String: JSONValue] = ["slot": .number(Double(slot)), "configuredModel": .string(device.model),
            "specificationSource": .string("imported_config"),
            "specification": .string(device.specType?.hasPrefix("urn:miot-spec-v2:device:") == true ? device.specType! : "not recorded")]
        do {
            let info = try await call("miIO.info", .array([]))
            report["firmware"] = .object(firmware(info))
            guard case .object(let infoFields) = info,
                  infoFields["model"] == .string(device.model) else {
                report["error"] = .string("model_mismatch_no_properties_queried")
                return .object(report)
            }
            var readings: [JSONValue] = []
            for (siid, piid) in props {
                let params: JSONValue = .array([.object(["did": .string(device.did), "siid": .number(Double(siid)), "piid": .number(Double(piid))])])
                do {
                    let result = try await call("get_properties", params)
                    readings.append(.object(reading(result, siid: siid, piid: piid)))
                } catch {
                    var row: [String: JSONValue] = ["siid": .number(Double(siid)), "piid": .number(Double(piid)), "method": .string("get_properties"), "error": .string("rpc_failed")]
                    if case MiioError.deviceError(let code, _) = error { row["code"] = .number(Double(code)) }
                    readings.append(.object(row))
                }
            }
            report["readings"] = .array(readings)
        } catch {
            report["error"] = .string("info_failed_no_properties_queried")
            if case MiioError.deviceError(let code, _) = error { report["code"] = .number(Double(code)) }
        }
        return .object(report)
    }

    static func run(_ input: Data, port: UInt16, followup: Bool = false) async throws {
        guard let config = LocalHomeConfig.decode(input) else { throw MiioError.badResponse("Invalid diagnostic input") }
        var reports: [JSONValue] = []
        var seenModels: Set<String> = []
        let devices = config.devices.filter { device in
            guard properties[device.model] != nil else { return false }
            if !followup { return true }
            guard ["dooya.motor.dc1545", "xiaomi.feeder.pi2001"].contains(device.model) else { return false }
            return seenModels.insert(device.model).inserted
        }
        for (index, device) in devices.prefix(12).enumerated() {
            guard let token = MiioToken.parse(device.token) else {
                reports.append(.object(["slot": .number(Double(index)), "configuredModel": .string(device.model), "error": .string("invalid_token")]))
                continue
            }
            let client = MiioClient(host: device.host, token: token, port: port, timeout: .seconds(2), retries: 0)
            var report: JSONValue
            if followup {
                var protocolDID: String?
                if device.model == "dooya.motor.dc1545" {
                    do { protocolDID = String(try await client.handshake().deviceID) }
                    catch {
                        reports.append(.object(["slot": .number(Double(index)), "configuredModel": .string(device.model), "error": .string("handshake_failed")]))
                        continue
                    }
                }
                report = await collectFollowup(device: device, slot: index, protocolDID: protocolDID) { method, params in
                    try await client.call(method, params: params, retryCount: 0)
                }
            } else {
                report = await collect(device: device, slot: index) { method, params in
                    try await client.call(method, params: params, retryCount: 0)
                }
            }
            if case .object(var fields) = report {
                fields["cachedSpecifications"] = .array(cachedSpecifications(model: device.model, directory: LocalHomeProvider.specCacheDirectory))
                report = .object(fields)
            }
            reports.append(report)
        }
        let data = try JSONEncoder().encode(JSONValue.object(["devices": .array(reports)]))
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
