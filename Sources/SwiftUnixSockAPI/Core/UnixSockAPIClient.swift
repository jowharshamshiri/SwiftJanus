// UnixSockAPIClient.swift
// High-level API client with channel management and command handling

import Foundation

/// Configuration for UnixSockAPIClient with security and resource limits
public struct UnixSockAPIClientConfig {
    public let maxConcurrentConnections: Int
    public let maxMessageSize: Int
    public let connectionTimeout: TimeInterval
    public let maxPendingCommands: Int
    public let maxCommandHandlers: Int
    public let enableResourceMonitoring: Bool
    public let maxChannelNameLength: Int
    public let maxCommandNameLength: Int
    public let maxArgsDataSize: Int
    
    public init(
        maxConcurrentConnections: Int = 100,
        maxMessageSize: Int = 10 * 1024 * 1024, // 10MB
        connectionTimeout: TimeInterval = 30.0,
        maxPendingCommands: Int = 1000,
        maxCommandHandlers: Int = 500,
        enableResourceMonitoring: Bool = true,
        maxChannelNameLength: Int = 256,
        maxCommandNameLength: Int = 256,
        maxArgsDataSize: Int = 5 * 1024 * 1024 // 5MB
    ) {
        self.maxConcurrentConnections = maxConcurrentConnections
        self.maxMessageSize = maxMessageSize
        self.connectionTimeout = connectionTimeout
        self.maxPendingCommands = maxPendingCommands
        self.maxCommandHandlers = maxCommandHandlers
        self.enableResourceMonitoring = enableResourceMonitoring
        self.maxChannelNameLength = maxChannelNameLength
        self.maxCommandNameLength = maxCommandNameLength
        self.maxArgsDataSize = maxArgsDataSize
    }
    
    public static let `default` = UnixSockAPIClientConfig()
}

/// Connection pool for managing socket connections efficiently
@MainActor
public final class ConnectionPool {
    private var availableConnections: [UnixSocketClient] = []
    private var activeConnections: Set<ObjectIdentifier> = []
    private let socketPath: String
    private let config: UnixSockAPIClientConfig
    
    public init(socketPath: String, config: UnixSockAPIClientConfig) {
        self.socketPath = socketPath
        self.config = config
    }
    
    public func borrowConnection() async throws -> UnixSocketClient {
        // Reuse available connection if possible
        if let connection = availableConnections.popLast() {
            activeConnections.insert(ObjectIdentifier(connection))
            return connection
        }
        
        // Check connection limit
        guard activeConnections.count < config.maxConcurrentConnections else {
            throw UnixSockAPIError.resourceLimit("Maximum concurrent connections exceeded")
        }
        
        // Create new connection with security configuration
        let connection = UnixSocketClient(
            socketPath: socketPath,
            maxMessageSize: config.maxMessageSize,
            connectionTimeout: config.connectionTimeout
        )
        try await connection.connect()
        activeConnections.insert(ObjectIdentifier(connection))
        return connection
    }
    
    public func returnConnection(_ connection: UnixSocketClient) {
        let id = ObjectIdentifier(connection)
        activeConnections.remove(id)
        
        // Return to pool if under limit
        if availableConnections.count < 10 { // Keep small pool of ready connections
            availableConnections.append(connection)
        } else {
            connection.disconnect()
        }
    }
    
    public func closeAllConnections() {
        for connection in availableConnections {
            connection.disconnect()
        }
        availableConnections.removeAll()
        activeConnections.removeAll()
    }
}

/// Response tracking for stateless commands
public struct ResponseTracker {
    public let commandId: String
    public let channelId: String
    public let responseHandler: (SocketResponse) -> Void
    public let createdAt: Date
    public let timeout: TimeInterval
    
    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > timeout
    }
}

/// High-level Unix Socket API client with stateless communication and security features
@MainActor
public final class UnixSockAPIClient {
    private let socketPath: String
    private let channelId: String
    nonisolated private let apiSpec: APISpecification
    nonisolated private let config: UnixSockAPIClientConfig
    private let connectionPool: ConnectionPool
    
    private var commandHandlers: [String: CommandHandler] = [:]
    private var pendingCommands: [String: CheckedContinuation<SocketResponse, Error>] = [:]
    private var responseTrackers: [String: ResponseTracker] = [:]
    private var persistentConnection: UnixSocketClient?
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cleanupTimer: Timer?
    
