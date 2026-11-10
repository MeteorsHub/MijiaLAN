import Foundation
import MijiaCore
import os
@testable import MijiaLAN

/// A real UDP miIO peer, bound only to 127.0.0.1:0. The blocking descriptor is confined to its
/// dispatch queue; a lock protects the small state shared with async test code. No device API is mocked.
final class LoopbackMiioDevice: Sendable {
    static let token = "00112233445566778899aabbccddeeff"
    static let model = "zhimi.airpurifier.rma1"
    static let lampModel = "yeelink.light.lamp4"
    private struct State: Sendable {
        var phase = 0
        var stopped = false
        var encryptedRequests = 0
        var writes = 0
        var lampWrites: [String] = []
        /// Values from `set_properties`, reported back by later reads.
        var written: [String: JSONValue] = [:]
        /// How many reads after a write still report a value on the way to it, like a light fading to a new level:
        /// halfway for a number, the old value otherwise.
        var readsBeforeSettling = 0
        var ignoresSetsWhileOff = false
        var settling: [String: (passing: JSONValue, reads: Int)] = [:]
        var error: String?
    }
    private final class Storage: Sendable { let state = OSAllocatedUnfairLock(initialState: State()) }
    private let storage = Storage()
    private let queue = DispatchQueue(label: "test.mijialan.miio-device")
    let port: UInt16

