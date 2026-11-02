// PairingStore.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation

// MARK: - PairingStore Protocol

public protocol PairingStore: Sendable {
    func store(controllerIdentifier: String, publicKey: Data) async throws
    func publicKey(for controllerIdentifier: String) async throws -> Data?
    func remove(controllerIdentifier: String) async throws
    func listPairings() async throws -> [(identifier: String, publicKey: Data)]
    var isPaired: Bool { get async }
}

// MARK: - InMemoryPairingStore

public actor InMemoryPairingStore: PairingStore {
    private var pairings: [String: Data] = [:]

    public init() {}

    public func store(controllerIdentifier: String, publicKey: Data) {
        pairings[controllerIdentifier] = publicKey
    }

    public func publicKey(for controllerIdentifier: String) -> Data? {
        pairings[controllerIdentifier]
    }

    public func remove(controllerIdentifier: String) {
        pairings.removeValue(forKey: controllerIdentifier)
    }

    public func listPairings() -> [(identifier: String, publicKey: Data)] {
        pairings.map { (identifier: $0.key, publicKey: $0.value) }
    }

    public var isPaired: Bool {
        !pairings.isEmpty
    }
}
