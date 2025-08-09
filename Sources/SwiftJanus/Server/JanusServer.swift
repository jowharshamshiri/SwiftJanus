import Foundation
import os.log

// MARK: - Logging
private let logger = Logger(subsystem: "com.janus.swift", category: "server")

/// Request handler function type for SOCK_DGRAM server
/// Updated to support direct value responses (not just dictionaries) for protocol compliance
public typealias JanusRequestHandler = (JanusRequest) -> Result<AnyCodable, JSONRPCError>

/// Event handler function type for server events
public typealias ServerEventHandler = (Any) -> Void

// ClientConnection removed - SOCK_DGRAM is stateless, no persistent client objects needed

/// Server configuration options
public struct ServerConfig {
    let maxConnections: Int
    let defaultTimeout: TimeInterval
    let maxMessageSize: Int
    let cleanupOnStart: Bool
    let cleanupOnShutdown: Bool
    let debugLogging: Bool
    let maxConcurrentHandlers: Int
    
    public init(maxConnections: Int = 100, defaultTimeout: TimeInterval = 30.0, maxMessageSize: Int = 65536, cleanupOnStart: Bool = true, cleanupOnShutdown: Bool = true, debugLogging: Bool = false, maxConcurrentHandlers: Int = 100) {
        self.maxConnections = maxConnections
        self.defaultTimeout = defaultTimeout
        self.maxMessageSize = maxMessageSize
        self.cleanupOnStart = cleanupOnStart
        self.cleanupOnShutdown = cleanupOnShutdown
        self.debugLogging = debugLogging
        self.maxConcurrentHandlers = maxConcurrentHandlers
    }
}

/// Server event emitter for monitoring server activity
public class ServerEventEmitter {
    private var listeningHandlers: [ServerEventHandler] = []
    private var connectionHandlers: [ServerEventHandler] = []
    private var disconnectionHandlers: [ServerEventHandler] = []
    private var requestHandlers: [ServerEventHandler] = []
    private var responseHandlers: [ServerEventHandler] = []
    private var errorHandlers: [ServerEventHandler] = []
    private let queue = DispatchQueue(label: "server.events", attributes: .concurrent)
    
    public func on(_ event: String, handler: @escaping ServerEventHandler) {
        queue.async(flags: .barrier) {
            switch event {
            case "listening": self.listeningHandlers.append(handler)
            case "connection": self.connectionHandlers.append(handler)
            case "disconnection": self.disconnectionHandlers.append(handler)
            case "request": self.requestHandlers.append(handler)
            case "response": self.responseHandlers.append(handler)
            case "error": self.errorHandlers.append(handler)
            default: break
            }
        }
    }
    
    public func emit(_ event: String, data: Any) {
        queue.async {
            let handlers: [ServerEventHandler]
            switch event {
            case "listening": handlers = self.listeningHandlers
            case "connection": handlers = self.connectionHandlers
            case "disconnection": handlers = self.disconnectionHandlers
            case "request": handlers = self.requestHandlers
            case "response": handlers = self.responseHandlers
            case "error": handlers = self.errorHandlers
            default: return
            }
            
            for handler in handlers {
                handler(data)
            }
        }
    }
}

/// Server state for tracking clients and activity
/// Note: For SOCK_DGRAM, each request creates an ephemeral client socket, 
/// so "clients" represent individual request socket addresses, not persistent connections
// ServerState removed - SOCK_DGRAM is stateless, no client tracking needed
// This matches Go/Rust server implementations that don't track ephemeral datagram clients

/// High-level SOCK_DGRAM Unix socket server
/// Extracted from SwiftJanusDgram main binary and made reusable
public class JanusServer {
    private var handlers: [String: JanusRequestHandler] = [:]
    private var isRunning = false
    private let manifest: Manifest?
    private let config: ServerConfig
    private let eventEmitter = ServerEventEmitter()
    // Removed activeHandlers and handlerQueue - keep it simple like Go server
    private let serverStartTime = Date()
    
