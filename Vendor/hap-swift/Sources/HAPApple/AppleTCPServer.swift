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
/// The receive loop admits one processing call at a time, including across actor
/// suspensions. Responses and events submit encrypted bytes through HAPSession.
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
    let send: @Sendable (Data) -> Void
    /// Keep EVENTs behind the HTTP response, including while a fragmented request is still arriving.
    /// Actor isolation alone does not prevent an event from entering while a request handler awaits I/O.
    private var responsePending = false
    private var pendingEvents: [Data] = []
    private var flushingEvents = false
    init(
        bridge: HAPBridge,
        setupCode: String,
        identity: HAPIdentity,
        pairingStore: any PairingStore,
        deviceID: String,
        connectionID: Int,
        send: @escaping @Sendable (Data) -> Void,
        onPairingChange: (@Sendable () async -> Void)? = nil
    ) {
        self.connectionID = connectionID
        self.send = send
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

    /// Submit EVENT bytes in the same actor-isolated order as response encryption.
    func sendEvent(_ data: Data, logger: Logger, connectionID: Int) async {
        guard await session.isEncrypted else { return }
        pendingEvents.append(data)
        logger.debug("Connection \(connectionID): queued event (\(data.count) bytes), response pending: \(responsePending)")
        await flushEvents(logger: logger, connectionID: connectionID)
    }

    private func flushEvents(logger: Logger, connectionID: Int) async {
        guard !responsePending, !flushingEvents else { return }
        flushingEvents = true
        defer { flushingEvents = false }
        while !responsePending, !pendingEvents.isEmpty {
            let data = pendingEvents.removeFirst()
            do {
                try await session.encryptAndSend(data, send: send)
                logger.debug("Connection \(connectionID): submitted event (\(data.count) plaintext bytes)")
            } catch {
                logger.debug("Connection \(connectionID): event encryption failed: \(error)")
                return
            }
        }
    }

    // MARK: - Data processing

    /// Process one TCP receive, submitting complete responses before queued events.
    func process(incoming data: Data, logger: Logger, connectionID: Int) async -> Bool {
        guard !closed, data.count <= 128 * 1024 - buffer.count else { closed = true; return false }
        if partialStarted == nil { partialStarted = .now }
        responsePending = true
        buffer.append(data)

        while !buffer.isEmpty {
            if await session.isEncrypted {
                // --- Encrypted phase ---
                // Actor-isolated properties cannot be passed inout across actor hops.
                // The receive loop waits for processing, so this prefix remains owned
                // by this request while the session actor decrypts it.
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
                    return false
                }
                let consumed = bytesAvailable - localBuffer.count
                buffer.removeFirst(consumed)
                logger.debug("Connection \(connectionID): decrypted \(plaintext.count) bytes (\(consumed) bytes consumed)")

                // A request larger than one frame, such as iOS subscribing to every characteristic of a big
                // bridge at once, arrives in pieces: keep the decrypted bytes until the whole request is here.
                pendingPlaintext.append(plaintext)
                guard pendingPlaintext.count <= Self.maxPendingPlaintext else {
                    logger.error("Connection \(connectionID): no complete request in \(pendingPlaintext.count) decrypted bytes, closing connection")
                    return false
                }
                if HTTPProtocol.requestBoundary(in: pendingPlaintext) == .invalid { closed = true; return false }
                while let length = HTTPProtocol.requestLength(in: pendingPlaintext) {
                    let requestData = Data(pendingPlaintext.prefix(length))
                    pendingPlaintext.removeFirst(length)
                    guard let request = HTTPProtocol.parseRequest(from: requestData) else {
                        logger.debug("Connection \(connectionID): failed to parse decrypted request (\(requestData.count) bytes plaintext)")
                        return false
                    }

                    let started = ContinuousClock.now
                    let response: HTTPResponse
                    do {
                        response = try await charProtocol.handleRequest(request)
                    } catch {
                        logger.error("Connection \(connectionID): request handler error: \(error)")
                        response = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                    }

                    let responseData = HTTPProtocol.serializeResponse(response)
                    logger.debug("Connection \(connectionID): response \(response.statusCode), \(response.body.count) body bytes after \(started.duration(to: .now))")
                    do {
                        try await session.encryptAndSend(responseData, send: send)
                    } catch {
                        logger.error("Connection \(connectionID): response encryption failed: \(error)")
                        return false
                    }
                }
                if HTTPProtocol.requestBoundary(in: pendingPlaintext) == .invalid { closed = true; return false }
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
                send(responseData)

                // If pair-verify just completed (M4 sent), promote this connection
                // to encrypted mode.  All subsequent data from iOS will be encrypted.
                if let keys = await pairVerifyStateMachine.sessionKeys() {
                    await session.establishSession(readKey: keys.readKey, writeKey: keys.writeKey)
                    logger.info("Connection \(connectionID): session encryption established")
                }
            }
        }

        if buffer.isEmpty && pendingPlaintext.isEmpty { partialStarted = nil }
        // All complete HTTP responses have been submitted through HAPSession. A remaining partial frame or
        // HTTP request still owns the next response slot; resume event delivery after its final fragment.
        responsePending = !buffer.isEmpty || !pendingPlaintext.isEmpty
        await flushEvents(logger: logger, connectionID: connectionID)
        return true
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
        try await start(port: port, loopbackOnly: false)
    }

    public func start(port: UInt16, loopbackOnly: Bool) async throws {
        let params = NWParameters.tcp
        if loopbackOnly { params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!) }
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
            // subsequent calls are no-ops.  The listener starts on a global queue,
            // which is concurrent, so two state updates can overlap: take the
            // continuation under a lock, or both could resume it and trap.
            final class ContinuationBox: @unchecked Sendable {
                private let lock = NSLock()
                private var continuation: CheckedContinuation<Void, Error>?
                init(_ continuation: CheckedContinuation<Void, Error>) {
                    self.continuation = continuation
                }
                func resume() { take()?.resume() }
                func resume(throwing error: Error) { take()?.resume(throwing: error) }
                private func take() -> CheckedContinuation<Void, Error>? {
                    lock.withLock {
                        defer { continuation = nil }
                        return continuation
                    }
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
                send: { [logger = self.logger] data in
                    let count = data.count
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { logger.debug("Connection \(id) send error: \(error)") }
                        else { logger.debug("Connection \(id): socket accepted \(count) bytes") }
                    })
                },
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

            // One processing task at a time preserves TCP byte order across actor
            // suspensions and prevents two tasks from decrypting the same buffer.
            Task {
                if let data = content, !data.isEmpty {
                    guard await self.processData(data: data, connection: connection, connectionID: connectionID) else {
                        self.removeConnection(connectionID)
                        return
                    }
                }

                if isComplete {
                    self.logger.debug("Connection \(connectionID): peer ended receive stream")
                    self.removeConnection(connectionID)
                } else if let error {
                    self.logger.debug("Connection \(connectionID) receive error: \(error)")
                    self.removeConnection(connectionID)
                } else {
                    self.receiveData(connection: connection, connectionID: connectionID)
                }
            }
        }
    }

    private func processData(data: Data, connection: NWConnection, connectionID: Int) async -> Bool {
        guard let context = lock.withLock({ contexts[connectionID] }) else { return false }

        let accepted = await context.process(incoming: data, logger: logger, connectionID: connectionID)
        let shouldClose = await context.mustClose()
        return accepted && !shouldClose
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
        guard let context = lock.withLock({ contexts[connectionID] }) else { return }
        await context.sendEvent(eventData, logger: logger, connectionID: connectionID)
    }
}
#endif
