// LinuxTCPServer.swift
// Copyright 2026 Monagle Pty Ltd

import Foundation
import Logging
import NIOCore
import NIOPosix
import HAPCore
import HAPCrypto
import HAPTransport

// MARK: - LinuxTCPServer

public final class LinuxTCPServer: HAPServer, @unchecked Sendable {
    private let lock = NSLock()
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let logger: Logger
    private let characteristicProtocol: CharacteristicProtocol
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
        logger: Logger = Logger(label: "hap.linux.tcp")
    ) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.logger = logger

        let pairingStateMachine = PairingStateMachine(
            setupCode: setupCode, identity: identity, pairingStore: pairingStore, deviceID: deviceID
        )
        let pairVerifyStateMachine = PairVerifyStateMachine(
            identity: identity, pairingStore: pairingStore, deviceID: deviceID
        )
        self.characteristicProtocol = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: pairingStateMachine,
            pairVerifyStateMachine: pairVerifyStateMachine,
            pairingStore: pairingStore,
            identity: identity
        )
    }

    // MARK: - HAPServer

    public func start(port: UInt16) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [characteristicProtocol, logger] channel in
                channel.pipeline.addHandler(
                    HAPChannelHandler(
                        characteristicProtocol: characteristicProtocol,
                        logger: logger
                    )
                )
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "::", port: Int(port)).get()

        if let localAddress = channel.localAddress, let actualPort = localAddress.port {
            lock.withLock { self._port = UInt16(actualPort) }
            logger.info("HAP server listening on port \(actualPort)")
        }

        lock.withLock { self.channel = channel }
    }

    public func stop() async {
        let currentChannel = lock.withLock {
            let ch = self.channel
            self.channel = nil
            return ch
        }

        try? await currentChannel?.close()
        try? await group.shutdownGracefully()
        logger.info("HAP server stopped")
    }
}

// MARK: - HAPChannelHandler

private final class HAPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let characteristicProtocol: CharacteristicProtocol
    private let logger: Logger
    private var buffer = Data()

    init(characteristicProtocol: CharacteristicProtocol, logger: Logger) {
        self.characteristicProtocol = characteristicProtocol
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            buffer.append(contentsOf: bytes)
        }

        // Try to parse a complete HTTP request
        guard let request = HTTPProtocol.parseRequest(from: buffer) else {
            return
        }

        buffer = Data()

        // Use an EventLoopPromise to bridge async work back to the event loop
        // without capturing ChannelHandlerContext across isolation boundaries.
        let promise = context.eventLoop.makePromise(of: Data.self)
        let proto = self.characteristicProtocol
        let log = self.logger
        promise.completeWithTask {
            do {
                let response = try await proto.handleRequest(request)
                return HTTPProtocol.serializeResponse(response)
            } catch {
                log.error("Request handling error: \(error)")
                let errorResponse = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                return HTTPProtocol.serializeResponse(errorResponse)
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            let responseData: Data
            switch result {
            case .success(let data): responseData = data
            case .failure:
                let err = HTTPProtocol.errorResponse(status: 500, message: "Internal Server Error")
                responseData = HTTPProtocol.serializeResponse(err)
            }
            var outBuf = context.channel.allocator.buffer(capacity: responseData.count)
            outBuf.writeBytes(responseData)
            context.writeAndFlush(self.wrapOutboundOut(outBuf), promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("Connection error: \(error)")
        context.close(promise: nil)
    }
}
