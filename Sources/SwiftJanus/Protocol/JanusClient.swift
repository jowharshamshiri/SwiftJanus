import Foundation

/// High-level API client for SOCK_DGRAM Unix socket communication
/// Connectionless implementation with command validation and response correlation
public class JanusClient {
    private let socketPath: String
    private let channelId: String
    private let apiSpec: APISpecification?
    private let coreClient: CoreJanusClient
    private let defaultTimeout: TimeInterval
    private let enableValidation: Bool
    
    public init(
        socketPath: String,
        channelId: String,
        apiSpec: APISpecification? = nil,
        maxMessageSize: Int = 65536,
        defaultTimeout: TimeInterval = 30.0,
        datagramTimeout: TimeInterval = 5.0,
        enableValidation: Bool = true
    ) throws {
        // Validate constructor inputs (matching Go/Rust implementations)
        try Self.validateConstructorInputs(
            socketPath: socketPath,
            channelId: channelId,
            apiSpec: apiSpec
        )
        
        self.socketPath = socketPath
        self.channelId = channelId
        self.apiSpec = apiSpec
        self.defaultTimeout = defaultTimeout
        self.enableValidation = enableValidation
        self.coreClient = CoreJanusClient(
            socketPath: socketPath,
            maxMessageSize: maxMessageSize,
            datagramTimeout: datagramTimeout
        )
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
        
        // Validate command against API specification
        if enableValidation, let spec = apiSpec {
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
        
        // Validate command against API specification
        if enableValidation, let spec = apiSpec {
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
        channelId: String,
        apiSpec: APISpecification?
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
        
        // Validate API spec and channel exists if provided
        if let spec = apiSpec {
            guard !spec.channels.isEmpty else {
                throw JanusError.validationError("API specification must contain at least one channel")
            }
            
            guard spec.channels.keys.contains(channelId) else {
                throw JanusError.invalidChannel(channelId)
            }
        }
    }
    
    private func validateCommandAgainstSpec(_ spec: APISpecification, command: SocketCommand) throws {
        // Check if channel exists
        guard let channel = spec.channels[command.channelId] else {
            throw JanusError.validationError("Channel \(command.channelId) not found in API specification")
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
    
    public var apiSpecification: APISpecification? {
        return apiSpec
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
}