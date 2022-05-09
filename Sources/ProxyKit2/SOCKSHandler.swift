//
//  SOCKSHandler.swift
//  
//
//  Created by JJTech on 5/4/22.
//

import Foundation
import NIO

//  This uses a really weird pseudo-state machine
//  Because I don't really understand them.
//  Feel free to clean up

protocol StateHandler {
    func handleByte(context: ChannelHandlerContext, byte: UInt8) -> StateHandler // Returns the next handler (can be self)
}

/// Handles the negotiation of SOCKS version and authentication method
class Negotiator: StateHandler {
    
    // Index of the current byte
    var index = 0
    
    // The number of methods the client supports.
    // Must be at least one.
    var number_of_methods = 1
    
    // Methods we support
    // Should be configurable
    let supported_methods = [0, 1]
    
    // Final, decided method
    // 255 means that there are no acceptable methods
    var method = 255
    
    /*
     Handle the initial authentication negotiation:
     +-------+----------+----------+
     |VER    | NMETHODS | METHODS  |
     +-------+----------+----------+
     | X'05' |    1     | 1 to 255 |
     +-------+----------+----------+
     and return the decided upon method
     +-------+--------+
     |VER    | METHOD |
     +-------+--------+
     | X'05' |   1    |
     +-------+--------+
     */
    func handleByte(context: ChannelHandlerContext, byte: UInt8) -> StateHandler {
        switch index {
        case 0:
            guard byte == 5 else {
                context.close()
                return InvalidState()
            }
        case 1:
            guard byte > 0 else {
                // Second byte is number of methods, must be greater than 0
                context.close()
                return InvalidState()
            }
            number_of_methods = Int(byte)
            
        case 2...(number_of_methods + 1):
            if supported_methods.contains(Int(byte)) {
                method = Int(byte)
                print("decided upon method: \(byte)")
            }
            print("method: \(byte)")
            fallthrough
        case number_of_methods + 1:
            // We've processed all the data that we should.
            // Return a response and change the handler
            print("final method: \(byte)")
        
        default:
            print("Encountered unexpected byte \(byte) at index \(index)")
            context.close()
            return InvalidState()
        }
        
        index += 1
        
        print(byte)
        
        return self
    }
}

/// Authenticates with the negotiated authentication method
class Authenticator: StateHandler {
    func handleByte(context: ChannelHandlerContext, byte: UInt8) -> StateHandler {
        print(byte)
        return self
    }
}

class InvalidState: StateHandler {
    func handleByte(context: ChannelHandlerContext, byte: UInt8) -> StateHandler {
        // This stub will be called for each of the remaining bytes in the queue.
        context.close()
        return self // Still in the invalid state, no way to get out of it
    }
}

class SOCKSHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    // The current handler or "state"
    private var handler: StateHandler = Negotiator()
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        
        // Iterate over all of the readable bytes
        // i.e. the grouping has no meaning, so enforce it
        for byte in buffer.readableBytesView {
            handler = handler.handleByte(context: context, byte: byte)
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: \(error.localizedDescription)")
        context.close(promise: nil)
    }
}
