import Foundation

/// Result of a handler execution with type safety
public enum HandlerResult<T> {
    case success(T)
    case error(JSONRPCError)
    
    /// Create success result
    public static func withValue(_ value: T) -> HandlerResult<T> {
        return .success(value)
    }
    
    /// Create error result
    public static func withError(_ error: JSONRPCError) -> HandlerResult<T> {
        return .error(error)
    }
    
    /// Create result from Swift Result type
    public static func from(_ result: Result<T, Error>) -> HandlerResult<T> {
        switch result {
        case .success(let value):
            return .success(value)
        case .failure(let error):
            return .error(JSONRPCError.mapFromError(error))
        }
    }
}

/// Enhanced request handler protocol for direct value responses
public protocol RequestHandler {
    associatedtype Output: Codable
    
    func handle(_ request: JanusRequest) async -> HandlerResult<Output>
}

/// Synchronous handler wrapper for direct value responses
public struct SyncHandler<Output: Codable>: RequestHandler, @unchecked Sendable {
    private let handler: @Sendable (JanusRequest) -> HandlerResult<Output>
    
    public init(_ handler: @escaping @Sendable (JanusRequest) -> HandlerResult<Output>) {
        self.handler = handler
    }
    
    public func handle(_ request: JanusRequest) async -> HandlerResult<Output> {
        return handler(request)
    }
}

/// Asynchronous handler wrapper for direct value responses
public struct AsyncHandler<Output: Codable>: RequestHandler, @unchecked Sendable {
    private let handler: @Sendable (JanusRequest) async -> HandlerResult<Output>
    
    public init(_ handler: @escaping @Sendable (JanusRequest) async -> HandlerResult<Output>) {
        self.handler = handler
    }
    
    public func handle(_ request: JanusRequest) async -> HandlerResult<Output> {
        return await handler(request)
    }
}

// MARK: - Direct Value Handler Constructors

/// Create a boolean handler
public func boolHandler(_ handler: @escaping @Sendable (JanusRequest) -> Result<Bool, Error>) -> SyncHandler<Bool> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

/// Create a string handler
public func stringHandler(_ handler: @escaping @Sendable (JanusRequest) -> Result<String, Error>) -> SyncHandler<String> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

/// Create an integer handler
public func intHandler(_ handler: @escaping @Sendable (JanusRequest) -> Result<Int, Error>) -> SyncHandler<Int> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

/// Create a double handler
public func doubleHandler(_ handler: @escaping @Sendable (JanusRequest) -> Result<Double, Error>) -> SyncHandler<Double> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

/// Create an array handler
public func arrayHandler<T: Codable>(_ handler: @escaping @Sendable (JanusRequest) -> Result<[T], Error>) -> SyncHandler<[T]> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

/// Create a custom object handler
public func objectHandler<T: Codable>(_ handler: @escaping @Sendable (JanusRequest) -> Result<T, Error>) -> SyncHandler<T> {
    return SyncHandler { request in
        HandlerResult.from(handler(request))
    }
}

// MARK: - Async Handler Constructors

/// Create an async boolean handler
public func asyncBoolHandler(_ handler: @escaping @Sendable (JanusRequest) async -> Result<Bool, Error>) -> AsyncHandler<Bool> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

/// Create an async string handler
public func asyncStringHandler(_ handler: @escaping @Sendable (JanusRequest) async -> Result<String, Error>) -> AsyncHandler<String> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

/// Create an async integer handler
public func asyncIntHandler(_ handler: @escaping @Sendable (JanusRequest) async -> Result<Int, Error>) -> AsyncHandler<Int> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

/// Create an async double handler
public func asyncDoubleHandler(_ handler: @escaping @Sendable (JanusRequest) async -> Result<Double, Error>) -> AsyncHandler<Double> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

/// Create an async array handler
public func asyncArrayHandler<T: Codable>(_ handler: @escaping @Sendable (JanusRequest) async -> Result<[T], Error>) -> AsyncHandler<[T]> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

/// Create an async custom object handler
public func asyncObjectHandler<T: Codable>(_ handler: @escaping @Sendable (JanusRequest) async -> Result<T, Error>) -> AsyncHandler<T> {
    return AsyncHandler { request in
        HandlerResult.from(await handler(request))
    }
}

