import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private let token = "00112233445566778899aabbccddeeff"

struct MiioPacketTests {
    /// Built with python-miio 0.5.12 (`miio.protocol.Message.build`), the implementation Home Assistant uses.
    static let pythonMiioVector = "21310050000000000a1b2c3d123456783d32420e52de0a6a5ca0004151f14e432a36b2b7afa85bd6a9f1ed82b485a3d6c2c13a12855c97fc9a0bd7be55469c61b5393611ac2c922588d969ad8c226bde"
    static let pythonMiioPayload = Data(#"{"id": 1, "method": "miIO.info", "params": []}"#.utf8) + [0]

    @Test("Encoding matches python-miio byte for byte")
    func encodeMatchesPythonMiio() throws {
        let packet = try MiioPacket.encode(Self.pythonMiioPayload, token: MiioToken.parse(token)!, deviceID: 0x0A1B_2C3D, stamp: 0x1234_5678)
        #expect(MiioToken.hex(packet) == Self.pythonMiioVector)
    }

    @Test("A python-miio packet decodes, and the wrong token fails the checksum")
    func decodePythonMiio() throws {
        let packet = try #require(Data(hex: Self.pythonMiioVector))
        let (header, payload) = try MiioPacket.decode(packet, token: MiioToken.parse(token)!)
        #expect(header.deviceID == 0x0A1B_2C3D)
        #expect(header.stamp == 0x1234_5678)
        #expect(header.length == packet.count)
        #expect(payload == Self.pythonMiioPayload)

        #expect(throws: MiioError.checksumMismatch) {
            try MiioPacket.decode(packet, token: MiioToken.parse("ffeeddccbbaa99887766554433221100")!)
        }
    }

    @Test("Hello is 32 bytes of 0x2131 0x0020 then 0xFF")
    func hello() throws {
        #expect(MiioToken.hex(MiioPacket.hello) == "21310020" + String(repeating: "ff", count: 28))
        let header = try MiioPacket.parseHeader(MiioPacket.hello)
        #expect(header.deviceID == 0xFFFF_FFFF)
        #expect(header.revealedToken == nil)
    }

    @Test("A hello reply only reveals a token that is not all 0x00 or 0xFF")
    func revealedToken() throws {
        var bytes: [UInt8] = [0x21, 0x31, 0x00, 0x20, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 9]
        let hidden = Data(bytes + [UInt8](repeating: 0, count: 16))
        #expect(try MiioPacket.parseHeader(hidden).revealedToken == nil)
        bytes += [UInt8](MiioToken.parse(token)!)
        #expect(try MiioPacket.parseHeader(Data(bytes)).revealedToken == token)
    }

    @Test("Short, foreign and truncated packets are rejected")
    func malformed() {
        #expect(throws: MiioError.malformedPacket) { try MiioPacket.parseHeader(Data([0x21, 0x31])) }
        #expect(throws: MiioError.malformedPacket) { try MiioPacket.parseHeader(Data(repeating: 0, count: 32)) }
        // Claims 80 bytes but carries 32.
        #expect(throws: MiioError.malformedPacket) {
            try MiioPacket.parseHeader(Data([0x21, 0x31, 0x00, 0x50] + [UInt8](repeating: 0, count: 28)))
        }
    }

    @Test("Tokens are 32 hex characters; spaces are ignored")
    func tokens() {
        #expect(MiioToken.parse("0011 2233 4455 6677 8899 AABB CCDD EEFF") == MiioToken.parse(token))
        #expect(MiioToken.parse("0011") == nil)
        #expect(MiioToken.parse(String(repeating: "g", count: 32)) == nil)
    }

    @Test("Malformed replies go through python-miio's quirk fixes")
    func quirks() {
        #expect(MiioClient.parseJSON(Data(#"{"id":1,"result":["ok"]}"#.utf8) + [0, 0]) != nil)
        #expect(MiioClient.parseJSON(Data(#"{"id":1,"result":{"a":1,,"otu_stat":2}}"#.utf8))?["result"]?["otu_stat"] == .number(2))
        #expect(MiioClient.parseJSON(Data(#"{"id":1,"result":[{"value":00}]}"#.utf8)) != nil)
        #expect(MiioClient.parseJSON(Data(#"{"id":1,"result":[]}"#.utf8) + [0] + Data("junk".utf8)) != nil)
        #expect(MiioClient.parseJSON(Data("not json".utf8)) == nil)
    }
}

struct MiioClientTests {
    @Test("info, get and set go through the handshake and decode the device's replies")
    func roundTrip() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.168.1.50", token: token, deviceID: 77, props: ["2.1": .bool(true), "2.2": .number(40)])
        let client = MiioClient(host: "192.168.1.50", token: MiioToken.parse(token)!, transport: network)

