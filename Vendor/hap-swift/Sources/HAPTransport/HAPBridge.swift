// HAPBridge.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation
import HAPCore
import Logging

// MARK: - HAPBridge

public actor HAPBridge {
    private let logger = Logger(label: "hap.bridge")
    private var accessories: [UInt64: HAPAccessory] = [:]
    private var nextAID: UInt64 = 2
    private var writeHandlers: [String: @Sendable (HAPCharacteristicValue) async throws -> Void] = [:]
    public let category: HAPCategory

    // MARK: - Configuration number (c#)

    /// HAP configuration number — incremented when the accessory database changes.
    /// Persisted across restarts so paired iOS devices know to re-read /accessories.
    private var configurationNumber: Int = 1

    /// The current configuration number for mDNS advertisement.
    public var currentConfigurationNumber: Int { configurationNumber }

    /// Restore a previously persisted configuration number (call before adding accessories).
    public func restoreConfigurationNumber(_ n: Int) {
        configurationNumber = max(1, n)
    }

    /// Reserve an AID so auto-assignment skips it.
    ///
    /// Call before provisioning to prevent new accessories from being
    /// auto-assigned AIDs that belong to existing device map entries.
    public func reserveAID(_ aid: UInt64) {
        if aid >= nextAID {
            nextAID = aid + 1
        }
    }

    // MARK: - Accessory change handlers

    /// Callbacks fired when the accessory database changes (add/remove).
    /// Parameter is the new configuration number.
    private var accessoryChangeHandlers: [@Sendable (Int) async -> Void] = []

    /// Register a handler called when accessories are added or removed.
    /// Multiple handlers can be registered (e.g., re-advertisement + persistence).
    public func addAccessoryChangeHandler(_ handler: @escaping @Sendable (Int) async -> Void) {
        accessoryChangeHandlers.append(handler)
    }

    // MARK: - Batch updates

    private var isBatching = false
    private var batchDirty = false

    /// Begin a batch update — suppresses c# increment and change notifications
    /// until ``endBatchUpdate()`` is called.
    public func beginBatchUpdate() {
        isBatching = true
        batchDirty = false
    }

    /// End a batch update — increments c# once and fires change handlers if
    /// any accessories were added or removed during the batch.
    public func endBatchUpdate() async {
        isBatching = false
        guard batchDirty else { return }
        batchDirty = false
        configurationNumber += 1
        await notifyAccessoryChange()
    }

    private func incrementAndNotify() async {
        if isBatching {
            batchDirty = true
        } else {
            configurationNumber += 1
            await notifyAccessoryChange()
        }
    }

    private func notifyAccessoryChange() async {
        let cn = configurationNumber
        for handler in accessoryChangeHandlers {
            await handler(cn)
        }
    }

    // MARK: - Event subscriptions

    /// Maps "aid.iid" → set of connection IDs that subscribed to events.
    private var subscriptions: [String: Set<Int>] = [:]

    /// Called when a characteristic value changes and subscribers exist.
    /// Parameters: set of connection IDs, serialised EVENT/1.0 payload (pre-JSON,
    /// needs encryption per-connection).
    private var onCharacteristicChange: (@Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void)?
    private var notificationTail: Task<Void, Never>?

    private struct WriteOrigin: Sendable {
        let bridgeID: ObjectIdentifier
        let token = UUID()
    }

    private struct PendingWrite {
        let connectionID: Int
        var knownValue: HAPCharacteristicValue?
    }

    // A task-local follows awaited adapters and their child tasks without mixing concurrent writers.
    // Tokens also bound the lifetime: a child task that outlives its write must not mute later events.
    @TaskLocal private static var writeOrigin: WriteOrigin?
    private var pendingWrites: [String: [UUID: PendingWrite]] = [:]

    /// Set the handler called when a subscribed characteristic value changes.
    public func setCharacteristicChangeHandler(
        _ handler: @escaping @Sendable (_ subscribers: Set<Int>, _ eventData: Data) async -> Void
    ) {
        onCharacteristicChange = handler
    }

    private static func handlerKey(aid: UInt64, iid: UInt64) -> String {
        "\(aid).\(iid)"
    }

    public init(info: AccessoryInfo, category: HAPCategory = .bridge) {
        self.category = category

        // Bridge itself is AID=1
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        let protocolService = HAPService.protocolInformation(startIID: 8)
        let bridge = HAPAccessory(aid: 1, services: [infoService, protocolService])
        self.accessories[1] = bridge
    }

    // MARK: - Accessory Management

    /// Add an accessory to the bridge.
    ///
    /// - Parameters:
    ///   - info: Accessory metadata (name, manufacturer, etc.).
    ///   - services: HAP services to expose (e.g., lightbulb, motion sensor).
    ///   - aid: Explicit accessory ID. When `nil`, auto-assigns the next available AID.
    ///          Use explicit AIDs for AID stability across restarts.
    ///   - appendingCharacteristicTypes: New metadata allocated after all existing IIDs, preserving service
    ///          and control identifiers when upgrading an already paired accessory.
    /// - Returns: The assigned accessory ID.
    @discardableResult
    public func addAccessory(
        info: AccessoryInfo, services: [HAPService], aid: UInt64? = nil,
        appendingCharacteristicTypes: Set<HAPCharacteristicType> = [],
        servicesHaveStableIIDs: Bool = false
    ) async -> UInt64 {
        let aid: UInt64 = if let explicit = aid {
            explicit
        } else {
            { let a = nextAID; nextAID += 1; return a }()
        }

        // Keep nextAID ahead of any explicit AID to prevent collisions.
        if aid >= nextAID {
            nextAID = aid + 1
        }

        guard aid != 1 else {
            logger.warning("Cannot add accessory with AID=1 (reserved for bridge)")
            return aid
        }

        if accessories[aid] != nil {
            logger.warning("Replacing existing accessory at AID=\(aid)")
        }

        // Build accessory information service
        let infoService = HAPService.accessoryInformation(
            name: info.name,
            manufacturer: info.manufacturer,
            model: info.model,
            serialNumber: info.serialNumber,
            firmwareRevision: info.firmwareRevision,
            startIID: 1
        )

        // Assign IIDs to additional services.
        // Layout: infoService.iid=1, its N chars at 2..N+1,
        //         then service2.iid=N+2, its chars at N+3..., etc.
        var allServices = [infoService]
        var nextIID: UInt64 = infoService.iid + UInt64(infoService.characteristics.count) + 1
        func numbered(_ char: HAPCharacteristic) -> HAPCharacteristic {
            defer { nextIID += 1 }
            return HAPCharacteristic(
                iid: nextIID, type: char.type, value: char.value, permissions: char.permissions, format: char.format,
                minValue: char.minValue, maxValue: char.maxValue, minStep: char.minStep,
                unit: char.unit, validValues: char.validValues
            )
        }
        for service in services {
            let serviceIID = nextIID
            nextIID += 1
            var updatedChars: [HAPCharacteristic] = []
            for char in service.characteristics where !appendingCharacteristicTypes.contains(char.type) {
                updatedChars.append(numbered(char))
            }
            allServices.append(HAPService(iid: serviceIID, type: service.type, characteristics: updatedChars, isPrimary: service.isPrimary))
        }
        for (index, service) in services.enumerated() {
            for char in service.characteristics where appendingCharacteristicTypes.contains(char.type) {
                allServices[index + 1].characteristics.append(numbered(char))
            }
        }

        var accessory = HAPAccessory(aid: aid, services: servicesHaveStableIIDs ? [infoService] + services : allServices)
        for si in accessory.services.indices {
            for ci in accessory.services[si].characteristics.indices {
                let c = accessory.services[si].characteristics[ci]
                let checked = c.value.flatMap { c.normalizedRead($0) }
                accessory.services[si].characteristics[ci].value = checked
                if c.isReadable {
                    readStatuses[Self.handlerKey(aid: aid, iid: c.iid)] = checked == nil ? .communicationFailure : .success
                }
            }
        }
        accessories[aid] = accessory

        await incrementAndNotify()

        return aid
    }

    /// Remove an accessory from the bridge.
    ///
    /// Also cleans up associated write handlers and event subscriptions.
    /// The bridge accessory (AID=1) cannot be removed.
    public func removeAccessory(aid: UInt64) async {
        guard aid != 1 else { return }  // Cannot remove bridge
        guard accessories.removeValue(forKey: aid) != nil else { return }
        logger.warning("Removed accessory AID=\(aid). Remaining: \(accessories.keys.sorted())")

        // Clean up write handlers for this accessory
        let aidPrefix = "\(aid)."
        writeHandlers = writeHandlers.filter { !$0.key.hasPrefix(aidPrefix) }
        managedValues = managedValues.filter { !$0.hasPrefix(aidPrefix) }
        readStatuses = readStatuses.filter { !$0.key.hasPrefix(aidPrefix) }

        // Clean up event subscriptions for this accessory
        subscriptions = subscriptions.filter { !$0.key.hasPrefix(aidPrefix) }

        await incrementAndNotify()
    }

    // MARK: - Accessory Database

    public func accessoryDatabase() -> [HAPAccessory] {
        accessories.values.sorted { $0.aid < $1.aid }
    }

    // MARK: - Characteristic Access

    private var managedValues: Set<String> = []
    private var readStatuses: [String: HAPStatus] = [:]
    public func setReadStatus(aid: UInt64, iid: UInt64, status: HAPStatus) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        let previous = readStatuses[key] ?? .success
        readStatuses[key] = status
        if status != .success && status != previous {
            notifySubscribers(aid: aid, iid: iid, value: nil, status: status)
        }
    }
    public func readStatus(aid: UInt64, iid: UInt64) -> HAPStatus {
        readStatuses[Self.handlerKey(aid: aid, iid: iid)] ?? .success
    }

    public func readCharacteristic(aid: UInt64, iid: UInt64) -> HAPCharacteristicValue? {
        guard let accessory = accessories[aid] else { return nil }
        for service in accessory.services {
            for characteristic in service.characteristics where characteristic.iid == iid {
                return characteristic.value
            }
        }
        return nil
    }

    func characteristicType(aid: UInt64, iid: UInt64) -> HAPCharacteristicType? {
        accessories[aid]?.services.lazy.flatMap(\.characteristics).first { $0.iid == iid }?.type
    }

    public func writeCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue,
                                    originatingConnectionID: Int? = nil) async throws {
        guard var accessory = accessories[aid] else {
            throw HAPError.notFound
        }

        var normalizedValue: HAPCharacteristicValue?
        var found = false
        for serviceIndex in 0 ..< accessory.services.count {
            for charIndex in 0 ..< accessory.services[serviceIndex].characteristics.count {
                if accessory.services[serviceIndex].characteristics[charIndex].iid == iid {
                    guard accessory.services[serviceIndex].characteristics[charIndex].isWritable else {
                        throw HAPError.readOnly
                    }
                    let char = accessory.services[serviceIndex].characteristics[charIndex]
                    guard let normalized = char.normalizedWrite(value) else { throw HAPError.invalidValue }
                    normalizedValue = normalized
                    accessory.services[serviceIndex].characteristics[charIndex].value = normalized
                    found = true
                    break
                }
            }
            if found { break }
        }

        guard found, let normalizedValue else { throw HAPError.notFound }
        let key = Self.handlerKey(aid: aid, iid: iid)
        let origin = originatingConnectionID.map { connectionID in
            let origin = WriteOrigin(bridgeID: ObjectIdentifier(self))
            pendingWrites[key, default: [:]][origin.token] = PendingWrite(connectionID: connectionID, knownValue: normalizedValue)
            return origin
        }
        defer {
            if let origin {
                pendingWrites[key]?[origin.token] = nil
                if pendingWrites[key]?.isEmpty == true { pendingWrites[key] = nil }
            }
        }
        try await Self.$writeOrigin.withValue(origin) {
            if let handler = writeHandlers[key] {
                try await handler(normalizedValue)
            }
            // Handlers that perform a real device readback own the resulting value. A failed write never changes cache.
            if !managedValues.contains(key) {
                updateCharacteristic(aid: aid, iid: iid, value: normalizedValue)
            }
        }
    }

    // MARK: - Write Handlers

    public func registerWriteHandler(
        aid: UInt64,
        iid: UInt64,
        managesValue: Bool = false,
        handler: @escaping @Sendable (HAPCharacteristicValue) async throws -> Void
    ) {
        writeHandlers[Self.handlerKey(aid: aid, iid: iid)] = handler
        if managesValue { managedValues.insert(Self.handlerKey(aid: aid, iid: iid)) }
    }

    // MARK: - Characteristic Updates

    public func updateCharacteristic(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue, forceNotify: Bool = false) {
        guard var accessory = accessories[aid] else { return }

        for serviceIndex in 0 ..< accessory.services.count {
            for charIndex in 0 ..< accessory.services[serviceIndex].characteristics.count {
                if accessory.services[serviceIndex].characteristics[charIndex].iid == iid {
                    let char = accessory.services[serviceIndex].characteristics[charIndex]
                    let bounded: HAPCharacteristicValue
                    if case .string(let text) = value,
                       ["23", "20", "21", "30", "52", "E3"].contains(char.type.rawValue) {
                        bounded = .string(HAPString.bounded(text))
                    } else { bounded = value }
                    guard let normalized = char.normalizedRead(bounded) else {
                        setReadStatus(aid: aid, iid: iid, status: .communicationFailure)
                        return
                    }
                    let recovered = readStatus(aid: aid, iid: iid) != .success
                    setReadStatus(aid: aid, iid: iid, status: .success)
                    let oldValue = char.value
                    accessory.services[serviceIndex].characteristics[charIndex].value = normalized
                    accessories[aid] = accessory

                    // Notify subscribers if value changed
                    if forceNotify || recovered || oldValue != normalized {
                        notifySubscribers(aid: aid, iid: iid, value: normalized, includeOrigin: forceNotify || recovered)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Event Subscriptions

    public func subscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        guard subscriptions[key, default: []].insert(connectionID).inserted else { return }
        logger.debug("Event subscribe: connection \(connectionID) → aid=\(aid) iid=\(iid)")
        let status = readStatus(aid: aid, iid: iid)
        let event = Self.buildEventPayload(aid: aid, iid: iid,
            value: status == .success ? readCharacteristic(aid: aid, iid: iid) : nil, status: status)
        enqueueNotification(subscribers: [connectionID], eventData: event)
    }

    public func subscriptionStatus(aid: UInt64, iid: UInt64) -> HAPStatus {
        guard let c = accessories[aid]?.services.flatMap(\.characteristics).first(where: { $0.iid == iid }) else {
            return .resourceDoesNotExist
        }
        return c.supportsNotification ? .success : .notificationNotSupported
    }

    public func unsubscribe(connectionID: Int, aid: UInt64, iid: UInt64) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        subscriptions[key]?.remove(connectionID)
    }

    /// Remove all subscriptions for a disconnected connection.
    public func unsubscribeAll(connectionID: Int) {
        for key in subscriptions.keys {
            subscriptions[key]?.remove(connectionID)
        }
    }

    private func notifySubscribers(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue?,
                                   status: HAPStatus = .success, includeOrigin: Bool = false) {
        let key = Self.handlerKey(aid: aid, iid: iid)
        guard var subscribers = subscriptions[key], !subscribers.isEmpty else {
            logger.debug("Event notify: aid=\(aid) iid=\(iid) — no subscribers")
            return
        }
        guard onCharacteristicChange != nil else {
            logger.warning("Event notify: aid=\(aid) iid=\(iid) — no handler set")
            return
        }

        if var writes = pendingWrites[key] {
            // The PUT acknowledges the requested value. Once a different value or error has been
            // queued for the writer, a later return to the requested value must reach it too.
            if !includeOrigin, status == .success, let value, let origin = Self.writeOrigin,
               origin.bridgeID == ObjectIdentifier(self), let write = writes[origin.token],
               write.knownValue == value, subscribers.remove(write.connectionID) != nil {
                logger.debug("Event echo suppressed: connection \(write.connectionID) aid=\(aid) iid=\(iid)")
            }
            for (token, write) in writes where subscribers.contains(write.connectionID) {
                writes[token]?.knownValue = status == .success ? value : nil
            }
            pendingWrites[key] = writes
        }
        guard !subscribers.isEmpty else { return }

        logger.debug("Event notify: aid=\(aid) iid=\(iid) status=\(status.rawValue) value=\(String(describing: value)) → \(subscribers.count) subscriber(s)")
        let eventData = Self.buildEventPayload(aid: aid, iid: iid, value: value, status: status)
        enqueueNotification(subscribers: subscribers, eventData: eventData)
    }

    private func enqueueNotification(subscribers: Set<Int>, eventData: Data) {
        guard let handler = onCharacteristicChange else { return }
        // Actor isolation orders cache mutations, but separate tasks can overtake
        // one another when a send suspends. Include subscription snapshots in the
        // same FIFO so an older error cannot replace a newer recovery in Home.
        let previous = notificationTail
        notificationTail = Task {
            await previous?.value
            await handler(subscribers, eventData)
        }
    }

    /// Build the raw HTTP bytes for a HAP EVENT/1.0 message.
    ///
    /// Format:
    /// ```
    /// EVENT/1.0 200 OK\r\n
    /// Content-Type: application/hap+json\r\n
    /// Content-Length: <len>\r\n
    /// \r\n
    /// {"characteristics":[{"aid":<aid>,"iid":<iid>,"value":<value>}]}
    /// ```
    private static func buildEventPayload(aid: UInt64, iid: UInt64, value: HAPCharacteristicValue?, status: HAPStatus = .success) -> Data {
        var charDict: [String: Any] = ["aid": aid, "iid": iid]
        if status == .success, let value {
            let jsonValue: Any = switch value {
        case .bool(let v): v
        case .uint8(let v): v
        case .uint16(let v): v
        case .uint32(let v): v
        case .int32(let v): v
        case .float(let v): v
        case .string(let v): v
        case .data(let v): v.base64EncodedString()
        case .tlv8(let v): v.base64EncodedString()
            }
            charDict["value"] = jsonValue
        } else { charDict["status"] = (status == .success ? HAPStatus.communicationFailure : status).rawValue }
        let body: [String: Any] = ["characteristics": [charDict]]
        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        var event = "EVENT/1.0 200 OK\r\n"
        event += "Content-Type: application/hap+json\r\n"
        event += "Content-Length: \(jsonData.count)\r\n"
        event += "\r\n"

        var data = Data(event.utf8)
        data.append(jsonData)
        return data
    }
}