// MARK: - Type-Erased Handler for Registry

/// Type-erased handler for registry storage
public protocol BoxedHandler: Sendable {
    func handleBoxed(_ request: JanusRequest) async -> Result<Any, JSONRPCError>
}

extension SyncHandler: BoxedHandler {
    public func handleBoxed(_ request: JanusRequest) async -> Result<Any, JSONRPCError> {
        let result = await handle(request)
        switch result {
        case .success(let value):
            return .success(value)
        case .error(let error):
            return .failure(error)
        }
    }
}

extension AsyncHandler: BoxedHandler {
    public func handleBoxed(_ request: JanusRequest) async -> Result<Any, JSONRPCError> {
        let result = await handle(request)
        switch result {
        case .success(let value):
            return .success(value)
        case .error(let error):
            return .failure(error)
        }
    }
}

// MARK: - Enhanced Handler Registry

/// Enhanced handler registry with type safety and direct value support
public actor HandlerRegistry {
    private var handlers: [String: BoxedHandler] = [:]
    private let maxHandlers: Int
    
    public init(maxHandlers: Int = 100) {
        self.maxHandlers = maxHandlers
    }
    
    /// Register a handler for a request
    public func registerHandler<H: RequestHandler & Sendable>(_ request: String, handler: H) throws {
        guard handlers.count < maxHandlers else {
            throw JSONRPCError.create(code: .resourceLimitExceeded, details: "Maximum handlers (\(maxHandlers)) exceeded")
        }
        
        // Wrap the typed handler in a BoxedHandler
        let boxed = TypedHandlerWrapper(handler)
        handlers[request] = boxed
    }
    
    /// Unregister a handler
    public func unregisterHandler(_ request: String) -> Bool {
        return handlers.removeValue(forKey: request) != nil
    }
    
    /// Execute a handler for a request
    public func executeHandler(_ request: String, _ cmd: JanusRequest) async -> Result<Any, JSONRPCError> {
        guard let handler = handlers[request] else {
            return .failure(JSONRPCError.create(
                code: .methodNotFound,
                details: "Request not found: \(request)"
            ))
        }
        
        return await handler.handleBoxed(cmd)
    }
    
    /// Check if a handler exists for a request
    public func hasHandler(_ request: String) -> Bool {
        return handlers[request] != nil
    }
    
    /// Get the current number of registered handlers
    public func handlerCount() -> Int {
        return handlers.count
    }
}

/// Wrapper to convert typed handlers to BoxedHandler
private struct TypedHandlerWrapper<H: RequestHandler & Sendable>: BoxedHandler {
    private let handler: H
    
    init(_ handler: H) {
        self.handler = handler
    }
    
    func handleBoxed(_ request: JanusRequest) async -> Result<Any, JSONRPCError> {
        let result = await handler.handle(request)
        switch result {
        case .success(let value):
            return .success(value)
        case .error(let error):
            return .failure(error)
        }
    }
}

// MARK: - Extensions

extension JSONRPCError {
    /// Map a Swift Error to JSONRPCError
    public static func mapFromError(_ error: Error) -> JSONRPCError {
        // If it's already a JSONRPCError, return as-is
        if let jsonrpcError = error as? JSONRPCError {
            return jsonrpcError
        }
        
        // Map common error types to appropriate JSON-RPC error codes
        let errorMessage = error.localizedDescription
        
        let code: JSONRPCErrorCode
        switch error {
        case is DecodingError, is EncodingError:
            code = .parseError
        case let jsonRPCError as JSONRPCError:
            // Already a JSON-RPC error, preserve the error code
            return jsonRPCError
        default:
            // Determine code based on error message content
            let message = errorMessage.lowercased()
            if message.contains("validation") {
                code = .validationFailed
            } else if message.contains("timeout") {
                code = .handlerTimeout
            } else if message.contains("not found") {
                code = .resourceNotFound
            } else if message.contains("invalid") {
                code = .invalidParams
            } else if message.contains("parse") {
                code = .parseError
            } else if message.contains("security") {
                code = .securityViolation
            } else if message.contains("limit") {
                code = .resourceLimitExceeded
            } else if message.contains("auth") {
                code = .authenticationFailed
            } else {
                code = .internalError
            }
        }
        
        return JSONRPCError.create(code: code, details: errorMessage)
    }
}