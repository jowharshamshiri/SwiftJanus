// SocketProtocol.swift
// Socket communication protocol models

import Foundation

/// Request message sent over socket (PRIME DIRECTIVE: exact format for 100% cross-platform compatibility)
public struct JanusRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let request: String
    public let replyTo: String?
    public let args: [String: AnyCodable]?
    public let timeout: TimeInterval?
    public let timestamp: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case method
        case request
        case replyTo = "reply_to"
        case args
        case timeout
        case timestamp
    }
    
    public init(
        id: String = UUID().uuidString,
        request: String,
        replyTo: String? = nil,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.id = id
        self.method = request // PRIME DIRECTIVE: method field matches request name
        self.request = request
        self.replyTo = replyTo
        self.args = args
        self.timeout = timeout
        // PRIME DIRECTIVE: Use RFC 3339 timestamp format
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: Date())
    }
}

/// Response message sent over socket (PRIME DIRECTIVE: exact format for 100% cross-platform compatibility)
public struct JanusResponse: Codable, Sendable {
    public let result: AnyCodable?
    public let error: JSONRPCError?
    public let success: Bool
    public let requestId: String
    public let id: String
    public let timestamp: String
    
    private enum CodingKeys: String, CodingKey {
        case result
        case error
        case success
        case requestId = "request_id"
        case id
        case timestamp
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(success, forKey: .success)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
    }
    
    public init(
        requestId: String,
        success: Bool,
        result: AnyCodable? = nil,
        error: JSONRPCError? = nil
    ) {
        self.result = result
        self.error = error
        self.success = success
        self.requestId = requestId
        self.id = UUID().uuidString
        // PRIME DIRECTIVE: Use RFC 3339 timestamp format
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: Date())
    }
    
    // PRIME DIRECTIVE: Convenience constructors for standardized responses
    public static func success(requestId: String, result: AnyCodable?) -> JanusResponse {
        return JanusResponse(requestId: requestId, success: true, result: result, error: nil)
    }
    
    public static func error(requestId: String, error: JSONRPCError) -> JanusResponse {
        return JanusResponse(requestId: requestId, success: false, result: nil, error: error)
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
    case request
    case response
}

// Legacy JanusError enum removed - all error handling now uses JSONRPCError directly
// This maintains compatibility with Go, Rust, and TypeScript implementations

/// RequestHandle provides a user-friendly interface to track and manage requests
/// Hides internal UUID complexity from users
public final class RequestHandle: @unchecked Sendable {
    private let internalID: String
    private let request: String
    private let timestamp: Date
    private let cancelledFlag = NSLock()
    private var cancelled = false
    
    /// Create a new request handle from internal UUID
    public init(internalID: String, request: String) {
        self.internalID = internalID
        self.request = request
        self.timestamp = Date()
    }
    
    /// Get the request name for this request
    public func getRequest() -> String {
        return request
    }
    
    
    /// Get when this request was created
    public func getTimestamp() -> Date {
        return timestamp
    }
    
    /// Check if this request has been cancelled
    public func isCancelled() -> Bool {
        cancelledFlag.lock()
        defer { cancelledFlag.unlock() }
        return cancelled
    }
    
    /// Get the internal UUID (for internal use only)
    public func getInternalID() -> String {
        return internalID
    }
    
    /// Mark this handle as cancelled (internal use only)
    internal func markCancelled() {
        cancelledFlag.lock()
        defer { cancelledFlag.unlock() }
        cancelled = true
    }
}

/// RequestStatus represents the status of a tracked request
public enum RequestStatus: String, Codable, Sendable {
    case pending = "pending"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case timeout = "timeout"
}