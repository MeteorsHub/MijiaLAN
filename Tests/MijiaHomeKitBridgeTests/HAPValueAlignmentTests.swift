import Foundation
import HAPCore
import HAPTransport
import MijiaCore
import Testing
@testable import MijiaLAN

struct HAPValueAlignmentTests {
    @Test("Read and write constraints match executable Rust reference vectors")
    func rustReference() throws {
        let url = try #require(Bundle.module.url(forResource: "rust-value-reference", withExtension: "json", subdirectory: "Specs"))
        let cases = try #require(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).arrayValue)
        #expect(cases.count == 73)
        for item in cases {
            let attr = try #require(item["attribute"])
            let format = try #require(attr["format"]?.stringValue.flatMap(HAPFormat.init(rawValue:)))
            let writable = attr["perms"]?.arrayValue?.contains(.string("pw")) == true
            let c = HAPCharacteristic(iid: 9, type: .brightness, permissions: writable ? [.read, .write, .notify] : [.read], format: format,
                minValue: attr["minValue"]?.doubleValue, maxValue: attr["maxValue"]?.doubleValue, minStep: attr["minStep"]?.doubleValue,
                validValues: attr["valid-values"]?.arrayValue?.compactMap(\.intValue))
            let raw = try #require(item["value"])
            let input: HAPCharacteristicValue? = switch raw {
            case .number(let n): .float(n)
            case .bool(let b): .bool(b)
            case .string(let s): .string(s)
            default: nil
            }
            let read = input.flatMap { c.normalizedRead($0) }
            let write = input.flatMap { c.normalizedWrite($0) }
            #expect((read == nil ? -70402 : 0) == item["read"]?["status"]?.intValue, "\(item["name"] ?? .null)")
            #expect((!writable ? -70404 : write == nil ? -70410 : 0) == item["write"]?["status"]?.intValue, "\(item["name"] ?? .null)")
            if let read { try equal(read, try #require(item["read"]?["value"])) }
            if writable, let write { try equal(write, try #require(item["write"]?["value"])) }
        }
    }

    @Test("UTF-8 metadata truncation preserves scalar boundaries and the original strings")
    func stringBoundaries() throws {
        for (original, expected) in [
            (String(repeating: "中", count: 22), String(repeating: "中", count: 21)),
            (String(repeating: "🙂", count: 17), String(repeating: "🙂", count: 16)),
            (String(repeating: "中", count: 21) + "🙂abc", String(repeating: "中", count: 21)),
            (String(repeating: "中", count: 20) + "abcd", String(repeating: "中", count: 20) + "abcd"),
        ] {
            #expect(HAPString.bounded(original) == expected)
            let service = HAPService.accessoryInformation(name: original, manufacturer: original, model: original,
                serialNumber: original, firmwareRevision: original)
            for c in service.characteristics where c.format == .string { #expect(c.value == .string(expected)) }
            #expect(original.hasPrefix(expected))
            #expect(expected.utf8.count <= 64)
            #expect(String(data: Data(expected.utf8), encoding: .utf8) == expected)
        }
    }

    @Test("Initial values, updates and error events share the same numeric constraints")
    func bridgeNormalization() async throws {
        let info = AccessoryInfo(name: "Test", manufacturer: "Test", model: "Test", serialNumber: "Test", firmwareRevision: "1")
        let bridge = HAPBridge(info: info)
        let c = HAPCharacteristic(iid: 9, type: .currentTemperature, value: .float(21.56), permissions: [.read, .notify], format: .float,
                                  minValue: -40, maxValue: 100, minStep: 0.1)
        await bridge.addAccessory(info: info, services: [HAPService(iid: 8, type: .temperatureSensor, characteristics: [c])], aid: 2, servicesHaveStableIIDs: true)
        try equal(try #require(await bridge.readCharacteristic(aid: 2, iid: 9)), .number(21.6))
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .float(22.56))
        try equal(try #require(await bridge.readCharacteristic(aid: 2, iid: 9)), .number(22.6))
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .float(.nan))
        #expect(await bridge.readStatus(aid: 2, iid: 9) == .communicationFailure)
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .float(22.56))
        #expect(await bridge.readStatus(aid: 2, iid: 9) == .success)
    }

    private func equal(_ actual: HAPCharacteristicValue, _ expected: JSONValue) throws {
        switch actual {
        case .bool(let b): #expect(expected == .bool(b))
        case .string(let s): #expect(expected == .string(s))
        default:
            let n: Double? = switch actual {
            case .float(let n): n
            case .int32(let n): Double(n)
            case .uint8(let n): Double(n)
            case .uint16(let n): Double(n)
            case .uint32(let n): Double(n)
            default: nil
            }
            #expect(abs(try #require(n) - #require(expected.doubleValue)) < 1e-8)
        }
    }
}
