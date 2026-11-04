import CryptoKit
import Foundation
import HAPCore
import HAPCrypto
import HAPTransport
import Testing
@testable import MijiaHomeKitBridge

struct HomeKitSecurityHardeningTests {
    @Test("Malformed HTTP lengths and framing are rejected before slicing", arguments: [
        "Content-Length: -1", "Content-Length: +1", "Content-Length: 9223372036854775807",
        "Content-Length: 9999999999999999999999999", "Content-Length: garbage",
        "Content-Length: 1\r\nContent-Length: 1", "Transfer-Encoding: chunked",
        "Content-Length: \(HTTPProtocol.maxBodyBytes + 1)",
    ])
    func malformed(_ header: String) {
        let request = Data("POST /pair-setup HTTP/1.1\r\n\(header)\r\n\r\n".utf8)
        #expect(HTTPProtocol.requestBoundary(in: request) == .invalid)
        #expect(HTTPProtocol.parseRequest(from: request) == nil)
        #expect(HTTPProtocol.requestLength(in: request) == nil)
    }

    @Test("Oversized headers fail, bounded partial bodies wait, and pipelined bytes stay separate")
    func boundedFraming() throws {
        #expect(HTTPProtocol.requestBoundary(in: Data(repeating: 65, count: HTTPProtocol.maxHeaderBytes + 1)) == .invalid)
        let header = Data("POST /pair-setup HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
        #expect(HTTPProtocol.requestBoundary(in: header + [0, 1]) == .incomplete)
        let complete = header + Data([0, 1, 2, 3])
        let pipelined = complete + Data("GET /accessories HTTP/1.1\r\n\r\n".utf8)
        #expect(HTTPProtocol.requestLength(in: pipelined) == complete.count)
        #expect(HTTPProtocol.parseRequest(from: pipelined)?.body == Data([0, 1, 2, 3]))
        let slice = Data([255]) + complete
        #expect(HTTPProtocol.parseRequest(from: Data(slice.dropFirst()))?.body == Data([0, 1, 2, 3]))
    }

    @Test("Encrypted frames larger than the HAP limit are rejected immediately")
    func largeEncryptedFrame() async throws {
        let session = HAPSession()
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        await session.establishSession(readKey: key, writeKey: key)
        var bytes = Data([255, 255])
        await #expect(throws: (any Error).self) { _ = try await session.decryptFrame(from: &bytes) }
    }

    private func handler(_ store: InMemoryPairingStore, _ verify: PairVerifyStateMachine, _ identity: HAPIdentity) -> CharacteristicProtocol {
        let bridge = HAPBridge(info: AccessoryInfo(name: "test", manufacturer: "test", model: "test", serialNumber: "test", firmwareRevision: "1"))
        return CharacteristicProtocol(bridge: bridge,
            pairingStateMachine: PairingStateMachine(setupCode: "031-45-154", identity: identity, pairingStore: store, deviceID: "test"),
            pairVerifyStateMachine: verify, pairingStore: store, identity: identity)
    }

    @Test("Regular controllers retain device access but cannot list, add or revoke pairings")
    func regularController() async throws {
        let store = InMemoryPairingStore(), identity = HAPIdentity()
        await store.store(controllerIdentifier: "owner", publicKey: HAPIdentity().publicKeyData)
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "test")
        try await VerifiedTestController.authenticate(verify, store: store, identifier: "user", permissions: 0)
        let proto = handler(store, verify, identity)
        #expect(try await proto.handleRequest(HTTPRequest(method: "GET", path: "/accessories")).statusCode == 200)
        for method in [UInt8(3), 4, 5] {
            let data = TLV8.encode([(TLV8Type.method.rawValue, Data([method])),
                (TLV8Type.identifier.rawValue, Data("owner".utf8)),
                (TLV8Type.publicKey.rawValue, HAPIdentity().publicKeyData), (TLV8Type.permissions.rawValue, Data([1]))])
            let response = try await proto.handleRequest(HTTPRequest(method: "POST", path: "/pairings", body: data))
            #expect(try TLV8.decode(response.body).contains { $0.type == TLV8Type.error.rawValue && $0.value == Data([TLV8ErrorCode.authentication.rawValue]) })
        }
        #expect(await store.permissions(for: "user") == 0)
        #expect(await store.permissions(for: "owner") == 1)
        await store.remove(controllerIdentifier: "owner")
        #expect(await store.isPaired == false)
        #expect(try await proto.handleRequest(HTTPRequest(method: "GET", path: "/accessories")).statusCode == 470)
    }

