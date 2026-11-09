import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private final class SocketObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MiioTransportObservation] = []
    func append(_ event: MiioTransportObservation) { lock.withLock { events.append(event) } }
    var snapshot: [MiioTransportObservation] { lock.withLock { events } }
}

// BSD receives are blocking; never occupy Swift's cooperative executor while awaiting a peer.
func loopbackResponder<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) -> Task<T, Error> {
    Task {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

struct UDPDiagnosticsTests {
    @Test("Sixty-four real loopback exchanges expose actual source ports and use fresh local sockets")
    func freshSockets() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1")
        let responder = loopbackResponder { () throws -> [UInt16] in
            var ports: [UInt16] = []
            for _ in 0..<64 {
                guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
                ports.append(request.port)
                try server.send(request.data, to: "127.0.0.1", port: request.port)
            }
            return ports
        }
        let observations = SocketObservations(), transport = UDPMiioTransport()
        for index in 0..<64 {
            let request = Data([UInt8(index)])
            let reply = try await transport.exchangeDiagnosed(request, host: "127.0.0.1", port: server.localPort, timeout: .seconds(2), observe: observations.append)
            #expect(reply == request)
        }
        let measuredPorts = try await responder.value
        let sends = observations.snapshot.filter { if case .sent = $0.boundary { true } else { false } }
        #expect(sends.count == 64 && Set(sends.compactMap(\.socket)).count == 64)
        #expect(sends.compactMap(\.localPort) == measuredPorts)
        #expect(measuredPorts.allSatisfy { $0 != 0 })
        // The OS can reuse an ephemeral port; a fresh socket does not guarantee a new port number.
        print("UDP_LOOPBACK fresh_sockets=64 distinct_source_ports=\(Set(measuredPorts).count)")
    }
    @Test("A same-host datagram from the wrong UDP port is discarded before accepting the expected peer")
    func wrongSourcePort() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), unexpected = try UDPSocket(bindHost: "127.0.0.1")
        let responder = loopbackResponder {
            guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
            try unexpected.send(Data("wrong-peer".utf8), to: "127.0.0.1", port: request.port)
            Thread.sleep(forTimeInterval: 0.03)
            try server.send(Data("expected-peer".utf8), to: "127.0.0.1", port: request.port)
        }
        let observations = SocketObservations()
        let reply = try await UDPMiioTransport().exchangeDiagnosed(Data([1]), host: "127.0.0.1", port: server.localPort, timeout: .seconds(2), observe: observations.append)
        try await responder.value
        #expect(reply == Data("expected-peer".utf8))
        #expect(observations.snapshot.contains { if case .discarded = $0.boundary { true } else { false } })
    }
    @Test("Unexpected peer traffic does not restart the request deadline or trigger another send")
    func discardedTrafficTimesOut() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), unexpected = try UDPSocket(bindHost: "127.0.0.1")
        let responder = loopbackResponder {
            guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
            for _ in 0..<12 {
                try unexpected.send(Data([0]), to: "127.0.0.1", port: request.port)
                Thread.sleep(forTimeInterval: 0.015)
            }
        }
        let observations = SocketObservations()
        await #expect(throws: MiioError.timeout) {
            try await UDPMiioTransport().exchangeDiagnosed(Data([1]), host: "127.0.0.1", port: server.localPort, timeout: .milliseconds(80), observe: observations.append)
        }
        try await responder.value
        let events = observations.snapshot
        #expect(events.filter { if case .sent = $0.boundary { true } else { false } }.count == 1)
        #expect(events.contains { if case .discarded = $0.boundary { true } else { false } })
    }
    @Test("A reused raw loopback socket keeps one source port but can deliver an old reply to its next request")
    func rawReuseNeedsMatching() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), client = try UDPSocket(bindHost: "127.0.0.1")
        let responder = loopbackResponder { () throws -> [UInt16] in
            guard let first = try server.receive(timeout: 3), let second = try server.receive(timeout: 3) else { throw MiioError.timeout }
            try server.send(first.data, to: "127.0.0.1", port: second.port)
            try server.send(second.data, to: "127.0.0.1", port: second.port)
            return [first.port, second.port]
        }
        // No first reply is sent until the second request arrives. This stays entirely on loopback.
        try client.send(Data([1]), to: "127.0.0.1", port: server.localPort)
        try client.send(Data([2]), to: "127.0.0.1", port: server.localPort)
        let (stale, current) = try await loopbackResponder { (try client.receive(timeout: 2), try client.receive(timeout: 2)) }.value
        #expect(stale?.data == Data([1]) && current?.data == Data([2]))
        #expect(try await responder.value == [client.localPort, client.localPort])
    }
}

