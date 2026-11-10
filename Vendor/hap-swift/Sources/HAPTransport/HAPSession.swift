// HAPSession.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto
import HAPCrypto

// MARK: - HAPSession

public actor HAPSession {
    private var readKey: SymmetricKey?
    private var writeKey: SymmetricKey?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    public var isEncrypted: Bool { readKey != nil }

    public init() {}

    public func establishSession(readKey: SymmetricKey, writeKey: SymmetricKey) {
        self.readKey = readKey
        self.writeKey = writeKey
        self.readCounter = 0
        self.writeCounter = 0
    }

    // MARK: - Encrypt

    /// Encrypts plaintext into a HAP session frame.
    ///
    /// HAP spec §5.5.5 frame layout:
    /// ```
    /// [2-byte LE: plaintext length N] [N bytes: ChaCha20 ciphertext] [16 bytes: Poly1305 tag]
    /// ```
    /// The 2-byte length header is used as the AAD (additional authenticated data) for
    /// ChaCha20-Poly1305, so it is integrity-protected alongside the ciphertext.
    ///
    /// A frame carries at most `maxFramePlaintext` bytes and iOS drops the connection on a
    /// larger one, so longer plaintext (the accessory list of a bridge) goes out as
    /// consecutive frames.
    public func encrypt(_ plaintext: Data) throws -> Data {
        guard writeKey != nil else { throw HAPCryptoError.encryptionFailed }
        var output = Data()
        var offset = plaintext.startIndex
        repeat {
            let end = min(offset + Self.maxFramePlaintext, plaintext.endIndex)
            output.append(try encryptFrame(Data(plaintext[offset ..< end])))
            offset = end
        } while offset < plaintext.endIndex
        return output
    }

    /// Reserve frame counters and submit their bytes in one actor-isolated operation.
    /// Returning ciphertext to competing response/event tasks lets a later counter
    /// reach TCP first, which makes the peer's next authentication check fail.
    public func encryptAndSend(_ plaintext: Data, send: @Sendable (Data) -> Void) throws {
        send(try encrypt(plaintext))
    }

    /// HAP spec §6.5.2: the plaintext of one frame is at most 1024 bytes.
    public static let maxFramePlaintext = 1024

    private func encryptFrame(_ plaintext: Data) throws -> Data {
        guard let writeKey else { throw HAPCryptoError.encryptionFailed }

        // Build 2-byte LE PLAINTEXT length — this is both the frame header and the AAD.
        let plaintextLength = UInt16(plaintext.count)
        var aad = Data(count: 2)
        aad[0] = UInt8(plaintextLength & 0xFF)
        aad[1] = UInt8(plaintextLength >> 8)

        let nonce = HAPEncryption.buildNonce(counter: writeCounter)
        let ciphertextAndTag = try HAPEncryption.encrypt(plaintext: plaintext, key: writeKey, nonce: nonce, aad: aad)

        // Frame: [2-byte header (AAD)] + [ciphertext + 16-byte tag]
        var frame = aad
        frame.append(ciphertextAndTag)

        self.writeCounter += 1
        return frame
    }

    // MARK: - Decrypt

    /// Attempts to decrypt a complete HAP session frame from the buffer.
    ///
    /// Returns decrypted plaintext if a complete frame is available, `nil` if more data is needed.
    /// Throws `HAPCryptoError.decryptionFailed` if the frame is present but authentication fails.
    ///
    /// HAP spec §5.5.5: the 2-byte LE **plaintext** length is the frame header and is used as AAD.
    /// Total frame size = 2 (header) + N (ciphertext) + 16 (auth tag).
    public func decryptFrame(from buffer: inout Data) throws -> Data? {
        guard let readKey else { throw HAPCryptoError.decryptionFailed }
        guard buffer.count >= 2 else { return nil }

        // Header encodes PLAINTEXT length N; ciphertext occupies N bytes, auth tag 16 bytes.
        let plaintextLength = Int(buffer[buffer.startIndex]) | (Int(buffer[buffer.startIndex + 1]) << 8)
        guard plaintextLength <= 1024 else { throw HAPCryptoError.decryptionFailed }
        let totalFrameSize = 2 + plaintextLength + 16

        guard buffer.count >= totalFrameSize else { return nil }  // incomplete frame — wait

        let aad = Data(buffer[buffer.startIndex ..< buffer.startIndex + 2])
        let ciphertextAndTag = Data(buffer[buffer.startIndex + 2 ..< buffer.startIndex + totalFrameSize])

        let nonce = HAPEncryption.buildNonce(counter: readCounter)
        let plaintext = try HAPEncryption.decrypt(ciphertext: ciphertextAndTag, key: readKey, nonce: nonce, aad: aad)

        self.readCounter += 1
        buffer.removeFirst(totalFrameSize)

        return plaintext
    }
}