        #expect(try await client.info().model == "yeelink.light.fake1")
        let values = try await client.getProperties(did: "77", [(2, 1), (2, 2), (2, 9)])
        // Matched by siid/piid even though the fake echoes its own did; unknown properties are left out.
        #expect(values == [MiotPropKey(did: "77", siid: 2, piid: 1): .bool(true), MiotPropKey(did: "77", siid: 2, piid: 2): .number(40)])

        try await client.setProperties([MiotPropWrite(did: "77", siid: 2, piid: 2, value: .number(65))])
        #expect(device.props["2.2"] == .number(65))
        // Integers go out without a fraction, NUL-terminated like python-miio.
        let lastPayload = try #require(device.receivedPayloads.last)
        #expect(String(decoding: lastPayload, as: UTF8.self).contains(#""value":65}"#))
        #expect(lastPayload.last == 0)
        #expect(device.receivedMethods == ["miIO.info", "get_properties", "set_properties"])
    }

    @Test("Stamps follow the device clock and never go backwards")
    func stamps() async throws {
        let network = FakeMiioNetwork()
        let device = network.add(host: "192.168.1.51", token: token, deviceID: 78)
        device.stamp = 900_000
        let client = MiioClient(host: "192.168.1.51", token: MiioToken.parse(token)!, transport: network)
        for _ in 0..<3 { _ = try await client.info() }
        #expect(device.receivedStamps.count == 3)
        #expect(device.receivedStamps.allSatisfy { $0 > 900_000 })
        #expect(device.receivedStamps == device.receivedStamps.sorted())
    }

    @Test("Hello answered but requests ignored means the token is wrong")
    func wrongToken() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.52", token: token, deviceID: 79)
        let client = MiioClient(host: "192.168.1.52", token: MiioToken.parse("ffeeddccbbaa99887766554433221100")!, transport: network)
        await #expect(throws: MiioError.noEncryptedReply) { try await client.info() }
    }

    @Test("No reply at all is a timeout")
    func offline() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.53", token: token, deviceID: 80).offline = true
        let client = MiioClient(host: "192.168.1.53", token: MiioToken.parse(token)!, transport: network)
        await #expect(throws: MiioError.timeout) { try await client.info() }
    }

    @Test("Device errors and rejected writes surface as deviceError")
    func deviceErrors() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.54", token: token, deviceID: 81)
        let client = MiioClient(host: "192.168.1.54", token: MiioToken.parse(token)!, transport: network)
        await #expect(throws: MiioError.deviceError(code: -32601, message: "Method not found.")) { try await client.call("nope") }
        await #expect(throws: MiioError.deviceError(code: -4004, message: "参数错误（-4004）")) {
            try await client.setProperties([MiotPropWrite(did: "81", siid: 9, piid: 9, value: .number(1))])
        }
    }

    @Test("Discovery keeps one entry per device and drops our own broadcast")
    func discovery() async throws {
        let network = FakeMiioNetwork()
        network.add(host: "192.168.1.20", token: token, deviceID: 5)
        network.add(host: "192.168.1.3", token: token, deviceID: 6)
        network.add(host: "192.168.1.4", token: token, deviceID: 7).offline = true
        let found = try await MiioDiscovery.discover(duration: .milliseconds(10), transport: network)
        #expect(found.map(\.host) == ["192.168.1.3", "192.168.1.20"])
        #expect(found.map(\.did) == ["6", "5"])
    }
}

/// The real socket path, against a responder bound to 127.0.0.1.
struct UDPTransportTests {
    @Test("exchange reaches a local UDP responder and returns its reply")
    func loopback() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1", bindPort: 0)
        let port = server.localPort
        let reply = FakeMiioNetwork.helloReply(FakeMiioNetwork.Device(host: "127.0.0.1", token: MiioToken.parse(token)!, deviceID: 4242))
        let responder = Thread {
            guard let request = try? server.receive(timeout: 5), request.data == MiioPacket.hello else { return }
            try? server.send(reply, to: "127.0.0.1", port: request.port)
        }
        responder.start()

        let client = MiioClient(host: "127.0.0.1", token: MiioToken.parse(token)!, port: port)
        let header = try await client.handshake()
        #expect(header.deviceID == 4242)
        withExtendedLifetime(server) {}
    }

    @Test("A silent port times out")
    func silent() async throws {
        let server = try UDPSocket(bindHost: "127.0.0.1", bindPort: 0)
        let transport = UDPMiioTransport()
        await #expect(throws: MiioError.timeout) {
            try await transport.exchange(MiioPacket.hello, host: "127.0.0.1", port: server.localPort, timeout: .milliseconds(200))
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
