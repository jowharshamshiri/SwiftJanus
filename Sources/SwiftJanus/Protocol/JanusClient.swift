import Foundation

/// High-level API client for SOCK_DGRAM Unix socket communication
/// Connectionless implementation with command validation and response correlation
public class JanusClient {
    private let socketPath: String
    private let channelId: String
    private var manifest: Manifest?
    private let coreClient: CoreJanusClient
    private let defaultTimeout: TimeInterval
    private let enableValidation: Bool
    private let responseTracker: ResponseTracker
    
    public init(
        socketPath: String,
        channelId: String,
        maxMessageSize: Int = 65536,
        defaultTimeout: TimeInterval = 30.0,
        datagramTimeout: TimeInterval = 5.0,
        enableValidation: Bool = true
    ) async throws {
        // Validate constructor inputs (matching Go/Rust implementations)
        try Self.validateConstructorInputs(
            socketPath: socketPath,
            channelId: channelId
        )
        
        self.socketPath = socketPath
        self.channelId = channelId
        self.defaultTimeout = defaultTimeout
        self.enableValidation = enableValidation
        
        // Initialize response tracker
        let trackerConfig = TrackerConfig(
            maxPendingCommands: 1000,
            cleanupInterval: 30.0,
            defaultTimeout: defaultTimeout
        )
        self.responseTracker = ResponseTracker(config: trackerConfig)
        
        self.coreClient = CoreJanusClient(
            socketPath: socketPath,
            maxMessageSize: maxMessageSize,
            datagramTimeout: datagramTimeout
        )
        
        // Initialize manifest to nil first
        self.manifest = nil
        
        // Always fetch Manifest from server (matching Go/Rust/TypeScript)
        if enableValidation {
            // Fetch Manifest from server using spec command
            do {
                let specResponse = try await sendBuiltinCommand("spec", args: nil, timeout: 10.0)
                if specResponse.success,
                   let resultData = specResponse.result,
                   let jsonData = try? JSONSerialization.data(withJSONObject: resultData),
                   let fetchedSpec = try? ManifestParser().parseJSON(jsonData) {
                    self.manifest = fetchedSpec
                } else {
                    // If spec command fails, continue without validation
                    self.manifest = nil
                }
            } catch {
                // If spec fetching fails, continue without validation (matching Go/Rust behavior)
                self.manifest = nil
            }
        }
    }
    
    deinit {
        responseTracker.shutdown()
    }
    
