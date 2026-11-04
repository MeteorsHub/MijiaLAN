import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct FieldSpecificationTests {
    private func schema(_ model: String) throws -> DeviceSchema {
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        return try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
    }
    private func capabilities(_ model: String) throws -> [DeviceCapability] {
        DeviceCapabilityCatalog.capabilities(schema: try schema(model), model: model)
    }

    @Test("Reviewed field specification projections retain distinct addresses", arguments: [
        "dooya.motor.dc1545", "xiaomi.derh.13l", "iot.tow_w.jd015", "giot.heater.v13daf",
        "xiaomi.pet_waterer.70m2", "xiaomi.feeder.pi2001",
    ])
    func identities(_ model: String) throws {
        let schema = try schema(model)
        #expect(schema.model == model)
        #expect(schema.coreSpec != nil)
        let caps = try capabilities(model)
        #expect(!caps.isEmpty)
        #expect(Set(caps.map(\.id)).count == caps.count)
    }

    @Test("Float telemetry preserves fractions while write steps, bounds and enums remain enforced")
    func readValidation() throws {
        let caps = try capabilities("xiaomi.derh.13l")
        let temperature = try #require(caps.first { $0.id == "p:3:2" })
        #expect(try temperature.validatedReading(.number(24.5)) == .number(24.5))
        #expect(throws: DeviceControlError.self) { try temperature.validated(.number(24.5)) }
        for value in [JSONValue.number(101), .number(-31), .number(.nan), .number(.infinity), .string("24.5"), .bool(false), .null] {
            #expect(throws: DeviceControlError.self) { try temperature.validatedReading(value) }
        }
        let humidity = try #require(caps.first { $0.id == "p:3:1" })
        #expect(throws: DeviceControlError.self) { try humidity.validatedReading(.number(56.5)) }
        let mode = try #require(caps.first { $0.id == "p:2:3" })
        #expect(throws: DeviceControlError.self) { try mode.validatedReading(.number(99)) }
        let power = try #require(caps.first { $0.id == "p:2:1" })
        #expect(throws: DeviceControlError.self) { try power.validatedReading(.number(1)) }
        #expect(try power.validatedReading(.bool(false)) == .bool(false))
        let towel = try capabilities("iot.tow_w.jd015")
        let target = try #require(towel.first { $0.id == "p:2:5" })
        #expect(throws: DeviceControlError.self) { try target.validated(.number(57)) }
        #expect(try target.validated(.number(60)) == .number(60))
    }

    @Test("Repeated vendor properties have distinct titles in both languages", arguments: ["zh", "en"])
    func titles(_ language: String) throws {
        try L10n.$overrideLanguage.withValue(language == "zh" ? .zhHans : .en) {
            let fountain = try capabilities("xiaomi.pet_waterer.70m2").filter { $0.name == "out-water-interval" }
            #expect(fountain.count == 2)
            #expect(Set(fountain.map(\.title)).count == 2)
            #expect(fountain.contains { $0.id == "p:2:7" && $0.title.contains("S2/P7") && $0.range == [15, 120, 15] })
            #expect(fountain.contains { $0.id == "p:2:11" && $0.title.contains("S2/P11") && $0.range == [10, 120, 5] })
            let statuses = try capabilities("xiaomi.feeder.pi2001").filter { $0.name == "status" }
            #expect(statuses.count == 9)
            #expect(Set(statuses.map(\.title)).count == statuses.count)
            let labels = ["Normal", "MaxSchedule", "Left-gram-display"]
            if language == "zh" { #expect(labels.allSatisfy { CapabilityNames.option($0) != $0 }) }
        }
    }

    @Test("Fireplace main power stays separate from its light; unknown fault labels do not imply healthy state")
    func fireplace() throws {
        let model = "giot.heater.v13daf"
        let schema = try schema(model)
        let caps = try capabilities(model)
        let snapshot = DeviceSnapshot(device: LocalDevice(did: "test", name: "Fireplace", model: model,
            host: "192.0.2.1", token: "test-only"), schema: schema, capabilities: caps)
        #expect(snapshot.primaryPower?.id == "p:2:1")
        let main = try #require(caps.first { $0.id == "p:2:1" })
        let light = try #require(caps.first { $0.id == "p:3:1" })
        #expect(main.title != light.title)
        let fault = try #require(caps.first { $0.name == "fault" })
        let text = L10n.$overrideLanguage.withValue(.en) { fault.formatted(.number(0)) }
        #expect(text.contains("code 0"))
        #expect(!text.contains("No Fault"))
        #expect(throws: DeviceControlError.self) { try fault.validatedReading(.null) }
    }

    @Test("Write-only motor and inaccessible feeding fields are not read; feeding is not an enabled action")
    func accessBoundaries() throws {
        let curtain = try capabilities("dooya.motor.dc1545")
        let motor = try #require(curtain.first { $0.id == "p:2:1" })
        #expect(!motor.readable)
        #expect(motor.writable)
        let feeder = try capabilities("xiaomi.feeder.pi2001")
        let field = try #require(feeder.first { $0.id == "p:2:8" })
        #expect(!field.readable && !field.writable)
        let action = try #require(feeder.first { $0.name == "pet-food-out" })
        #expect(!action.writable)
        #expect(action.control == .unsupported)
    }
}
