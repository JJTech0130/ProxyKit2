//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import Logging

final class ConnectHandler {
    private var upgradeState: State

    private var logger: Logger

    init(logger: Logger) {
        self.upgradeState = .idle
        self.logger = logger
    }
}


extension ConnectHandler {
    fileprivate enum AuthenticationMethod: UInt8 {
        case none = 0
        case gss = 1
        case password = 2
        case invalid = 255
    }
        
    fileprivate enum State {
        case idle
        case awaitingAuthentication(authenticationMethod: AuthenticationMethod)
        case beganConnecting
        //case awaitingEnd(connectResult: Channel)
        case awaitingConnection(pendingBytes: [NIOAny])
        case upgradeComplete(pendingBytes: [NIOAny])
        case upgradeFailed
    }
}


extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.upgradeState {
        case .idle:
            self.negotiateAuthenticationMethod(context: context, data: self.unwrapInboundIn(data))
            
        case .awaitingAuthentication(let authenticationMethod):
            self.handleAuthentication(context: context, data: self.unwrapInboundIn(data), method: authenticationMethod)
            
        case .beganConnecting:
            self.handleInitialMessage(context: context, data: self.unwrapInboundIn(data))
            //self.upgradeState = .awaitingConnection(pendingBytes: [])
            // We got .end, we're still waiting on the connection
            //if case .end = self.unwrapInboundIn(data) {
            //    self.upgradeState = .awaitingConnection(pendingBytes: [])
            //    self.removeDecoder(context: context)
            //}

        /*case .awaitingEnd(let peerChannel):
            print("Encountered some leftovers from the old HTTP proxy. We shouldn't be here.")
            //if case .end = self.unwrapInboundIn(data) {
                // Upgrade has completed!
             //   self.upgradeState = .upgradeComplete(pendingBytes: [])
              //  self.removeDecoder(context: context)
               // self.glue(peerChannel, context: context)
            //}*/

        case .awaitingConnection(var pendingBytes):
            // We've seen end, this must not be HTTP anymore. Danger, Will Robinson! Do not unwrap.
            // // Just keeps adding bytes to pending bytes enum.
            self.upgradeState = .awaitingConnection(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .awaitingConnection(pendingBytes: pendingBytes)

        case .upgradeComplete(pendingBytes: var pendingBytes):
            // We're currently delivering data, keep doing so.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            pendingBytes.append(data)
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

        case .upgradeFailed:
            break
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Add logger metadata.
        self.logger[metadataKey: "localAddress"] = "\(String(describing: context.channel.localAddress))"
        self.logger[metadataKey: "remoteAddress"] = "\(String(describing: context.channel.remoteAddress))"
        self.logger[metadataKey: "channel"] = "\(ObjectIdentifier(context.channel))"
    }
}


extension ConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false

        // We are being removed, and need to deliver any pending bytes we may have if we're upgrading.
        while case .upgradeComplete(var pendingBytes) = self.upgradeState, pendingBytes.count > 0 {
            // Avoid a CoW while we pull some data out.
            self.upgradeState = .upgradeComplete(pendingBytes: [])
            let nextRead = pendingBytes.removeFirst()
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)

            context.fireChannelRead(nextRead)
            didRead = true
        }

        if didRead {
            context.fireChannelReadComplete()
        }

        self.logger.debug("Removing \(self) from pipeline")
        context.leavePipeline(removalToken: removalToken)
    }
}

//let supportedMethods: Set<AuthenticationMethod> = [ .none ] //TODO: Allow configuration at runtime

extension ConnectHandler {
    /// Handles the initial method negotiation packet, selects a method, and responds with it's selection.
    /// Changes upgradeState:
    ///     .upgradeFailed on error
    ///     .beganConnecting if no authentication is required
    ///     .awaitingAuthentication(method) if further authentication is required
    private func negotiateAuthenticationMethod(context: ChannelHandlerContext, data: InboundIn) {
        let inputBuffer = data.readableBytesView
        
        let version = Int(inputBuffer[0])
        guard version == 5 else {
            self.logger.error("Invalid SOCKS version \(version)")
            //TODO: Encapsulate error in function like HTTP one
            self.upgradeState = .upgradeFailed
            context.close()
            return
        }
        
        let numberOfMethods = Int(inputBuffer[1])
        guard numberOfMethods >= 1 else {
            self.logger.error("Client must support at least one authentication method")
            self.upgradeState = .upgradeFailed
            context.close()
            return
        }
        
        
        let methodsSlice = inputBuffer[2 ... (numberOfMethods + 1)] // i.e. len 1 means from 2 ... 2, len 2 means 2 ... 3
        let requestedMethods = Set(methodsSlice.compactMap({ AuthenticationMethod(rawValue: $0) }))
        
        let supportedMethods: Set<AuthenticationMethod> = [ .none ] //TODO: Allow configuration at runtime
        let methodsInCommon = supportedMethods.intersection(requestedMethods)
        
        let selectedMethod = methodsInCommon.first ?? .invalid
        
        
        self.logger.info("Selected authentication method \(selectedMethod)")
        
        let response = ByteBuffer([5, selectedMethod.rawValue])
        context.writeAndFlush(wrapOutboundOut(response))
        
        if selectedMethod == .none {
            self.upgradeState = .beganConnecting
        } else {
            self.upgradeState = .awaitingAuthentication(authenticationMethod: selectedMethod)
        }
    }
    
