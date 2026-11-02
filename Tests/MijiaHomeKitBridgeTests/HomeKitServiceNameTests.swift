import Foundation
import Testing
import HAPCore
import HAPTransport
import MijiaCore
@testable import MijiaHomeKitBridge

@MainActor
struct HomeKitServiceNameTests {
    @Test("Adding display names preserves every existing service and control IID")
    func keepsExistingInstanceIDs() async throws {
        for modes in [["cool", "dry", "fan_only"], ["cool", "dry"], ["cool", "fan_only"]] {
            let device = HomeKitAccessoryMapperTests.climate(modes: modes)
            let plan = try #require(HomeKitAccessoryMapper.plan(for: device, name: device.name))
            let legacyServices = plan.services.map { service in
                HAPService(type: service.type, characteristics: service.characteristics.filter { $0.type.rawValue != "E3" })
            }
            let legacy = HAPBridge(info: plan.info)
            let upgraded = HAPBridge(info: plan.info)
            await legacy.addAccessory(info: plan.info, services: legacyServices, aid: 2)
            await upgraded.addAccessory(info: plan.info, services: plan.services, aid: 2,
                                        appendingCharacteristicTypes: [HomeKitAccessoryMapper.configuredNameType])
            let before = try #require(await legacy.accessoryDatabase().first { $0.aid == 2 })
            let after = try #require(await upgraded.accessoryDatabase().first { $0.aid == 2 })
            #expect(before.services.map(\.iid) == after.services.map(\.iid))
            let lastOldIID = try #require(before.services.flatMap(\.characteristics).map(\.iid).max())
            for (oldService, newService) in zip(before.services, after.services) {
                for old in oldService.characteristics {
                    let current = try #require(newService.characteristics.first { $0.type == old.type })
                    #expect(current.iid == old.iid)
                }
                for added in newService.characteristics where added.type.rawValue == "E3" {
                    #expect(added.iid > lastOldIID)
                }
            }
            let identifiers = after.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }
            #expect(Set(identifiers).count == identifiers.count)
        }
    }

    @Test("Home app name writes survive refresh and restart without changing pairing or controlling the AC")
    func persistsHomeAppNames() async throws {
        let device = HomeKitAccessoryMapperTests.climate(modes: ["cool", "dry", "fan_only"])
        let (store, provider) = try await HomeKitWriteRoutingTests().makeStore([device])
        let suite = "test.homekit.names.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var secrets = HomeKitBridgeSecrets.generate()
        secrets.pairings = ["existing-controller": Data(repeating: 1, count: 32)]
        let secretData = try #require(secrets.encoded())
        let vault = HomeKitBridgeVault(load: { .value(secretData) }, save: { _ in true })
        let oldLayout = HomeKitBridgeController.Layout(aids: [device.id: 2], configurationNumber: 7, signature: "before-configured-names")
        defaults.set(try JSONEncoder().encode(oldLayout), forKey: HomeKitBridgeController.layoutKey)

        let controller = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0)
        defer { controller.isEnabled = false }
        controller.attach(to: store)
        await controller.waitUntilIdle()
        guard case .running = controller.status else {
            Issue.record("Expected a running test bridge"); return
        }
        #expect(controller.isPaired)
        let initialURI = controller.setupURI
        let layout = try JSONDecoder().decode(HomeKitBridgeController.Layout.self,
                                             from: #require(defaults.data(forKey: HomeKitBridgeController.layoutKey)))
        #expect(layout.configurationNumber == 8)
        #expect(layout.aids[device.id] == 2)
        let planBefore = try #require(controller.currentPlans(store: store).first?.plan)
        let json = try await database(controller: controller)
        let accessory = try #require(json.first { ($0["aid"] as? Int) == 2 })
        let switches = try #require(accessory["services"] as? [[String: Any]]).filter { $0["type"] as? String == "49" }
        let configured = try switches.map { service in
            try #require((service["characteristics"] as? [[String: Any]])?.first { $0["type"] as? String == "E3" })
        }
        let dryIID = try #require(configured.first?["iid"] as? Int)
        let fanIID = try #require(configured.last?["iid"] as? Int)
        let liveBridge = try #require(controller.bridge)
        try await liveBridge.writeCharacteristic(aid: 2, iid: UInt64(dryIID), value: .string("卧室除湿"))
        try await liveBridge.writeCharacteristic(aid: 2, iid: UInt64(fanIID), value: .string("清风模式"))
        await controller.waitUntilIdle()
        #expect(await provider.executedCommands.isEmpty)
        #expect(controller.currentPlans(store: store).first?.plan.signature == planBefore.signature)
        #expect(try await configuredValues(controller: controller, aid: 2) == ["卧室除湿", "清风模式"])
        controller.isEnabled = false
        await controller.waitUntilIdle()

        defaults.set(true, forKey: HomeKitBridgeController.enabledKey)
        let restarted = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0)
        defer { restarted.isEnabled = false }
        restarted.attach(to: store)
        await restarted.waitUntilIdle()
        guard case .running = restarted.status else {
            Issue.record("Expected the restarted test bridge to run"); return
        }
        #expect(restarted.isPaired)
        #expect(restarted.setupURI == initialURI)
        #expect(try await configuredValues(controller: restarted, aid: 2) == ["卧室除湿", "清风模式"])
        #expect(await provider.executedCommands.isEmpty)
        restarted.isEnabled = false
        await restarted.waitUntilIdle()
    }

    private func database(controller: HomeKitBridgeController) async throws -> [[String: Any]] {
        let bridge = try #require(controller.bridge)
        return await bridge.accessoryDatabase().map { accessory in
            ["aid": Int(accessory.aid), "services": accessory.services.map { service in
                ["type": service.type.rawValue, "characteristics": service.characteristics.map { c -> [String: Any] in
                    var row: [String: Any] = ["iid": Int(c.iid), "type": c.type.rawValue]
                    if case .string(let value) = c.value { row["value"] = value }
                    return row
                }]
            }]
        }
    }
    private func configuredValues(controller: HomeKitBridgeController, aid: Int) async throws -> [String] {
        let accessory = try #require(try await database(controller: controller).first { $0["aid"] as? Int == aid })
        let services = try #require(accessory["services"] as? [[String: Any]])
        return services.flatMap { $0["characteristics"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "E3" }.compactMap { $0["value"] as? String }
    }
}
