import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct DeviceLANPolicyTests {
    private struct Corpus: Decodable { let cases: [Batch]; let propertyRequestsReported: Int }
    private struct Batch: Decodable { let name: String; let reportedRequestCount: Int; let readings: [Row] }
    private struct Row: Decodable { let siid: Int; let piid: Int; let code: Int; let hasValue: Bool; let value: JSONValue? }

    private func snapshot() throws -> DeviceSnapshot {
        let model = "dooya.motor.dc1545"
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return DeviceSnapshot(device: LocalDevice(did: "test", name: "Curtain", model: model, host: "192.0.2.1", token: "test-only"),
            schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model), health: LANDeviceHealth(state: .online))
    }

    @Test("Only the exact reported model is restricted, independently of connectivity")
    func exactModel() {
        #expect(!DeviceLANPolicy.allowsPropertyRequests(for: "dooya.motor.dc1545"))
        for model in ["dooya.motor.other", "dooya.curtain.c1", "xiaomi.feeder.pi2001", "xiaomi.derh.13l", "yeelink.light.lamp4"] {
            #expect(DeviceLANPolicy.allowsPropertyRequests(for: model))
        }
    }

    @Test("Order-dependent code-zero values remain raw evidence, never trusted state or positions")
    func mixedResponses() throws {
        let url = try #require(Bundle.module.url(forResource: "dooya-order-dependent-readings-2026-11-06", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.reduce(0) { $0 + $1.reportedRequestCount } == corpus.propertyRequestsReported)
        #expect(corpus.propertyRequestsReported == 11)
        for batch in corpus.cases {
            var snapshot = try snapshot()
            for row in batch.readings {
                let id = DeviceCapability.propertyID(row.siid, row.piid)
                let cap = try #require(snapshot.capabilitiesByID[id])
                let incoming = DeviceReading(value: row.hasValue ? row.value : nil, code: row.code,
                    error: row.code == 0 ? nil : MiotPropertyStatus.description(row.code))
                let checked = cap.checkedReading(incoming)
                #expect(!checked.isAvailable)
                #expect(checked.code == row.code)
                #expect(checked.value == nil)
                #expect(checked.rawValue == row.value)
                snapshot.readings[id] = checked
            }
            #expect(snapshot.isOnline)
            #expect(snapshot.controls.isEmpty)
            for name in ["status", "current-position", "target-position", "fault"] {
                #expect(snapshot.value("motor-controller", name) == nil)
            }
            #expect(snapshot.lanReadingsRestriction != nil)
        }
    }

    @Test("Cached or injected values and write declarations cannot reopen controls")
    func staleState() throws {
        var snapshot = try snapshot()
        snapshot.readings["p:2:2"] = DeviceReading(value: .number(2), code: 0)
        snapshot.readings["p:2:3"] = DeviceReading(value: .number(50), code: 0)
        let status = try #require(snapshot.capabilitiesByID["p:2:2"])
        #expect(snapshot.value(status.id) == nil)
        #expect(status.formatted(.number(2)) == DeviceLANPolicy.unverifiedReadingsTitle)
        #expect(throws: DeviceControlError.self) { try status.validatedReading(.number(2)) }
        let target = try #require(snapshot.capabilitiesByID["p:2:4"])
        #expect(target.declaredAccess.contains("write"))
        #expect(!target.writable)
        #expect(snapshot.controlUnavailableReason(target) != nil)
        #expect(throws: DeviceControlError.self) { try target.validated(.number(50)) }
    }
}
