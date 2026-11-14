import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private let token = "00112233445566778899aabbccddeeff"

/// A device's reply is untrusted. `Int(_:)` traps on NaN, infinity and numbers past Int's range, and a reply can
/// hold any of them, including as text such as "nan" or a 20-digit number.
struct UntrustedNumberTests {
    @Test("integer is nil for any value Int cannot hold", arguments: [
        (JSONValue.number(2.6), 3), (.number(-0.4), 0), (.string("42"), 42),
        (.number(.nan), nil), (.number(.infinity), nil), (.number(1e19), nil), (.number(-1e19), nil),
        (.string("nan"), nil), (.string("-inf"), nil), (.string("12345678901234567890"), nil), (.bool(true), nil),
    ] as [(JSONValue, Int?)])
    func integer(value: JSONValue, expected: Int?) {
        #expect(value.integer == expected)
    }

    @Test("An id too large for Int64 is kept as text")
    func idString() {
        #expect(JSONValue.number(123).idString == "123")
        #expect(JSONValue.number(1e20).idString == "1e+20")
    }

    @Test("A 20-digit code in a reply is an error, not a crash")
    func hugeCodes() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "test", token: token, deviceID: 90)
        let client = MiioClient(host: "test", token: MiioToken.parse(token)!, transport: network)
        device.rawReply = #""error":{"code":12345678901234567890,"message":"busy"}"#
        await #expect(throws: MiioError.deviceError(code: 0, message: "busy")) { try await client.call("get_prop") }

        device.rawReply = #""result":[{"did":"90","siid":2,"piid":1,"code":12345678901234567890,"value":1}]"#
        let readings = try await client.readProperties(did: "90", [(siid: 2, piid: 1)])
        let reading = try #require(readings[MiotPropKey(did: "90", siid: 2, piid: 1)])
        #expect(!reading.isAvailable && reading.value == nil)

        device.rawReply = #""result":[{"code":12345678901234567890}]"#
        await #expect(throws: MiioError.self) {
            try await client.setProperties([MiotPropWrite(did: "90", siid: 2, piid: 1, value: .number(1))])
        }
    }

    @Test("Legacy readings and arguments past Int's range convert without trapping")
    func legacy() {
        let number = LegacyMiioProfile.Property(siid: 2, piid: 1, name: "speed", read: .number(ratio: 1, offset: 0, strip: nil),
                                                setter: "set_speed", write: .string, suffix: [])
        #expect(number.miotValue(.string("nan")) == nil)
        #expect(number.miotValue(.string("inf")) == nil)
        #expect(number.miotValue(.string("71")) == .number(71))
        #expect(number.legacyArgument(.number(40)) == .string("40"))
        #expect(number.legacyArgument(.number(1e20)) == .string("1e+20"))

        let table = LegacyMiioProfile.Property(siid: 2, piid: 2, name: "mode", read: .values(["1": 1], fallback: nil),
                                               setter: nil, write: nil, suffix: [])
        #expect(table.miotValue(.number(1)) == .number(1))
        #expect(table.miotValue(.number(1e20)) == nil)
    }

    @Test("Values MijiaCore cannot convert stay out of the synthesized home, but the panel still shows them")
    @MainActor func synthesizedHome() async throws {
        // A spec without value ranges, so readings this large pass validation. MijiaCore turns brightness into a
        // percentage and colour temperature into kelvin with `Int(_:)`.
        let type = "urn:miot-spec-v2:device:light:0000A001:test-bounds-\(UUID().uuidString):1"
        let property = { (iid: Int, name: String, format: String) in
            #"{"iid": \#(iid), "type": "urn:miot-spec-v2:property:\#(name):00000001:test:1", "description": "\#(name)", "format": "\#(format)", "access": ["read", "write", "notify"]}"#
        }
        let spec = #"{"type": "\#(type)", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:light:00007802:test:1", "description": "Light", "properties": [\#(property(1, "on", "bool")), \#(property(2, "brightness", "uint32")), \#(property(3, "color-temperature", "uint32"))]}]}"#
        let directory = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(type.replacingOccurrences(of: ":", with: "_") + ".json")
        try Data(spec.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 91, props: [
            "2.1": .bool(true), "2.2": .number(12345678901234567890), "2.3": .number(1e300),
        ])
        fake.model = "test.light.bounds"
        let device = LocalDevice(did: "91", name: "Lamp", model: fake.model, host: "test", token: token, specType: type)
        let config = LocalHomeConfig(devices: [device])
        let controller = DeviceController(api: LANMiotAPI(config: { config }, transport: network), config: { config })
        await controller.refreshNow()

        #expect(controller.snapshots["91"]?.value("p:2:2") == .number(12345678901234567890))
        let lamp = try #require(controller.synthesizedHome().devices.first { $0.id == "91" })
        guard case .light(let light) = lamp.kind else { Issue.record("Expected a light, got \(lamp.kind)"); return }
        #expect(light.isOn)
        #expect(light.brightnessPercent == nil)
        #expect(light.colorTempKelvin == nil)
    }
}
