import Foundation
import HAPCore
import MijiaCore
@testable import MijiaLAN
import os
import Testing
@testable import MijiaHomeKitBridge

@MainActor
struct WireHomeKitIntegrationTests {
    @Test("A brightness-only write turns on an off legacy lamp before applying its level")
    func lampBrightnessBeforePower() async throws {
        let fixture = try await Fixture.make(model: LoopbackMiioDevice.lampModel)
        let client = WireHAPController(port: fixture.port)
        do {
            try await client.connect()
            try await client.pair(setupCode: fixture.code)
            try await client.verify()
            let database = try json(await client.request("GET", "/accessories"))
            let lamp = try #require(database["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = lamp["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            let power = try #require(chars.first { $0["type"]?.stringValue == "25" }?["iid"]?.intValue)
            let brightness = try #require(chars.first { $0["type"]?.stringValue == "8" }?["iid"]?.intValue)
            let temperature = try #require(chars.first { $0["type"]?.stringValue == "CE" }?["iid"]?.intValue)
            let hap = try #require(fixture.bridge.bridge)
            let subscription = JSONValue.object(["characteristics": .array([power, brightness, temperature].map {
                .object(["aid": .number(2), "iid": .number(Double($0)), "ev": .bool(true)])
            })])
            #expect(try await client.request("PUT", "/characteristics", body: data(subscription)).status == 204)
            for _ in 0..<3 { _ = try await client.nextEvent() }

            // A marker on another characteristic drains the event FIFO without a timing-based assertion
            // that "no event arrived". It leaves the lamp's confirmed colour temperature unchanged.
            func confirmedChanges() async throws -> [String] {
                await fixture.settle()
                await hap.updateCharacteristic(aid: 2, iid: UInt64(temperature), value: .int32(356), forceNotify: true)
                var changes: [String] = []
                for _ in 0..<12 {
                    let c = try #require(json(await client.nextEvent())["characteristics"]?.arrayValue?.first)
                    let iid = try #require(c["iid"]?.intValue)
                    if iid == temperature { return changes }
                    changes.append("\(iid):\(try #require(c["value"]).compactJSONString)")
                }
                throw WireHAPController.Failure.invalidHTTP
            }
            let path = "/characteristics?id=2.\(power),2.\(brightness)"
            func write(_ entries: [(Int, JSONValue)]) -> JSONValue {
                .object(["characteristics": .array(entries.map {
                    .object(["aid": .number(2), "iid": .number(Double($0.0)), "value": $0.1])
                })])
            }
            // A standalone brightness write must also work when Home has not sent an On value.
            let turnOn = try await client.request("PUT", "/characteristics", body: data(write([
                (brightness, .number(2)),
            ])))
            #expect(turnOn.status == 204)
            let onChanges = try await confirmedChanges()
            // Brightness is acknowledged by PUT; only the linked On change is unsolicited to this controller.
            #expect(onChanges == ["\(power):true"])
            let on = try json(await client.request("GET", path))["characteristics"]?.arrayValue ?? []
            #expect(on.first { $0["iid"]?.intValue == power }?["value"] == .bool(true))
            #expect(on.first { $0["iid"]?.intValue == brightness }?["value"] == .number(2))
            #expect(Array(fixture.device.lampWrites.prefix(2)) == ["set_power", "set_bright"])

            let off = try await client.request("PUT", "/characteristics", body: data(write([
                (brightness, .number(0)), (power, .bool(false)),
            ])))
            #expect(off.status == 204)
            // Sliding Home's dimmer to zero turns power off while the lamp retains its last level.
            // Re-sending that unchanged nonzero level can overwrite Home's just-completed zero gesture.
            let offChanges = try await confirmedChanges()
            #expect(offChanges == ["\(power):false"])
            let state = try json(await client.request("GET", path))["characteristics"]?.arrayValue ?? []
            #expect(state.first { $0["iid"]?.intValue == power }?["value"] == .bool(false))
            #expect(state.first { $0["iid"]?.intValue == brightness }?["value"] == .number(2))
            #expect(fixture.device.lampWrites.filter { $0 == "set_bright" }.count == 1)
            #expect(fixture.bridge.readFailures.isEmpty)
            #expect(fixture.device.error == nil)
        } catch {
            await client.close(); await fixture.stop()
            throw error
        }
        await client.close(); await fixture.stop()
    }

