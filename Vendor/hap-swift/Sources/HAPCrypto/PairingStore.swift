// PairingStore.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation

// MARK: - PairingStore Protocol

public protocol PairingStore: Sendable {
    /// Only Pair Setup uses this overload to create the initial administrator.
    func store(controllerIdentifier: String, publicKey: Data) async throws
    func store(controllerIdentifier: String, publicKey: Data, permissions: UInt8) async throws
    func permissions(for controllerIdentifier: String) async throws -> UInt8?
    func publicKey(for controllerIdentifier: String) async throws -> Data?
    func remove(controllerIdentifier: String) async throws
    func listPairings() async throws -> [(identifier: String, publicKey: Data, permissions: UInt8)]
    var isPaired: Bool { get async }
}

// MARK: - InMemoryPairingStore

public actor InMemoryPairingStore: PairingStore {
    private var pairings: [String: Data] = [:]
    private var roles: [String: UInt8] = [:]

    public init() {}

    public func store(controllerIdentifier: String, publicKey: Data, permissions: UInt8) {
        pairings[controllerIdentifier] = publicKey
        roles[controllerIdentifier] = permissions
        if !roles.values.contains(1) { pairings = [:]; roles = [:] }
    }

    public func store(controllerIdentifier: String, publicKey: Data) {
        store(controllerIdentifier: controllerIdentifier, publicKey: publicKey, permissions: 1)
    }

    public func permissions(for controllerIdentifier: String) -> UInt8? { roles[controllerIdentifier] }

    public func publicKey(for controllerIdentifier: String) -> Data? {
        pairings[controllerIdentifier]
    }

    public func remove(controllerIdentifier: String) {
        pairings.removeValue(forKey: controllerIdentifier)
        roles.removeValue(forKey: controllerIdentifier)
        if !roles.values.contains(1) { pairings = [:]; roles = [:] }
    }

    public func listPairings() -> [(identifier: String, publicKey: Data, permissions: UInt8)] {
        pairings.map { (identifier: $0.key, publicKey: $0.value, permissions: roles[$0.key] ?? 0) }
    }

    public var isPaired: Bool {
        !pairings.isEmpty
    }
}
