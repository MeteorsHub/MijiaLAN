import CryptoKit
import Foundation
import HAPCore
import HAPCrypto
import HAPTransport
import Testing

enum VerifiedTestController {
    /// Exercise real Pair Verify cryptography; no authentication bypass is compiled into the server.
    static func authenticate(_ verify: PairVerifyStateMachine, store: InMemoryPairingStore, identifier: String = "test-controller", permissions: UInt8 = 1) async throws {
        let signing = HAPIdentity()
        let id = identifier
        await store.store(controllerIdentifier: id, publicKey: signing.publicKeyData, permissions: permissions)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let pub = ephemeral.publicKey.rawRepresentation
        let m2 = try await verify.handleRequest(TLV8.encode([
            (TLV8Type.state.rawValue, Data([1])), (TLV8Type.publicKey.rawValue, pub),
        ]))
        let fields = try TLV8.decode(m2)
        let accessoryKey = try #require(fields.first { $0.type == TLV8Type.publicKey.rawValue }?.value)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: accessoryKey))
        let key = HAPKeyDerivation.derivePairVerifyEncryptionKey(from: shared.withUnsafeBytes { Data($0) })
        let signature = try signing.sign(pub + Data(id.utf8) + accessoryKey)
        let sub = TLV8.encode([(TLV8Type.identifier.rawValue, Data(id.utf8)), (TLV8Type.signature.rawValue, signature)])
        let encrypted = try HAPEncryption.encrypt(plaintext: sub, key: key, nonce: HAPEncryption.buildNonce(from: "PV-Msg03"))
        _ = try await verify.handleRequest(TLV8.encode([(TLV8Type.state.rawValue, Data([3])), (TLV8Type.encryptedData.rawValue, encrypted)]))
        #expect(await verify.sessionKeys() != nil)
    }
}

struct CapabilitySecurityTests {
    actor EventCapture {
        var data: [Data] = []
        func append(_ value: Data) { data.append(value) }
    }
    @Test("Momentary actions notify their false state even when cached false already")
    func actionResetEvent() async throws {
        let info = AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1")
        let bridge = HAPBridge(info: info), capture = EventCapture()
        await bridge.addAccessory(info: info, services: [HAPService(iid: 8, type: .switch, characteristics: [
            HAPCharacteristic(iid: 9, type: .on, value: .bool(false), permissions: [.read, .write, .notify], format: .bool),
        ])], aid: 2, servicesHaveStableIIDs: true)
        await bridge.subscribe(connectionID: 42, aid: 2, iid: 9)
        await bridge.setCharacteristicChangeHandler { subscribers, data in
            #expect(subscribers == [42]); await capture.append(data)
        }
        await bridge.updateCharacteristic(aid: 2, iid: 9, value: .bool(false), forceNotify: true)
        for _ in 0..<20 {
            if await !capture.data.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await capture.data.count == 1)
        #expect(await capture.data.first.map { String(decoding: $0, as: UTF8.self).contains("false") } == true)
    }
    @Test("All operational paths reject unverified and revoked controllers")
    func authentication() async throws {
        let identity = HAPIdentity()
        let store = InMemoryPairingStore()
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "AA:BB:CC:DD:EE:FF")
        let bridge = HAPBridge(info: AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1"))
        let handler = CharacteristicProtocol(bridge: bridge,
            pairingStateMachine: PairingStateMachine(setupCode: "031-45-154", identity: identity, pairingStore: store, deviceID: "AA:BB:CC:DD:EE:FF"),
            pairVerifyStateMachine: verify, pairingStore: store, identity: identity)
        let paths = [("GET", "/accessories"), ("GET", "/characteristics?id=1.2"), ("PUT", "/characteristics"), ("PUT", "/prepare"), ("POST", "/pairings")]
        for (method, path) in paths {
            #expect(try await handler.handleRequest(HTTPRequest(method: method, path: path)).statusCode == 470)
        }
        try await VerifiedTestController.authenticate(verify, store: store)
        #expect(try await handler.handleRequest(HTTPRequest(method: "GET", path: "/accessories")).statusCode == 200)
        await store.remove(controllerIdentifier: "test-controller")
        #expect(try await handler.handleRequest(HTTPRequest(method: "GET", path: "/accessories")).statusCode == 470)
    }

    @Test("Failed writes preserve confirmed values and return per-characteristic HAP errors")
    func errorsAndCache() async throws {
        let identity = HAPIdentity(), store = InMemoryPairingStore()
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "test")
        let info = AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1")
        let bridge = HAPBridge(info: info)
        await bridge.addAccessory(info: info, services: [HAPService(iid: 8, type: .switch, characteristics: [
            HAPCharacteristic(iid: 9, type: .on, value: .bool(false), permissions: [.read, .write, .notify], format: .bool),
        ])], aid: 2, servicesHaveStableIIDs: true)
        await bridge.registerWriteHandler(aid: 2, iid: 9) { _ in throw HAPError.unavailable }
        let handler = CharacteristicProtocol(bridge: bridge,
            pairingStateMachine: PairingStateMachine(setupCode: "031-45-154", identity: identity, pairingStore: store, deviceID: "test"),
            pairVerifyStateMachine: verify, pairingStore: store, identity: identity)
        try await VerifiedTestController.authenticate(verify, store: store)
        let response = try await handler.handleRequest(HTTPRequest(method: "PUT", path: "/characteristics",
            body: Data(#"{"characteristics":[{"aid":2,"iid":9,"value":true}]}"#.utf8)))
        #expect(response.statusCode == 207)
        #expect(String(decoding: response.body, as: UTF8.self).contains("-70402"))
        #expect(await bridge.readCharacteristic(aid: 2, iid: 9) == .bool(false))
        await bridge.setReadStatus(aid: 2, iid: 9, status: .communicationFailure)
        let read = try await handler.handleRequest(HTTPRequest(method: "GET", path: "/characteristics?id=2.9&meta=1"))
        #expect(read.statusCode == 207)
        #expect(!String(decoding: read.body, as: UTF8.self).contains("value"))
        let database = try await handler.handleRequest(HTTPRequest(method: "GET", path: "/accessories"))
        let json = try #require(JSONSerialization.jsonObject(with: database.body) as? [String: Any])
        let accessories = try #require(json["accessories"] as? [[String: Any]])
        let bridged = try #require(accessories.first { $0["aid"] as? Int == 2 })
        let chars = (bridged["services"] as? [[String: Any]] ?? []).flatMap { $0["characteristics"] as? [[String: Any]] ?? [] }
        #expect(chars.first { $0["iid"] as? Int == 9 }?["value"] is NSNull)
    }
}
