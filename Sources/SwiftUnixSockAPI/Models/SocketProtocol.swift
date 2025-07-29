// SocketProtocol.swift
// Socket communication protocol models

import Foundation

/// Command message sent over socket
public struct SocketCommand: Codable, Sendable {
    public let id: String
    public let channelId: String
    public let command: String
    public let replyTo: String?
    public let args: [String: AnyCodable]?
    public let timeout: TimeInterval?
    public let timestamp: Date
    
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
        timestamp: Date = Date()
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
public struct SocketResponse: Codable, Sendable {
    public let commandId: String
    public let channelId: String
    public let success: Bool
    public let result: [String: AnyCodable]?
    public let error: SocketError?
    public let timestamp: Date
    
    public init(
        commandId: String,
        channelId: String,
        success: Bool,
        result: [String: AnyCodable]? = nil,
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

/// Unified error enum for SOCK_DGRAM communication
public enum UnixSockApiError: Error, LocalizedError {
    case invalidChannel(String)
    case unknownCommand(String)
    case missingRequiredArgument(String)
    case invalidArgument(String, String)
    case connectionRequired
    case encodingFailed(String)
    case decodingFailed(String)
    case commandTimeout(String, TimeInterval)
    case handlerTimeout(String, TimeInterval)
    case resourceLimit(String)
    case invalidSocketPath(String)
    case securityViolation(String)
    case malformedData(String)
    case messageTooLarge(Int, Int)
    case connectionError(String)
    case ioError(String)
    case validationError(String)
    case socketCreationFailed(String)
    case bindFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case connectionClosed(String)
    case connectionTestFailed(String)
    case timeout(String)
    case protocolError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidChannel(let channel):
            return "Invalid channel: \(channel)"
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingRequiredArgument(let arg):
            return "Missing required argument: \(arg)"
        case .invalidArgument(let arg, let reason):
            return "Invalid argument '\(arg)': \(reason)"
        case .connectionRequired:
            return "Connection required for operation"
        case .encodingFailed(let error):
            return "Encoding failed: \(error)"
        case .decodingFailed(let error):
            return "Decoding failed: \(error)"
        case .commandTimeout(let command, let timeout):
            return "Command '\(command)' timed out after \(timeout) seconds"
        case .handlerTimeout(let handler, let timeout):
            return "Handler for command '\(handler)' timed out after \(timeout) seconds"
        case .resourceLimit(let limit):
            return "Resource limit exceeded: \(limit)"
        case .invalidSocketPath(let path):
            return "Invalid socket path: \(path)"
        case .securityViolation(let violation):
            return "Security violation: \(violation)"
        case .malformedData(let data):
            return "Malformed data: \(data)"
        case .messageTooLarge(let size, let limit):
            return "Message too large: \(size) bytes (limit: \(limit) bytes)"
        case .connectionError(let error):
            return "Connection error: \(error)"
        case .ioError(let error):
            return "IO error: \(error)"
        case .validationError(let error):
            return "Validation error: \(error)"
        case .socketCreationFailed(let error):
            return "Socket creation failed: \(error)"
        case .bindFailed(let error):
            return "Bind failed: \(error)"
        case .sendFailed(let error):
            return "Send failed: \(error)"
        case .receiveFailed(let error):
            return "Receive failed: \(error)"
        case .connectionClosed(let error):
            return "Connection closed: \(error)"
        case .connectionTestFailed(let error):
            return "Connection test failed: \(error)"
        case .timeout(let error):
            return "Timeout: \(error)"
        case .protocolError(let error):
            return "Protocol error: \(error)"
        }
    }
}