    public init(manifest: Manifest? = nil, config: ServerConfig = ServerConfig()) {
        self.manifest = manifest
        self.config = config
        // Register default requests that match other implementations
        registerDefaultHandlers()
    }
    
    /// Access to event emitter for server monitoring
    public var events: ServerEventEmitter {
        return eventEmitter
    }
    
    /// Get server statistics (stateless - no client tracking for SOCK_DGRAM)
    public func getServerStats() -> [String: AnyCodable] {
        let uptime = Date().timeIntervalSince(serverStartTime)
        return [
            "uptime": AnyCodable(uptime),
            "serverType": AnyCodable("SOCK_DGRAM (stateless)"),
            "startTime": AnyCodable(serverStartTime.timeIntervalSince1970)
        ]
    }
    
    /// Register a request handler
    public func registerHandler(_ request: String, handler: @escaping JanusRequestHandler) {
        handlers[request] = handler
    }
    
    // Store socket information for the server
    private var serverSocketFD: Int32 = -1
    private var currentSocketPath: String = ""
    
    /// Start listening on the manifestified socket path using SOCK_DGRAM (non-blocking startup)
    public func startListening(_ socketPath: String) async throws {
        isRunning = true
        
        logger.info("Starting SOCK_DGRAM server on: \(socketPath)")
        
        // Socket cleanup on start if configured
        if config.cleanupOnStart {
            logger.debug("Cleaning up existing socket file")
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create SOCK_DGRAM socket
        logger.debug("Creating socket...")
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            logger.error("Failed to create socket, errno: \(errno)")
            throw JSONRPCError.create(code: .socketError, details: "Failed to create socket")
        }
        logger.debug("Socket created with FD: \(socketFD)")
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Safely copy socket path to sun_path
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(socketFD)
            throw JSONRPCError.create(code: .socketError, details: "Socket path too long")
        }
        
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { cString in
                strcpy(ptr, cString)
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                // Calculate proper address length: sun_family (2 bytes) + path length + null terminator
                let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + socketPath.utf8.count + 1)
                return Darwin.bind(socketFD, sockaddrPtr, addressLength)
            }
        }
        
        print("Attempting bind...")
        guard bindResult == 0 else {
            let errorCode = errno
            print("Bind failed with errno: \(errorCode), error: \(String(cString: strerror(errorCode)))")
            Darwin.close(socketFD)
            throw JSONRPCError.create(code: .socketError, details: "Failed to bind socket: \(String(cString: strerror(errorCode)))")  
        }
        print("Bind successful")
        
        // Verify socket file was created
        guard FileManager.default.fileExists(atPath: socketPath) else {
            print("Socket file does not exist after bind: \(socketPath)")
            Darwin.close(socketFD)
            throw JSONRPCError.create(code: .socketError, details: "Socket file was not created after bind")
        }
        print("Socket file verified: \(socketPath)")
        
        // Set socket to non-blocking mode for proper shutdown handling
        let flags = fcntl(socketFD, F_GETFL, 0)
        fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        
        // Store socket information
        self.serverSocketFD = socketFD
        self.currentSocketPath = socketPath
        
        print("Ready to receive datagrams")
        eventEmitter.emit("listening", data: ["socketPath": socketPath])
        
        // Start message processing in background task
        Task {
            await self.processMessages()
        }
        
        // Return immediately after successful setup
        print("Swift server startup complete")
    }
    
    /// Process incoming messages in a background loop
    private func processMessages() async {
        let socketFD = self.serverSocketFD
        let socketPath = self.currentSocketPath
        
        defer {
            debugLog("Server defer block executing - closing socket and cleaning up")
            Darwin.close(socketFD)
            if config.cleanupOnShutdown {
                debugLog("Removing socket file: \(socketPath)")
                try? FileManager.default.removeItem(atPath: socketPath)
                let exists = FileManager.default.fileExists(atPath: socketPath)
                debugLog("Socket file exists after cleanup: \(exists)")
            }
        }
        
        // Receive datagrams (extracted from main binary)
        while isRunning {
            // Use configurable buffer size with validation against system limits
            let maxBufferSize = min(config.maxMessageSize, 64 * 1024)
            var buffer = Data(count: maxBufferSize)
            let bufferSize = buffer.count
            var senderAddr = sockaddr_un()
            var senderAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            let bytesReceived = buffer.withUnsafeMutableBytes { bufferPtr in
                withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        withUnsafeMutablePointer(to: &senderAddrLen) { lenPtr in
                            Darwin.recvfrom(socketFD, bufferPtr.baseAddress, bufferSize, 0, sockaddrPtr, lenPtr)
                        }
                    }
                }
            }
            
            // Check if we should stop after each recv (important for proper shutdown)
            if !isRunning {
                debugLog("Server loop exiting due to stop request")
                break
            }
            
            guard bytesReceived > 0 else {
                // On error or no data, check again quickly
                if bytesReceived == -1 {
                    let error = errno
                    if error == EAGAIN || error == EWOULDBLOCK {
                        // No data available, continue
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        continue
                    } else {
                        debugLog("recv error: \(error), exiting loop")
                        break
                    }
                }
                continue
            }
            
            // Extract sender socket path for client tracking (like Go/Rust/TypeScript)
            let senderAddrCopy = senderAddr  // Copy to avoid overlapping access
            let senderSocketPath = withUnsafePointer(to: senderAddrCopy.sun_path) { pathPtr in
                let cStringPtr = UnsafeRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                // Use consistent UTF-8 handling without base64 fallback (like other implementations)
                return String(cString: cStringPtr)
            }
            
            let receivedData = buffer.prefix(bytesReceived)
            // Process message concurrently with handler limits (like TypeScript server)
            Task { [self] in
                await processReceivedDatagramWithLimits(receivedData, senderAddress: senderSocketPath)
            }
        }
        
        debugLog("Server loop completed, isRunning: \(isRunning)")
    }
    
    /// Stop the server gracefully
    public func stop() {
        debugLog("Server.stop() called, setting isRunning = false")
        isRunning = false
        print("Swift server stopping...")
    }
    
    // MARK: - Private Implementation (extracted from main binary)
    
    /// Debug logging helper - only prints when debug logging is enabled
    private func debugLog(_ message: String) {
        if config.debugLogging {
            print("DEBUG: \(message)")
        }
    }
    
    private func processReceivedDatagramWithLimits(_ data: Data, senderAddress: String) async {
        // No concurrency limits - keep it simple like Go server
        await processReceivedDatagram(data, senderAddress: senderAddress)
    }
    
    private func processReceivedDatagram(_ data: Data, senderAddress: String) async {
        // Simple JSON parsing like Go server - no complex error handling
        guard let cmd = try? JSONDecoder().decode(JanusRequest.self, from: data) else {
            debugLog("Failed to decode JanusRequest from \(senderAddress)")
            return
        }
        
        debugLog("Received request: \(cmd.request) (ID: \(cmd.id))")
        
        // Emit request event
        eventEmitter.emit("request", data: cmd)
        
        // Send response via reply_to if manifestified
        if let replyTo = cmd.replyTo {
            await sendResponse(cmd.id, "default", cmd.request, cmd.args, replyTo)
            
            // Emit response event  
            eventEmitter.emit("response", data: ["requestId": cmd.id, "replyTo": replyTo])
        }
    }
    
    // Removed complex malformed JSON error response - keep it simple like Go server
    
    private func sendResponse(_ requestId: String, _ channelId: String, _ request: String, _ args: [String: AnyCodable]?, _ replyTo: String) async {
        debugLog("sendResponse called for request '\(request)' ID '\(requestId)'")
        var success = true
        var result: AnyCodable? = nil
        var responseError: JSONRPCError? = nil
        
        // Execute request with timeout management
        let requestTask = Task {
            // Check if we have a custom handler
            debugLog("Looking for handler for request '\(request)'")
            debugLog("Available handlers: \(Array(self.handlers.keys))")
            if let handler = handlers[request] {
                debugLog("Found custom handler for '\(request)'")
                let janusRequest = JanusRequest(
                    id: requestId,
                    request: request,
                    replyTo: replyTo,
                    args: args,
                    timeout: nil
                )
                
                debugLog("Executing custom handler for '\(request)'")
                let handlerResult = handler(janusRequest)
                debugLog("Handler result received")
                switch handlerResult {
                case .success(let data):
                    debugLog("Handler succeeded with data: \(data)")
                    return (true, data, nil as JSONRPCError?)
                case .failure(let error):
                    debugLog("Handler failed with error: \(error)")
                    return (false, AnyCodable(""), error)
                }
            } else {
                // Use default handlers (extracted from main binary)
                debugLog("Using default handler for '\(request)'")
                switch request {
                case "server_stats":
                    let stats = self.getServerStats()
                    // Direct stats return - already AnyCodable
                    return (true, AnyCodable(stats), nil as JSONRPCError?)
                case "ping":
                    let pingResult = [
                        "pong": AnyCodable(true),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, AnyCodable(pingResult), nil as JSONRPCError?)
                case "echo":
                    // Return dictionary format like Go server for consistency  
                    let message = args?["message"]?.value as? String ?? "Hello from Swift SOCK_DGRAM server!"
                    let echoResult = [
                        "echo": AnyCodable(message),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, AnyCodable(echoResult), nil as JSONRPCError?)
                case "get_info":
                    let infoResult = [
                        "server": AnyCodable("Swift Janus"),
                        "version": AnyCodable("1.0.0"),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, AnyCodable(infoResult), nil as JSONRPCError?)
                case "validate":
                    // Test JSON validation
                    if let message = args?["message"]?.value as? String {
                        do {
                            _ = try JSONSerialization.jsonObject(with: message.data(using: .utf8) ?? Data())
                            let validateResult = [
                                "valid": AnyCodable(true),
                                "message": AnyCodable("Valid JSON")
                            ]
                            return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                        } catch {
                            let validateResult = [
                                "valid": AnyCodable(false),
                                "error": AnyCodable("Invalid JSON: \(error)")
                            ]
                            return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                        }
                    } else {
                        let validateResult = [
                            "valid": AnyCodable(false),
                            "error": AnyCodable("No message provided for validation")
                        ]
                        return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                    }
                case "slow_process":
                    // Simulate a slow process that might timeout
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                    var slowResult = [
                        "processed": AnyCodable(true),
                        "delay": AnyCodable("2000ms")
                    ]
                    if let message = args?["message"] {
                        slowResult["message"] = message
                    }
                    return (true, AnyCodable(slowResult), nil as JSONRPCError?)
                default:
                    let error = JSONRPCError.create(code: .methodNotFound, details: "Unknown request: \(request)")
                    return (false, AnyCodable(""), error)
                }
            }
        }
        
        // Execute with simple timeout - no TaskGroup complexity
        do {
            debugLog("Starting request execution with timeout")
            
            // Simple async timeout using withThrowingTaskGroup for clean timeout handling
            let (requestSuccess, requestResult, taskError): (Bool, AnyCodable, JSONRPCError?) = try await withThrowingTaskGroup(of: (Bool, AnyCodable, JSONRPCError?).self) { group in
                // Add request execution task
                group.addTask { [self] in
                    do {
                        let result = try await requestTask.value
                        self.debugLog("Request completed successfully")
                        return result
                    } catch {
                        self.debugLog("Request failed: \(error)")
                        let taskError = JSONRPCError.create(code: .internalError, details: "Request execution failed: \(error.localizedDescription)")
                        return (false, AnyCodable(""), taskError)
                    }
                }
                
                // Add timeout task
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(self.config.defaultTimeout * 1_000_000_000))
                    self.debugLog("Request timeout after \(self.config.defaultTimeout) seconds")
                    let timeoutError = JSONRPCError.create(code: .internalError, details: "Request timeout after \(self.config.defaultTimeout) seconds")
                    return (false, AnyCodable(""), timeoutError)
                }
                
                // Return first completed task, cancel others
                guard let result = try await group.next() else {
                    let taskError = JSONRPCError.create(code: .internalError, details: "No task completed")
                    return (false, AnyCodable(""), taskError)
                }
                
                group.cancelAll()
                return result
            }
            
            success = requestSuccess
            result = success ? requestResult : nil
            responseError = taskError
            debugLog("Request execution completed - success: \(success)")
            
        } catch {
            // Handle task group errors
            debugLog("Task group failed: \(error)")
            success = false
            result = nil
            responseError = JSONRPCError.create(code: .internalError, details: "Request execution failed: \(error.localizedDescription)")
        }
        
        // Validate response against Manifest if available
        if let manifest = self.manifest, let result = result {
            let validator = ResponseValidator(manifest: manifest)
            // Convert AnyCodable result to [String: Any] for validation
            if let resultDict = result.value as? [String: Any] {
                let validationResult = validator.validateRequestResponse(
                    resultDict,
                    channelId: "default",
                    requestName: request
                )
                if !validationResult.valid {
                    // Log validation errors but don't fail the response
                    debugLog("Response validation failed for \(request): \(validationResult.errors.map { $0.localizedDescription }.joined(separator: ", "))")
                }
            }
        }
        
        let response = JanusResponse(
            requestId: requestId,
            success: success,
            result: result,
            error: success ? nil : responseError
        )
        
        // Emit response event
        eventEmitter.emit("response", data: response)
        
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // Send response datagram to reply_to socket with improved error handling
            let replySocketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard replySocketFD != -1 else { 
                debugLog("Failed to create reply socket")
                return 
            }
            defer { Darwin.close(replySocketFD) }
            
            // No artificial delays - direct response sending like Go/Rust servers
            
            var replyAddr = sockaddr_un()
            replyAddr.sun_family = sa_family_t(AF_UNIX)
            
            // Safe UTF-8 string conversion with proper error handling
            guard let replyPathCString = replyTo.cString(using: .utf8) else {
                debugLog("Failed to convert replyTo path to UTF-8: \(replyTo)")
                return
            }
            
            // Validate path length against Unix socket limits
            let maxPathLength = MemoryLayout.size(ofValue: replyAddr.sun_path) - 1
            guard replyPathCString.count <= maxPathLength else {
                debugLog("Reply path too long: \(replyPathCString.count) > \(maxPathLength)")
                return
            }
            
            withUnsafeMutablePointer(to: &replyAddr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: replyPathCString.count) { pathPtr in
                    replyPathCString.withUnsafeBufferPointer { buffer in
                        pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                    }
                }
            }
            
            let sendResult = responseData.withUnsafeBytes { dataPtr in
                withUnsafePointer(to: &replyAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.sendto(replySocketFD, dataPtr.baseAddress, responseData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            
            // Check for send errors with improved error handling
            if sendResult == -1 {
                let error = errno
                if error == EMSGSIZE {
                    print("ERROR: Response message too long for SOCK_DGRAM buffer limits")
                    print("Consider reducing response size or splitting data")
                } else if error == ENOENT {
                    // Response socket no longer exists - client likely timed out
                    // This is expected behavior in high-load scenarios, don't treat as critical error
                    debugLog("Client response socket no longer exists (\(replyTo)) - client may have timed out")
                } else {
                    debugLog("Failed to send response to \(replyTo): errno \(error) - \(String(cString: strerror(error)))")
                }
            } else {
                debugLog("Response sent successfully to \(replyTo) (\(sendResult) bytes)")
            }
            
        } catch {
            print("Error encoding response: \(error)")
        }
    }
    
    private func sendRawResponse(_ responseData: Data, to replyTo: String) async {
        let replySocketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard replySocketFD != -1 else { 
            debugLog("Failed to create reply socket for raw response")
            return 
        }
        defer { Darwin.close(replySocketFD) }
        
        // No artificial delays for raw responses
        
        var replyAddr = sockaddr_un()
        replyAddr.sun_family = sa_family_t(AF_UNIX)
        
        guard let replyPathCString = replyTo.cString(using: .utf8) else {
            debugLog("Failed to convert replyTo path to UTF-8 for raw response: \(replyTo)")
            return
        }
        
        let maxPathLength = MemoryLayout.size(ofValue: replyAddr.sun_path) - 1
        guard replyPathCString.count <= maxPathLength else {
            debugLog("Reply path too long for raw response: \(replyPathCString.count) > \(maxPathLength)")
            return
        }
        
        withUnsafeMutablePointer(to: &replyAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: replyPathCString.count) { pathPtr in
                replyPathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                }
            }
        }
        
        let sendResult = responseData.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &replyAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.sendto(replySocketFD, dataPtr.baseAddress, responseData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        
        if sendResult == -1 {
            let error = errno
            debugLog("Failed to send raw response to \(replyTo): errno \(error)")
        } else {
            debugLog("Raw response sent successfully to \(replyTo) (\(sendResult) bytes)")
        }
    }
    
    private func registerDefaultHandlers() {
        // Built-in request handlers matching other implementations
        
        // Ping request - basic connectivity test
        self.registerHandler("ping") { request in
            var result: [String: AnyCodable] = [:]
            result["message"] = AnyCodable("pong")
            result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            return .success(AnyCodable(result))
        }
        
        // Echo request - echo back the message parameter
        self.registerHandler("echo") { request in
            let message = request.args?["message"] ?? AnyCodable("No message provided")
            var result: [String: AnyCodable] = [:]
            result["echo"] = message
            result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            return .success(AnyCodable(result))
        }
        
        // Get info request - implementation information
        self.registerHandler("get_info") { request in
            var result: [String: AnyCodable] = [:]
            result["server"] = AnyCodable("Swift Janus")
            result["version"] = AnyCodable("1.0.0")
            result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            return .success(AnyCodable(result))
        }
        
        // Validate request - JSON validation service
        self.registerHandler("validate") { request in
            guard let message = request.args?["message"] else {
                var result: [String: AnyCodable] = [:]
                result["valid"] = AnyCodable(false)
                result["error"] = AnyCodable("No message provided for validation")
                result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
                return .success(AnyCodable(result))
            }
            
            do {
                // Try to parse the message as JSON
                if let messageString = message.value as? String {
                    let jsonData = messageString.data(using: .utf8) ?? Data()
                    _ = try JSONSerialization.jsonObject(with: jsonData, options: [])
                    var result: [String: AnyCodable] = [:]
                    result["valid"] = AnyCodable(true)
                    result["message"] = AnyCodable("JSON is valid")
                    result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
                    return .success(AnyCodable(result))
                } else {
                    var result: [String: AnyCodable] = [:]
                    result["valid"] = AnyCodable(false)
                    result["error"] = AnyCodable("Invalid JSON: \(message.value)")
                    result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
                    return .success(AnyCodable(result))
                }
            } catch {
                var result: [String: AnyCodable] = [:]
                result["valid"] = AnyCodable(false)
                result["error"] = AnyCodable("Invalid JSON: \(error.localizedDescription)")
                result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
                return .success(AnyCodable(result))
            }
        }
        
        // Slow process request - 2-second delay simulation
        self.registerHandler("slow_process") { request in
            Thread.sleep(forTimeInterval: 2.0)
            let message = request.args?["message"] ?? AnyCodable("No message")
            var result: [String: AnyCodable] = [:]
            result["processed"] = AnyCodable(true)
            result["delay"] = AnyCodable("2000ms")
            result["message"] = message
            result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            return .success(AnyCodable(result))
        }
        
        // Manifest request - return server manifest
        self.registerHandler("manifest") { request in
            // Generate and return the server manifest directly
            var result: [String: AnyCodable] = [:]
            result["version"] = AnyCodable("1.0.0")
            // Channels removed from protocol - no longer included in manifest response
            result["models"] = AnyCodable([:] as [String: AnyCodable])
            result["name"] = AnyCodable("Swift Janus Server API")
            result["description"] = AnyCodable("Swift implementation of Janus SOCK_DGRAM server")
            return .success(AnyCodable(result))
        }
    }
}