    init(model: String = LoopbackMiioDevice.model) throws {
        let socket = try UDPSocket(bindHost: "127.0.0.1", bindPort: 0)
        port = socket.localPort
        let schema = DeviceSchema.bundled(model: model)!
        var values: [String: JSONValue] = [:]
        for c in DeviceCapabilityCatalog.capabilities(schema: schema, model: model) where c.readable {
            values["\(c.siid).\(c.iid)"] = c.format == "bool" ? .bool(false) : .number(c.options.first.map { Double($0.value) } ?? c.min ?? 0)
        }
        values["2.1"] = .bool(true)
        values["3.1"] = .number(45)
        values["3.7"] = .number(21.56)
        if model == Self.lampModel {
            values["2.1"] = .bool(false)
            values["2.2"] = .number(51)
            values["2.3"] = .number(2812)
        }
        let initialValues = values
        let storage = storage
        queue.async {
            var deviceValues = initialValues
            while !storage.state.withLock({ $0.stopped }) {
                do {
                    guard let datagram = try socket.receive(timeout: 0.1) else { continue }
                    let response: Data
                    if datagram.data == MiioPacket.hello {
                        response = Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 77, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
                    } else {
                        let token = MiioToken.parse(Self.token)!
                        let (_, bytes) = try MiioPacket.decode(datagram.data, token: token)
                        let request = try JSONDecoder().decode(JSONValue.self, from: bytes.prefix { $0 != 0 })
                        let method = request["method"]?.stringValue ?? ""
                        let params = request["params"]?.arrayValue ?? []
                        @Sendable func key(_ p: JSONValue) -> String { "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)" }
                        let (phase, written, stale) = storage.state.withLock { state in
                            state.encryptedRequests += 1
                            if method.hasPrefix("set_") || method == "action" { state.writes += 1 }
                            if model == Self.lampModel, method.hasPrefix("set_") { state.lampWrites.append(method) }
                            if method == "set_properties" {
                                for p in params {
                                    if state.ignoresSetsWhileOff, key(p) != "2.1",
                                       (state.written["2.1"] ?? initialValues["2.1"]) == .bool(false) { continue }
                                    if state.readsBeforeSettling > 0, let old = state.written[key(p)] ?? initialValues[key(p)] {
                                        let passing = old.doubleValue.flatMap { from in
                                            p["value"]?.doubleValue.map { JSONValue.number(((from + $0) / 2).rounded(.down)) }
                                        } ?? old
                                        state.settling[key(p)] = (passing, state.readsBeforeSettling)
                                    }
                                    state.written[key(p)] = p["value"]
                                }
                            }
                            var stale: [String: JSONValue] = [:]
                            if method == "get_properties" {
                                for p in params {
                                    guard let entry = state.settling[key(p)] else { continue }
                                    stale[key(p)] = entry.passing
                                    state.settling[key(p)] = entry.reads > 1 ? (entry.passing, entry.reads - 1) : nil
                                }
                            }
                            return (state.phase, state.written, stale)
                        }
                        var values = deviceValues.merging(written) { _, new in new }.merging(stale) { _, old in old }
                        if model == Self.lampModel {
                            if phase == 1 { values["2.3"] = .number(0) }
                        } else if phase == 1 {
                            values["2.1"] = .string("on")
                            values["3.1"] = .number(123)
                            values["3.7"] = .number(-3276.8)
                        } else if phase == 2 { values["3.1"] = .number(55) }
                        let result: JSONValue
                        var deviceError: JSONValue?
                        if method == "miIO.info" { result = .object(["model": .string(model)]) }
                        else if model == Self.lampModel, method == "set_power" {
                            deviceValues["2.1"] = .bool(request["params"]?.arrayValue?.first?.stringValue == "on")
                            result = .array([.string("ok")])
                        }
                        else if model == Self.lampModel, method == "set_bright" {
                            // Yeelight set_bright is only accepted while on. Apple Home can send
                            // brightness before On in the same HAP write request.
                            if values["2.1"]?.boolValue == true {
                                deviceValues["2.2"] = request["params"]?.arrayValue?.first
                            } else {
                                deviceError = .object(["code": .number(-1), "message": .string("light is off")])
                            }
                            result = .array([.string("ok")])
                        }
                        else if method == "get_prop", model == Self.lampModel {
                            // The 1S uses legacy miIO and returns numeric readings as strings.
                            let legacy: [String: JSONValue] = [
                                "power": .string(values["2.1"]?.boolValue == true ? "on" : "off"),
                                "bright": .string(values["2.2"]!.compactJSONString),
                                "ct": .string(values["2.3"]!.compactJSONString),
                            ]
                            result = .array((request["params"]?.arrayValue ?? []).map { legacy[$0.stringValue ?? ""] ?? .null })
                        }
                        else if method == "get_properties" {
                            result = .array(params.map { p in
                                .object(["siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null,
                                    "value": values[key(p)] ?? .null, "code": .number(values[key(p)] == nil ? -4003 : 0)])
                            })
                        } else if method == "set_properties" {
                            result = .array(params.map { p in
                                .object(["did": p["did"] ?? .null, "siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null, "code": .number(0)])
                            })
                        } else { result = .array([.object(["code": .number(-4004)])]) }
                        let body = JSONValue.object(["id": request["id"] ?? .null,
                            deviceError == nil ? "result" : "error": deviceError ?? result])
                        response = try MiioPacket.encode(Data(body.compactJSONString.utf8) + [0], token: token, deviceID: 77, stamp: 5000)
                    }
                    try socket.send(response, to: datagram.host, port: datagram.port)
                } catch { storage.state.withLock { $0.error = String(describing: error) } }
            }
        }
    }

    func setPhase(_ phase: Int) { storage.state.withLock { $0.phase = phase } }
    func setReadsBeforeSettling(_ reads: Int) { storage.state.withLock { $0.readsBeforeSettling = reads } }
    /// Like a Yeelight lamp ignoring brightness: while power is off, other writes succeed but change nothing.
    func setIgnoresSetsWhileOff(_ ignores: Bool) { storage.state.withLock { $0.ignoresSetsWhileOff = ignores } }
    var encryptedRequests: Int { storage.state.withLock { $0.encryptedRequests } }
    var writes: Int { storage.state.withLock { $0.writes } }
    var lampWrites: [String] { storage.state.withLock { $0.lampWrites } }
    var error: String? { storage.state.withLock { $0.error } }
    func stop() async {
        storage.state.withLock { $0.stopped = true }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// Redirect only the fixed miIO port to the isolated fixture's ephemeral port. Every byte still
/// travels through production UDPMiioTransport and the production miIO encryption codec.
struct LoopbackMiioTransport: MiioTransport {
    let port: UInt16
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        guard host == "127.0.0.1" else { throw MiioError.hostUnreachable }
        return try await UDPMiioTransport().exchange(packet, host: host, port: self.port, timeout: timeout)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
