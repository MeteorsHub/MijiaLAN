import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

@MainActor
struct DeviceCapabilityTests {
    private let token = "00112233445566778899aabbccddeeff"

    @Test("Every enabled MIoT property routes to its exact service and property", arguments: DeviceSchema.bundledModels.filter { LegacyMiioProfile.forModel($0) == nil })
    func everyProperty(model: String) async throws {
        let (controller, fake, _) = try makeController(model: model)
        await controller.refreshNow()
        let snapshot = try #require(controller.snapshots["123"])
        for c in snapshot.controls where c.kind == .property && !c.prepared {
            let value: JSONValue = c.format == "bool" ? .bool(true) : .number(c.options.last.map { Double($0.value) } ?? c.max ?? 0)
            try await controller.execute(did: "123", .set(c.id, value))
            let packet = try #require(fake.receivedWrites.last)
            #expect(packet["siid"]?.intValue == c.siid)
            #expect(packet["piid"]?.intValue == c.iid)
            #expect(packet["value"] == value)
        }
    }

    @Test("Firmware-quantized values are retained, never overwritten with the requested number")
    func quantization() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        fake.quantizeSpeed = true
        await #expect(throws: DeviceControlError.notConfirmed) { try await controller.execute(did: "123", .set("p:8:1", .number(43))) }
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(40))
        #expect(controller.snapshots["123"]?.commandReceipt?.acceptedAt != nil)
        #expect(controller.snapshots["123"]?.commandReceipt?.confirmedAt == nil)
    }

    @Test("A write reply without a return code is rejected")
    func missingCode() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        fake.omitWriteCode = true
        await #expect(throws: (any Error).self) { try await controller.execute(did: "123", .set("p:8:1", .number(43))) }
        #expect(controller.snapshots["123"]?.commandReceipt?.acceptedAt == nil)
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(1))
    }

    @Test("All ten pinned schemas retain service IDs, enum comments and ordered action arguments", arguments: DeviceSchema.bundledModels)
    func schema(model: String) throws {
        let schema = try #require(DeviceSchema.bundled(model: model))
        #expect(schema.model == model)
        #expect(schema.coreSpec != nil)
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        #expect(Set(caps.map(\.id)).count == caps.count)
        #expect(!caps.filter { $0.control != .reading && $0.control != .unsupported }.isEmpty)
        for c in caps where c.control == .number || c.control == .choice {
            if let value = c.options.first?.value { #expect(try c.validated(.number(Double(value))) == .number(Double(value))) }
            if let min = c.min { #expect(throws: DeviceControlError.self) { try c.validated(.number(min - c.step)) } }
            if let max = c.max { #expect(throws: DeviceControlError.self) { try c.validated(.number(max + c.step)) } }
        }
        if model == "dmaker.fan.p28" {
            #expect(caps.first { $0.id == "p:8:1" }?.range == [1, 100, 1])
            #expect(caps.first { $0.id == "p:2:2" }?.options.map(\.value) == [1, 2, 3, 4])
            #expect(caps.first { $0.id == "p:2:3" }?.options.map(\.title) == ["直吹风", "自然风", "智能风", "睡眠风"])
            #expect(caps.first { $0.id == "p:8:2" }?.control == .unsupported)
        }
        if model == "careli.fryer.maf07c" {
            #expect(schema.services.first { $0.iid == 2 }?.actions.first { $0.iid == 5 }?.inputs == [3, 4, 7, 10, 11, 13, 16, 17, 18])
            #expect(caps.first { $0.id == "a:2:5" }?.control == .unsupported)
        }
        if model == "cuco.plug.v3" {
            #expect(caps.first { $0.id == "p:2:2" }?.options.map(\.title) == ["恢复断电前状态", "上电打开", "上电关闭"])
            #expect(caps.first { $0.id == "p:4:2" }?.range == [2, 10, 1])
            #expect(caps.first { $0.id == "p:14:1" }?.range == [2, 600, 1])
            #expect(caps.first { $0.id == "p:5:1" }?.writable == false)
        }
    }

    @Test("Kitchen menu selection sends nothing and start uses the schema's exact input parameter", arguments: ["chunmi.cooker.cmwy3", "chunmi.health_pot.a1", "chunmi.juicer.a1", "careli.fryer.maf07c"])
    func kitchen(model: String) async throws {
        let (controller, fake, _) = try makeController(model: model)
        await controller.refreshNow()
        let snapshot = try #require(controller.snapshots["123"])
        let menu = try #require(snapshot.capabilities.first { $0.prepared && ["mode", "cook-mode"].contains($0.name) })
        #expect(throws: DeviceControlError.self) { try controller.actionInputs(snapshot: snapshot, action: #require(snapshot.capabilities.first { $0.id == "a:2:1" })) }
        let option = try #require(menu.options.first)
        try await controller.execute(did: "123", .set(menu.id, .number(Double(option.value))))
        #expect(fake.receivedWrites.isEmpty)
        #expect(controller.snapshots["123"]?.value(menu.id) == snapshot.value(menu.id))
        try await controller.execute(did: "123", .invoke("a:2:1"))
        let action = try #require(fake.receivedWrites.last)
        #expect(action["aiid"]?.intValue == 1)
        #expect(action["siid"]?.intValue == 2)
        #expect(action["in"] == .array(model == "careli.fryer.maf07c" ? [] : [.number(Double(option.value))]))
        if !menu.writable { #expect(fake.receivedMethods.filter { $0 == "set_properties" }.isEmpty) }
    }

    @Test("Partial property errors stay local; missing readings never become zero or false")
    func partialErrors() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        fake.props["9.1"] = nil
        await controller.refreshNow()
        let s = try #require(controller.snapshots["123"])
        #expect(s.isOnline)
        #expect(s.value("p:2:1") == .bool(false))
        #expect(s.value("p:9:1") == nil)
        #expect(s.readings["p:9:1"]?.code == -4003)
        #expect(s.readings["p:9:1"]?.error != nil)
        let requested = try fake.receivedPayloads.compactMap { data -> Int? in
            let json = try JSONDecoder().decode(JSONValue.self, from: data.prefix { $0 != 0 })
            return json["method"]?.stringValue == "get_properties" ? json["params"]?.arrayValue?.count : nil
        }
        #expect(!requested.isEmpty && requested.allSatisfy { $0 <= 15 })
    }

    @Test("Coalescing sends the latest speed once and never updates from the requested value")
    func coalescing() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        await controller.refreshNow()
        let one = Task { try await controller.execute(did: "123", .set("p:8:1", .number(30)), coalesce: true) }
        let two = Task { try await controller.execute(did: "123", .set("p:8:1", .number(60)), coalesce: true) }
        let three = Task { try await controller.execute(did: "123", .set("p:8:1", .number(75)), coalesce: true) }
        try await one.value; try await two.value; try await three.value
        #expect(fake.receivedWrites.count == 1)
        #expect(fake.receivedWrites.first?["value"] == .number(75))
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(75))
        #expect(fake.receivedMethods.last == "get_properties")
        fake.offline = true
        await #expect(throws: (any Error).self) { try await controller.execute(did: "123", .set("p:8:1", .number(90))) }
        #expect(controller.snapshots["123"]?.readings["p:8:1"]?.value == .number(75))
    }

    @Test("Offline commands reject without claiming success; pending menus are allowed offline")
    func offline() async throws {
        let (controller, fake, _) = try makeController(model: "chunmi.juicer.a1")
        fake.offline = true
        await controller.refreshNow()
        try await controller.execute(did: "123", .set("p:2:2", .number(3)))
        await #expect(throws: DeviceControlError.offline) { try await controller.execute(did: "123", .invoke("a:2:1")) }
        #expect(fake.receivedWrites.isEmpty)
    }

    @Test("A timed-out cooking action is not resent")
    func actionTimeout() async throws {
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123)
        fake.actionTimeout = true
        let client = MiioClient(host: "test", token: MiioToken.parse(token)!, transport: network, retries: 3)
        await #expect(throws: (any Error).self) { try await client.action(MiotActionCall(did: "123", siid: 2, aiid: 1, inputs: [.number(1)])) }
        #expect(fake.receivedMethods.filter { $0 == "action" }.count == 1)
    }

    @Test("An explicit reconnect bypasses offline backoff and only reads device state")
    func manualReconnect() async throws {
        let (controller, fake, _) = try makeController(model: "dmaker.fan.p28")
        fake.offline = true
        await controller.refreshNow()
        #expect(controller.snapshots["123"]?.health.state == .offline)
        fake.offline = false
        await controller.retry(did: "123")
        #expect(controller.snapshots["123"]?.health.state == .online)
        #expect(controller.snapshots["123"]?.value("p:8:1") == .number(1))
        #expect(fake.receivedWrites.isEmpty)
        #expect(fake.receivedMethods.contains("miIO.info"))
    }

    private func makeController(model: String) throws -> (DeviceController, FakeMiioNetwork.Device, LANMiotAPI) {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let caps = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
        let values = Dictionary(uniqueKeysWithValues: caps.filter(\.readable).map { c in
            let value: JSONValue = c.format == "bool" ? .bool(false) : .number(c.options.first.map { Double($0.value) } ?? c.min ?? 0)
            return ("\(c.siid).\(c.iid)", value)
        })
        let network = FakeMiioNetwork()
        let fake = network.add(host: "test", token: token, deviceID: 123, props: values)
        fake.model = model
        let device = LocalDevice(did: "123", name: "Test", model: model, host: "test", token: token)
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: network)
        return (DeviceController(api: api, config: { config }), fake, api)
    }
}
