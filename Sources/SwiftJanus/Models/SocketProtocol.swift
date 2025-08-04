// SocketProtocol.swift
// Socket communication protocol models

import Foundation

/// Command message sent over socket
public struct JanusCommand: Codable, Sendable {
    public let id: String
    public let channelId: String
    public let command: String
    public let replyTo: String?
    public let args: [String: AnyCodable]?
    public let timeout: TimeInterval?
    public let timestamp: Double
    
    enum CodingKeys: String, CodingKey {
        case id
        case channelId
        case command
        case replyTo = "reply_to"
        case args
        case timeout
        case timestamp
    }
    
    public init(
        id: String = UUID().uuidString,
        channelId: String,
        command: String,
        replyTo: String? = nil,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.channelId = channelId
        self.command = command
        self.replyTo = replyTo
        self.args = args
        self.timeout = timeout
        self.timestamp = timestamp
    }
}

/// Response message sent over socket
/// Updated to support direct value responses for protocol compliance
public struct JanusResponse: Codable, Sendable {
    public let commandId: String
    public let channelId: String
    public let success: Bool
    public let result: AnyCodable?
    public let error: JSONRPCError?
    public let timestamp: Double
    
    public init(
        commandId: String,
        channelId: String,
        success: Bool,
        result: AnyCodable? = nil,
        error: JSONRPCError? = nil,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.commandId = commandId
        self.channelId = channelId
        self.success = success
        self.result = result
        self.error = error
        self.timestamp = timestamp
    }
    
}

/// Error information in socket responses
public struct SocketError: Error, Codable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: AnyCodable]?
    
    public init(code: String, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Socket message envelope for multiplexing channels
public struct SocketMessage: Codable, Sendable {
    public let type: MessageType
    public let payload: Data
    
    public init(type: MessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

/// Types of socket messages (stateless)
public enum MessageType: String, Codable, Sendable {
    case command
    case response
}

// Legacy JanusError enum removed - all error handling now uses JSONRPCError directly
// This maintains compatibility with Go, Rust, and TypeScript implementations