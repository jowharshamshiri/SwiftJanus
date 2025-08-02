// SecurityValidator.swift
// Comprehensive security validation matching Go/Rust/TypeScript implementations

import Foundation
import RegexBuilder

/// Security validation framework implementing all 25+ security mechanisms
/// Matches Go, Rust, and TypeScript implementations exactly for cross-language parity
public final class SecurityValidator {
    
    // MARK: - Configuration Constants
    
    private static let maxSocketPathLength = 104  // Unix socket path limit
    private static let maxChannelNameLength = 64
    private static let maxCommandNameLength = 64
    private static let maxArgsDataSize = 64 * 1024  // 64KB limit
    private static let maxMessageSize = 8192
    
    // MARK: - Regular Expressions
    
    private static let commandNamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$")
    private static let channelNamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$")
    private static let socketPathPattern = try! NSRegularExpression(pattern: "^(/[a-zA-Z0-9._-]+)+$")
    
    // MARK: - Allowed Directories
    
    private static let allowedDirectories: Set<String> = [
        "/tmp", "/var/tmp", "/dev/shm"
    ]
    
    public init() {}
    
    // MARK: - Socket Path Validation
    
    /// Validate socket path for security (matches Go implementation exactly)
    public static func validateSocketPath(_ path: String) throws {
        // 1. Path length validation
        guard path.count <= maxSocketPathLength else {
            throw JanusError.securityViolation("Socket path exceeds maximum length of \(maxSocketPathLength) characters")
        }
        
        // 2. Must be absolute path
        guard path.hasPrefix("/") else {
            throw JanusError.securityViolation("Socket path must be absolute")
        }
        
        // 3. Check for path traversal sequences
        if path.contains("../") || path.contains("..\\") {
            throw JanusError.securityViolation("Path traversal detected in socket path")
        }
        
        // 4. Validate path characters
        let range = NSRange(location: 0, length: path.utf16.count)
        guard socketPathPattern.firstMatch(in: path, range: range) != nil else {
            throw JanusError.securityViolation("Socket path contains invalid characters")
        }
        
        // 5. Check allowed directories
        let pathURL = URL(fileURLWithPath: path)
        let directory = pathURL.deletingLastPathComponent().path
        
        guard allowedDirectories.contains(where: { directory.hasPrefix($0) }) else {
            throw JanusError.securityViolation("Socket path not in allowed directory")
        }
        
        // 6. Check for null bytes
        if path.contains("\0") {
            throw JanusError.securityViolation("Socket path contains null bytes")
        }
    }
    
    // MARK: - Channel Validation
    
    /// Validate channel name (matches Go implementation exactly)
    public static func validateChannelName(_ channelName: String) throws {
        // 1. Length validation
        guard !channelName.isEmpty else {
            throw JanusError.securityViolation("Channel name cannot be empty")
        }
        
        guard channelName.count <= maxChannelNameLength else {
            throw JanusError.securityViolation("Channel name exceeds maximum length of \(maxChannelNameLength) characters")
        }
        
        // 2. Character validation (alphanumeric + hyphen + underscore only)
        let range = NSRange(location: 0, length: channelName.utf16.count)
        guard channelNamePattern.firstMatch(in: channelName, range: range) != nil else {
            throw JanusError.securityViolation("Channel name contains invalid characters (only alphanumeric, hyphen, underscore allowed)")
        }
        
        // 3. Check for reserved channel names
        let reservedChannels: Set<String> = ["system", "admin", "root", "test"]
        if reservedChannels.contains(channelName.lowercased()) {
            throw JanusError.securityViolation("Channel name '\(channelName)' is reserved")
        }
    }
    
    // MARK: - Command Validation
    
    /// Validate command name (matches Go implementation exactly)
    public static func validateCommandName(_ commandName: String) throws {
        // 1. Length validation
        guard !commandName.isEmpty else {
            throw JanusError.securityViolation("Command name cannot be empty")
        }
        
        guard commandName.count <= maxCommandNameLength else {
            throw JanusError.securityViolation("Command name exceeds maximum length of \(maxCommandNameLength) characters")
        }
        
        // 2. Character validation (alphanumeric + hyphen + underscore only)
        let range = NSRange(location: 0, length: commandName.utf16.count)
        guard commandNamePattern.firstMatch(in: commandName, range: range) != nil else {
            throw JanusError.securityViolation("Command name contains invalid characters (only alphanumeric, hyphen, underscore allowed)")
        }
        
        // 3. Check for dangerous command patterns
        let dangerousPatterns = ["eval", "exec", "system", "shell", "rm", "delete", "drop"]
        for pattern in dangerousPatterns {
            if commandName.lowercased().contains(pattern) {
                throw JanusError.securityViolation("Command name contains dangerous pattern: \(pattern)")
            }
        }
    }
    
    // MARK: - Arguments Validation
    
