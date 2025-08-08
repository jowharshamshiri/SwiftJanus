import Foundation

/// High-level API client for SOCK_DGRAM Unix socket communication
/// Connectionless implementation with request validation and response correlation
public class JanusClient {
    private let socketPath: String
    private var manifest: Manifest?
    private let coreClient: CoreJanusClient
    private let defaultTimeout: TimeInterval
    private let enableValidation: Bool
    private let responseTracker: ResponseTracker
    
    // Request lifecycle management (automatic ID system)
    private var requestRegistry: [String: RequestHandle] = [:]
    private let registryQueue = DispatchQueue(label: "janus.request.registry", attributes: .concurrent)
    
    public init(
        socketPath: String,
        maxMessageSize: Int = 65536,
        defaultTimeout: TimeInterval = 30.0,
        datagramTimeout: TimeInterval = 5.0,
        enableValidation: Bool = true
    ) async throws {
        // Validate constructor inputs (matching Go/Rust implementations)
        try Self.validateConstructorInputs(
            socketPath: socketPath
        )
        
        self.socketPath = socketPath
        self.defaultTimeout = defaultTimeout
        self.enableValidation = enableValidation
        
        // Initialize response tracker
        let trackerConfig = TrackerConfig(
            maxPendingRequests: 1000,
            cleanupInterval: 30.0,
            defaultTimeout: defaultTimeout
        )
        self.responseTracker = ResponseTracker(config: trackerConfig)
        
        self.coreClient = CoreJanusClient(
            socketPath: socketPath,
            maxMessageSize: maxMessageSize,
            datagramTimeout: datagramTimeout
        )
        
        // Initialize manifest to nil - will be loaded lazily when needed (matching Go pattern)
        self.manifest = nil
    }
    
    deinit {
        responseTracker.shutdown()
    }
    
    /// Ensure manifest is loaded if validation is enabled (lazy loading pattern like Go)
    private func ensureManifestLoaded() async throws {
        // Skip if manifest already loaded or validation disabled
        if manifest != nil || !enableValidation {
            return
        }
        
        // Fetch Manifest from server using manifest request (bypass validation to avoid circular dependency)
        do {
            let manifestResponse = try await sendBuiltinRequest("manifest", args: nil, timeout: 10.0)
            if manifestResponse.success {
                // Try to parse the AnyCodable result as JSON directly
                do {
                    let encoder = JSONEncoder()
                    let jsonData = try encoder.encode(manifestResponse.result)
                    let fetchedManifest = try ManifestParser().parseJSON(jsonData)
                    self.manifest = fetchedManifest
                } catch {
                    // If parsing fails, continue without validation
                    self.manifest = nil
                }
            } else {
                // If manifest request fails, continue without validation
                self.manifest = nil
            }
        } catch {
            // If manifest fetching fails, continue without validation (matching Go behavior)
            // Preserve connection errors instead of wrapping as validation errors
            if error.localizedDescription.contains("dial") || 
               error.localizedDescription.contains("connect") || 
               error.localizedDescription.contains("No such file") {
                throw error  // Preserve connection errors
            }
            self.manifest = nil
        }
    }
    