    /// Send command via SOCK_DGRAM and wait for response
    public func sendCommand(
        _ command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> SocketResponse {
        // Generate command ID and response socket path
        let commandId = UUID().uuidString
        let responseSocketPath = coreClient.generateResponseSocketPath()
        
        // Create socket command
        let socketCommand = SocketCommand(
            id: commandId,
            channelId: channelId,
            command: command,
            replyTo: responseSocketPath,
            args: args,
            timeout: timeout ?? defaultTimeout
        )
        
        // Validate command against Manifest 
        if enableValidation, let spec = manifest {
            try validateCommandAgainstSpec(spec, command: socketCommand)
        }
        
        // Serialize command
        let encoder = JSONEncoder()
        let commandData = try encoder.encode(socketCommand)
        
        // Send datagram and wait for response
        let responseData = try await coreClient.sendDatagram(commandData, responseSocketPath: responseSocketPath)
        
        // Deserialize response
        let decoder = JSONDecoder()
        let response = try decoder.decode(SocketResponse.self, from: responseData)
        
        // Validate response correlation
        guard response.commandId == commandId else {
            throw JanusError.protocolError("Response correlation mismatch: expected \\(commandId), got \\(response.commandId)")
        }
        
        guard response.channelId == channelId else {
            throw JanusError.protocolError("Channel mismatch: expected \\(channelId), got \\(response.channelId)")
        }
        
        // Update connection state after successful operation
        updateConnectionState(messagesSent: 1, responsesReceived: 1)
        
        return response
    }
    
    /// Send command without expecting response (fire-and-forget)
    public func sendCommandNoResponse(
        _ command: String,
        args: [String: AnyCodable]? = nil
    ) async throws {
        // Generate command ID
        let commandId = UUID().uuidString
        
        // Create socket command (no replyTo field)
        let socketCommand = SocketCommand(
            id: commandId,
            channelId: channelId,
            command: command,
            replyTo: nil,
            args: args,
            timeout: nil
        )
        
        // Validate command against Manifest 
        if enableValidation, let spec = manifest {
            try validateCommandAgainstSpec(spec, command: socketCommand)
        }
        
        // Serialize command
        let encoder = JSONEncoder()
        let commandData = try encoder.encode(socketCommand)
        
        // Send datagram without waiting for response
        try await coreClient.sendDatagramNoResponse(commandData)
    }
    
    /// Test connectivity to the server
    public func testConnection() async throws {
        try await coreClient.testConnection()
    }
    
    // MARK: - Private Methods
    
    /// Validate constructor inputs (matching Go/Rust implementations)
    private static func validateConstructorInputs(
        socketPath: String,
        channelId: String
    ) throws {
        // Validate socket path
        guard !socketPath.isEmpty else {
            throw JanusError.invalidSocketPath("Socket path cannot be empty")
        }
        
        // Security validation for socket path (matching Go implementation)
        if socketPath.contains("\0") {
            throw JanusError.invalidSocketPath("Socket path contains invalid null byte")
        }
        
        if socketPath.contains("..") {
            throw JanusError.invalidSocketPath("Socket path contains path traversal sequence")
        }
        
        // Validate channel ID
        guard !channelId.isEmpty else {
            throw JanusError.invalidChannel("Channel ID cannot be empty")
        }
        
        // Security validation for channel ID (matching Go implementation)
        let forbiddenChars = CharacterSet(charactersIn: "\0;`$|&\n\r\t")
        if channelId.rangeOfCharacter(from: forbiddenChars) != nil {
            throw JanusError.invalidChannel("Channel ID contains forbidden characters")
        }
        
        if channelId.contains("..") || channelId.hasPrefix("/") {
            throw JanusError.invalidChannel("Channel ID contains invalid path characters")
        }
    }
    
    private func validateCommandAgainstSpec(_ spec: Manifest, command: SocketCommand) throws {
        // Check if command is reserved (built-in commands should never be in Manifests)
        if isBuiltinCommand(command.command) {
            throw JanusError.validationError("Command '\(command.command)' is reserved and cannot be used from Manifest")
        }
        
        // Check if channel exists
        guard let channel = spec.channels[command.channelId] else {
            throw JanusError.validationError("Channel \(command.channelId) not found in Manifest")
        }
        
        // Check if command exists in channel
        guard channel.commands.keys.contains(command.command) else {
            throw JanusError.unknownCommand(command.command)
        }
        
        // Validate command arguments
        if let commandSpec = channel.commands[command.command],
           let specArgs = commandSpec.args {
            
            let args = command.args ?? [:]  // Use empty dict if no args provided
            
            // Check for required arguments
            for (argName, argSpec) in specArgs {
                if argSpec.required && args[argName] == nil {
                    throw JanusError.missingRequiredArgument(argName)
                }
            }
        }
    }
    
    // MARK: - Public Properties
    
    public var channelIdValue: String {
        return channelId
    }
    
    public var socketPathValue: String {
        return socketPath
    }
    
    public var manifest: Manifest? {
        return manifest
    }
    
    /// Send a ping command and return success/failure
    /// Convenience method for testing connectivity with a simple ping
    public func ping() async -> Bool {
        do {
            let response = try await sendCommand("ping", args: nil, timeout: 10.0)
            return response.success
        } catch {
            return false
        }
    }
    
    // MARK: - Built-in Command Support
    
    /// Check if command is a built-in command that should bypass API validation
    private func isBuiltinCommand(_ command: String) -> Bool {
        let builtinCommands = ["ping", "echo", "get_info", "validate", "slow_process", "spec"]
        return builtinCommands.contains(command)
    }
    
    /// Send built-in command (used during initialization for spec fetching)
    private func sendBuiltinCommand(
        _ command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval
    ) async throws -> SocketResponse {
        // Generate command ID and response socket path
        let commandId = UUID().uuidString
        let responseSocketPath = coreClient.generateResponseSocketPath()
        
        // Create socket command for built-in command
        let socketCommand = SocketCommand(
            id: commandId,
            channelId: channelId,
            command: command,
            replyTo: responseSocketPath,
            args: args,
            timeout: timeout
        )
        
        // Serialize command
        let encoder = JSONEncoder()
        let commandData = try encoder.encode(socketCommand)
        
        // Send datagram and wait for response
        let responseData = try await coreClient.sendDatagram(commandData, responseSocketPath: responseSocketPath)
        
        // Deserialize response
        let decoder = JSONDecoder()
        let response = try decoder.decode(SocketResponse.self, from: responseData)
        
        // Validate response correlation
        guard response.commandId == commandId else {
            throw JanusError.protocolError("Response correlation mismatch: expected \\(commandId), got \\(response.commandId)")
        }
        
        guard response.channelId == channelId else {
            throw JanusError.protocolError("Channel mismatch: expected \\(channelId), got \\(response.channelId)")
        }
        
        return response
    }
    
    // MARK: - Advanced Client Features
    
    /// Send command with response correlation (async with Promise-like API)
    public func sendCommandAsync(
        _ command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> SocketResponse {
        return try await withCheckedThrowingContinuation { continuation in
            let commandId = UUID().uuidString
            let effectiveTimeout = timeout ?? defaultTimeout
            
            do {
                try responseTracker.registerCommand(
                    commandId: commandId,
                    timeout: effectiveTimeout,
                    resolve: { response in
                        continuation.resume(returning: response)
                    },
                    reject: { error in
                        continuation.resume(throwing: error)
                    }
                )
                
                // Send the actual command
                Task {
                    do {
                        let response = try await sendCommand(command, args: args, timeout: effectiveTimeout)
                        _ = responseTracker.resolveCommand(commandId: commandId, response: response)
                    } catch {
                        _ = responseTracker.rejectCommand(commandId: commandId, error: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Cancel a specific command by ID
    public func cancelCommand(commandId: String) -> Bool {
        return responseTracker.cancelCommand(commandId: commandId)
    }
    
    /// Cancel all pending commands
    public func cancelAllCommands() -> Int {
        return responseTracker.cancelAllCommands()
    }
    
    /// Get pending command statistics
    public func getCommandStatistics() -> CommandStatistics {
        return responseTracker.getStatistics()
    }
    
    /// Execute multiple commands in parallel
    public func executeParallel(_ commands: [(command: String, args: [String: AnyCodable]?)]) async throws -> [SocketResponse] {
        return try await withThrowingTaskGroup(of: SocketResponse.self) { group in
            for (command, args) in commands {
                group.addTask {
                    try await self.sendCommand(command, args: args)
                }
            }
            
            var results: [SocketResponse] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Channel proxy for command execution with specific channel context
    public func channelProxy(channelId: String) -> JanusChannelProxy {
        return JanusChannelProxy(client: self, channelId: channelId)
    }
    
    /// Add event handler to response tracker
    public func on(_ event: String, handler: @escaping (Any) -> Void) {
        responseTracker.on(event, handler: handler)
    }
    
    // MARK: - Command Handler Registration
    
    /// Register a command handler with validation against Manifest
    public func registerCommandHandler(_ command: String, handler: @escaping (SocketCommand) throws -> [String: AnyCodable]) throws {
        // Validate that command exists in Manifest
        guard let manifest = self.manifest else {
            throw JanusError.validationError("Cannot register handler: Manifest not loaded")
        }
        
        // Check if command exists in the current channel
        guard let channel = manifest.channels[channelId] else {
            throw JanusError.validationError("Channel \(channelId) not found in Manifest")
        }
        
        guard channel.commands.keys.contains(command) else {
            throw JanusError.validationError("Command \(command) not found in channel \(channelId) specification")
        }
        
        // In SOCK_DGRAM, we can't actually register handlers on the client side
        // This method validates the command exists but doesn't store the handler
        // (Handlers are registered on the server side)
        print("✅ Command handler validation passed for: \(command)")
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
}

/// Channel-specific command execution proxy
public class JanusChannelProxy {
    private let client: JanusClient
    private let targetChannelId: String
    
    init(client: JanusClient, channelId: String) {
        self.client = client
        self.targetChannelId = channelId
    }
    
    /// Send command through this channel proxy
    public func sendCommand(
        _ command: String,
        args: [String: AnyCodable]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> SocketResponse {
        // Create a temporary client with the target channel ID
        let proxyClient = try await JanusClient(
            socketPath: client.socketPathValue,
            channelId: targetChannelId,
            defaultTimeout: timeout ?? 30.0
        )
        
        defer {
            // Cleanup happens automatically in deinit
        }
        
        return try await proxyClient.sendCommand(command, args: args, timeout: timeout)
    }
}