// AppleTCPServer.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

#if canImport(Network)
import Foundation
import Network
import Logging
import HAPCore
import HAPCrypto
import HAPTransport

// MARK: - HAPConnectionContext

/// Per-connection state: own state machines, session, and receive buffer.
///
/// Using an actor serialises buffer mutations and ensures the encrypted/plain
/// transition happens atomically with respect to incoming data.
private actor HAPConnectionContext {
    var buffer = Data()
    private var closed = false
    private let created = ContinuousClock.now
    private var partialStarted: ContinuousClock.Instant?

    func mustClose() async -> Bool {
        if closed { return true }
        if !(await session.isEncrypted), ContinuousClock.now - created > .seconds(30) { return true }
        if let partialStarted, ContinuousClock.now - partialStarted > .seconds(15) { return true }
        return false
    }
    /// Decrypted bytes of a request that spans several frames; each frame carries at most 1024 plaintext bytes.
    var pendingPlaintext = Data()
    /// A peer that never completes a request cannot grow `pendingPlaintext` past this.
    static let maxPendingPlaintext = 64 * 1024
    let session = HAPSession()
    let charProtocol: CharacteristicProtocol
    let pairVerifyStateMachine: PairVerifyStateMachine
    let connectionID: Int
    init(
        bridge: HAPBridge,
        setupCode: String,
        identity: HAPIdentity,
        pairingStore: any PairingStore,
        deviceID: String,
        connectionID: Int,
        onPairingChange: (@Sendable () async -> Void)? = nil
    ) {
        self.connectionID = connectionID
        let pairing = PairingStateMachine(
            setupCode: setupCode, identity: identity, pairingStore: pairingStore, deviceID: deviceID
        )
        let pairVerify = PairVerifyStateMachine(
            identity: identity, pairingStore: pairingStore, deviceID: deviceID
        )
        self.pairVerifyStateMachine = pairVerify
        self.charProtocol = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: pairing,
            pairVerifyStateMachine: pairVerify,
            pairingStore: pairingStore,
            identity: identity,
            connectionID: connectionID,
            onPairingChange: onPairingChange
        )
    }

    // MARK: - Outgoing encryption (for event notifications)

    /// Encrypt an outgoing EVENT payload using this connection's session keys.
    /// Returns nil if the session is not yet encrypted (pre-pair-verify).
    func encryptOutgoing(_ data: Data, logger: Logger, connectionID: Int) async -> Data? {
        guard await session.isEncrypted else { return nil }
        do {
            return try await session.encrypt(data)
        } catch {
            logger.debug("Connection \(connectionID): event encryption failed: \(error)")
            return nil
        }
    }

    // MARK: - Data processing

    /// Append newly-received bytes to the buffer and process as many complete
    /// frames as possible.  Returns a list of raw byte blobs to send back.
    func process(incoming data: Data, logger: Logger, connectionID: Int) async -> [Data] {
        guard !closed, data.count <= 128 * 1024 - buffer.count else { closed = true; return [] }
        if partialStarted == nil { partialStarted = .now }
        buffer.append(data)
        var outgoing: [Data] = []

        while !buffer.isEmpty {
            if await session.isEncrypted {
                // --- Encrypted phase ---
                // Snapshot the buffer into a local copy (required because actor-isolated
                // properties cannot be passed inout across actor hops).  Only the consumed
                // prefix is removed from self.buffer after the call, so any bytes appended
                // by a concurrent task during the await are preserved.
                let bytesAvailable = buffer.count
                logger.trace("Connection \(connectionID): encrypted data received (\(bytesAvailable) bytes buffered)")
                var localBuffer = buffer
                let plaintext: Data
                do {
                    guard let decrypted = try await session.decryptFrame(from: &localBuffer) else {
                        logger.trace("Connection \(connectionID): incomplete encrypted frame, waiting for more data")
                        break // incomplete frame — wait for more data
                    }
                    plaintext = decrypted
                } catch {
                    logger.error("Connection \(connectionID): session decrypt failed (frame format or key mismatch): \(error)")
                    closed = true
                    break
                }
                let consumed = bytesAvailable - localBuffer.count
                buffer.removeFirst(consumed)
                logger.debug("Connection \(connectionID): decrypted \(plaintext.count) bytes (\(consumed) bytes consumed)")

                // A request larger than one frame, such as iOS subscribing to every characteristic of a big
                // bridge at once, arrives in pieces: keep the decrypted bytes until the whole request is here.
                pendingPlaintext.append(plaintext)
                guard pendingPlaintext.count <= Self.maxPendingPlaintext else {
                    logger.error("Connection \(connectionID): no complete request in \(pendingPlaintext.count) decrypted bytes, dropping them")
                    pendingPlaintext.removeAll()
                    closed = true
                    break
                }
                if HTTPProtocol.requestBoundary(in: pendingPlaintext) == .invalid { closed = true; break }
                while let length = HTTPProtocol.requestLength(in: pendingPlaintext) {
                    let requestData = Data(pendingPlaintext.prefix(length))
                    pendingPlaintext.removeFirst(length)
                    guard let request = HTTPProtocol.parseRequest(from: requestData) else {
                        logger.debug("Connection \(connectionID): failed to parse decrypted request (\(requestData.count) bytes plaintext)")
                        continue
                    }

                    let response: HTTPResponse
                    do {
                        response = try await charProtocol.handleRequest(request)
                    } catch {
                        logger.error("Connection \(connectionID): request handler error: \(error)")
                        response = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                    }

                    let responseData = HTTPProtocol.serializeResponse(response)
                    do {
                        let encrypted = try await session.encrypt(responseData)
                        outgoing.append(encrypted)
                    } catch {
                        logger.error("Connection \(connectionID): response encryption failed: \(error)")
                    }
                }
                if HTTPProtocol.requestBoundary(in: pendingPlaintext) == .invalid { closed = true; break }
                if !pendingPlaintext.isEmpty {
                    logger.debug("Connection \(connectionID): request incomplete (\(pendingPlaintext.count) bytes so far), waiting for the next frame")
                }

            } else {
                // --- Plaintext phase (pair-setup / pair-verify) ---
                if HTTPProtocol.requestBoundary(in: buffer) == .invalid { closed = true; break }
                guard let request = HTTPProtocol.parseRequest(from: buffer) else {
                    break // incomplete or unparseable — wait for more data
                }

                // Consume the request from the buffer.
                // HTTPProtocol.parseRequest does not report how many bytes it consumed,
                // so we clear the whole buffer — during the plaintext phase iOS sends
                // exactly one request and waits for a full response before sending the next.
                buffer.removeAll()

                let response: HTTPResponse
                do {
                    response = try await charProtocol.handleRequest(request)
                } catch {
                    logger.error("Connection \(connectionID): request handler error: \(error)")
                    response = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                }

                let responseData = HTTPProtocol.serializeResponse(response)
                outgoing.append(responseData)

                // If pair-verify just completed (M4 sent), promote this connection
                // to encrypted mode.  All subsequent data from iOS will be encrypted.
                if let keys = await pairVerifyStateMachine.sessionKeys() {
                    await session.establishSession(readKey: keys.readKey, writeKey: keys.writeKey)
                    logger.info("Connection \(connectionID): session encryption established")
                }
            }
        }

        if buffer.isEmpty && pendingPlaintext.isEmpty { partialStarted = nil }
        return outgoing
    }
}

