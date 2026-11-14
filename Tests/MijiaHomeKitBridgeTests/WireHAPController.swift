import CryptoKit
import Foundation
import HAPCore
import Network
@testable import HAPCrypto

/// A controller at the TCP boundary. It owns its HTTP parser, CryptoKit signatures, HKDF and frame
/// encryption; it never calls the server's pairing/protocol handlers. Only SRP client arithmetic is shared.
actor WireHAPController {
    struct Message: Sendable {
        let event: Bool
        let status: Int
        let body: Data
    }
    enum Failure: Error { case closed, invalidHTTP, invalidFrame, invalidPairing, timedOut }
    let identifier = UUID().uuidString
    private let signing = Curve25519.Signing.PrivateKey()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.mijialan.hap-controller")
    private var starting: CheckedContinuation<Void, any Error>?
    private var raw = Data()
    private var plaintext = Data()
    private var events: [Message] = []
    private var readKey: SymmetricKey?
    private var writeKey: SymmetricKey?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private(set) var accessoryIdentifier = ""
    private(set) var accessoryKey = Data()
    private(set) var receivedFrames = 0
    private(set) var largestFrame = 0
    /// Do not silently hide an EVENT that overtakes the response to the current request.
    private(set) var eventsBeforeLastResponse = 0

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        let timer = timeout()
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.changed(state) }
            }
            connection.start(queue: queue)
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready: starting?.resume(); starting = nil
        case .failed(let error): starting?.resume(throwing: error); starting = nil
        case .cancelled: starting?.resume(throwing: Failure.closed); starting = nil
        default: break
        }
    }

    func close() { connection.cancel() }

    /// A corrupt authenticated frame cannot be retried on the same session. The peer must close it,
    /// rather than leave Home waiting until this test client's own five-second watchdog fires.
    func peerClosesAfterInvalidFrame() async throws -> Bool {
        guard readKey != nil else { throw Failure.invalidPairing }
        try await send(Data([1, 0] + [UInt8](repeating: 0, count: 17)))
        let start = ContinuousClock.now
        do {
            _ = try await readRaw()
            return false
        } catch {
            return start.duration(to: .now) < .seconds(2)
        }
    }

    func request(_ method: String, _ path: String, body: Data = Data()) async throws -> Message {
        eventsBeforeLastResponse = 0
        let contentType = path.hasPrefix("/pair") ? "application/pairing+tlv8" : "application/hap+json"
        var bytes = Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        bytes.append(body)
        if let key = writeKey {
            var encrypted = Data()
            for offset in stride(from: 0, to: bytes.count, by: 1024) {
                let block = Data(bytes.dropFirst(offset).prefix(1024))
                let header = Data([UInt8(block.count & 255), UInt8(block.count >> 8)])
                encrypted.append(header)
                encrypted.append(try Self.seal(block, key: key, nonce: Self.nonce(writeCounter), aad: header))
                writeCounter += 1
            }
            bytes = encrypted
        }
        try await send(bytes)
        while true {
            let message = try await receive()
            if message.event { eventsBeforeLastResponse += 1; events.append(message) }
            else { return message }
        }
    }

    /// Events that arrived while a `request` waited for its response, i.e. between a request and its response.
    func takeEventsBeforeResponses() -> [Message] {
        defer { events.removeAll() }
        return events
    }

    func nextEvent() async throws -> Message {
        if !events.isEmpty { return events.removeFirst() }
        let message = try await receive()
        guard message.event else { throw Failure.invalidHTTP }
        return message
    }

    func pair(setupCode: String) async throws {
        let m2 = try await request("POST", "/pair-setup", body: TLV8.encode([(6, Data([1])), (0, Data([0]))]))
        let salt = try Self.field(m2.body, 2), server = try Self.field(m2.body, 3)
        let client = SRPClient()
        let proof = try client.processServerChallenge(serverPublicKey: server, salt: salt, setupCode: setupCode)
        let m4 = try await request("POST", "/pair-setup", body: TLV8.encode([
            (6, Data([3])), (3, client.clientPublicKey), (4, proof.clientProof),
        ]))
        guard try Self.field(m4.body, 4) == proof.serverProofExpected else { throw Failure.invalidPairing }
        let key = Self.derive(proof.sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let controllerX = Self.derive(proof.sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let publicKey = signing.publicKey.rawRepresentation
        let signature = try signing.signature(for: controllerX.withUnsafeBytes { Data($0) } + Data(identifier.utf8) + publicKey)
        let sub = TLV8.encode([(1, Data(identifier.utf8)), (3, publicKey), (10, signature)])
        let encrypted = try Self.seal(sub, key: key, nonce: Self.labelNonce("PS-Msg05"))
        let m6 = try await request("POST", "/pair-setup", body: TLV8.encode([(6, Data([5])), (5, encrypted)]))
        let accessory = try Self.open(Self.field(m6.body, 5), key: key, nonce: Self.labelNonce("PS-Msg06"))
        let id = try Self.field(accessory, 1), pub = try Self.field(accessory, 3)
        let accessoryX = Self.derive(proof.sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let message = accessoryX.withUnsafeBytes { Data($0) } + id + pub
        guard try Curve25519.Signing.PublicKey(rawRepresentation: pub).isValidSignature(Self.field(accessory, 10), for: message),
              let identifier = String(data: id, encoding: .utf8) else { throw Failure.invalidPairing }
        accessoryIdentifier = identifier
        accessoryKey = pub
    }

    func verify() async throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let pub = ephemeral.publicKey.rawRepresentation
        let m2 = try await request("POST", "/pair-verify", body: TLV8.encode([(6, Data([1])), (3, pub)]))
        let accessoryEphemeral = try Self.field(m2.body, 3)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryEphemeral))
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let key = Self.derive(sharedData, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let sub = try Self.open(Self.field(m2.body, 5), key: key, nonce: Self.labelNonce("PV-Msg02"))
        guard try Self.field(sub, 1) == Data(accessoryIdentifier.utf8),
              try Curve25519.Signing.PublicKey(rawRepresentation: accessoryKey).isValidSignature(Self.field(sub, 10),
                for: accessoryEphemeral + Data(accessoryIdentifier.utf8) + pub) else { throw Failure.invalidPairing }
        let signature = try signing.signature(for: pub + Data(identifier.utf8) + accessoryEphemeral)
        let m3 = TLV8.encode([(1, Data(identifier.utf8)), (10, signature)])
        let encrypted = try Self.seal(m3, key: key, nonce: Self.labelNonce("PV-Msg03"))
        let m4 = try await request("POST", "/pair-verify", body: TLV8.encode([(6, Data([3])), (5, encrypted)]))
        guard try Self.field(m4.body, 6) == Data([4]) else { throw Failure.invalidPairing }
        readKey = Self.derive(sharedData, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        writeKey = Self.derive(sharedData, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
    }

    private func timeout() -> Task<Void, Never> {
        let connection = connection
        return Task {
            do { try await Task.sleep(for: .seconds(5)); connection.cancel() } catch {}
        }
    }

    private func send(_ bytes: Data) async throws {
        let timer = timeout()
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func readRaw() async throws -> Data {
        let timer = timeout()
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Failure.closed) }
            }
        }
    }

    private func fill(_ count: Int) async throws {
        while raw.count < count { raw.append(try await readRaw()) }
    }

    private func receive() async throws -> Message {
        while true {
            if let separator = plaintext.range(of: Data([13, 10, 13, 10])) {
                let header = String(decoding: plaintext[..<separator.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let total = separator.upperBound - plaintext.startIndex + length
                if plaintext.count >= total {
                    let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                    guard let status else { throw Failure.invalidHTTP }
                    let body = Data(plaintext[separator.upperBound..<separator.upperBound + length])
                    plaintext.removeFirst(total)
                    return Message(event: header.hasPrefix("EVENT/"), status: status, body: body)
                }
            }
            if let key = readKey {
                try await fill(2)
                let header = Data(raw.prefix(2)), bytes = Array(header)
                let length = Int(bytes[0]) | Int(bytes[1]) << 8
                guard length <= 1024 else { throw Failure.invalidFrame }
                try await fill(length + 18)
                let ciphertext = Data(raw.dropFirst(2).prefix(length + 16))
                raw.removeFirst(length + 18)
                plaintext.append(try Self.open(ciphertext, key: key, nonce: Self.nonce(readCounter), aad: header))
                readCounter += 1
                receivedFrames += 1
                largestFrame = max(largestFrame, length)
            } else { plaintext.append(try await readRaw()) }
        }
    }

    private static func field(_ body: Data, _ tag: UInt8) throws -> Data {
        let items = try TLV8.decode(body)
        guard !items.contains(where: { $0.type == 7 }), let data = items.first(where: { $0.type == tag })?.value else {
            throw Failure.invalidPairing
        }
        return data
    }
    private static func derive(_ data: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: data), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }
    private static func nonce(_ counter: UInt64) -> Data {
        var le = counter.littleEndian
        return Data(repeating: 0, count: 4) + withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func labelNonce(_ label: String) -> Data { Data(repeating: 0, count: 4) + Data(label.utf8) }
    private static func seal(_ data: Data, key: SymmetricKey, nonce: Data, aad: Data = Data()) throws -> Data {
        let sealed = try ChaChaPoly.seal(data, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }
    private static func open(_ data: Data, key: SymmetricKey, nonce: Data, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}
