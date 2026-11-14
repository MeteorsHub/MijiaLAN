import Foundation
import HAPCore
import MijiaCore
import Testing
@testable import MijiaLAN
@testable import MijiaHomeKitBridge

struct DeviceInterfaceReportTests {
    @MainActor @Test("The offline matrix uses current legacy setters and contains every bundled model")
    func offlineMatrix() {
        let report = DeviceInterfaceReport.markdown()
        for model in DeviceSchema.bundledModels { #expect(report.contains("## \(model)")) }
        #expect(report.contains("get_prop [power]; set_power [on/off 字符串]"))
        #expect(report.contains("set_ct_abx [MIoT 原值, \"smooth\", 500]"))
        #expect(report.contains("0→auto,1→cool,2→dry,3→heat,4→wind"))
        #expect(!report.contains("预设＋增减"))
    }

    @Test("Legacy report describes each current write transform and status-method reads without executing them")
    func legacyTransforms() {
        let cases: [(LegacyMiioProfile.Property.Write, String)] = [
            (.onOff, "setter [on/off 字符串, 7]"),
            (.value, "setter [MIoT 原值, 7]"),
            (.string, "setter [字符串, 7]"),
            (.integer(ratio: 2, offset: 3), "setter [Int(value × 2.0 + 3.0), 7]"),
            (.values(["high": 2, "low": 1]), "setter [1→low,2→high, 7]"),
            (.boolChoice(on: .string("enabled"), off: .number(0)), "setter [true→\"enabled\", false→0, 7]"),
            (.methodSwitch(on: "enable", off: "disable"), "true→enable [7]; false→disable [7]"),
        ]
        for (write, expected) in cases {
            let property = LegacyMiioProfile.Property(siid: 2, piid: 1, name: "state", read: .auto,
                setter: "setter", write: write, suffix: [.number(7)])
            #expect(DeviceInterfaceReport.legacyProtocol(property, statusMethod: "get_status") == "get_status [] → state; " + expected)
        }
        let readOnly = LegacyMiioProfile.Property(siid: 2, piid: 1, name: "state", read: .boolean,
            setter: nil, write: nil, suffix: [])
        #expect(DeviceInterfaceReport.legacyProtocol(readOnly, statusMethod: nil) == "get_prop [state]; 只读")
    }

    @Test("Vacuum report includes cleaning actions and status, but does not count constant/name bindings")
    func bindingCoverage() throws {
        let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
        var capability = try #require(DeviceCapabilityCatalog.capabilities(schema: schema, model: "yeelink.light.lamp4").first)
        let cleaning = CapabilityHAPBinding.cleaning(start: "a:2:1", dock: "a:2:2", status: "p:2:3")
        for id in ["a:2:1", "a:2:2", "p:2:3"] {
            capability.id = id
            #expect(DeviceInterfaceReport.maps(cleaning, capability: capability))
        }
        capability.id = "p:2:9"
        #expect(!DeviceInterfaceReport.maps(cleaning, capability: capability))
        #expect(!DeviceInterfaceReport.maps(.name("p:2:9", "Label"), capability: capability))
        #expect(!DeviceInterfaceReport.maps(.constant(.bool(true)), capability: capability))
        #expect(DeviceInterfaceReport.maps(.property("p:2:9", .direct), capability: capability))
        #expect(DeviceInterfaceReport.maps(.option("p:2:9", .number(0)), capability: capability))
        #expect(DeviceInterfaceReport.maps(.action("p:2:9"), capability: capability))
    }
}
