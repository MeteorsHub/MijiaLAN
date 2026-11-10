import Crypto
import Foundation
import HAPTransport
import os
import Testing

struct HAPFrameOrderingTests {
    @Test("Concurrent responses and events submit frames in their authenticated counter order")
    func concurrentWriters() async throws {
        let key = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
        let sender = HAPSession()
        let receiver = HAPSession()
        await sender.establishSession(readKey: key, writeKey: key)
        await receiver.establishSession(readKey: key, writeKey: key)
        let wire = OSAllocatedUnfairLock<[Data]>(initialState: [])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<128 {
                group.addTask {
                    if i.isMultiple(of: 3) { await Task.yield() }
                    try await sender.encryptAndSend(Data(repeating: UInt8(i), count: 80)) { frame in
                        wire.withLock { $0.append(frame) }
                    }
                }
            }
            try await group.waitForAll()
        }
        var buffer = wire.withLock { $0.reduce(into: Data()) { $0.append($1) } }
        var received = Set<UInt8>()
        while let plaintext = try await receiver.decryptFrame(from: &buffer) {
            #expect(plaintext.count == 80)
            let value = try #require(plaintext.first)
            #expect(plaintext.allSatisfy { $0 == value })
            received.insert(value)
        }
        #expect(buffer.isEmpty)
        #expect(received == Set((0..<128).map(UInt8.init)))
    }
}
