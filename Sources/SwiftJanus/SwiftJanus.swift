// SwiftJanus.swift
// Cross-platform Janus communication library

import Foundation

/// Main entry point for SwiftJanus library
public final class SwiftJanus {
    public static let version = "2.0.0"
    
    private init() {}
}

// Export high-level SOCK_DGRAM APIs for simple usage
public typealias SocketServer = JanusServer
public typealias SocketClient = JanusClient

// Re-export core protocol types for convenience
public typealias Command = SocketCommand
public typealias Response = SocketResponse
public typealias ServerError = JSONRPCError