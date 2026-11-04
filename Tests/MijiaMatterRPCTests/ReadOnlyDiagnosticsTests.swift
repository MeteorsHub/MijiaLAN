import Foundation
import MijiaCore
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
}
