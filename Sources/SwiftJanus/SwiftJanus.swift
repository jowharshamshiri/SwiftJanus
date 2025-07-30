// SwiftJanus.swift
// Cross-platform Unix Socket API communication library

import Foundation

/// Main entry point for SwiftJanus library
public final class SwiftJanus {
    public static let version = "2.0.0"
    
    private init() {}
}

// Export high-level SOCK_DGRAM APIs for simple usage
public typealias SocketServer = UnixDatagramServer
public typealias SocketClient = JanusDatagramClient

// Re-export core protocol types for convenience
public typealias Command = SocketCommand
public typealias Response = SocketResponse
public typealias ServerError = SocketError