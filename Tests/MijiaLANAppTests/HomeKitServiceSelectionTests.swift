// The simulated device catalog and transport are available in Debug builds.
#if DEBUG
import Combine
import Foundation
import MijiaHomeKitBridge
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
struct HomeKitServiceSelectionTests {
    @Test("Turning off a device's last Home service keeps the device out of Home; turning the device on brings it all back")
    func lastService() async throws {
        // Simulated devices, in-memory secrets and a scratch defaults suite; the bridge stays off.
        let model = AppModel(environment: ["MIJIALAN_EPHEMERAL": "1", "MIJIALAN_UI_PREVIEW": "1"])
        defer {
            model.devices.shutdown()
            UserDefaults.standard.removePersistentDomain(forName: "com.mijialan.MijiaLAN.dev")
        }
        let device = try #require(model.config.devices.first { $0.model == "zhimi.airpurifier.rma1" })
        for _ in 0..<500 where model.devices.snapshots[device.did] == nil { try await Task.sleep(for: .milliseconds(2)) }
        let services = model.homeKitServices(device)
        #expect(services.count > 2)
        #expect(services.first?.isPrimary == true)
        #expect(model.isInHomeKit(device))

        let sensor = try #require(services.first { $0.kind == .airQuality })
        var selectionChanges = 0
        let observation = model.objectWillChange.sink { selectionChanges += 1 }
        defer { observation.cancel() }
        model.setInHomeKit(device, service: sensor, false)
        #expect(selectionChanges == 1)
        #expect(!model.isInHomeKit(device, service: sensor))
        #expect(model.bridge.excludedServices[device.did] == [sensor.key])
        model.setInHomeKit(device, service: sensor, true)
        #expect(model.bridge.excludedServices[device.did] == nil)

        for service in services.dropLast() { model.setInHomeKit(device, service: service, false) }
        #expect(model.isInHomeKit(device))
        model.setInHomeKit(device, service: try #require(services.last), false)
        #expect(!model.isInHomeKit(device))

        model.setInHomeKit(device, true)
        #expect(model.isInHomeKit(device))
        #expect(services.allSatisfy { model.isInHomeKit(device, service: $0) })
        #expect(model.bridge.excludedServices[device.did] == nil)

        // Hiding a device by its own switch keeps its choices for when it returns.
        model.setInHomeKit(device, service: sensor, false)
        model.setInHomeKit(device, false)
        model.setInHomeKit(device, true)
        #expect(model.bridge.excludedServices[device.did] == [sensor.key])
    }
}
#endif
