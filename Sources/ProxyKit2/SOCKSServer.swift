//
//  SOCKSServer.swift
//  
//
//  Created by JJTech on 5/5/22.
//

import Foundation
import NIO
import Logging

enum SOCKSServerError: Error {
    case invalidHost
    case invalidPort
}

public class SOCKSServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    
    private var host: String?
    var port: Int?
    
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
    
    public func start() throws {
        guard let host = host else {
            throw SOCKSServerError.invalidHost
        }
        guard let port = port else {
            throw SOCKSServerError.invalidPort
        }
        do {
            let channel = try serverBootstrap.bind(host: host, port: port).wait()
            print("Listening on \(String(describing: channel.localAddress))...")
            try channel.closeFuture.wait()
            print("closed?")
        } catch let error {
            throw error
        }
    }
    
    public func stop() {
        do {
            try group.syncShutdownGracefully()
        } catch let error {
            print("Error shutting down \(error.localizedDescription)")
            exit(0)
        }
        print("Client connection closed")
    }
    
    private var serverBootstrap: ServerBootstrap {
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConnectHandler(logger: Logger(label: "com.apple.nio-connect-proxy.ConnectHandler")))
            }
    }
}