extension UDPDiagnosticsTests {
    @Test("A stable session retains one measured source port for 256 rounds, releases it on close and rejects use after close")
    func stableManyRounds() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1")
        let responder = loopbackResponder { () throws -> [UInt16] in
            var ports: [UInt16] = []
            for _ in 0..<256 {
                guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
                ports.append(request.port); try server.send(request.data, to: "127.0.0.1", port: request.port)
            }
            return ports
        }
        let transport = UDPMiioTransport().sessionTransport(policy: .stable), log = SocketObservations()
        for index in 0..<256 {
            let data = Data([UInt8(index % 256)])
            #expect(try await transport.exchangeDiagnosed(data, host: "127.0.0.1", port: server.localPort, timeout: .seconds(2), observe: log.append) == data)
        }
        let ports = try await responder.value
        #expect(Set(ports).count == 1)
        let sends = log.snapshot.filter { if case .sent = $0.boundary { true } else { false } }
        #expect(Set(sends.compactMap(\.socket)).count == 1 && Set(sends.compactMap(\.session)).count == 1)
        let port = try #require(ports.first)
        #expect(throws: (any Error).self) { try UDPSocket(bindHost: "0.0.0.0", bindPort: port, reuseAddress: false) }
        await transport.closeSession(observe: log.append)
        let rebound = try UDPSocket(bindHost: "0.0.0.0", bindPort: port, reuseAddress: false)
        rebound.invalidate()
        await #expect(throws: (any Error).self) { try await transport.exchange(Data([0]), host: "127.0.0.1", port: server.localPort, timeout: .milliseconds(50)) }
        #expect(log.snapshot.contains { if case .closed = $0.boundary { true } else { false } })
    }
    @Test("Cancelling an in-flight stable exchange closes its socket without retry; a new session can reopen")
    func stableCancellation() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), log = SocketObservations()
        let transport = UDPMiioTransport().sessionTransport(policy: .stable)
        let task = Task { try await transport.exchangeDiagnosed(Data([1]), host: "127.0.0.1", port: server.localPort, timeout: .seconds(2), observe: log.append) }
        let deadline = Date().addingTimeInterval(2)
        while !log.snapshot.contains(where: { if case .sent = $0.boundary { true } else { false } }), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.snapshot.filter { if case .sent = $0.boundary { true } else { false } }.count == 1)
        let closed = try #require(log.snapshot.first { if case .closed = $0.boundary { true } else { false } })
        #expect(closed.reason == .cancelled)
        let port = try #require(closed.localPort)
        let reopened = try UDPSocket(bindHost: "0.0.0.0", bindPort: port, reuseAddress: false)
        reopened.invalidate(); await transport.closeSession(observe: { _ in })
    }
    @Test("Stable client rejects same-peer late RPC IDs and wrong DIDs before accepting the matching encrypted reply")
    func stableReplyMatching() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1"), token = Data(repeating: 0, count: 16)
        let fake = FakeMiioNetwork.Device(host: "127.0.0.1", token: token, deviceID: 123)
        let responder = loopbackResponder {
            guard let hello = try server.receive(timeout: 3) else { throw MiioError.timeout }
            try server.send(FakeMiioNetwork.helloReply(fake), to: "127.0.0.1", port: hello.port)
            guard let request = try server.receive(timeout: 3) else { throw MiioError.timeout }
            let (_, body) = try MiioPacket.decode(request.data, token: token)
            let json = try JSONDecoder().decode(JSONValue.self, from: body.prefix { $0 != 0 })
            let id = json["id"]?.intValue ?? 1
            for (responseID, deviceID) in [(id % 9_999 + 1, UInt32(123)), (id, UInt32(124)), (id, UInt32(123))] {
                let reply = JSONValue.object(["id": .number(Double(responseID)), "result": .object(["model": .string("test")])])
                let bytes = try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: deviceID, stamp: 5_000)
                try server.send(bytes, to: "127.0.0.1", port: request.port)
            }
        }
        let journal = DeviceEventLog(scope: .offlineTest)
        let client = MiioClient(host: "127.0.0.1", token: token, port: server.localPort, events: journal, policy: .revised, expectedDeviceID: 123)
        #expect(try await client.info().model == "test")
        try await responder.value
        let checks = journal.snapshot().filter { $0.outcome == .packetChecked }
        #expect(checks.contains { $0.packet?.rpcIDMatches == false })
        #expect(checks.contains { $0.packet?.headerIdentityMatches == false })
        #expect(journal.snapshot().filter { $0.outcome == .discarded }.count == 2)
        await client.close()
    }
}