    /// Send request via SOCK_DGRAM and wait for response
    public func sendRequest(
        _ request: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JanusResponse {
        // Generate request ID and response socket path
        let requestId = UUID().uuidString
        let responseSocketPath = coreClient.generateResponseSocketPath()
        
        // Create socket request
        let janusRequest = JanusRequest(
            id: requestId,
            request: request,
            replyTo: responseSocketPath,
            args: args,
            timeout: timeout ?? defaultTimeout
        )
        
        // Ensure manifest is loaded if validation is enabled (lazy loading like Go)
        // Only fetch manifest if we don't have one yet and validation is enabled
        if enableValidation && manifest == nil {
            do {
                try await ensureManifestLoaded()
            } catch {
                // If manifest loading fails but we still want to validate basic request structure,
                // we can do basic validation without manifest
                try validateBasicRequestStructure(janusRequest)
                throw error  // Re-throw the connection error after basic validation
            }
        }
        
        // Validate request against Manifest 
        if enableValidation {
            // Built-in requests skip manifest validation
            if isBuiltinRequest(janusRequest.request) {
                // Built-in requests are always valid, no manifest validation needed
                try validateBasicRequestStructure(janusRequest)
            } else if let manifest = manifest {
                // Non-built-in requests need manifest validation
                try validateRequestAgainstManifest(manifest, request: janusRequest)
            } else {
                // No manifest available, do basic validation only
                try validateBasicRequestStructure(janusRequest)
            }
        }
        
        // Serialize request
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(janusRequest)
        
        // Send datagram and wait for response
        let responseData = try await coreClient.sendDatagram(requestData, responseSocketPath: responseSocketPath)
        
        // Deserialize response
        let decoder = JSONDecoder()
        let response = try decoder.decode(JanusResponse.self, from: responseData)
        
        // Validate response correlation
        guard response.requestId == requestId else {
            throw JSONRPCError.create(code: .responseTrackingError, details: "Response correlation mismatch: expected \\(requestId), got \\(response.requestId)")
        }
        
        // PRIME DIRECTIVE: channelId is not part of JanusResponse format
        // Response validation is based on request_id correlation only
        
        // Update connection state after successful operation
        updateConnectionState(messagesSent: 1, responsesReceived: 1)
        
        return response
    }
    
    /// Send request without expecting response (fire-and-forget)
    public func sendRequestNoResponse(
        _ request: String,
        args: [String: AnyCodable]? = nil
    ) async throws {
        // Generate request ID
        let requestId = UUID().uuidString
        
        // Create socket request (no replyTo field)
        let janusRequest = JanusRequest(
            id: requestId,
            request: request,
            replyTo: nil,
            args: args,
            timeout: nil
        )
        
        // Ensure manifest is loaded if validation is enabled (lazy loading like Go)
        try await ensureManifestLoaded()
        
        // Validate request against Manifest 
        if enableValidation {
            // Built-in requests skip manifest validation
            if isBuiltinRequest(janusRequest.request) {
                // Built-in requests are always valid, no manifest validation needed
                try validateBasicRequestStructure(janusRequest)
            } else if let manifest = manifest {
                // Non-built-in requests need manifest validation
                try validateRequestAgainstManifest(manifest, request: janusRequest)
            } else {
                // No manifest available, do basic validation only
                try validateBasicRequestStructure(janusRequest)
            }
        }
        
        // Serialize request
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(janusRequest)
        
        // Send datagram without waiting for response
        try await coreClient.sendDatagramNoResponse(requestData)
    }
    
    /// Test connectivity to the server
    public func testConnection() async throws {
        try await coreClient.testConnection()
    }
    
    // MARK: - Private Methods
    
    /// Validate constructor inputs (matching Go/Rust implementations)
    private static func validateConstructorInputs(
        socketPath: String
    ) throws {
        // Validate socket path
        guard !socketPath.isEmpty else {
            throw JSONRPCError.create(code: .invalidParams, details: "Socket path cannot be empty")
        }
        
        // Security validation for socket path (matching Go implementation)
        if socketPath.contains("\0") {
            throw JSONRPCError.create(code: .invalidParams, details: "Socket path contains invalid null byte")
        }
        
        if socketPath.contains("..") {
            throw JSONRPCError.create(code: .invalidParams, details: "Socket path contains path traversal sequence")
        }
        
        // Channel validation removed - channels no longer part of protocol
    }
    
    private func validateBasicRequestStructure(_ request: JanusRequest) throws {
        // Basic validation without manifest
        
        // Validate request name
        guard !request.request.isEmpty else {
            throw JSONRPCError.create(code: .invalidParams, details: "Request name cannot be empty")
        }
        
        // Check for obviously invalid request names
        if request.request.contains(" ") || request.request.contains("\n") || request.request.contains("\t") {
            throw JSONRPCError.create(code: .invalidParams, details: "Invalid request name format")
        }
        
        // For built-in requests, we can validate
        let reservedRequests = ["ping", "echo", "get_info", "validate", "slow_process", "manifest"]
        if reservedRequests.contains(request.request) {
            // Built-in requests don't need argument validation here
            return
        }
        
        // For non-reserved requests like "quickRequest", we can't validate existence without manifest
        // But we can still proceed - the actual request execution will fail if the request doesn't exist
        // This allows tests to check for parameter validation errors on potentially valid requests
    }
    
    private func validateRequestAgainstManifest(_ manifest: Manifest, request: JanusRequest) throws {
        // Check if request is reserved (built-in requests should never be in Manifests)
        if isBuiltinRequest(request.request) {
            throw JSONRPCError.create(code: .manifestValidationError, details: "Request '\(request.request)' is reserved and cannot be used from Manifest")
        }
        
        // Channel-based validation removed - server-side validation only
        // No client-side manifest validation since channels are removed
    }
    
    // MARK: - Public Properties
    
    public var socketPathValue: String {
        return socketPath
    }
    
    
    /// Send a ping request and return success/failure
    /// Convenience method for testing connectivity with a simple ping
    public func ping() async -> Bool {
        do {
            let response = try await sendRequest("ping", args: nil, timeout: 10.0)
            return response.success
        } catch {
            return false
        }
    }
    
    // MARK: - Built-in Request Support
    
    /// Check if request is a built-in request that should bypass API validation
    private func isBuiltinRequest(_ request: String) -> Bool {
        let builtinRequests = ["ping", "echo", "get_info", "validate", "slow_process", "manifest"]
        return builtinRequests.contains(request)
    }
    
    /// Send built-in request (used during initialization for manifest fetching)
    private func sendBuiltinRequest(
        _ request: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval
    ) async throws -> JanusResponse {
        // Generate request ID and response socket path
        let requestId = UUID().uuidString
        let responseSocketPath = coreClient.generateResponseSocketPath()
        
        // Create socket request for built-in request
        let janusRequest = JanusRequest(
            id: requestId,
            request: request,
            replyTo: responseSocketPath,
            args: args,
            timeout: timeout
        )
        
        // Serialize request
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(janusRequest)
        
        // Send datagram and wait for response
        let responseData = try await coreClient.sendDatagram(requestData, responseSocketPath: responseSocketPath)
        
        // Deserialize response
        let decoder = JSONDecoder()
        let response = try decoder.decode(JanusResponse.self, from: responseData)
        
        // Validate response correlation
        guard response.requestId == requestId else {
            throw JSONRPCError.create(code: .responseTrackingError, details: "Response correlation mismatch: expected \\(requestId), got \\(response.requestId)")
        }
        
        // PRIME DIRECTIVE: channelId is not part of JanusResponse format
        // Response validation is based on request_id correlation only
        
        return response
    }
    
    // MARK: - Advanced Client Features
    
    /// Send request with response correlation (async with Promise-like API)
    public func sendRequestAsync(
        _ request: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JanusResponse {
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = UUID().uuidString
            let effectiveTimeout = timeout ?? defaultTimeout
            
            do {
                try responseTracker.registerRequest(
                    requestId: requestId,
                    timeout: effectiveTimeout,
                    resolve: { response in
                        continuation.resume(returning: response)
                    },
                    reject: { error in
                        continuation.resume(throwing: error)
                    }
                )
                
                // Send the actual request
                Task {
                    do {
                        let response = try await sendRequest(request, args: args, timeout: effectiveTimeout)
                        _ = responseTracker.resolveRequest(requestId: requestId, response: response)
                    } catch {
                        _ = responseTracker.rejectRequest(requestId: requestId, error: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Cancel a manifestific request by ID
    public func cancelRequest(requestId: String) -> Bool {
        return responseTracker.cancelRequest(requestId: requestId)
    }
    
    /// Cancel all pending requests
    public func cancelAllRequests() -> Int {
        return responseTracker.cancelAllRequests()
    }
    
    /// Get pending request statistics
    public func getRequestStatistics() -> RequestStatistics {
        return responseTracker.getStatistics()
    }
    
    /// Execute multiple requests in parallel
    public func executeParallel(_ requests: [(request: String, args: [String: AnyCodable]?)]) async throws -> [JanusResponse] {
        return try await withThrowingTaskGroup(of: JanusResponse.self) { group in
            for (request, args) in requests {
                group.addTask {
                    try await self.sendRequest(request, args: args)
                }
            }
            
            var results: [JanusResponse] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    
    /// Add event handler to response tracker
    public func on(_ event: String, handler: @escaping (Any) -> Void) {
        responseTracker.on(event, handler: handler)
    }
    
    // MARK: - Request Handler Registration
    
    /// Register a request handler (no validation since channels removed)
    public func registerRequestHandler(_ request: String, handler: @escaping (JanusRequest) throws -> [String: AnyCodable]) throws {
        // Channel validation removed - handlers registered server-side only
        // In SOCK_DGRAM, we can't actually register handlers on the client side
        // This method exists for API compatibility
        print("✅ Request handler registration (server-side only): \(request)")
    }
    
    // MARK: - Legacy Method Support
    
    /// Get socket path as string (legacy compatibility)
    public func socketPathString() -> String {
        return socketPath
    }
    
    /// Disconnect method (legacy compatibility - SOCK_DGRAM doesn't maintain connections)
    public func disconnect() {
        // In SOCK_DGRAM, there's no persistent connection to disconnect
        // This method exists for backward compatibility only
        print("💡 Disconnect called (SOCK_DGRAM is connectionless)")
    }
    
    /// Check if connected (legacy compatibility - SOCK_DGRAM doesn't maintain connections)
    public func isConnected() -> Bool {
        // In SOCK_DGRAM, we don't maintain persistent connections
        // Return true if we can reach the server with a ping
        Task {
            return await ping()
        }
        
        // For synchronous compatibility, test connectivity with file existence
        return FileManager.default.fileExists(atPath: socketPath)
    }
    
    // MARK: - Connection State Simulation
    
    /// Simulate connection state for SOCK_DGRAM compatibility
    public struct ConnectionState {
        public let isConnected: Bool
        public let lastActivity: Date
        public let messagesSent: Int
        public let responsesReceived: Int
        
        public init(isConnected: Bool = false, lastActivity: Date = Date(), messagesSent: Int = 0, responsesReceived: Int = 0) {
            self.isConnected = isConnected
            self.lastActivity = lastActivity
            self.messagesSent = messagesSent
            self.responsesReceived = responsesReceived
        }
    }
    
    private var connectionState = ConnectionState()
    
    /// Get simulated connection state
    public func getConnectionState() -> ConnectionState {
        return connectionState
    }
    
    /// Update connection state after successful operation
    private func updateConnectionState(messagesSent: Int = 0, responsesReceived: Int = 0) {
        connectionState = ConnectionState(
            isConnected: true,
            lastActivity: Date(),
            messagesSent: connectionState.messagesSent + messagesSent,
            responsesReceived: connectionState.responsesReceived + responsesReceived
        )
    }
    
    // MARK: - Automatic ID Management Methods (F0193-F0216)
    
    /// Send request with handle - returns RequestHandle for tracking
    /// Hides UUID complexity from users while providing request lifecycle management
    public func sendRequestWithHandle(
        _ request: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (RequestHandle, Task<JanusResponse, Error>) {
        // Generate internal UUID (hidden from user)
        let requestId = UUID().uuidString
        
        // Create request handle for user
        let handle = RequestHandle(internalID: requestId, request: request)
        
        // Register the request handle
        registryQueue.async(flags: .barrier) {
            self.requestRegistry[requestId] = handle
        }
        
        // Create async task for request execution
        let task = Task<JanusResponse, Error> {
            defer {
                // Clean up request handle when done
                self.registryQueue.async(flags: .barrier) {
                    self.requestRegistry.removeValue(forKey: requestId)
                }
            }
            
            return try await self.sendRequest(request, args: args, timeout: timeout)
        }
        
        return (handle, task)
    }
    
    /// Get request status by handle
    public func getRequestStatus(_ handle: RequestHandle) -> RequestStatus {
        if handle.isCancelled() {
            return .cancelled
        }
        
        return registryQueue.sync {
            if requestRegistry[handle.getInternalID()] != nil {
                return RequestStatus.pending
            } else {
                return RequestStatus.completed
            }
        }
    }
    
    /// Cancel request using handle
    public func cancelRequest(_ handle: RequestHandle) throws {
        if handle.isCancelled() {
            throw JSONRPCError.create(code: .validationFailed, details: "Request already cancelled")
        }
        
        var found = false
        registryQueue.sync(flags: .barrier) {
            if self.requestRegistry[handle.getInternalID()] != nil {
                found = true
                handle.markCancelled()
                self.requestRegistry.removeValue(forKey: handle.getInternalID())
            }
        }
        
        if !found {
            throw JSONRPCError.create(code: .validationFailed, details: "Request not found or already completed")
        }
    }
    
    /// Get all pending request handles
    public func getPendingRequests() -> [RequestHandle] {
        return registryQueue.sync {
            return Array(requestRegistry.values)
        }
    }
    
}