    /// Validate command arguments (matches Go implementation exactly)
    public static func validateCommandArgs(_ args: [String: AnyCodable]?) throws {
        guard let args = args else { return }
        
        // 1. Serialize to check size
        let jsonData = try JSONEncoder().encode(args)
        guard jsonData.count <= maxArgsDataSize else {
            throw JanusError.securityViolation("Command arguments exceed maximum size of \(maxArgsDataSize) bytes")
        }
        
        // 2. Check for dangerous argument names
        let dangerousArgs = ["__proto__", "constructor", "prototype", "eval", "function"]
        for argName in args.keys {
            if dangerousArgs.contains(argName.lowercased()) {
                throw JanusError.securityViolation("Dangerous argument name: \(argName)")
            }
        }
        
        // 3. Validate argument values for injection attempts
        for (key, value) in args {
            try validateArgumentValue(key: key, value: value)
        }
    }
    
    private static func validateArgumentValue(key: String, value: AnyCodable) throws {
        // Check for SQL injection patterns
        if let stringValue = value.value as? String {
            let sqlPatterns = ["'", "\"", "--", "/*", "*/", "union", "select", "drop", "delete", "insert", "update"]
            let lowerValue = stringValue.lowercased()
            
            for pattern in sqlPatterns {
                if lowerValue.contains(pattern) {
                    throw JanusError.securityViolation("Argument '\(key)' contains potentially dangerous pattern: \(pattern)")
                }
            }
            
            // Check for script injection
            let scriptPatterns = ["<script", "javascript:", "vbscript:", "onload=", "onerror="]
            for pattern in scriptPatterns {
                if lowerValue.contains(pattern) {
                    throw JanusError.securityViolation("Argument '\(key)' contains script injection pattern: \(pattern)")
                }
            }
        }
    }
    
    // MARK: - Message Content Validation
    
    /// Validate message size (matches Go implementation exactly)
    public static func validateMessageSize(_ data: Data) throws {
        guard data.count <= maxMessageSize else {
            throw JanusError.securityViolation("Message size \(data.count) exceeds maximum of \(maxMessageSize) bytes")
        }
    }
    
