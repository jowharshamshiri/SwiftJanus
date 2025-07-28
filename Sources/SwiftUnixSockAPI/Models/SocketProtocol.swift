// SocketProtocol.swift
// Socket communication protocol models

import Foundation

/// Command message sent over socket
public struct SocketCommand: Codable, Sendable {
    public let id: String
    public let channelId: String
    public let command: String
    public let args: [String: AnyCodable]?
    public let timeout: TimeInterval?
    public let timestamp: Date
    
    public init(
        id: String = UUID().uuidString,
        channelId: String,
        command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.channelId = channelId
        self.command = command
        self.args = args
        self.timeout = timeout
        self.timestamp = timestamp
    }
}

/// Response message sent over socket
public struct SocketResponse: Codable, Sendable {
    public let commandId: String
    public let channelId: String
    public let success: Bool
    public let result: AnyCodable?
    public let error: SocketError?
    public let timestamp: Date
    
    public init(
        commandId: String,
        channelId: String,
        success: Bool,
        result: AnyCodable? = nil,
        error: SocketError? = nil,
        timestamp: Date = Date()
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
public struct SocketError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let details: [String: AnyCodable]?
    
    public init(code: Int, message: String, details: [String: AnyCodable]? = nil) {
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