// HAPIdentity.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Crypto

public struct HAPIdentity: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(privateKeyData: Data) throws {
        guard privateKeyData.count == 32 else {
            throw HAPCryptoError.invalidKeyData
        }
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    public var publicKeyData: Data {
        Data(privateKey.publicKey.rawRepresentation)
    }

    public var privateKeyData: Data {
        Data(privateKey.rawRepresentation)
    }

    public func sign(_ data: Data) throws -> Data {
        Data(try privateKey.signature(for: data))
    }

    public static func verify(signature: Data, data: Data, publicKey: Data) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: data)
    }
}
