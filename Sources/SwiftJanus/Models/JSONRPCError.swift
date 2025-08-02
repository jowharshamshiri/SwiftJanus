import Foundation

/// JSON-RPC 2.0 compliant error codes
public enum JSONRPCErrorCode: Int, CaseIterable, Codable, Sendable {
    // Standard JSON-RPC 2.0 error codes
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    
    // Implementation-defined server error codes (-32000 to -32099)
    case serverError = -32000
    case serviceUnavailable = -32001
    case authenticationFailed = -32002
    case rateLimitExceeded = -32003
    case resourceNotFound = -32004
    case validationFailed = -32005
    case handlerTimeout = -32006
    case socketError = -32007
    case configurationError = -32008
    case securityViolation = -32009
    case resourceLimitExceeded = -32010
    
    /// Returns the string representation of the error code
    public var stringValue: String {
        switch self {
        case .parseError: return "PARSE_ERROR"
        case .invalidRequest: return "INVALID_REQUEST"
        case .methodNotFound: return "METHOD_NOT_FOUND"
        case .invalidParams: return "INVALID_PARAMS"
        case .internalError: return "INTERNAL_ERROR"
        case .serverError: return "SERVER_ERROR"
        case .serviceUnavailable: return "SERVICE_UNAVAILABLE"
        case .authenticationFailed: return "AUTHENTICATION_FAILED"
        case .rateLimitExceeded: return "RATE_LIMIT_EXCEEDED"
        case .resourceNotFound: return "RESOURCE_NOT_FOUND"
        case .validationFailed: return "VALIDATION_FAILED"
        case .handlerTimeout: return "HANDLER_TIMEOUT"
        case .socketError: return "SOCKET_ERROR"
        case .configurationError: return "CONFIGURATION_ERROR"
        case .securityViolation: return "SECURITY_VIOLATION"
        case .resourceLimitExceeded: return "RESOURCE_LIMIT_EXCEEDED"
        }
    }
    
    /// Returns the standard human-readable message for the error code
    public var message: String {
        switch self {
        case .parseError: return "Parse error"
        case .invalidRequest: return "Invalid Request"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid params"
        case .internalError: return "Internal error"
        case .serverError: return "Server error"
        case .serviceUnavailable: return "Service unavailable"
        case .authenticationFailed: return "Authentication failed"
        case .rateLimitExceeded: return "Rate limit exceeded"
        case .resourceNotFound: return "Resource not found"
        case .validationFailed: return "Validation failed"
        case .handlerTimeout: return "Handler timeout"
        case .socketError: return "Socket error"
        case .configurationError: return "Configuration error"
        case .securityViolation: return "Security violation"
        case .resourceLimitExceeded: return "Resource limit exceeded"
        }
    }
    
    /// Initializes from a numeric error code
    public init?(code: Int) {
        self.init(rawValue: code)
    }
}

/// Additional error context information
public struct JSONRPCErrorData: Codable, Sendable, Equatable {
    public let details: String?
    public let field: String?
    public let value: AnyCodable?
    public let constraints: [String: AnyCodable]?
    public let context: [String: AnyCodable]?
    
    public init(
        details: String? = nil,
        field: String? = nil,
        value: AnyCodable? = nil,
        constraints: [String: AnyCodable]? = nil,
        context: [String: AnyCodable]? = nil
    ) {
        self.details = details
        self.field = field
        self.value = value
        self.constraints = constraints
        self.context = context
    }
    
    /// Custom Equatable implementation since AnyCodable doesn't conform to Equatable
    public static func == (lhs: JSONRPCErrorData, rhs: JSONRPCErrorData) -> Bool {
        return lhs.details == rhs.details &&
               lhs.field == rhs.field
        // Note: value, constraints, and context comparisons omitted due to AnyCodable
        // This provides basic equality for the most commonly used fields
    }
    
    /// Creates error data with just details
    public static func withDetails(_ details: String) -> JSONRPCErrorData {
        return JSONRPCErrorData(details: details)
    }
    
    /// Creates error data with validation information
    public static func withValidation(
        field: String,
        value: AnyCodable,
        details: String,
        constraints: [String: AnyCodable]? = nil
    ) -> JSONRPCErrorData {
        return JSONRPCErrorData(
            details: details,
            field: field,
            value: value,
            constraints: constraints
        )
    }
    
    /// Creates error data with context information
    public static func withContext(
        details: String,
        context: [String: AnyCodable]
    ) -> JSONRPCErrorData {
        return JSONRPCErrorData(details: details, context: context)
    }
}

