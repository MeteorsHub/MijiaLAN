// CharacteristicProtocol.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import HAPCrypto
import Logging

// MARK: - CharacteristicProtocol

public struct CharacteristicProtocol: Sendable {
    private let bridge: HAPBridge
    private let pairingStateMachine: PairingStateMachine
    private let pairVerifyStateMachine: PairVerifyStateMachine
    private let pairingStore: any PairingStore
    private let identity: HAPIdentity
    private let onPairingChange: (@Sendable () async -> Void)?
    let connectionID: Int
    private let logger = Logger(label: "hap.characteristic")

    public init(
        bridge: HAPBridge,
        pairingStateMachine: PairingStateMachine,
        pairVerifyStateMachine: PairVerifyStateMachine,
        pairingStore: any PairingStore,
        identity: HAPIdentity,
        connectionID: Int = 0,
        onPairingChange: (@Sendable () async -> Void)? = nil
    ) {
        self.bridge = bridge
        self.pairingStateMachine = pairingStateMachine
        self.pairVerifyStateMachine = pairVerifyStateMachine
        self.pairingStore = pairingStore
        self.identity = identity
        self.connectionID = connectionID
        self.onPairingChange = onPairingChange
    }

    public func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        logger.debug("\(request.method) \(request.path) (\(request.body.count) bytes)")
        let isPairingHandshake = request.method == "POST" && ["/pair-setup", "/pair-verify"].contains(request.path)
        if !isPairingHandshake {
            guard let identifier = await pairVerifyStateMachine.verifiedControllerIdentifier,
                  let verifiedKey = await pairVerifyStateMachine.verifiedControllerPublicKey,
                  await pairVerifyStateMachine.sessionKeys() != nil,
                  try await pairingStore.publicKey(for: identifier) == verifiedKey else {
                let body = try JSONSerialization.data(withJSONObject: ["status": HAPStatus.insufficientAuthorization.rawValue])
                return HTTPResponse(statusCode: 470, statusMessage: "Connection Authorization Required",
                    headers: [("Content-Type", HTTPProtocol.hapJSON)], body: body)
            }
        }
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"):
            return try await handlePairSetup(request)
        case ("POST", "/pair-verify"):
            return try await handlePairVerify(request)
        case ("POST", "/pairings"):
            return try await handlePairings(request)
        case ("GET", "/accessories"):
            return try await handleGetAccessories()
        case ("GET", let path) where path.hasPrefix("/characteristics"):
            return try await handleGetCharacteristics(request)
        case ("PUT", "/characteristics"):
            return try await handlePutCharacteristics(request)
        case ("PUT", "/prepare"):
            return try handlePrepare(request)
        default:
            logger.warning("Unhandled request: \(request.method) \(request.path)")
            return HTTPProtocol.errorResponse(status: 404, message: "Not Found")
        }
    }

    // MARK: - Pair Setup

    private func handlePairSetup(_ request: HTTPRequest) async throws -> HTTPResponse {
        let wasPaired = await pairingStore.isPaired
        guard !wasPaired else { return pairingsErrorResponse(error: .unavailable) }
        let responseData = try await pairingStateMachine.handleRequest(request.body)
        // The first controller is stored: the Bonjour record must say "paired" (sf=0) now. iOS looks the
        // accessory up again to finish adding it, and an accessory still advertising sf=1 counts as reset.
        if !wasPaired, await pairingStore.isPaired {
            logger.info("Pair-setup stored the first controller; advertising as paired")
            await onPairingChange?()
        }
        return HTTPProtocol.okResponse(body: responseData, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - Pair Verify

    private func handlePairVerify(_ request: HTTPRequest) async throws -> HTTPResponse {
        let responseData = try await pairVerifyStateMachine.handleRequest(request.body)
        return HTTPProtocol.okResponse(body: responseData, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - POST /pairings (Add / Remove / List)

    private func handlePairings(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let caller = await pairVerifyStateMachine.verifiedControllerIdentifier,
              try await pairingStore.permissions(for: caller) == 1 else {
            return pairingsErrorResponse(error: .authentication)
        }
        let items = try TLV8.decode(request.body)
        guard let methodData = items.first(where: { $0.type == TLV8Type.method.rawValue })?.value,
              let method = methodData.first else {
            logger.warning("POST /pairings: missing method TLV")
            return pairingsErrorResponse(error: .unknown)
        }

        switch method {
        case 3: return try await handleAddPairing(items)
        case 4: return try await handleRemovePairing(items)
        case 5: return try await handleListPairings()
        default:
            logger.warning("POST /pairings: unknown method \(method)")
            return pairingsErrorResponse(error: .unknown)
        }
    }

    private func handleAddPairing(_ items: [TLV8.Item]) async throws -> HTTPResponse {
        guard let identifierData = items.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let identifier = String(data: identifierData, encoding: .utf8),
              let publicKey = items.first(where: { $0.type == TLV8Type.publicKey.rawValue })?.value else {
            logger.warning("POST /pairings Add: missing identifier or public key")
            return pairingsErrorResponse(error: .unknown)
        }

        guard publicKey.count == 32, !identifier.isEmpty, identifier.utf8.count <= 64,
              let permissionData = items.first(where: { $0.type == TLV8Type.permissions.rawValue })?.value,
              permissionData.count == 1, let permissions = permissionData.first, permissions <= 1 else {
            return pairingsErrorResponse(error: .unknown)
        }
        if let existing = try await pairingStore.publicKey(for: identifier), existing != publicKey {
            return pairingsErrorResponse(error: .unknown)
        }
        logger.info("POST /pairings: Add pairing for '\(identifier)' (permissions: \(permissions))")

        try await pairingStore.store(controllerIdentifier: identifier, publicKey: publicKey, permissions: permissions)
        await onPairingChange?()

        return HTTPProtocol.okResponse(
            body: TLV8.encode([(type: TLV8Type.state.rawValue, value: Data([2]))]),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func handleRemovePairing(_ items: [TLV8.Item]) async throws -> HTTPResponse {
        guard let identifierData = items.first(where: { $0.type == TLV8Type.identifier.rawValue })?.value,
              let identifier = String(data: identifierData, encoding: .utf8) else {
            logger.warning("POST /pairings Remove: missing identifier")
            return pairingsErrorResponse(error: .unknown)
        }

        logger.info("POST /pairings: Remove pairing for '\(identifier)'")
        try await pairingStore.remove(controllerIdentifier: identifier)

        let stillPaired = await pairingStore.isPaired
        logger.debug("POST /pairings: pairing removed. Still paired: \(stillPaired)")
        await onPairingChange?()

        return HTTPProtocol.okResponse(
            body: TLV8.encode([(type: TLV8Type.state.rawValue, value: Data([2]))]),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func handleListPairings() async throws -> HTTPResponse {
        let pairings = try await pairingStore.listPairings()
        logger.debug("POST /pairings: List (\(pairings.count) pairing(s))")

        var tlvItems: [TLV8.Item] = [
            (type: TLV8Type.state.rawValue, value: Data([2])),
        ]
        for (index, pairing) in pairings.enumerated() {
            if index > 0 {
                tlvItems.append((type: TLV8Type.separator.rawValue, value: Data()))
            }
            tlvItems.append((type: TLV8Type.identifier.rawValue, value: Data(pairing.identifier.utf8)))
            tlvItems.append((type: TLV8Type.publicKey.rawValue, value: pairing.publicKey))
            tlvItems.append((type: TLV8Type.permissions.rawValue, value: Data([pairing.permissions])))
        }

        return HTTPProtocol.okResponse(
            body: TLV8.encode(tlvItems),
            contentType: HTTPProtocol.pairingTLV8
        )
    }

    private func pairingsErrorResponse(error: TLV8ErrorCode) -> HTTPResponse {
        let tlv = TLV8.encode([
            (type: TLV8Type.state.rawValue, value: Data([2])),
            (type: TLV8Type.error.rawValue, value: Data([error.rawValue])),
        ])
        return HTTPProtocol.okResponse(body: tlv, contentType: HTTPProtocol.pairingTLV8)
    }

    // MARK: - PUT /prepare (Timed Writes)

    /// HAP timed writes: iOS sends PUT /prepare before writing security-sensitive
    /// characteristics (alarm, lock). We acknowledge the prepare and accept the
    /// subsequent PUT /characteristics unconditionally — as a software bridge we
    /// don't need to enforce the TTL window.
    private func handlePrepare(_ request: HTTPRequest) throws -> HTTPResponse {
        logger.debug("PUT /prepare: \(request.body.count) bytes")
        let json = try JSONSerialization.data(withJSONObject: ["status": 0])
        return HTTPProtocol.okResponse(body: json, contentType: HTTPProtocol.hapJSON)
    }

    // MARK: - GET /accessories

    private func handleGetAccessories() async throws -> HTTPResponse {
        let accessories = await bridge.accessoryDatabase()
        let json = await encodeAccessoryDatabase(accessories)
        logger.debug("GET /accessories (\(accessories.count) accessories)")
        if logger.logLevel <= .trace, let str = String(data: json, encoding: .utf8) {
            logger.trace("GET /accessories body:\n\(str)")
        }
        return HTTPProtocol.okResponse(body: json, contentType: HTTPProtocol.hapJSON)
    }

    // MARK: - GET /characteristics?id=AID.IID,...

    private func handleGetCharacteristics(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let queryStart = request.path.firstIndex(of: "?") else {
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        let query = request.path[request.path.index(after: queryStart)...]
        guard query.hasPrefix("id=") else {
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        let idsString = query.dropFirst(3).split(separator: "&").first ?? ""  // Remove "id="
        let ids = idsString.split(separator: ",")

        var characteristics: [[String: Any]] = []
        for id in ids {
            let parts = id.split(separator: ".")
            guard parts.count == 2,
                  let aid = UInt64(parts[0]),
                  let iid = UInt64(parts[1]) else {
                continue
            }

            var charDict: [String: Any] = ["aid": aid, "iid": iid]
            let status = await bridge.readStatus(aid: aid, iid: iid)
            if status != .success {
                charDict["status"] = status.rawValue
            } else if let value = await bridge.readCharacteristic(aid: aid, iid: iid) {
                charDict["value"] = encodeValue(value)
            } else {
                charDict["status"] = HAPStatus.resourceDoesNotExist.rawValue
            }
            characteristics.append(charDict)
        }

        let responseDict: [String: Any] = ["characteristics": characteristics]
        let json = try JSONSerialization.data(withJSONObject: responseDict)
        let hasError = characteristics.contains { $0["status"] != nil }
        return HTTPResponse(statusCode: hasError ? 207 : 200, statusMessage: hasError ? "Multi-Status" : "OK",
            headers: [("Content-Type", HTTPProtocol.hapJSON)], body: json)
    }

    // MARK: - PUT /characteristics

    private func handlePutCharacteristics(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let characteristics = parsed["characteristics"] as? [[String: Any]] else {
            logger.warning("PUT /characteristics: failed to parse JSON body (\(request.body.count) bytes)")
            return HTTPProtocol.errorResponse(status: 400, message: "Bad Request")
        }

        logger.debug("PUT /characteristics: \(characteristics.count) characteristic(s)")

        var results: [[String: Any]] = []
        for charDict in characteristics {
            guard let aid = (charDict["aid"] as? NSNumber)?.uint64Value,
                  let iid = (charDict["iid"] as? NSNumber)?.uint64Value else {
                return HTTPProtocol.errorResponse(status: 400, message: "Missing aid/iid")
            }
            var status = HAPStatus.success
            do {
                if let raw = charDict["value"] {
                    guard let value = decodeValue(raw) else { throw HAPError.invalidValue }
                    try await bridge.writeCharacteristic(aid: aid, iid: iid, value: value)
                }
                if let ev = charDict["ev"] as? Bool {
                    if ev { await bridge.subscribe(connectionID: connectionID, aid: aid, iid: iid) }
                    else { await bridge.unsubscribe(connectionID: connectionID, aid: aid, iid: iid) }
                }
            } catch {
                switch error as? HAPError {
                case .notFound: status = .resourceDoesNotExist
                case .readOnly: status = .readOnly
                case .writeOnly: status = .writeOnly
                case .outOfRange, .invalidValue: status = .invalidValueInRequest
                case .busy: status = .busy
                case .authenticationFailed: status = .insufficientAuthorization
                default: status = .communicationFailure
                }
            }
            results.append(["aid": aid, "iid": iid, "status": status.rawValue])
        }
        guard results.contains(where: { ($0["status"] as? Int) != 0 }) else { return HTTPProtocol.noContentResponse() }
        let body = try JSONSerialization.data(withJSONObject: ["characteristics": results])
        return HTTPResponse(statusCode: 207, statusMessage: "Multi-Status", headers: [("Content-Type", HTTPProtocol.hapJSON)], body: body)
    }

    // MARK: - JSON Encoding

    private func encodeAccessoryDatabase(_ accessories: [HAPAccessory]) async -> Data {
        var accessoryList: [[String: Any]] = []

        for accessory in accessories {
            var serviceList: [[String: Any]] = []

            for service in accessory.services {
                var charList: [[String: Any]] = []

                for char in service.characteristics {
                    var charDict: [String: Any] = [
                        "iid": char.iid,
                        "type": char.type.rawValue,
                        "perms": char.permissions.map(\.rawValue),
                        "format": char.format.rawValue,
                    ]
                    if await bridge.readStatus(aid: accessory.aid, iid: char.iid) == .success, let value = char.value {
                        charDict["value"] = encodeValue(value)
                    } else if char.isReadable {
                        // Apple HomeKit ADK HAPIPAccessory.c emits null for failed reads in /accessories.
                        // Preserve an unknown value rather than inventing a zero or omitting required metadata.
                        charDict["value"] = NSNull()
                    }
                    if let v = char.minValue { charDict["minValue"] = v }
                    if let v = char.maxValue { charDict["maxValue"] = v }
                    if let v = char.minStep { charDict["minStep"] = v }
                    if let v = char.unit { charDict["unit"] = v.rawValue }
                    if let v = char.validValues { charDict["valid-values"] = v }
                    charList.append(charDict)
                }

                serviceList.append([
                    "iid": service.iid,
                    "type": service.type.rawValue,
                    "characteristics": charList,
                ])
            }

            accessoryList.append([
                "aid": accessory.aid,
                "services": serviceList,
            ])
        }

        let json: [String: Any] = ["accessories": accessoryList]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func encodeValue(_ value: HAPCharacteristicValue) -> Any {
        switch value {
        case .bool(let v): return v
        case .uint8(let v): return v
        case .uint16(let v): return v
        case .uint32(let v): return v
        case .int32(let v): return v
        case .float(let v): return v
        case .string(let v): return v
        case .data(let v): return v.base64EncodedString()
        case .tlv8(let v): return v.base64EncodedString()
        }
    }

    private func decodeValue(_ raw: Any) -> HAPCharacteristicValue? {
        // JSONSerialization returns NSNumber for JSON booleans, integers, and
        // floats.  On Apple platforms, NSNumber(intValue: 1) as? Bool returns
        // true — so Swift's `as? Bool` conflates JSON `1` with JSON `true`.
        // This causes "Arm Away" (uint8 1) to decode as .bool(true), silently
        // breaking write handlers that pattern-match .uint8.
        //
        // Fix: use CFBooleanGetTypeID to distinguish genuine JSON booleans
        // (__NSCFBoolean) from integer NSNumbers (__NSCFNumber).
        #if canImport(Darwin)
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let d = number.doubleValue
            guard d.isFinite, d >= Double(Int32.min), d <= Double(UInt32.max) else { return nil }
            let i = number.intValue
            if d == Double(i) {
                if i >= 0, i <= Int(UInt8.max)  { return .uint8(UInt8(i)) }
                if i >= 0, i <= Int(UInt16.max) { return .uint16(UInt16(i)) }
                if i > Int(Int32.max) { return .uint32(UInt32(i)) }
                return .int32(Int32(i))
            }
            return .float(d)
        }
        #else
        // On Linux, swift-corelibs-foundation maintains the Bool/Int distinction.
        if let v = raw as? Bool { return .bool(v) }
        if let v = raw as? Int {
            if v >= 0, v <= Int(UInt8.max)  { return .uint8(UInt8(v)) }
            if v >= 0, v <= Int(UInt16.max) { return .uint16(UInt16(v)) }
            return .int32(Int32(v))
        }
        if let v = raw as? Double { return .float(v) }
        #endif
        if let v = raw as? String { return .string(v) }
        return nil
    }
}