// MARK: - AppleTCPServer

public final class AppleTCPServer: HAPServer, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var contexts: [Int: HAPConnectionContext] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextConnectionID = 0
    private let logger: Logger

    // Stored for creating per-connection contexts
    private let bridge: HAPBridge
    private let setupCode: String
    private let identity: HAPIdentity
    private let pairingStore: any PairingStore
    private let deviceID: String
    // Set after init by AppleHAPService.start() — must be configured before
    // any connection can trigger a pairing change.
    var onPairingChange: (@Sendable () async -> Void)?

    private var _port: UInt16 = 0

    public var port: UInt16 {
        lock.withLock { _port }
    }

    public init(
        bridge: HAPBridge,
        setupCode: String,
        identity: HAPIdentity,
        pairingStore: any PairingStore,
        deviceID: String,
        logger: Logger = Logger(label: "hap.apple.tcp")
    ) {
        self.bridge = bridge
        self.setupCode = setupCode
        self.identity = identity
        self.pairingStore = pairingStore
        self.deviceID = deviceID
        self.logger = logger
    }

    // MARK: - HAPServer

    public func start(port: UInt16) async throws {
        let params = NWParameters.tcp
        let listener: NWListener
        if port == 0 {
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // Set the state handler BEFORE start() to eliminate the race where .ready
        // fires between start() and a second handler assignment.
        // The continuation is wrapped in a one-shot box because multiple states
        // (.ready then .cancelled) can fire over the listener's lifetime — only
        // the first resume is valid.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // One-shot wrapper: the first resume() consumes the continuation;
            // subsequent calls are no-ops.  Safe without a lock because
            // stateUpdateHandler is always called on the listener's serial queue.
            class ContinuationBox: @unchecked Sendable {
                var continuation: CheckedContinuation<Void, Error>?
                init(_ continuation: CheckedContinuation<Void, Error>) {
                    self.continuation = continuation
                }
                func resume() {
                    continuation?.resume()
                    continuation = nil
                }
                func resume(throwing error: Error) {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }
            let box = ContinuationBox(continuation)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let actualPort = listener.port?.rawValue {
                        self.lock.withLock { self._port = actualPort }
                        self.logger.info("HAP server listening on port \(actualPort)")
                    }
                    box.resume()
                case .failed(let error):
                    self.logger.error("HAP listener failed: \(error)")
                    box.resume(throwing: error)
                case .cancelled:
                    self.logger.debug("HAP listener cancelled")
                    box.resume(throwing: HAPError.unavailable)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        self.lock.withLock { self.listener = listener }
    }

    public func stop() async {
        let (currentListener, currentConnections) = lock.withLock {
            let l = self.listener
            let c = self.connections
            self.listener = nil
            self.connections.removeAll()
            self.contexts.removeAll()
            self.deadlines.values.forEach { $0.cancel() }
            self.deadlines.removeAll()
            return (l, c)
        }

        for (_, connection) in currentConnections {
            connection.cancel()
        }
        currentListener?.cancel()
        logger.info("HAP server stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let admitted: Int? = lock.withLock {
            guard connections.count < 32 else { return nil }
            let id = nextConnectionID
            nextConnectionID += 1
            connections[id] = connection
            contexts[id] = HAPConnectionContext(
                bridge: bridge,
                setupCode: setupCode,
                identity: identity,
                pairingStore: pairingStore,
                deviceID: deviceID,
                connectionID: id,
                onPairingChange: self.onPairingChange
            )
            return id
        }

        guard let connectionID = admitted else { connection.cancel(); return }
        let deadline = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let context = self.lock.withLock({ self.contexts[connectionID] }) else { return }
                if await context.mustClose() { self.removeConnection(connectionID); return }
            }
        }
        lock.withLock { deadlines[connectionID] = deadline }

        logger.debug("New HAP connection \(connectionID)")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.debug("Connection \(connectionID) ready")
                self.receiveData(connection: connection, connectionID: connectionID)
            case .failed(let error):
                self.logger.debug("Connection \(connectionID) failed: \(error)")
                self.removeConnection(connectionID)
            case .cancelled:
                self.logger.debug("Connection \(connectionID) cancelled")
                self.removeConnection(connectionID)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveData(connection: NWConnection, connectionID: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            // Apply backpressure: one processing task per connection, rather than queueing unbounded tasks.
            Task {
                if let data = content, !data.isEmpty {
                    await self.processData(data: data, connection: connection, connectionID: connectionID)
                }
                if isComplete || error != nil {
                    self.removeConnection(connectionID)
                } else if self.lock.withLock({ self.contexts[connectionID] != nil }) {
                    self.receiveData(connection: connection, connectionID: connectionID)
                }
            }
        }
    }

    private func processData(data: Data, connection: NWConnection, connectionID: Int) async {
        guard let context = lock.withLock({ contexts[connectionID] }) else { return }

        let responses = await context.process(incoming: data, logger: logger, connectionID: connectionID)
        if await context.mustClose() { removeConnection(connectionID); return }
        for responseData in responses {
            connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.debug("Connection \(connectionID) send error: \(error)")
                }
            })
        }
    }

    private func removeConnection(_ connectionID: Int) {
        let connection = lock.withLock {
            contexts.removeValue(forKey: connectionID)
            deadlines.removeValue(forKey: connectionID)?.cancel()
            return connections.removeValue(forKey: connectionID)
        }
        connection?.cancel()

        // Clean up event subscriptions for this connection
        Task {
            await bridge.unsubscribeAll(connectionID: connectionID)
        }
    }

    // MARK: - Event Notifications

    /// Send a pre-built EVENT/1.0 payload to a specific connection, encrypted
    /// with that connection's session keys.
    func sendEvent(_ eventData: Data, to connectionID: Int) async {
        let (context, connection) = lock.withLock {
            (contexts[connectionID], connections[connectionID])
        }
        guard let context, let connection else { return }

        let encrypted = await context.encryptOutgoing(eventData, logger: logger, connectionID: connectionID)
        guard let encrypted else { return }

        connection.send(content: encrypted, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.debug("Connection \(connectionID) event send error: \(error)")
            }
        })
    }
}
#endif