/// JSON-RPC 2.0 compliant error structure
public struct JSONRPCError: Error, Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONRPCErrorData?
    
    public init(code: JSONRPCErrorCode, message: String? = nil, data: JSONRPCErrorData? = nil) {
        self.code = code.rawValue
        self.message = message ?? code.message
        self.data = data
    }
    
    public init(code: Int, message: String, data: JSONRPCErrorData? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
    
    /// Creates a new JSON-RPC error with the specified code and optional details
    public static func create(
        code: JSONRPCErrorCode,
        details: String? = nil
    ) -> JSONRPCError {
        let data = details.map { JSONRPCErrorData.withDetails($0) }
        return JSONRPCError(code: code, data: data)
    }
    
    /// Creates a new JSON-RPC error with additional context
    public static func createWithContext(
        code: JSONRPCErrorCode,
        details: String? = nil,
        context: [String: AnyCodable]
    ) -> JSONRPCError {
        let data = JSONRPCErrorData.withContext(
            details: details ?? "",
            context: context
        )
        return JSONRPCError(code: code, data: data)
    }
    
    /// Creates a validation-specific JSON-RPC error
    public static func validationError(
        field: String,
        value: AnyCodable,
        details: String,
        constraints: [String: AnyCodable]? = nil
    ) -> JSONRPCError {
        let data = JSONRPCErrorData.withValidation(
            field: field,
            value: value,
            details: details,
            constraints: constraints
        )
        return JSONRPCError(code: .validationFailed, data: data)
    }
    
    /// Returns the error code as an enum if it's a known code
    public var errorCode: JSONRPCErrorCode? {
        return JSONRPCErrorCode(code: code)
    }
    
    /// Returns a formatted error description
    public var errorDescription: String {
        if let data = data, let details = data.details, !details.isEmpty {
            return "JSON-RPC Error \(code): \(message) - \(details)"
        }
        return "JSON-RPC Error \(code): \(message)"
    }
}

// MARK: - Legacy Error Mapping

extension JSONRPCError {
    /// Maps legacy JanusError cases to JSON-RPC error codes
    public static func mapLegacyJanusError(_ error: JanusError) -> JSONRPCErrorCode {
        switch error {
        case .invalidChannel: return .invalidParams
        case .unknownCommand: return .methodNotFound
        case .missingRequiredArgument: return .invalidParams
        case .invalidArgument: return .invalidParams
        case .connectionRequired: return .serviceUnavailable
        case .encodingFailed: return .internalError
        case .decodingFailed: return .parseError
        case .commandTimeout: return .handlerTimeout
        case .handlerTimeout: return .handlerTimeout
        case .resourceLimit: return .resourceLimitExceeded
        case .invalidSocketPath: return .invalidParams
        case .securityViolation: return .securityViolation
        case .malformedData: return .parseError
        case .messageTooLarge: return .resourceLimitExceeded
        case .connectionError: return .serviceUnavailable
        case .ioError: return .internalError
        case .validationError: return .validationFailed
        case .socketCreationFailed: return .socketError
        case .bindFailed: return .socketError
        case .sendFailed: return .socketError
        case .receiveFailed: return .socketError
        case .connectionClosed: return .serviceUnavailable
        case .connectionTestFailed: return .serviceUnavailable
        case .timeout: return .handlerTimeout
        case .timeoutError: return .handlerTimeout
        case .protocolError: return .internalError
        }
    }
    
    /// Creates a JSON-RPC error from a legacy JanusError
    public static func fromLegacyJanusError(_ error: JanusError) -> JSONRPCError {
        let code = mapLegacyJanusError(error)
        let details = error.localizedDescription
        return JSONRPCError.create(code: code, details: details)
    }
    
    /// Maps legacy SocketError string codes to JSON-RPC error codes
    public static func mapLegacySocketErrorCode(_ legacyCode: String) -> JSONRPCErrorCode {
        switch legacyCode {
        case "UNKNOWN_COMMAND": return .methodNotFound
        case "VALIDATION_ERROR": return .validationFailed
        case "INVALID_ARGUMENTS": return .invalidParams
        case "HANDLER_ERROR": return .internalError
        case "HANDLER_TIMEOUT": return .handlerTimeout
        case "SOCKET_ERROR": return .socketError
        case "SECURITY_VIOLATION": return .securityViolation
        case "RESOURCE_LIMIT": return .resourceLimitExceeded
        case "SERVICE_UNAVAILABLE": return .serviceUnavailable
        case "AUTHENTICATION_FAILED": return .authenticationFailed
        case "CONFIGURATION_ERROR": return .configurationError
        default: return .serverError
        }
    }
}

// MARK: - CustomStringConvertible

extension JSONRPCError: CustomStringConvertible {
    public var description: String {
        if let data = data, let details = data.details {
            return "JSON-RPC Error \(code): \(message) (\(details))"
        }
        return "JSON-RPC Error \(code): \(message)"
    }
}

// MARK: - Error Protocol
// JSONRPCError conforms to Error and provides errorDescription

// MARK: - JSONRPCErrorCode Extensions

extension JSONRPCErrorCode: CustomStringConvertible {
    public var description: String {
        return stringValue
    }
}

extension JSONRPCErrorCode: LocalizedError {
    public var errorDescription: String? {
        return message
    }
    
    public var localizedDescription: String {
        return message
    }
}