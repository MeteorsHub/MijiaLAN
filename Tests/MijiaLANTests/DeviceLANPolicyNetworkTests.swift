import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct DeviceLANPolicyNetworkTests {
    private let token = "00112233445566778899aabbccddeeff"
    private let model = "dooya.motor.dc1545"

    private func capabilities() throws -> [DeviceCapability] {
        let url = try #require(Bundle.module.url(forResource: model, withExtension: "json"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
    }

    @Test("A known-model client rejects reads, writes and actions before sending even a hello")
    func knownClient() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        let client = MiioClient(host: "test", token: try #require(MiioToken.parse(token)), transport: network, knownModel: model)
        await #expect(throws: DeviceControlError.self) { try await client.readProperties(did: "123", [(2, 2)]) }
        await #expect(throws: DeviceControlError.self) { try await client.setProperties([MiotPropWrite(did: "123", siid: 2, piid: 1, value: .number(2))]) }
        await #expect(throws: DeviceControlError.self) { try await client.action(MiotActionCall(did: "123", siid: 2, aiid: 1)) }
        await #expect(throws: DeviceControlError.self) { try await client.call("get_prop") }
        #expect(network.exchangeCount == 0)
        #expect(fake.receivedMethods.isEmpty)
        #expect(try await client.info().model == model)
        #expect(fake.receivedMethods == ["miIO.info"])
    }

    @Test("An info reply identifies an initially unknown client and latches the restriction")
    func identifiedClient() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        let client = MiioClient(host: "test", token: try #require(MiioToken.parse(token)), transport: network)
        _ = try await client.info()
        let before = network.exchangeCount
        await #expect(throws: DeviceControlError.self) { try await client.call("get_properties") }
        await #expect(throws: DeviceControlError.self) { try await client.call("set_motor") }
        #expect(network.exchangeCount == before)
        #expect(fake.receivedMethods == ["miIO.info"])
    }

    @Test("LAN API property and control routes, including mixed write batches, emit no packets for the model")
    func apiRoutes() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        let other = network.add(host: "other", token: token, deviceID: 456, props: ["2.1": .bool(true)])
        let config = LocalHomeConfig(devices: [
            LocalDevice(did: "123", name: "Curtain", model: model, host: "test", token: token),
            LocalDevice(did: "456", name: "Other", model: "test.other", host: "other", token: token),
        ])
        let api = LANMiotAPI(config: { config }, transport: network)
        let keys = [MiotPropKey(did: "123", siid: 2, piid: 2)]
        #expect(try await api.getProps(keys).isEmpty)
        let caps = try capabilities()
        let readings = await api.readCapabilities(did: "123", capabilities: caps)
        #expect(readings.count == 6)
        #expect(readings.values.allSatisfy { !$0.isAvailable && $0.error != nil })
        await #expect(throws: DeviceControlError.self) {
            try await api.setProps([MiotPropWrite(did: "456", siid: 2, piid: 1, value: .bool(false)),
                                    MiotPropWrite(did: "123", siid: 2, piid: 1, value: .number(2))])
        }
        await #expect(throws: DeviceControlError.self) { try await api.action(MiotActionCall(did: "123", siid: 2, aiid: 1)) }
        #expect(network.exchangeCount == 0)
        #expect(other.receivedWrites.isEmpty)
        #expect(await api.latestValue(keys[0]) == nil)
        // Unaffected devices still read and write through the same API instance.
        let key = MiotPropKey(did: "456", siid: 2, piid: 1)
        #expect(try await api.getProps([key])[key] == .bool(true))
        try await api.setProps([MiotPropWrite(did: "456", siid: 2, piid: 1, value: .bool(false))])
        #expect(other.props["2.1"] == .bool(false))
        #expect(fake.receivedMethods.isEmpty)
        await api.shutdown()
    }

    @Test("Startup, idle refresh and compatibility retry do not send even hello/info for the exact curtain model")
    func connectivity() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        let config = LocalHomeConfig(devices: [LocalDevice(did: "123", name: "Curtain", model: model, host: "test", token: token)])
        let api = LANMiotAPI(config: { config }, transport: network)
        let devices = try await api.deviceList()
        #expect(devices.first?.isOnline == false)
        await api.retryDevice(did: "123")
        _ = await api.readCapabilities(did: "123", capabilities: try capabilities())
        let health = await api.currentHealth()
        #expect(health["123"]?.state != .online)
        #expect(network.exchangeCount == 0)
        #expect(fake.receivedMethods.isEmpty)
        await api.shutdown()
    }
#if os(macOS)
    @MainActor @Test("Controller startup, reconnect and queued controls cannot query the restricted model even without a cached schema")
    func controllerRoutes() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.model = model
        let config = LocalHomeConfig(devices: [LocalDevice(did: "123", name: "Curtain", model: model, host: "test", token: token)])
        let api = LANMiotAPI(config: { config }, transport: network)
        let controller = DeviceController(api: api, config: { config })
        defer { controller.shutdown() }
        await controller.refreshNow()
        await controller.refreshNow()
        await controller.retry(did: "123")
        let snapshot = try #require(controller.snapshots["123"])
        #expect(!snapshot.isOnline)
        #expect(snapshot.lanReadingsRestriction != nil)
        #expect(snapshot.controls.isEmpty)
        await #expect(throws: DeviceControlError.self) { try await controller.execute(did: "123", .batch([.set("p:2:1", .number(2))])) }
        #expect(fake.receivedMethods.isEmpty)
        #expect(fake.receivedWrites.isEmpty)
    }
#endif

}
