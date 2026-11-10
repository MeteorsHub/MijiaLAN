import Foundation
import HAPCore
import HAPCrypto
import HAPTransport
import MijiaCore
import Testing
@testable import MijiaLAN

struct HAPWriteOriginTests {
    @Test("A write acknowledges its origin while other controllers and linked characteristics still get events")
    func writeEcho() async throws {
        let fixture = await Fixture.make()
        let handler = try await fixture.protocolHandler(connectionID: 11)
        await fixture.bridge.registerWriteHandler(aid: 2, iid: 10, managesValue: true) { value in
            // The real adapter crosses MainActor and creates a task to publish its readback.
            await Task { @MainActor in
                await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: value)
                await fixture.bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(true))
            }.value
        }
        #expect(try await handler.handleRequest(write(iid: 10, value: 64)).statusCode == 204)
        let events = try await fixture.drain()
        #expect(events.filter { $0.iid == 10 }.map(\.subscribers) == [[22]])
        #expect(events.filter { $0.iid == 9 }.map(\.subscribers) == [[11, 22]])
        #expect(await fixture.bridge.readCharacteristic(aid: 2, iid: 10) == .int32(64))

        // A later physical-device change must reach the writing controller too.
        await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: .int32(61))
        let external = try await fixture.drain()
        #expect(external.filter { $0.iid == 10 }.map(\.subscribers) == [[11, 22]])
    }

    @Test("A write's original value reaches the writer again after a correction")
    func correctionThenConfirmation() async throws {
        let fixture = await Fixture.make()
        let handler = try await fixture.protocolHandler(connectionID: 11)
        await fixture.bridge.registerWriteHandler(aid: 2, iid: 10, managesValue: true) { value in
            await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: value)
            await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: .int32(61))
            await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: value)
        }
        #expect(try await handler.handleRequest(write(iid: 10, value: 64)).statusCode == 204)
        let events = try await fixture.drain().filter { $0.iid == 10 }
        #expect(events.map(\.value) == [.number(64), .number(61), .number(64)])
        #expect(events.map(\.subscribers) == [[22], [11, 22], [11, 22]])
    }

    @Test("Concurrent writes preserve each controller's event origin", arguments: [30, 70])
    func concurrentOrigins(secondValue: Int) async throws {
        let fixture = await Fixture.make(), gate = Gate(required: 2)
        let first = try await fixture.protocolHandler(connectionID: 11)
        let second = try await fixture.protocolHandler(connectionID: 22)
        await fixture.bridge.registerWriteHandler(aid: 2, iid: 10, managesValue: true) { value in
            await gate.arrive()
            await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: value)
        }
        async let one = first.handleRequest(write(iid: 10, value: 30))
        async let two = second.handleRequest(write(iid: 10, value: secondValue))
        let responses = try await (one, two)
        #expect(responses.0.statusCode == 204 && responses.1.statusCode == 204)
        let events = try await fixture.drain().filter { $0.iid == 10 }
        let firstChange = try #require(events.first)
        if secondValue == 30 {
            #expect(events.count == 1)
            #expect(firstChange.value == .number(30))
            #expect(firstChange.subscribers == [11] || firstChange.subscribers == [22])
        } else {
            #expect(events.count == 2)
            #expect(Set(events.compactMap { $0.value?.intValue }) == [30, 70])
            #expect(firstChange.subscribers == (firstChange.value == .number(30) ? [22] : [11]))
            // The second writer was queued the other value. Its final value must follow it.
            #expect(events.last?.subscribers == [11, 22])
        }
    }

    @Test("Write errors and explicit corrective resets still notify the writing controller")
    func failureAndReset() async throws {
        let fixture = await Fixture.make()
        let handler = try await fixture.protocolHandler(connectionID: 11)
        await fixture.bridge.registerWriteHandler(aid: 2, iid: 10, managesValue: true) { _ in
            await fixture.bridge.setReadStatus(aid: 2, iid: 10, status: .communicationFailure)
            await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: .int32(50), forceNotify: true)
            throw HAPError.unavailable
        }
        #expect(try await handler.handleRequest(write(iid: 10, value: 50)).statusCode == 207)
        let events = try await fixture.drain().filter { $0.iid == 10 }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.subscribers == [11, 22] })
        #expect(events.first?.status == -70402)
        #expect(events.last?.value == .number(50))
        await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: .int32(60))
        #expect(try await fixture.drain().first { $0.iid == 10 }?.subscribers == [11, 22])
    }

    @Test("A child task that outlives its request cannot keep suppressing events")
    func originLifetime() async throws {
        let fixture = await Fixture.make(), gate = Gate(required: 2)
        let handler = try await fixture.protocolHandler(connectionID: 11)
        await fixture.bridge.registerWriteHandler(aid: 2, iid: 10, managesValue: true) { value in
            let delayed = Task {
                await gate.arrive()
                await fixture.bridge.updateCharacteristic(aid: 2, iid: 10, value: value)
            }
            await fixture.capture.setDeferred(delayed)
        }
        #expect(try await handler.handleRequest(write(iid: 10, value: 64)).statusCode == 204)
        await gate.arrive()
        await fixture.capture.waitForDeferred()
        let events = try await fixture.drain().filter { $0.iid == 10 }
        #expect(events.count == 1)
        #expect(events.first?.subscribers == [11, 22])
    }

    private func write(iid: UInt64, value: Int) -> HTTPRequest {
        HTTPRequest(method: "PUT", path: "/characteristics",
                    body: Data("{\"characteristics\":[{\"aid\":2,\"iid\":\(iid),\"value\":\(value)}]}".utf8))
    }

    private struct Event: Sendable {
        let subscribers: Set<Int>
        let iid: UInt64
        let value: JSONValue?
        let status: Int?
    }
    private actor Capture {
        var events: [Event] = []
        private var deferred: Task<Void, Never>?
        func setDeferred(_ task: Task<Void, Never>) { deferred = task }
        func waitForDeferred() async { await deferred?.value; deferred = nil }
        func append(_ subscribers: Set<Int>, _ data: Data) {
            guard let split = data.range(of: Data("\r\n\r\n".utf8)),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data[split.upperBound...]),
                  let c = json["characteristics"]?.arrayValue?.first, let iid = c["iid"]?.intValue else { return }
            events.append(Event(subscribers: subscribers, iid: UInt64(iid), value: c["value"], status: c["status"]?.intValue))
        }
        func take() -> [Event] { defer { events.removeAll() }; return events }
    }
    private actor Gate {
        let required: Int
        var waiting: [CheckedContinuation<Void, Never>] = []
        init(required: Int) { self.required = required }
        func arrive() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count == required {
                    let ready = waiting; waiting.removeAll()
                    ready.forEach { $0.resume() }
                }
            }
        }
    }
    private struct Fixture: Sendable {
        let bridge: HAPBridge
        let capture: Capture
        static func make() async -> Fixture {
            let info = AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1")
            let bridge = HAPBridge(info: info), capture = Capture()
            await bridge.addAccessory(info: info, services: [HAPService(iid: 8, type: .lightbulb, characteristics: [
                HAPCharacteristic(iid: 9, type: .on, value: .bool(false), permissions: [.read, .write, .notify], format: .bool),
                HAPCharacteristic(iid: 10, type: .brightness, value: .int32(50), permissions: [.read, .write, .notify], format: .int, minValue: 0, maxValue: 100),
                HAPCharacteristic(iid: 11, type: .colorTemperature, value: .int32(356), permissions: [.read, .notify], format: .int),
            ])], aid: 2, servicesHaveStableIIDs: true)
            for connection in [11, 22] {
                for iid: UInt64 in [9, 10, 11] { await bridge.subscribe(connectionID: connection, aid: 2, iid: iid) }
            }
            await bridge.setCharacteristicChangeHandler { ids, data in await capture.append(ids, data) }
            return Fixture(bridge: bridge, capture: capture)
        }
        func protocolHandler(connectionID: Int) async throws -> CharacteristicProtocol {
            let identity = HAPIdentity(), store = InMemoryPairingStore()
            let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "test")
            try await VerifiedTestController.authenticate(verify, store: store)
            return CharacteristicProtocol(bridge: bridge,
                pairingStateMachine: PairingStateMachine(setupCode: "031-45-154", identity: identity, pairingStore: store, deviceID: "test"),
                pairVerifyStateMachine: verify, pairingStore: store, identity: identity, connectionID: connectionID)
        }
        func drain() async throws -> [Event] {
            // FIFO marker proves completion without asserting that nothing arrives during a short sleep.
            await bridge.updateCharacteristic(aid: 2, iid: 11, value: .int32(356), forceNotify: true)
            for _ in 0..<200 {
                if await capture.events.last?.iid == 11 { return await capture.take() }
                try await Task.sleep(for: .milliseconds(2))
            }
            throw WireHAPController.Failure.timedOut
        }
    }
}
