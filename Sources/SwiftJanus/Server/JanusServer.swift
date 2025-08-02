import Foundation

/// Command handler function type for SOCK_DGRAM server
public typealias JanusCommandHandler = (SocketCommand) -> Result<[String: AnyCodable], JanusError>

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
    
    public init(maxConnections: Int = 100, defaultTimeout: TimeInterval = 30.0, maxMessageSize: Int = 65536, cleanupOnStart: Bool = true, cleanupOnShutdown: Bool = true) {
        self.maxConnections = maxConnections
        self.defaultTimeout = defaultTimeout
        self.maxMessageSize = maxMessageSize
        self.cleanupOnStart = cleanupOnStart
        self.cleanupOnShutdown = cleanupOnShutdown
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
    
    mutating func removeInactiveClients(timeout: TimeInterval = 300) { // 5 minutes default
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
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        // Create SOCK_DGRAM socket
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            throw JanusError.socketCreationFailed("Failed to create socket")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCString = socketPath.cString(using: .utf8)!
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCString.count) { pathPtr in
                pathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                }
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw JanusError.bindFailed("Failed to bind socket")  
        }
        
        defer {
            Darwin.close(socketFD)
            if config.cleanupOnShutdown {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        }
        
        print("Ready to receive datagrams")
        eventEmitter.emit("listening", data: ["socketPath": socketPath])
        
        // Receive datagrams (extracted from main binary)
        while isRunning {
            var buffer = Data(count: 64 * 1024)
            let bufferSize = buffer.count
            let bytesReceived = buffer.withUnsafeMutableBytes { bufferPtr in
                Darwin.recv(socketFD, bufferPtr.baseAddress, bufferSize, 0)
            }
            
            guard bytesReceived > 0 else {
                continue
            }
            
            let receivedData = buffer.prefix(bytesReceived)
            await processReceivedDatagram(receivedData)
        }
    }
    
    /// Stop the server
    public func stop() {
        isRunning = false
    }
    
    // MARK: - Private Implementation (extracted from main binary)
    
    private func processReceivedDatagram(_ data: Data) async {
        do {
            let cmd = try JSONDecoder().decode(SocketCommand.self, from: data)
            print("Received datagram: \(cmd.command) (ID: \(cmd.id))")
            
            // Track client activity (using channelId as client identifier for SOCK_DGRAM)
            stateQueue.async(flags: .barrier) {
                if self.serverState.clients[cmd.channelId] == nil {
                    let client = self.serverState.addClient(address: cmd.channelId)
                    self.eventEmitter.emit("connection", data: client)
                }
                self.serverState.updateClientActivity(address: cmd.channelId)
            }
            
            // Emit command event
            eventEmitter.emit("command", data: cmd)
            
            // Send response via reply_to if specified
            if let replyTo = cmd.replyTo {
                await sendResponse(cmd.id, cmd.channelId, cmd.command, cmd.args, replyTo)
            }
        } catch {
            print("Failed to parse datagram: \(error)")
            eventEmitter.emit("error", data: ["error": error.localizedDescription, "data": data])
        }
    }
    
    private func sendResponse(_ commandId: String, _ channelId: String, _ command: String, _ args: [String: AnyCodable]?, _ replyTo: String) async {
        var success = true
        var result: [String: AnyCodable] = [:]
        
        // Execute command with timeout management
        let commandTask = Task {
            // Check if we have a custom handler
            if let handler = handlers[command] {
                let socketCommand = SocketCommand(
                    id: commandId,
                    channelId: channelId,
                    command: command,
                    replyTo: replyTo,
                    args: args,
                    timeout: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                
                let handlerResult = handler(socketCommand)
                switch handlerResult {
                case .success(let data):
                    return (true, data)
                case .failure(let error):
                    return (false, ["error": AnyCodable(error.localizedDescription)])
                }
            } else {
                // Use default handlers (extracted from main binary)
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
                    return (true, statsResult)
                case "ping":
                    let pingResult: [String: AnyCodable] = [
                        "pong": AnyCodable(true),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, pingResult)
                case "echo":
                    let echoResult: [String: AnyCodable]
                    if let message = args?["message"] {
                        echoResult = ["echo": message]
                    } else {
                        echoResult = ["echo": AnyCodable("Hello from Swift SOCK_DGRAM server!")]
                    }
                    return (true, echoResult)
                case "get_info":
                    let infoResult: [String: AnyCodable] = [
                        "server": AnyCodable("Swift Janus"),
                        "version": AnyCodable("1.0.0"),
                        "timestamp": AnyCodable(Date().timeIntervalSince1970)
                    ]
                    return (true, infoResult)
                case "validate":
                    // Test JSON validation
                    if let message = args?["message"]?.value as? String {
                        do {
                            _ = try JSONSerialization.jsonObject(with: message.data(using: .utf8) ?? Data())
                            let validateResult: [String: AnyCodable] = [
                                "valid": AnyCodable(true),
                                "message": AnyCodable("Valid JSON")
                            ]
                            return (true, validateResult)
                        } catch {
                            let validateResult: [String: AnyCodable] = [
                                "valid": AnyCodable(false),
                                "error": AnyCodable("Invalid JSON: \(error)")
                            ]
                            return (true, validateResult)
                        }
                    } else {
                        let validateResult: [String: AnyCodable] = [
                            "valid": AnyCodable(false),
                            "error": AnyCodable("No message provided for validation")
                        ]
                        return (true, validateResult)
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
                    return (true, slowResult)
                default:
                    return (false, ["error": AnyCodable("Unknown command: \(command)")])
                }
            }
        }
        
        // Execute with timeout
        do {
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(config.defaultTimeout * 1_000_000_000))
                return (false, ["error": AnyCodable("Command timeout after \(config.defaultTimeout) seconds")])
            }
            
            let (commandSuccess, commandResult) = await withTaskGroup(of: (Bool, [String: AnyCodable]).self, returning: (Bool, [String: AnyCodable]).self) { group in
                group.addTask { try! await commandTask.value }
                group.addTask { try! await timeoutTask.value }
                
                let result = await group.next()!
                group.cancelAll()
                return result
            }
            
            success = commandSuccess
            result = commandResult
        }
        
        // Validate response against Manifest if available
        if let manifest = self.manifest, !result.isEmpty {
            let validator = ResponseValidator(specification: manifest)
            // Convert AnyCodable result to [String: Any] for validation
            let resultDict = result.mapValues { $0.value }
            let validationResult = validator.validateCommandResponse(
                resultDict,
                channelId: channelId,
                commandName: command
            )
            if !validationResult.valid {
                // Log validation errors but don't fail the response
                print("Response validation failed for \(command): \(validationResult.errors.map { $0.localizedDescription }.joined(separator: ", "))")
            }
        }
        
        let response = SocketResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: result.isEmpty ? nil : result,
            error: success ? nil : JSONRPCError.create(code: .internalError, details: result["error"]?.value as? String ?? "Unknown error"),
            timestamp: Date().timeIntervalSince1970
        )
        
        // Emit response event
        eventEmitter.emit("response", data: response)
        
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // Send response datagram to reply_to socket (extracted from main binary)
            let replySocketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard replySocketFD != -1 else { return }
            defer { Darwin.close(replySocketFD) }
            
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
            
            // Check for send errors, especially message too long (matching main binary)
            if sendResult == -1 {
                let error = errno
                if error == EMSGSIZE {
                    print("ERROR: Response message too long for SOCK_DGRAM buffer limits")
                    print("Consider reducing response size or splitting data")
                } else {
                    print("ERROR: Failed to send response: errno \(error)")
                }
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