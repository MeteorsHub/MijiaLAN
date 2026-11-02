// LinuxHAPService.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Logging
import MDNSLinux
import HAPCore
import HAPCrypto
import HAPTransport

// MARK: - LinuxHAPService

/// High-level HAP service for Linux. Combines SwiftNIO TCP server, mDNS advertisement, and bridge management.
public actor LinuxHAPService {
    private let bridge: HAPBridge
    private let server: LinuxTCPServer
    private let advertiser: HAPAdvertiser
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    private let logger: Logger

    public init(
        info: AccessoryInfo,
        setupCode: String,
        deviceID: String,
        identity: HAPIdentity? = nil,
        pairingStore: (any PairingStore)? = nil,
        logger: Logger = Logger(label: "hap.linux")
    ) {
        let identity = identity ?? HAPIdentity()
        let pairingStore = pairingStore ?? InMemoryPairingStore()
        let bridge = HAPBridge(info: info)
        let discovery = LinuxServiceDiscovery(logger: logger)

        self.bridge = bridge
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.logger = logger
        self.advertiser = HAPAdvertiser(discovery: discovery, deviceID: deviceID)
        self.server = LinuxTCPServer(
            bridge: bridge,
            setupCode: setupCode,
            identity: identity,
            pairingStore: pairingStore,
            deviceID: deviceID,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    public func start(port: UInt16 = 0) async throws {
        try await server.start(port: port)
        let actualPort = server.port

        let isPaired = await pairingStore.isPaired
        try await advertiser.advertise(
            name: await bridge.accessoryDatabase().first?.name ?? "HAP Bridge",
            port: actualPort,
            category: await bridge.category,
            isPaired: isPaired
        )

        logger.info("HAP service started on port \(actualPort), device ID: \(deviceID)")
    }

    public func stop() async {
        await advertiser.stopAdvertising()
        await server.stop()
        logger.info("HAP service stopped")
    }

    // MARK: - Accessory Management

    @discardableResult
    public func addAccessory(info: AccessoryInfo, services: [HAPService]) async -> UInt64 {
        await bridge.addAccessory(info: info, services: services)
    }

    public func removeAccessory(aid: UInt64) async {
        await bridge.removeAccessory(aid: aid)
    }
}
