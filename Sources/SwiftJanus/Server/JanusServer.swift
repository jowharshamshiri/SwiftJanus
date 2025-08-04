import Foundation

/// Command handler function type for SOCK_DGRAM server
/// Updated to support direct value responses (not just dictionaries) for protocol compliance
public typealias JanusCommandHandler = (JanusCommand) -> Result<AnyCodable, JSONRPCError>

/// Event handler function type for server events
public typealias ServerEventHandler = (Any) -> Void

/// Client connection information for SOCK_DGRAM servers
public struct ClientConnection {
    let id: String
    let address: String
    var lastSeen: Date
    var messageCount: Int
    let connectedAt: Date
    
    init(address: String) {
        self.id = UUID().uuidString
        self.address = address
        self.lastSeen = Date()
        self.messageCount = 0
        self.connectedAt = Date()
    }
    
    mutating func updateActivity() {
        self.lastSeen = Date()
        self.messageCount += 1
    }
}

/// Server configuration options
public struct ServerConfig {
    let maxConnections: Int
    let defaultTimeout: TimeInterval
    let maxMessageSize: Int
    let cleanupOnStart: Bool
    let cleanupOnShutdown: Bool
    let debugLogging: Bool
    
    public init(maxConnections: Int = 100, defaultTimeout: TimeInterval = 30.0, maxMessageSize: Int = 65536, cleanupOnStart: Bool = true, cleanupOnShutdown: Bool = true, debugLogging: Bool = false) {
        self.maxConnections = maxConnections
        self.defaultTimeout = defaultTimeout
        self.maxMessageSize = maxMessageSize
        self.cleanupOnStart = cleanupOnStart
        self.cleanupOnShutdown = cleanupOnShutdown
        self.debugLogging = debugLogging
    }
}

/// Server event emitter for monitoring server activity
public class ServerEventEmitter {
    private var listeningHandlers: [ServerEventHandler] = []
    private var connectionHandlers: [ServerEventHandler] = []
    private var disconnectionHandlers: [ServerEventHandler] = []
    private var commandHandlers: [ServerEventHandler] = []
    private var responseHandlers: [ServerEventHandler] = []
    private var errorHandlers: [ServerEventHandler] = []
    private let queue = DispatchQueue(label: "server.events", attributes: .concurrent)
    