    @Test("An invalid encrypted request closes its connection instead of leaving Home waiting")
    func invalidSessionCloses() async throws {
        let fixture = try await Fixture.make(model: LoopbackMiioDevice.lampModel)
        let client = WireHAPController(port: fixture.port)
        do {
            try await client.connect()
            try await client.pair(setupCode: fixture.code)
            try await client.verify()
            #expect(try await client.peerClosesAfterInvalidFrame())
            await fixture.settle()
            #expect(fixture.bridge.isPaired)
            #expect(fixture.device.writes == 0)
        } catch {
            await client.close(); await fixture.stop()
            throw error
        }
        await client.close(); await fixture.stop()
    }

    @Test("A legacy desk lamp returns confirmed status and acknowledges requests before delivering their events")
    func lampStatusDelivery() async throws {
        let fixture = try await Fixture.make(model: LoopbackMiioDevice.lampModel)
        let client = WireHAPController(port: fixture.port)
        do {
            try await client.connect()
            try await client.pair(setupCode: fixture.code)
            try await client.verify()
            let database = try json(await client.request("GET", "/accessories"))
            let lamp = try #require(database["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = lamp["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            let power = try #require(chars.first { $0["type"]?.stringValue == "25" }?["iid"]?.intValue)
            let brightness = try #require(chars.first { $0["type"]?.stringValue == "8" }?["iid"]?.intValue)
            let temperature = try #require(chars.first { $0["type"]?.stringValue == "CE" }?["iid"]?.intValue)
            let expected: [Int: JSONValue] = [power: .bool(false), brightness: .number(51), temperature: .number(356)]
            let path = "/characteristics?id=2.\(power),2.\(brightness),2.\(temperature)"
            let read = try await client.request("GET", path)
            #expect(read.status == 200)
            for c in try json(read)["characteristics"]?.arrayValue ?? [] {
                #expect(c["value"] == expected[c["iid"]?.intValue ?? 0])
            }
            let subscription = JSONValue.object(["characteristics": .array([power, brightness, temperature].map {
                .object(["aid": .number(2), "iid": .number(Double($0)), "ev": .bool(true)])
            })])
            #expect(try await client.request("PUT", "/characteristics", body: data(subscription)).status == 204)
            #expect(await client.eventsBeforeLastResponse == 0)
            var initial: [Int: JSONValue] = [:]
            for _ in 0..<3 {
                let c = try #require(json(await client.nextEvent())["characteristics"]?.arrayValue?.first)
                initial[try #require(c["iid"]?.intValue)] = c["value"]
            }
            #expect(initial == expected)

            fixture.device.setPhase(1)
            await fixture.devices.refreshNow()
            await fixture.settle()
            #expect(try await event(client, iid: temperature)["status"]?.intValue == -70402)
            let failed = try await client.request("GET", path)
            #expect(failed.status == 207)
            for c in try json(failed)["characteristics"]?.arrayValue ?? [] {
                #expect(c["status"]?.intValue == (c["iid"]?.intValue == temperature ? -70402 : 0))
            }
            fixture.device.setPhase(2)
            await fixture.devices.refreshNow()
            await fixture.settle()
            #expect(try await event(client, iid: temperature)["value"] == expected[temperature])
            #expect(try await client.request("GET", path).status == 200)

            // A handler may publish confirmed state while awaiting device I/O. Its event must wait for the ACK.
            let hap = try #require(fixture.bridge.bridge)
            await hap.registerWriteHandler(aid: 2, iid: UInt64(brightness), managesValue: true) { _ in
                await hap.updateCharacteristic(aid: 2, iid: UInt64(brightness), value: .int32(51), forceNotify: true)
                try await Task.sleep(for: .milliseconds(75))
            }
            let write = JSONValue.object(["characteristics": .array([
                .object(["aid": .number(2), "iid": .number(Double(brightness)), "value": .number(51)]),
            ])])
            #expect(try await client.request("PUT", "/characteristics", body: data(write)).status == 204)
            #expect(await client.eventsBeforeLastResponse == 0)
            #expect(try await event(client, iid: brightness)["value"] == .number(51))
            #expect(fixture.device.writes == 0)
            #expect(fixture.device.error == nil)
        } catch {
            await client.close(); await fixture.stop()
            throw error
        }
        await client.close(); await fixture.stop()
    }

    // Multiple independent controllers exercise response/event frame ordering under concurrent load.
    @Test("Real miIO UDP and encrypted HAP TCP preserve invalid reads, recovery, UTF-8 limits and pairing rollback", arguments: 0..<8)
    func udpTCPAndRollback(_ iteration: Int) async throws {
        let fixture = try await Fixture.make()
        let first = WireHAPController(port: fixture.port)
        let retry = WireHAPController(port: fixture.port)
        do {
            try await first.connect()
            try await first.pair(setupCode: fixture.code)
            try await first.verify()
            await fixture.settle()
            #expect(fixture.bridge.isPaired)
            let identity = await first.accessoryIdentifier
            let key = await first.accessoryKey
            let uri = fixture.bridge.setupURI
            let good = try json(await first.request("GET", "/accessories"))
            try validateStrings(good)
            let device = try #require(good["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = device["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            let humidity = try #require(chars.first { $0["type"]?.stringValue == "10" })
            let temperature = try #require(chars.first { $0["type"]?.stringValue == "11" })
            let humidityIID = try #require(humidity["iid"]?.intValue)
            #expect(humidity["value"]?.doubleValue == 45)
            #expect(abs(try #require(temperature["value"]?.doubleValue) - 21.6) < 1e-8)
            #expect(await first.receivedFrames > 1)
            #expect(await first.largestFrame <= 1024)
            // This request also exercises a request spanning multiple authenticated 1024-byte frames.
            let subscription = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(humidityIID)), "ev": .bool(true)])]),
                "padding": .string(String(repeating: "x", count: 2500))])
            #expect(try await first.request("PUT", "/characteristics", body: data(subscription)).status == 204)
            let initial = try await event(first, iid: humidityIID)
            #expect(initial["value"]?.doubleValue == 45)

            fixture.device.setPhase(1)
            await fixture.devices.refreshNow()
            await fixture.settle()
            let unavailable = try await event(first, iid: humidityIID)
            #expect(unavailable["status"]?.intValue == -70402)
            #expect(unavailable["value"] == nil)
            let bad = try json(await first.request("GET", "/accessories"))
            let badDevice = try #require(bad["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            for c in badDevice["services"]?.arrayValue?.flatMap({ $0["characteristics"]?.arrayValue ?? [] }) ?? [] {
                if ["B0", "A9", "10", "11"].contains(c["type"]?.stringValue ?? "") { #expect(c["value"] == .null) }
            }
            let read = try await first.request("GET", "/characteristics?id=2.\(humidityIID)")
            #expect(read.status == 207)
            #expect(try json(read)["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70402)
            fixture.device.setPhase(2)
            await fixture.devices.refreshNow()
            await fixture.settle()
            #expect(try await event(first, iid: humidityIID)["value"]?.doubleValue == 55)

            let active = try #require(chars.first { $0["type"]?.stringValue == "B0" }?["iid"]?.intValue)
            let invalid = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(active)), "value": .number(2.5)])])])
            let rejected = try await first.request("PUT", "/characteristics", body: data(invalid))
            #expect(rejected.status == 207)
            #expect(try json(rejected)["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70410)

            let nameIID = try #require(chars.first { $0["type"]?.stringValue == "E3" }?["iid"]?.intValue)
            let long = String(repeating: "中", count: 22)
            let rename = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "value": .string(long)])])])
            #expect(try json(await first.request("PUT", "/characteristics", body: data(rename)))["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70410)
            let legal = String(repeating: "中", count: 20) + "abcd"
            let subscribeName = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "ev": .bool(true)])])])
            #expect(try await first.request("PUT", "/characteristics", body: data(subscribeName)).status == 204)
            _ = try await event(first, iid: nameIID)
            let validRename = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "value": .string(legal)])])])
            #expect(try await first.request("PUT", "/characteristics", body: data(validRename)).status == 204)
            // The writer gets no event repeating its own value, neither before the response nor after it.
            #expect(try values(await first.takeEventsBeforeResponses(), iid: nameIID).isEmpty)
            let renamed = try json(await first.request("GET", "/characteristics?id=2.\(nameIID)"))
            #expect(renamed["characteristics"]?.arrayValue?.first?["value"]?.stringValue == legal)
            #expect(try values(await first.takeEventsBeforeResponses(), iid: nameIID).isEmpty)
            let noEvents = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(2), "ev": .bool(true)])])])
            #expect(try json(await first.request("PUT", "/characteristics", body: data(noEvents)))["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70406)
            try validateStrings(json(await first.request("GET", "/accessories")))
            #expect(fixture.devices.snapshots["77"]?.device.name == fixture.originalName)
            #expect(fixture.device.encryptedRequests > 0)
            #expect(fixture.device.writes == 0)
            #expect(fixture.device.error == nil)

            let id = first.identifier
            let remove = TLV8.encode([(6, Data([1])), (0, Data([4])), (1, Data(id.utf8))])
            #expect(try await first.request("POST", "/pairings", body: remove).status == 200)
            await fixture.settle()
            #expect(!fixture.bridge.isPaired)
            #expect(try await first.request("GET", "/accessories").status == 470)
            await first.close()
            try await retry.connect()
            try await retry.pair(setupCode: fixture.code)
            try await retry.verify()
            #expect(await retry.accessoryIdentifier == identity)
            #expect(await retry.accessoryKey == key)
            #expect(try await retry.request("GET", "/accessories").status == 200)
            await fixture.settle()
            #expect(fixture.bridge.isPaired)
            #expect(fixture.bridge.setupURI == uri)
            #expect(fixture.device.writes == 0)
        } catch {
            await first.close(); await retry.close(); await fixture.stop()
            throw error
        }
        await first.close(); await retry.close(); await fixture.stop()
    }

    @Test("A write from Home is answered before any event it causes, and its own value is not echoed to the writer")
    func writeResponsePrecedesEvents() async throws {
        let fixture = try await Fixture.make()
        let controller = WireHAPController(port: fixture.port)
        do {
            let (active, state) = try await pairedPurifier(controller, fixture)
            let subscribe = JSONValue.object(["characteristics": .array([active, state].map {
                .object(["aid": .number(2), "iid": .number(Double($0)), "ev": .bool(true)])
            })])
            #expect(try await controller.request("PUT", "/characteristics", body: data(subscribe)).status == 204)
            #expect(try await event(controller, iid: active)["value"]?.intValue == 1)
            _ = try await event(controller, iid: state)

            let off = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(active)), "value": .number(0)])])])
            #expect(try await controller.request("PUT", "/characteristics", body: data(off)).status == 204)
            // Switching off changes the purifier's current state while the write runs; that event follows the response.
            #expect(await controller.takeEventsBeforeResponses().isEmpty)
            var after: [JSONValue] = []
            while !after.contains(where: { $0["iid"]?.intValue == state }) {
                after += try json(await controller.nextEvent())["characteristics"]?.arrayValue ?? []
            }
            #expect(after.first { $0["iid"]?.intValue == state }?["value"]?.intValue == 0)
            #expect(!after.contains { $0["iid"]?.intValue == active })
            let read = try json(await controller.request("GET", "/characteristics?id=2.\(active)"))
            #expect(read["characteristics"]?.arrayValue?.first?["value"]?.intValue == 0)
            #expect(try values(await controller.takeEventsBeforeResponses(), iid: active).isEmpty)
            #expect(fixture.device.writes == 1)
            #expect(fixture.device.error == nil)
        } catch {
            await controller.close(); await fixture.stop()
            throw error
        }
        await controller.close(); await fixture.stop()
    }

    @Test("A device read on its way to a written value never sends that passing value to Home")
    func settlingWriteSendsNoPassingValue() async throws {
        let fixture = try await Fixture.make()
        let controller = WireHAPController(port: fixture.port)
        do {
            _ = try await pairedPurifier(controller, fixture)
            let speed = try await rotationSpeed(controller)
            let subscribe = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(speed)), "ev": .bool(true)])])])
            #expect(try await controller.request("PUT", "/characteristics", body: data(subscribe)).status == 204)
            _ = try await event(controller, iid: speed)

            // Like a lamp read mid-fade: the first reads after the write report a level halfway there. Polls keep
            // publishing meanwhile, as they do in the app while other devices change state.
            fixture.device.setReadsBeforeSettling(2)
            let polling = Task { @MainActor in
                while !Task.isCancelled {
                    await fixture.devices.refreshNow()
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            defer { polling.cancel() }
            let full = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(speed)), "value": .number(100)])])])
            let written = try await controller.request("PUT", "/characteristics", body: data(full))
            polling.cancel(); await polling.value
            #expect(written.status == 204)
            let read = try json(await controller.request("GET", "/characteristics?id=2.\(speed)"))
            #expect(read["characteristics"]?.arrayValue?.first?["value"]?.doubleValue == 100)
            // Anything Home heard about the speed since the write must agree with it.
            let heard = try values(await controller.takeEventsBeforeResponses(), iid: speed)
            #expect(heard.allSatisfy { $0["value"]?.doubleValue == 100 }, "Home was told \(heard)")
            #expect(fixture.device.error == nil)
        } catch {
            await controller.close(); await fixture.stop()
            throw error
        }
        await controller.close(); await fixture.stop()
    }

    @Test("A request that turns a device on applies its other values once the device is on")
    func turningOnPrecedesOtherWrites() async throws {
        let fixture = try await Fixture.make()
        let controller = WireHAPController(port: fixture.port)
        do {
            let (active, _) = try await pairedPurifier(controller, fixture)
            let speed = try await rotationSpeed(controller)
            fixture.device.setIgnoresSetsWhileOff(true)
            let off = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(active)), "value": .number(0)])])])
            #expect(try await controller.request("PUT", "/characteristics", body: data(off)).status == 204)

            // Home's order for a slider moved on a switched-off accessory: the level first, then turning it on.
            let on = JSONValue.object(["characteristics": .array([
                .object(["aid": .number(2), "iid": .number(Double(speed)), "value": .number(100)]),
                .object(["aid": .number(2), "iid": .number(Double(active)), "value": .number(1)]),
            ])])
            let written = try await controller.request("PUT", "/characteristics", body: data(on))
            #expect(written.status == 204, "\(String(decoding: written.body, as: UTF8.self))")
            let read = try json(await controller.request("GET", "/characteristics?id=2.\(speed),2.\(active)"))
            #expect(read["characteristics"]?.arrayValue?.map { $0["value"]?.intValue } == [100, 1])
            #expect(fixture.device.error == nil)
        } catch {
            await controller.close(); await fixture.stop()
            throw error
        }
        await controller.close(); await fixture.stop()
    }

    private func rotationSpeed(_ controller: WireHAPController) async throws -> Int {
        let database = try json(await controller.request("GET", "/accessories"))
        let device = try #require(database["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
        return try #require(device["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] }
            .first { $0["type"]?.stringValue == "29" }?["iid"]?.intValue)
    }

    /// Pairs `controller` and returns the purifier's Active and Current Air Purifier State IIDs.
    private func pairedPurifier(_ controller: WireHAPController, _ fixture: Fixture) async throws -> (active: Int, state: Int) {
        try await controller.connect()
        try await controller.pair(setupCode: fixture.code)
        try await controller.verify()
        await fixture.settle()
        let database = try json(await controller.request("GET", "/accessories"))
        let device = try #require(database["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
        let chars = device["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
        return (try #require(chars.first { $0["type"]?.stringValue == "B0" }?["iid"]?.intValue),
                try #require(chars.first { $0["type"]?.stringValue == "A9" }?["iid"]?.intValue))
    }

    private func values(_ messages: [WireHAPController.Message], iid: Int) throws -> [JSONValue] {
        try messages.flatMap { try json($0)["characteristics"]?.arrayValue ?? [] }
            .filter { $0["aid"]?.intValue == 2 && $0["iid"]?.intValue == iid }
    }

    private func event(_ client: WireHAPController, iid: Int) async throws -> JSONValue {
        for _ in 0..<30 {
            let message = try await client.nextEvent()
            let value = try json(message)
            if let c = value["characteristics"]?.arrayValue?.first(where: { $0["aid"]?.intValue == 2 && $0["iid"]?.intValue == iid }) { return c }
        }
        throw WireHAPController.Failure.invalidHTTP
    }
    private func json(_ message: WireHAPController.Message) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: message.body)
    }
    private func data(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }
    private func validateStrings(_ json: JSONValue) throws {
        for accessory in json["accessories"]?.arrayValue ?? [] {
            for c in accessory["services"]?.arrayValue?.flatMap({ $0["characteristics"]?.arrayValue ?? [] }) ?? [] where c["format"]?.stringValue == "string" {
                if let value = c["value"]?.stringValue { #expect(value.utf8.count <= 64) }
            }
        }
    }

    @MainActor private struct Fixture {
        let device: LoopbackMiioDevice
        let api: LANMiotAPI
        let devices: DeviceController
        let store: HomeStore
        let bridge: HomeKitBridgeController
        let suite: String
        let defaults: UserDefaults
        let originalName: String
        let port: UInt16
        let code: String

        static func make(model: String = LoopbackMiioDevice.model) async throws -> Fixture {
            let device = try LoopbackMiioDevice(model: model)
            let name = String(repeating: "测试空气净化器🙂", count: 12)
            let local = LocalDevice(did: "77", name: name, model: model, host: "127.0.0.1", token: LoopbackMiioDevice.token)
            let config = LocalHomeConfig(devices: [local])
            let api = LANMiotAPI(config: { config }, transport: LoopbackMiioTransport(port: device.port))
            let devices = DeviceController(api: api, config: { config })
            await devices.refreshNow()
            #expect(devices.snapshots["77"]?.isOnline == true)
            let suite = "test.mijialan.wire.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(false, forKey: HomeKitBridgeController.keepAwakeKey)
            let store = HomeStore(provider: CapabilityHomeProvider(controller: devices), defaultsSuiteName: suite)
            for _ in 0..<100 where !store.hasReceivedInitialSnapshot { try await Task.sleep(for: .milliseconds(2)) }
            let storage = VaultStorage()
            let vault = HomeKitBridgeVault(load: { storage.data.withLock { $0.map { .value($0) } ?? .missing } },
                save: { value in storage.data.withLock { $0 = value }; return true })
            let bridge = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0, loopbackOnly: true)
            bridge.attach(to: store, capabilities: devices)
            await bridge.waitUntilIdle()
            guard case .running(let port) = bridge.status, let code = bridge.setupCode else {
                bridge.isEnabled = false
                await bridge.waitUntilIdle()
                devices.shutdown()
                await api.shutdown()
                await device.stop()
                defaults.removePersistentDomain(forName: suite)
                throw WireHAPController.Failure.closed
            }
            return Fixture(device: device, api: api, devices: devices, store: store, bridge: bridge,
                           suite: suite, defaults: defaults, originalName: name, port: port, code: code)
        }
        func settle() async {
            for _ in 0..<10 { await Task.yield() }
            await bridge.waitUntilIdle()
        }
        func stop() async {
            bridge.isEnabled = false
            await bridge.waitUntilIdle()
            devices.shutdown()
            await api.shutdown()
            await device.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class VaultStorage: Sendable { let data = OSAllocatedUnfairLock<Data?>(initialState: nil) }