    /// Handles any further authentication required.
    /// To be implemented. Currently a stub
    private func handleAuthentication(context: ChannelHandlerContext, data: InboundIn, method: AuthenticationMethod) {
        self.logger.error("Encountered stub trying to authorize with method \(method)")
        //TODO: Implement authentication
    }
    
    
    private func handleInitialMessage(context: ChannelHandlerContext, data: InboundIn) {
        let inputBuffer = data.readableBytesView
        
        let version = Int(inputBuffer[0])
        guard version == 5 else {
            self.logger.error("Invalid SOCKS version \(version)")
            //TODO: Encapsulate error in function like HTTP one
            self.upgradeState = .upgradeFailed
            context.close()
            return
        }
        
        // These enums are simple convenience
        // Shouldn't be used outside this function (yet)
        enum Command: UInt8 {
            case connect = 1
            case bind = 2
            case associate = 3
        }
        
        guard let command = Command(rawValue: inputBuffer[1]) else {
            self.logger.error("Invalid command \(inputBuffer[1])")
            self.upgradeState = .upgradeFailed
            context.close()
            return
        }
        
        enum AddressType: UInt8 {
            case v4 = 1
            case domain = 3
            case v6 = 4
        }
        
        guard let addressType = AddressType(rawValue: inputBuffer[3]) else {
            self.logger.error("Invalid address type \(inputBuffer[3])")
            self.upgradeState = .upgradeFailed
            context.close()
            return
        }
        
        print("Version: \(version)")
        print("Command: \(command)")
        print("Address Type: \(addressType)")
        
        // Assuming domain
        // Wrapped in Array() so that we can slice it again
        let address = Array(inputBuffer[4...])
        
        //var host: String
        
        let host: String = {
            switch addressType {
            case .v4:
                return address[0...3].map({ String(Int($0)) }).joined(separator: ".")
            case .domain:
                let len = Int(address[0])
                return String(bytes: address[1...len], encoding: .ascii) ?? ""
            case .v6:
                self.logger.error("Encountered unimplemented IPV6 address........")
                return ""
            }
        }()
        
        
        let rawPort = Array(address.suffix(2))
        let port = (Int(rawPort[0]) * 256) + Int(rawPort[1])
        
        self.upgradeState = .awaitingConnection(pendingBytes: [])
        self.connectTo(host: String(host), port: port, context: context)
    }

    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        self.logger.info("Connecting to \(host):\(port)")

        let channelFuture = ClientBootstrap(group: context.eventLoop)
            .connect(host: String(host), port: port)

        channelFuture.whenSuccess { channel in
            self.connectSucceeded(channel: channel, context: context)
        }
        channelFuture.whenFailure { error in
            self.connectFailed(error: error, context: context)
        }
    }

    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        self.logger.info("Connected to \(String(describing: channel.remoteAddress))")

        switch self.upgradeState {
        case .beganConnecting, .awaitingAuthentication:
            print("WAIT WHAT HOW DID WE GET HERE")
            // Ok, we have a channel, let's wait for end.
            //self.upgradeState = .awaitingEnd(connectResult: channel)

        case .awaitingConnection(pendingBytes: let pendingBytes):
            // Upgrade complete! Begin gluing the connection together.
            self.upgradeState = .upgradeComplete(pendingBytes: pendingBytes)
            self.glue(channel, context: context)

        /*case .awaitingEnd(let peerChannel):
            print("SHOULDN't BE HERE EiThEr!")
            // This case is a logic error, close already connected peer channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)*/

        case .idle, .upgradeFailed, .upgradeComplete:
            // These cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }
    }

    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        self.logger.error("Connect failed: \(error)")

        switch self.upgradeState {
        case .beganConnecting, .awaitingConnection, .awaitingAuthentication:
            // We still have a somewhat active connection here in HTTP mode, and can report failure.
            //self.httpErrorAndClose(context: context)
            context.close()

        /*case .awaitingEnd(let peerChannel):
            // This case is a logic error, close already connected peer channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)*/

        case .idle, .upgradeFailed, .upgradeComplete:
            // Most of these cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }

        context.fireErrorCaught(error)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        self.logger.debug("Gluing together \(ObjectIdentifier(context.channel)) and \(ObjectIdentifier(peerChannel))")
        
        //TODO: Figure out a better response. Noone seems to care as long as it's a valid address and port
        //  but we probably shouldn't make it up.
        context.writeAndFlush(self.wrapOutboundOut(ByteBuffer([5, 0, 0, 1, 127,0,0,1, 0,20])))
        
        // Now we need to glue our channel and the peer channel together.
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue).and(peerChannel.pipeline.addHandler(peerGlue)).whenComplete { result in
            switch result {
            case .success(_):
                // Remove ourselves from the pipeline
                context.pipeline.removeHandler(self, promise: nil)
            case .failure(_):
                // Close connected peer channel before closing our channel.
                peerChannel.close(mode: .all, promise: nil)
                context.close(promise: nil)
            }
        }
    }

    /*private func httpErrorAndClose(context: ChannelHandlerContext) {
        self.upgradeState = .upgradeFailed
        //TODO: REIMPLEMENT
        //let headers = HTTPHeaders([("Content-Length", "0"), ("Connection", "close")])
        //let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .badRequest, headers: headers)
        //context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        //context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
        //    context.close(mode: .output, promise: nil)
        //}
    }*/

    /*private func removeDecoder(context: ChannelHandlerContext) {
        // We drop the future on the floor here as these handlers must all be in our own pipeline, and this should
        // therefore succeed fast.
        context.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }

    private func removeEncoder(context: ChannelHandlerContext) {
        context.pipeline.context(handlerType: HTTPResponseEncoder.self).whenSuccess {
            context.pipeline.removeHandler(context: $0, promise: nil)
        }
    }*/
}