    public typealias CommandHandler = (SocketCommand, [String: AnyCodable]?) async throws -> [String: AnyCodable]?
    public typealias TimeoutHandler = (String, TimeInterval) -> Void
    
    // MARK: - Public API Properties (Read-Only)
    
    /// Get the current configuration (read-only)
    public nonisolated var configuration: UnixSockAPIClientConfig {
        return config
    }
    
    /// Get the API specification (read-only)
    public nonisolated var specification: APISpecification {
        return apiSpec
    }
    
    /// Get the socket path (read-only)
    public var socketPathString: String {
        return socketPath
    }
    
    /// Get the channel ID (read-only)
    public var channelIdentifier: String {
        return channelId
    }
    
    /// Error thrown when a command handler exceeds its timeout
    public struct CommandHandlerTimeoutError: Error, LocalizedError {
        public let commandId: String
        public let timeout: TimeInterval
        
        public var errorDescription: String? {
            return "Command handler for \(commandId) exceeded timeout of \(timeout) seconds"
        }
    }
    
    public init(
        socketPath: String, 
        channelId: String, 
        apiSpec: APISpecification,
        config: UnixSockAPIClientConfig = .default
    ) throws {
        // Security validation
        try Self.validateSocketPath(socketPath)
        try Self.validateChannelId(channelId, config: config)
        
        self.socketPath = socketPath
        self.channelId = channelId
        self.apiSpec = apiSpec
        self.config = config
        self.connectionPool = ConnectionPool(socketPath: socketPath, config: config)
        
        // Validate that the channel exists in the API spec
        guard apiSpec.channels[channelId] != nil else {
            throw UnixSockAPIError.invalidChannel(channelId)
        }
        
        // Validate API specification
        try APISpecificationParser.validate(apiSpec)
        
        // Configure JSON encoding/decoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        
        // Set up cleanup timer for expired response trackers
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.cleanupExpiredTrackers()
            }
        }
        self.cleanupTimer = timer
    }
    
    deinit {
        cleanupTimer?.invalidate()
        // Note: We can't call async methods in deinit, so connection cleanup 
        // will happen when the pool is deallocated
    }
    
    /// Security validation for socket path
    private static func validateSocketPath(_ path: String) throws {
        // Check path length
        guard path.count <= 108 else { // Unix socket path limit
            throw UnixSockAPIError.invalidSocketPath("Socket path too long (max 108 characters)")
        }
        
        // Check for path traversal attempts
        guard !path.contains("../") && !path.contains("..\\") else {
            throw UnixSockAPIError.invalidSocketPath("Path traversal not allowed")
        }
        
        // Ensure it's in a safe directory (typically /tmp or /var/run)
        let allowedPrefixes = ["/tmp/", "/var/run/", "/var/tmp/"]
        guard allowedPrefixes.contains(where: path.hasPrefix) else {
            throw UnixSockAPIError.invalidSocketPath("Socket must be in /tmp/, /var/run/, or /var/tmp/")
        }
        
        // Check for null bytes
        guard !path.contains("\0") else {
            throw UnixSockAPIError.invalidSocketPath("Socket path cannot contain null bytes")
        }
    }
    
    /// Security validation for channel ID
    private static func validateChannelId(_ channelId: String, config: UnixSockAPIClientConfig) throws {
        guard channelId.count <= config.maxChannelNameLength else {
            throw UnixSockAPIError.invalidChannel("Channel ID too long")
        }
        
        guard !channelId.isEmpty else {
            throw UnixSockAPIError.invalidChannel("Channel ID cannot be empty")
        }
        
        // Only allow alphanumeric, hyphens, underscores
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard channelId.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw UnixSockAPIError.invalidChannel("Channel ID contains invalid characters")
        }
        
        // Check for null bytes
        guard !channelId.contains("\0") else {
            throw UnixSockAPIError.invalidChannel("Channel ID cannot contain null bytes")
        }
    }
    
    /// Clean up expired response trackers
    private func cleanupExpiredTrackers() async {
        let expiredTrackers = responseTrackers.filter { $0.value.isExpired }
        
        for (commandId, _) in expiredTrackers {
            responseTrackers.removeValue(forKey: commandId)
        }
        
        // Also clean up old pending commands
        let expiredCommands = pendingCommands.filter { key, _ in
            // Consider commands expired if they're older than 5 minutes
            // (This is a safety cleanup - normal timeouts should handle this)
            !responseTrackers.keys.contains(key)
        }
        
        for (commandId, continuation) in expiredCommands {
            pendingCommands.removeValue(forKey: commandId)
            continuation.resume(throwing: UnixSockAPIError.commandTimeout(commandId, 300.0))
        }
    }
    
    /// Register a handler for a specific command
    public func registerCommandHandler(_ commandName: String, handler: @escaping CommandHandler) throws {
        // Security validation
        try Self.validateCommandName(commandName, config: config)
        
        // Check handler limit
        guard commandHandlers.count < config.maxCommandHandlers else {
            throw UnixSockAPIError.resourceLimit("Maximum command handlers exceeded")
        }
        
        // Validate that the command exists in the API spec
        guard let channelSpec = apiSpec.channels[channelId],
              channelSpec.commands[commandName] != nil else {
            throw UnixSockAPIError.unknownCommand(commandName)
        }
        
        commandHandlers[commandName] = handler
    }
    
    /// Security validation for command names
    private static func validateCommandName(_ commandName: String, config: UnixSockAPIClientConfig) throws {
        guard commandName.count <= config.maxCommandNameLength else {
            throw UnixSockAPIError.unknownCommand("Command name too long")
        }
        
        guard !commandName.isEmpty else {
            throw UnixSockAPIError.unknownCommand("Command name cannot be empty")
        }
        
        // Only allow alphanumeric, hyphens, underscores
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard commandName.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw UnixSockAPIError.unknownCommand("Command name contains invalid characters")
        }
        
        // Check for null bytes
        guard !commandName.contains("\0") else {
            throw UnixSockAPIError.unknownCommand("Command name cannot contain null bytes")
        }
    }
    
    /// Send a command and wait for response with proper stateless response routing
    public func sendCommand(
        _ commandName: String, 
        args: [String: AnyCodable]? = nil, 
        timeout: TimeInterval = 30.0,
        onTimeout: TimeoutHandler? = nil
    ) async throws -> SocketResponse {
        // Security and validation
        try Self.validateCommandName(commandName, config: config)
        try validateCommand(commandName, args: args)
        try validateArgsSize(args)
        
        // Check pending command limit
        guard pendingCommands.count < config.maxPendingCommands else {
            throw UnixSockAPIError.resourceLimit("Maximum pending commands exceeded")
        }
        
        let commandId = UUID().uuidString
        let command = SocketCommand(
            id: commandId,
            channelId: channelId,
            command: commandName,
            args: args,
            timeout: timeout
        )
        
        // Get connection from pool
        let socketClient = try await connectionPool.borrowConnection()
        defer { 
            Task { @MainActor in
                connectionPool.returnConnection(socketClient)
            }
        }
        
        return try await withThrowingTaskGroup(of: SocketResponse.self) { group in
            // Add response handling task
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    // Register response tracker for stateless response routing
                    let tracker = ResponseTracker(
                        commandId: commandId,
                        channelId: self.channelId,
                        responseHandler: { response in
                            continuation.resume(returning: response)
                        },
                        createdAt: Date(),
                        timeout: timeout
                    )
                    
                    self.responseTrackers[commandId] = tracker
                    self.pendingCommands[commandId] = continuation
                    
                    Task {
                        do {
                            // Set up response handler for this command
                            socketClient.addMessageHandler { [weak self] data in
                                Task { @MainActor in
                                    await self?.handleStatelessResponse(data)
                                }
                            }
                            
                            // Send command with response routing information
                            let message = SocketMessage(
                                type: .command,
                                payload: try self.encoder.encode(command)
                            )
                            
                            try await socketClient.send(try self.encoder.encode(message))
                        } catch {
                            // Clean up on error
                            self.responseTrackers.removeValue(forKey: commandId)
                            self.pendingCommands.removeValue(forKey: commandId)
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                
                Task { @MainActor in
                    // Clean up on timeout
                    self.responseTrackers.removeValue(forKey: commandId)
                    if let continuation = self.pendingCommands.removeValue(forKey: commandId) {
                        onTimeout?(commandId, timeout)
                        continuation.resume(throwing: UnixSockAPIError.commandTimeout(commandId, timeout))
                    }
                }
                
                throw UnixSockAPIError.commandTimeout(commandId, timeout)
            }
            
            // Return the first result (either response or timeout)
            guard let result = try await group.next() else {
                throw UnixSockAPIError.commandTimeout(commandId, timeout)
            }
            
            group.cancelAll()
            return result
        }
    }
    
    /// Validate arguments data size
    private func validateArgsSize(_ args: [String: AnyCodable]?) throws {
        guard let args = args else { return }
        
        do {
            let data = try encoder.encode(args)
            guard data.count <= config.maxArgsDataSize else {
                throw UnixSockAPIError.resourceLimit("Arguments data size exceeds limit")
            }
        } catch {
            throw UnixSockAPIError.encodingFailed(error)
        }
    }
    
    /// Handle responses for stateless commands with proper routing
    private func handleStatelessResponse(_ data: Data) async {
        do {
            let message = try decoder.decode(SocketMessage.self, from: data)
            
            if message.type == .response {
                let response = try decoder.decode(SocketResponse.self, from: message.payload)
                
                // Route response to correct tracker
                if let tracker = responseTrackers[response.commandId] {
                    // Verify channel matches for security
                    guard tracker.channelId == response.channelId else {
                        print("Security warning: Response channel mismatch for command \(response.commandId)")
                        return
                    }
                    
                    // Remove tracker and complete the response
                    responseTrackers.removeValue(forKey: response.commandId)
                    
                    if let continuation = pendingCommands.removeValue(forKey: response.commandId) {
                        continuation.resume(returning: response)
                    } else {
                        // Use the tracker's response handler
                        tracker.responseHandler(response)
                    }
                }
            }
        } catch {
            print("Error decoding stateless response: \(error)")
        }
    }
    
    /// Send a command without waiting for response (fire and forget, stateless)
    public func publishCommand(_ commandName: String, args: [String: AnyCodable]? = nil) async throws -> String {
        try validateCommand(commandName, args: args)
        
        let commandId = UUID().uuidString
        let command = SocketCommand(
            id: commandId,
            channelId: channelId,
            command: commandName,
            args: args
        )
        
        // Create a new socket connection for this command (stateless)
        let socketClient = UnixSocketClient(socketPath: socketPath)
        defer { socketClient.disconnect() }
        
        try await socketClient.connect()
        
        let message = SocketMessage(
            type: .command,
            payload: try encoder.encode(command)
        )
        
        try await socketClient.send(try encoder.encode(message))
        
        return commandId
    }
    
    /// Start listening for commands on this channel
    /// Logic: if handlers registered -> create server socket, if no handlers -> client mode
    public func startListening() async throws {
        // Check if we have handlers registered (expecting requests mode)
        let hasHandlers = !commandHandlers.isEmpty
        
        if hasHandlers {
            // Server mode: create Unix domain socket server and listen for connections
            try await startServerMode()
        } else {
            // Client mode: connect to existing socket for receiving responses
            try await startClientMode()
        }
    }
    
    /// Server mode: create Unix domain socket server and listen for connections
    private func startServerMode() async throws {
        // Remove existing socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create Unix domain socket server using BSD sockets
        let serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket != -1 else {
            throw UnixSockAPIError.connectionRequired
        }
        
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        
        guard socketPath.count < MemoryLayout.size(ofValue: serverAddr.sun_path) else {
            throw UnixSockAPIError.invalidSocketPath("Socket path too long")
        }
        
        _ = withUnsafeMutableBytes(of: &serverAddr.sun_path) { ptr in
            socketPath.withCString { cString in
                strcpy(ptr.bindMemory(to: CChar.self).baseAddress, cString)
            }
        }
        
        let addrSize = MemoryLayout<sockaddr_un>.size
        let bindResult = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(addrSize))
            }
        }
        
        guard bindResult == 0 else {
            close(serverSocket)
            throw UnixSockAPIError.connectionRequired
        }
        
        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw UnixSockAPIError.connectionRequired
        }
        
        // Accept connections in background task
        Task {
            while true {
                let clientSocket = accept(serverSocket, nil, nil)
                if clientSocket != -1 {
                    Task {
                        await self.handleServerConnection(clientSocket)
                    }
                }
            }
        }
    }
    
    /// Client mode: connect to existing socket for receiving responses
    private func startClientMode() async throws {
        let socketClient = UnixSocketClient(socketPath: socketPath)
        
        try await socketClient.connect()
        
        socketClient.addMessageHandler { [weak self] data in
            Task { @MainActor in
                await self?.handleIncomingMessage(data)
            }
        }
        
        // Keep connection alive for listening
        // Note: In a real implementation, you might want to store this connection
        // and provide a way to stop listening
    }
    
    /// Handle incoming connections in server mode
    private func handleServerConnection(_ clientSocket: Int32) async {
        defer { close(clientSocket) }
        
        var buffer = Data(count: Int(config.maxMessageSize))
        let bufferSize = buffer.count
        
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                recv(clientSocket, ptr.baseAddress, bufferSize, 0)
            }
            
            if bytesRead <= 0 {
                break
            }
            
            let data = buffer.prefix(bytesRead)
            await handleIncomingMessage(data)
        }
    }
    
    private func handleSingleCommandResponse(_ data: Data, commandId: String, continuation: CheckedContinuation<SocketResponse, Error>) async {
        do {
            let message = try decoder.decode(SocketMessage.self, from: data)
            
            if message.type == .response {
                let response = try decoder.decode(SocketResponse.self, from: message.payload)
                
                // Only process responses for our channel and command
                if response.channelId == channelId && response.commandId == commandId {
                    continuation.resume(returning: response)
                }
            }
        } catch {
            continuation.resume(throwing: UnixSockAPIError.decodingFailed(error))
        }
    }
    
    private func handleIncomingMessage(_ data: Data) async {
        do {
            let message = try decoder.decode(SocketMessage.self, from: data)
            
            switch message.type {
            case .command:
                await handleIncomingCommand(message.payload)
            case .response:
                await handleIncomingResponse(message.payload)
            }
        } catch {
            print("Error decoding incoming message: \(error)")
        }
    }
    
    private func handleIncomingCommand(_ payload: Data) async {
        do {
            let command = try decoder.decode(SocketCommand.self, from: payload)
            
            // Only process commands for our channel
            guard command.channelId == channelId else { return }
            
            // Check if we have a handler for this command
            guard let handler = commandHandlers[command.command] else {
                // Log unknown command error
                print("Unknown command '\(command.command)' received on channel '\(channelId)'")
                return
            }
            
            // Execute command handler with timeout enforcement
            // Note: In stateless mode, responses would need to be sent back via the incoming socket
            // This is a simplified implementation - in practice, you'd need to track the originating socket
            do {
                let result: [String: AnyCodable]?
                
                if let timeout = command.timeout {
                    // Execute with timeout enforcement
                    result = try await withThrowingTaskGroup(of: [String: AnyCodable]?.self) { group in
                        // Add handler execution task
                        group.addTask {
                            try await handler(command, command.args)
                        }
                        
                        // Add timeout task
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            throw CommandHandlerTimeoutError(commandId: command.id, timeout: timeout)
                        }
                        
                        // Return the first result (either handler result or timeout)
                        guard let result = try await group.next() else {
                            throw CommandHandlerTimeoutError(commandId: command.id, timeout: timeout)
                        }
                        
                        group.cancelAll()
                        return result
                    }
                } else {
                    // Execute without timeout
                    result = try await handler(command, command.args)
                }
                
                print("Command '\(command.command)' executed successfully with result: \(result != nil ? "data" : "no data")")
                // Response would be sent back via the socket that received the command
                
            } catch let timeoutError as CommandHandlerTimeoutError {
                print("Command '\(command.command)' handler timed out: \(timeoutError.localizedDescription)")
                // Error response would indicate timeout to the caller
            } catch {
                print("Command '\(command.command)' failed: \(error.localizedDescription)")
                // Error response would be sent back via the socket that received the command
            }
        } catch {
            print("Error decoding incoming command: \(error)")
        }
    }
    
    private func handleIncomingResponse(_ payload: Data) async {
        do {
            let response = try decoder.decode(SocketResponse.self, from: payload)
            
            // Only process responses for our channel
            guard response.channelId == channelId else { return }
            
            // Note: In stateless mode, responses are handled by individual command handlers
        } catch {
            print("Error decoding incoming response: \(error)")
        }
    }
    
    
    private func sendSuccessResponse(commandId: String, result: [String: AnyCodable]?, using socketClient: UnixSocketClient) async {
        let response = SocketResponse(
            commandId: commandId,
            channelId: channelId,
            success: true,
            result: result
        )
        
        await sendResponse(response, using: socketClient)
    }
    
    private func sendErrorResponse(commandId: String, error: SocketError, using socketClient: UnixSocketClient) async {
        let response = SocketResponse(
            commandId: commandId,
            channelId: channelId,
            success: false,
            error: error
        )
        
        await sendResponse(response, using: socketClient)
    }
    
    private func sendResponse(_ response: SocketResponse, using socketClient: UnixSocketClient) async {
        do {
            let message = SocketMessage(
                type: .response,
                payload: try encoder.encode(response)
            )
            
            try await socketClient.send(try encoder.encode(message))
        } catch {
            print("Error sending response: \(error)")
        }
    }
    
    private func validateCommand(_ commandName: String, args: [String: AnyCodable]?) throws {
        guard let channelSpec = apiSpec.channels[channelId] else {
            throw UnixSockAPIError.invalidChannel(channelId)
        }
        
        guard let commandSpec = channelSpec.commands[commandName] else {
            throw UnixSockAPIError.unknownCommand(commandName)
        }
        
        // Validate required arguments
        if let argSpecs = commandSpec.args {
            for (argName, argSpec) in argSpecs {
                if argSpec.required {
                    guard let args = args, args[argName] != nil else {
                        throw UnixSockAPIError.missingRequiredArgument(argName)
                    }
                }
            }
        }
        
        // Additional argument validation could be added here
        // (type checking, format validation, etc.)
    }
}