    @Test("Administrators store user permissions and cannot silently replace an existing public key")
    func administrator() async throws {
        let store = InMemoryPairingStore(), identity = HAPIdentity()
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: store, deviceID: "test")
        try await VerifiedTestController.authenticate(verify, store: store)
        let proto = handler(store, verify, identity)
        let key = HAPIdentity().publicKeyData
        func request(_ key: Data, permissions: UInt8) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/pairings", body: TLV8.encode([
                (TLV8Type.method.rawValue, Data([3])), (TLV8Type.identifier.rawValue, Data("new-user".utf8)),
                (TLV8Type.publicKey.rawValue, key), (TLV8Type.permissions.rawValue, Data([permissions])),
            ]))
        }
        _ = try await proto.handleRequest(request(key, permissions: 0))
        #expect(await store.permissions(for: "new-user") == 0)
        let list = try await proto.handleRequest(HTTPRequest(method: "POST", path: "/pairings",
            body: TLV8.encode([(TLV8Type.method.rawValue, Data([5]))])))
        #expect(try TLV8.decode(list.body).contains { $0.type == TLV8Type.permissions.rawValue && $0.value == Data([0]) })
        let denied = try await proto.handleRequest(request(HAPIdentity().publicKeyData, permissions: 1))
        #expect(try TLV8.decode(denied.body).contains { $0.type == TLV8Type.error.rawValue })
        #expect(await store.publicKey(for: "new-user") == key)
        #expect(await store.permissions(for: "new-user") == 0)
    }

    @Test("Concurrent pairing updates do not restore revoked users or discard another saved pairing")
    func concurrentPersistence() async throws {
        let store = HomeKitBridgePairingStore(pairings: ["owner": HAPIdentity().publicKeyData],
            persist: { _, _ in await Task.yield(); return true })
        let key = HAPIdentity().publicKeyData
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { try await store.store(controllerIdentifier: "user-\(index)", publicKey: key, permissions: 0) }
            }
            try await group.waitForAll()
        }
        #expect(await store.listPairings().count == 21)
        try await store.remove(controllerIdentifier: "owner")
        #expect(await store.isPaired == false)
    }

    @Test("Roles survive vault round trips and failed persistence does not update the live role")
    func persistence() async throws {
        let keys = ["owner": HAPIdentity().publicKeyData, "user": HAPIdentity().publicKeyData]
        var secrets = HomeKitBridgeSecrets.generate()
        secrets.pairings = keys; secrets.pairingPermissions = ["owner": 1, "user": 0]
        let encodedData = try #require(secrets.encoded())
        let decoded = try #require(HomeKitBridgeSecrets.decode(encodedData))
        let store = HomeKitBridgePairingStore(pairings: decoded.pairings, permissions: decoded.pairingPermissions, persist: { _, _ in false })
        #expect(await store.permissions(for: "user") == 0)
        await #expect(throws: (any Error).self) { try await store.store(controllerIdentifier: "user", publicKey: keys["user"]!, permissions: 1) }
        #expect(await store.permissions(for: "user") == 0)
        let legacy = HomeKitBridgePairingStore(pairings: keys, persist: { _, _ in true })
        #expect(await legacy.permissions(for: "owner") == 1)
        #expect(await legacy.permissions(for: "user") == 1)
    }
}
