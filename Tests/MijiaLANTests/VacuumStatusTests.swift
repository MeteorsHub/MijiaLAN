import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@MainActor
struct VacuumStatusTests {
    /// ijai.vacuum.v19 from miot-spec.org, trimmed. Its numbers differ from Roborock's, where 2 is Sweeping.
    private static let schemaJSON = """
    {"type": "urn:miot-spec-v2:device:vacuum:0000A006:ijai-v19:1", "services": [
     {"iid": 2, "type": "urn:miot-spec-v2:service:vacuum:00007810:ijai-v19:1",
      "properties": [
       {"iid": 1, "type": "urn:miot-spec-v2:property:status:00000007:ijai-v19:1", "format": "uint8", "access": ["read", "notify"],
        "value-list": [{"value": 0, "description": "Sleep"}, {"value": 1, "description": "Idle"}, {"value": 2, "description": "Paused"},
                       {"value": 3, "description": "Go Charging"}, {"value": 4, "description": "Charging"}, {"value": 5, "description": "Sweeping"}]},
       {"iid": 10, "type": "urn:miot-spec-v2:property:room-ids:00000073:ijai-v19:1", "format": "string", "access": []}],
      "actions": [
       {"iid": 1, "type": "urn:miot-spec-v2:action:start-sweep:00002804:ijai-v19:1", "in": [], "out": []},
       {"iid": 2, "type": "urn:miot-spec-v2:action:stop-sweeping:00002805:ijai-v19:1", "in": [], "out": []},
       {"iid": 7, "type": "urn:miot-spec-v2:action:start-room-sweep:00002826:ijai-v19:1", "in": [10], "out": []}]},
     {"iid": 3, "type": "urn:miot-spec-v2:service:battery:00007805:ijai-v19:1",
      "actions": [{"iid": 1, "type": "urn:miot-spec-v2:action:start-charge:00002802:ijai-v19:1", "in": [], "out": []}]}]}
    """

    private func capabilities() throws -> [DeviceCapability] {
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(Self.schemaJSON.utf8))
        return DeviceCapabilityCatalog.capabilities(schema: schema, model: "test.vacuum.v19")
    }

    @Test("Vacuum actions without inputs are buttons, including the dock action in the battery service")
    func catalog() throws {
        let caps = try capabilities()
        func control(_ id: String) -> DeviceCapability.Control? { caps.first { $0.id == id }?.control }
        #expect(control("a:2:1") == .button)
        #expect(control("a:2:2") == .button)
        #expect(control("a:3:1") == .button)
        #expect(control("a:2:7") == .unsupported)
        #expect(caps.first { $0.id == "a:3:1" }?.title == L10n.tr("回充", "Return to Dock"))
    }

    @Test("A vacuum action is confirmed by what its status means, not by its number")
    func confirmation() throws {
        let status = try #require(try capabilities().first { $0.id == "p:2:1" })
        func confirmed(_ action: String, _ value: Int, before: Int?) -> Bool {
            DeviceController.actionConfirmed(action, category: "vacuum", status: value, before: before, in: status)
        }
        #expect(confirmed("start-sweep", 5, before: 4))
        #expect(!confirmed("start-sweep", 4, before: 4))
        #expect(!confirmed("start-sweep", 1, before: 4))
        #expect(confirmed("start-charge", 3, before: 5))
        #expect(confirmed("start-charge", 4, before: 4))
        #expect(!confirmed("start-charge", 2, before: 5))
        #expect(confirmed("stop-sweeping", 1, before: 5))
        #expect(!confirmed("stop-sweeping", 5, before: 5))
    }

    @Test("Status descriptions from real specs", arguments: [
        ("Sweeping", true, false), ("Sweeping and Mopping", true, false), ("Mopping", true, false), ("Zone Sweeping", true, false),
        ("Go Charging", false, true), ("Charging", false, true), ("Charging Completed", false, true), ("BreakCharging", false, true),
        ("Paused", false, false), ("Idle", false, false), ("SweepSummoning", false, false), ("ChargingError", false, false),
        ("FindChargerPause", false, false), ("SelfCleaning", false, false), ("StationAssistingCleaning", false, false),
    ])
    func descriptions(_ example: (description: String, cleaning: Bool, docking: Bool)) {
        #expect(VacuumStatus.isCleaning(example.description) == example.cleaning)
        #expect(VacuumStatus.isDocking(example.description) == example.docking)
    }

    @Test("A start is also confirmed by a step before cleaning, never by rest, an error or docking")
    func preparation() {
        #expect(VacuumStatus.confirms("start-sweep", status: "BuildingMap", before: "Charging"))
        #expect(VacuumStatus.confirms("start-sweep-mop", status: "GoWash", before: "Charging"))
        #expect(!VacuumStatus.confirms("start-sweep", status: "BuildingMap", before: "BuildingMap"))
        #expect(!VacuumStatus.confirms("start-sweep", status: "Error", before: "Charging"))
        #expect(!VacuumStatus.confirms("start-sweep", status: "Go Charging", before: "Idle"))
        #expect(!VacuumStatus.confirms("start-sweep", status: nil, before: "Idle"))
    }
}