    public func on(_ event: String, handler: @escaping ServerEventHandler) {
        queue.async(flags: .barrier) {
            switch event {
            case "listening": self.listeningHandlers.append(handler)
            case "connection": self.connectionHandlers.append(handler)
            case "disconnection": self.disconnectionHandlers.append(handler)
            case "command": self.commandHandlers.append(handler)
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
            case "command": handlers = self.commandHandlers
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
/// Note: For SOCK_DGRAM, each command creates an ephemeral client socket, 
/// so "clients" represent individual command socket addresses, not persistent connections
public struct ServerState {
    var clients: [String: ClientConnection] = [:]
    var totalConnections: Int = 0
    var totalCommands: Int = 0
    var startTime: Date = Date()
    
    mutating func addClient(address: String) -> ClientConnection {
        let client = ClientConnection(address: address)
        clients[address] = client
        totalConnections += 1
        return client
    }
    
    mutating func updateClientActivity(address: String) {
        clients[address]?.updateActivity()
        totalCommands += 1
    }
    
    mutating func removeInactiveClients(timeout: TimeInterval = 60) { // 1 minute default for SOCK_DGRAM ephemeral sockets
        let cutoff = Date().addingTimeInterval(-timeout)
        clients = clients.filter { $0.value.lastSeen > cutoff }
    }
}

/// High-level SOCK_DGRAM Unix socket server
/// Extracted from SwiftJanusDgram main binary and made reusable
public class JanusServer {
    private var handlers: [String: JanusCommandHandler] = [:]
    private var isRunning = false
    private let manifest: Manifest?
    private let config: ServerConfig
    private var serverState = ServerState()
    private let eventEmitter = ServerEventEmitter()
    private let stateQueue = DispatchQueue(label: "server.state", attributes: .concurrent)
    
    public init(manifest: Manifest? = nil, config: ServerConfig = ServerConfig()) {
        self.manifest = manifest
        self.config = config
        // Register default commands that match other implementations
        registerDefaultHandlers()
    }
    
    /// Access to event emitter for server monitoring
    public var events: ServerEventEmitter {
        return eventEmitter
    }
    
    /// Get server statistics
    public func getServerStats() -> [String: Any] {
        return stateQueue.sync {
            let uptime = Date().timeIntervalSince(serverState.startTime)
            return [
                "uptime": uptime,
                "totalConnections": serverState.totalConnections,
                "totalCommands": serverState.totalCommands,
                "activeClients": serverState.clients.count,
                "clients": serverState.clients.mapValues { client in
                    [
                        "id": client.id,
                        "address": client.address,
                        "lastSeen": client.lastSeen.timeIntervalSince1970,
                        "messageCount": client.messageCount,
                        "connectedAt": client.connectedAt.timeIntervalSince1970
                    ]
                }
            ]
        }
    }
    
    /// Register a command handler
    public func registerHandler(_ command: String, handler: @escaping JanusCommandHandler) {
        handlers[command] = handler
    }
    
    /// Start listening on the specified socket path using SOCK_DGRAM
    public func startListening(_ socketPath: String) async throws {
        isRunning = true
        
        print("Starting SOCK_DGRAM server on: \(socketPath)")
        
        // Socket cleanup on start if configured
        if config.cleanupOnStart {
            print("Cleaning up existing socket file")
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create SOCK_DGRAM socket
        print("Creating socket...")
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            print("Failed to create socket, errno: \(errno)")
            throw JSONRPCError.create(code: .socketError, details: "Failed to create socket")
        }
        print("Socket created with FD: \(socketFD)")
        
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
        
        print("Ready to receive datagrams")
        eventEmitter.emit("listening", data: ["socketPath": socketPath])
        
        // Receive datagrams (extracted from main binary)
        while isRunning {
            var buffer = Data(count: 64 * 1024)
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
            
            // Extract sender socket path for client tracking
            let senderSocketPath = withUnsafePointer(to: &senderAddr.sun_path) { pathPtr in
                String(cString: UnsafeRawPointer(pathPtr).assumingMemoryBound(to: CChar.self))
            }
            
            let receivedData = buffer.prefix(bytesReceived)
            await processReceivedDatagram(receivedData, senderAddress: senderSocketPath)
        }
        
        debugLog("Server loop completed, isRunning: \(isRunning)")
    }
    
    /// Stop the server
    public func stop() {
        debugLog("Server.stop() called, setting isRunning = false")
        isRunning = false
    }
    
    // MARK: - Private Implementation (extracted from main binary)
    
    /// Debug logging helper - only prints when debug logging is enabled
    private func debugLog(_ message: String) {
        if config.debugLogging {
            print("DEBUG: \(message)")
        }
    }
    
    private func processReceivedDatagram(_ data: Data, senderAddress: String) async {
        do {
            let cmd = try JSONDecoder().decode(JanusCommand.self, from: data)
            debugLog("Received datagram: \(cmd.command) (ID: \(cmd.id)) from socket: \(senderAddress)")
            
            // Track client activity (using sender socket address as client identifier for SOCK_DGRAM)
            stateQueue.async(flags: .barrier) {
                if self.serverState.clients[senderAddress] == nil {
                    let client = self.serverState.addClient(address: senderAddress)
                    self.eventEmitter.emit("connection", data: client)
                }
                self.serverState.updateClientActivity(address: senderAddress)
            }
            
            // Emit command event
            eventEmitter.emit("command", data: cmd)
            
            // Send response via reply_to if specified
            if let replyTo = cmd.replyTo {
                debugLog("Processing command '\(cmd.command)' with replyTo: \(replyTo)")
                await sendResponse(cmd.id, cmd.channelId, cmd.command, cmd.args, replyTo)
            } else {
                debugLog("No replyTo specified for command '\(cmd.command)'")
            }
        } catch {
            print("Failed to parse datagram: \(error)")
            eventEmitter.emit("error", data: ["error": error.localizedDescription, "data": data])
        }
    }
    
    private func sendResponse(_ commandId: String, _ channelId: String, _ command: String, _ args: [String: AnyCodable]?, _ replyTo: String) async {
        debugLog("sendResponse called for command '\(command)' ID '\(commandId)'")
        var success = true
        var result: AnyCodable? = nil
        var responseError: JSONRPCError? = nil
        
        // Execute command with timeout management
        let commandTask = Task {
            // Check if we have a custom handler
            debugLog("Looking for handler for command '\(command)'")
            debugLog("Available handlers: \(Array(self.handlers.keys))")
            if let handler = handlers[command] {
                debugLog("Found custom handler for '\(command)'")
                let janusCommand = JanusCommand(
                    id: commandId,
                    channelId: channelId,
                    command: command,
                    replyTo: replyTo,
                    args: args,
                    timeout: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                
                debugLog("Executing custom handler for '\(command)'")
                let handlerResult = handler(janusCommand)
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
                debugLog("Using default handler for '\(command)'")
                switch command {
                case "server_stats":
                    let stats = self.getServerStats()
                    // Convert stats to AnyCodable manually to handle Any type
                    var statsResult: [String: AnyCodable] = [:]
                    for (key, value) in stats {
                        if let stringValue = value as? String {
                            statsResult[key] = AnyCodable(stringValue)
                        } else if let intValue = value as? Int {
                            statsResult[key] = AnyCodable(intValue)
                        } else if let doubleValue = value as? Double {
                            statsResult[key] = AnyCodable(doubleValue)
                        } else if let dictValue = value as? [String: Any] {
                            // Handle nested dictionaries
                            var nestedDict: [String: AnyCodable] = [:]
                            for (nestedKey, nestedValue) in dictValue {
                                if let nestedString = nestedValue as? String {
                                    nestedDict[nestedKey] = AnyCodable(nestedString)
                                } else if let nestedInt = nestedValue as? Int {
                                    nestedDict[nestedKey] = AnyCodable(nestedInt)
                                } else if let nestedDouble = nestedValue as? Double {
                                    nestedDict[nestedKey] = AnyCodable(nestedDouble)
                                }
                            }
                            statsResult[key] = AnyCodable(nestedDict)
                        }
                    }
                    return (true, AnyCodable(statsResult), nil as JSONRPCError?)
                case "ping":
                    let pingResult: [String: AnyCodable] = [
                        "pong": AnyCodable(true),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, AnyCodable(pingResult), nil as JSONRPCError?)
                case "echo":
                    let echoResult: [String: AnyCodable]
                    if let message = args?["message"] {
                        echoResult = ["echo": message]
                    } else {
                        echoResult = ["echo": AnyCodable("Hello from Swift SOCK_DGRAM server!")]
                    }
                    return (true, AnyCodable(echoResult), nil as JSONRPCError?)
                case "get_info":
                    let infoResult: [String: AnyCodable] = [
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
                            let validateResult: [String: AnyCodable] = [
                                "valid": AnyCodable(true),
                                "message": AnyCodable("Valid JSON")
                            ]
                            return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                        } catch {
                            let validateResult: [String: AnyCodable] = [
                                "valid": AnyCodable(false),
                                "error": AnyCodable("Invalid JSON: \(error)")
                            ]
                            return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                        }
                    } else {
                        let validateResult: [String: AnyCodable] = [
                            "valid": AnyCodable(false),
                            "error": AnyCodable("No message provided for validation")
                        ]
                        return (true, AnyCodable(validateResult), nil as JSONRPCError?)
                    }
                case "slow_process":
                    // Simulate a slow process that might timeout
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay
                    var slowResult: [String: AnyCodable] = [
                        "processed": AnyCodable(true),
                        "delay": AnyCodable("2000ms")
                    ]
                    if let message = args?["message"] {
                        slowResult["message"] = message
                    }
                    return (true, AnyCodable(slowResult), nil as JSONRPCError?)
                default:
                    let error = JSONRPCError.create(code: .methodNotFound, details: "Unknown command: \(command)")
                    return (false, AnyCodable(""), error)
                }
            }
        }
        
        // Execute with timeout
        do {
            debugLog("Starting command execution with timeout")
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(config.defaultTimeout * 1_000_000_000))
                debugLog("Command timeout triggered after \(config.defaultTimeout) seconds")
                let timeoutError = JSONRPCError.create(code: .internalError, details: "Command timeout after \(config.defaultTimeout) seconds")
                return (false, AnyCodable(""), timeoutError)
            }
            
            debugLog("Setting up TaskGroup")
            let (commandSuccess, commandResult, taskError) = await withTaskGroup(of: (Bool, AnyCodable, JSONRPCError?).self, returning: (Bool, AnyCodable, JSONRPCError?).self) { group in
                group.addTask { [self] in
                    debugLog("Command task starting")
                    let result = try! await commandTask.value
                    debugLog("Command task completed with result: \(result)")
                    return result
                }
                group.addTask { [self] in
                    debugLog("Timeout task starting")
                    let result = try! await timeoutTask.value
                    debugLog("Timeout task completed")
                    return result
                }
                
                debugLog("Waiting for first task to complete")
                let result = await group.next()!
                debugLog("First task completed with result: \(result)")
                group.cancelAll()
                return result
            }
            
            success = commandSuccess
            result = success ? commandResult : nil
            responseError = taskError
            debugLog("Command execution completed - success: \(success), result: \(String(describing: result))")
        }
        
        // Validate response against Manifest if available
        if let manifest = self.manifest, let result = result {
            let validator = ResponseValidator(specification: manifest)
            // Convert AnyCodable result to [String: Any] for validation
            if let resultDict = result.value as? [String: Any] {
                let validationResult = validator.validateCommandResponse(
                    resultDict,
                    channelId: channelId,
                    commandName: command
                )
                if !validationResult.valid {
                    // Log validation errors but don't fail the response
                    debugLog("Response validation failed for \(command): \(validationResult.errors.map { $0.localizedDescription }.joined(separator: ", "))")
                }
            }
        }
        
        let response = JanusResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: result,
            error: success ? nil : responseError,
            timestamp: Date().timeIntervalSince1970
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
            
            // Add small delay to prevent race condition with client socket cleanup
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms delay
            
            var replyAddr = sockaddr_un()
            replyAddr.sun_family = sa_family_t(AF_UNIX)
            let replyPathCString = replyTo.cString(using: .utf8)!
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
    
    private func registerDefaultHandlers() {
        // Default handlers match the main binary implementation
        // These can be overridden by calling registerHandler
    }
}