    /// Validate message content for security (matches Go/Rust implementations)
    public static func validateMessageContent(_ data: Data) throws {
        // 1. Check for null bytes in message content
        guard !data.contains(0) else {
            throw JanusError.securityViolation("Message contains null bytes")
        }
        
        // 2. Validate UTF-8 encoding
        guard String(data: data, encoding: .utf8) != nil else {
            throw JanusError.securityViolation("Message contains invalid UTF-8 encoding")
        }
        
        // 3. Basic JSON structure validation
        if data.count > 0 {
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                // Ensure it's a JSON object (dictionary), not just any JSON
                guard jsonObject is [String: Any] else {
                    throw JanusError.securityViolation("Message must be a JSON object")
                }
            } catch {
                throw JanusError.securityViolation("Message contains invalid JSON structure")
            }
        }
    }
    
    /// Validate string content for UTF-8 and null bytes (matches Go implementation)
    public static func validateStringContent(_ string: String) throws {
        // Check for null bytes
        guard !string.contains("\0") else {
            throw JanusError.securityViolation("String contains null bytes")
        }
        
        // Validate UTF-8 encoding (Swift strings are already UTF-8, but check for valid encoding)
        guard string.data(using: .utf8) != nil else {
            throw JanusError.securityViolation("String contains invalid UTF-8")
        }
    }
    
    // MARK: - Command ID Validation
    
    /// Validate command ID format and security
    public static func validateCommandId(_ commandId: String) throws {
        guard !commandId.isEmpty else {
            throw JanusError.securityViolation("Command ID cannot be empty")
        }
        
        guard commandId.count <= 64 else {
            throw JanusError.securityViolation("Command ID exceeds maximum length of 64 characters")
        }
        
        // Must be alphanumeric or UUID-like format
        let uuidPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9-]+$")
        let range = NSRange(location: 0, length: commandId.utf16.count)
        guard uuidPattern.firstMatch(in: commandId, range: range) != nil else {
            throw JanusError.securityViolation("Command ID contains invalid characters")
        }
    }
    
    // MARK: - UUID Format Validation
    
    /// Validate UUID format (RFC 4122 compliant)
    public static func validateUUIDFormat(_ uuid: String) throws {
        let uuidRegex = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
        let range = NSRange(location: 0, length: uuid.utf16.count)
        
        guard uuidRegex.firstMatch(in: uuid, range: range) != nil else {
            throw JanusError.securityViolation("Invalid UUID format: \(uuid)")
        }
    }
    
    // MARK: - Timestamp Format Validation
    
    /// Validate ISO 8601 timestamp format
    public static func validateTimestampFormat(_ timestamp: String) throws {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard iso8601Formatter.date(from: timestamp) != nil else {
            throw JanusError.securityViolation("Invalid ISO 8601 timestamp format: \(timestamp)")
        }
    }
    
    // MARK: - Timeout Range Validation
    
    /// Validate timeout values are within acceptable range
    public static func validateTimeoutRange(_ timeout: TimeInterval) throws {
        let minTimeout: TimeInterval = 0.1 // 100ms minimum
        let maxTimeout: TimeInterval = 3600.0 // 1 hour maximum
        
        guard timeout >= minTimeout else {
            throw JanusError.securityViolation("Timeout \(timeout) is below minimum of \(minTimeout) seconds")  
        }
        
        guard timeout <= maxTimeout else {
            throw JanusError.securityViolation("Timeout \(timeout) exceeds maximum of \(maxTimeout) seconds")
        }
    }
    
    // MARK: - Resource Monitoring
    
    /// Resource limit monitoring configuration
    public struct ResourceLimits {
        public let maxActiveConnections: Int
        public let maxCommandHandlers: Int
        public let maxPendingRequests: Int
        public let maxMemoryUsage: Int // bytes
        
        public init(maxActiveConnections: Int = 100, maxCommandHandlers: Int = 50, maxPendingRequests: Int = 1000, maxMemoryUsage: Int = 64 * 1024 * 1024) {
            self.maxActiveConnections = maxActiveConnections
            self.maxCommandHandlers = maxCommandHandlers
            self.maxPendingRequests = maxPendingRequests
            self.maxMemoryUsage = maxMemoryUsage
        }
    }
    
    /// Validate resource usage against limits
    public static func validateResourceUsage(
        activeConnections: Int,
        commandHandlers: Int,
        pendingRequests: Int,
        memoryUsage: Int,
        limits: ResourceLimits = ResourceLimits()
    ) throws {
        guard activeConnections <= limits.maxActiveConnections else {
            throw JanusError.securityViolation("Active connections (\(activeConnections)) exceed limit (\(limits.maxActiveConnections))")
        }
        
        guard commandHandlers <= limits.maxCommandHandlers else {
            throw JanusError.securityViolation("Command handlers (\(commandHandlers)) exceed limit (\(limits.maxCommandHandlers))")
        }
        
        guard pendingRequests <= limits.maxPendingRequests else {
            throw JanusError.securityViolation("Pending requests (\(pendingRequests)) exceed limit (\(limits.maxPendingRequests))")
        }
        
        guard memoryUsage <= limits.maxMemoryUsage else {
            throw JanusError.securityViolation("Memory usage (\(memoryUsage) bytes) exceeds limit (\(limits.maxMemoryUsage) bytes)")
        }
    }
    
    // MARK: - Channel Isolation
    
    /// Validate channel isolation rules
    public static func validateChannelIsolation(requestedChannel: String, allowedChannels: Set<String>) throws {
        guard allowedChannels.contains(requestedChannel) else {
            throw JanusError.securityViolation("Access denied to channel '\(requestedChannel)' - channel isolation violation")
        }
    }
    
    /// Check for reserved channel names
    public static func validateReservedChannels(_ channelId: String) throws {
        let reservedChannels: Set<String> = ["system", "admin", "root", "internal", "__proto__", "constructor"]
        
        guard !reservedChannels.contains(channelId.lowercased()) else {
            throw JanusError.securityViolation("Channel ID '\(channelId)' is reserved and cannot be used")
        }
    }
    
    // MARK: - Comprehensive Security Check
    
    /// Perform comprehensive security validation on a socket command
    public static func validateJanusCommand(_ command: JanusCommand) throws {
        try validateCommandId(command.id)
        try validateChannelName(command.channelId)
        try validateCommandName(command.command)
        try validateCommandArgs(command.args)
        
        // Validate reply-to socket path if present
        if let replyTo = command.replyTo {
            try validateSocketPath(replyTo)
        }
        
        // Validate timestamp (must be reasonable)
        let now = Date().timeIntervalSince1970
        let timeDiff = abs(command.timestamp - now)
        
        // Allow 5-minute clock skew
        guard timeDiff <= 300 else {
            throw JanusError.securityViolation("Command timestamp is too far from current time")
        }
    }
    
    // MARK: - Rate Limiting Helpers
    
    /// Check if socket path looks like it could cause resource exhaustion
    public static func validateSocketPathForResourceLimits(_ path: String) throws {
        // Check for patterns that might cause resource exhaustion
        let components = path.components(separatedBy: "/")
        
        // Too many path components could indicate an attack
        guard components.count <= 10 else {
            throw JanusError.securityViolation("Socket path has too many components")
        }
        
        // Check for excessively long component names
        for component in components {
            guard component.count <= 50 else {
                throw JanusError.securityViolation("Socket path component exceeds maximum length")
            }
        }
    }
}