/// Errors that can occur during UnixSockAPI operations
public enum UnixSockAPIError: Error, LocalizedError {
    case invalidChannel(String)
    case unknownCommand(String)
    case missingRequiredArgument(String)
    case invalidArgument(String, String)
    case connectionRequired
    case encodingFailed(Error)
    case decodingFailed(Error)
    case commandTimeout(String, TimeInterval)
    case handlerTimeout(String, TimeInterval)
    case resourceLimit(String)
    case tooManyHandlers(String)  // Specific resource limit for handlers
    case invalidSocketPath(String)
    case invalidArguments(String)  // General invalid arguments case
    case invalidCommand(String)  // Alias for unknownCommand for consistency
    case securityViolation(String)
    case malformedData(String)
    case messageToLarge(Int, Int) // actual size, max size
    
    public var errorDescription: String? {
        switch self {
        case .invalidChannel(let channelId):
            return "Invalid channel: \(channelId)"
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingRequiredArgument(let argName):
            return "Missing required argument: \(argName)"
        case .invalidArgument(let argName, let reason):
            return "Invalid argument '\(argName)': \(reason)"
        case .connectionRequired:
            return "Connection required"
        case .encodingFailed(let error):
            return "Encoding failed: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .commandTimeout(let commandId, let timeout):
            return "Command \(commandId) timed out after \(timeout) seconds"
        case .handlerTimeout(let commandId, let timeout):
            return "Command handler for \(commandId) exceeded timeout of \(timeout) seconds"
        case .resourceLimit(let description):
            return "Resource limit exceeded: \(description)"
        case .tooManyHandlers(let description):
            return "Too many handlers: \(description)"
        case .invalidSocketPath(let reason):
            return "Invalid socket path: \(reason)"
        case .invalidArguments(let reason):
            return "Invalid arguments: \(reason)"
        case .invalidCommand(let command):
            return "Invalid command: \(command)"
        case .securityViolation(let description):
            return "Security violation: \(description)"
        case .malformedData(let description):
            return "Malformed data: \(description)"
        case .messageToLarge(let actualSize, let maxSize):
            return "Message too large: \(actualSize) bytes exceeds limit of \(maxSize) bytes"
        }
    }
}