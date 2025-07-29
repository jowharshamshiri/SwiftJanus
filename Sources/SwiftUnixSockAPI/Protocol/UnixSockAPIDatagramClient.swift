import Foundation

/// High-level API client for SOCK_DGRAM Unix socket communication
/// Connectionless implementation with command validation and response correlation
public class UnixSockAPIDatagramClient {
    private let socketPath: String
    private let channelId: String
    private let apiSpec: APISpecification?
    private let datagramClient: UnixDatagramClient
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
    ) {
        self.socketPath = socketPath
        self.channelId = channelId
        self.apiSpec = apiSpec
        self.defaultTimeout = defaultTimeout
        self.enableValidation = enableValidation
        self.datagramClient = UnixDatagramClient(
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
        let responseSocketPath = datagramClient.generateResponseSocketPath()
        
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
        let responseData = try await datagramClient.sendDatagram(commandData, responseSocketPath: responseSocketPath)
        
        // Deserialize response
        let decoder = JSONDecoder()
        let response = try decoder.decode(SocketResponse.self, from: responseData)
        
        // Validate response correlation
        guard response.commandId == commandId else {
            throw UnixSockApiError.protocolError("Response correlation mismatch: expected \\(commandId), got \\(response.commandId)")
        }
        
        guard response.channelId == channelId else {
            throw UnixSockApiError.protocolError("Channel mismatch: expected \\(channelId), got \\(response.channelId)")
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
        try await datagramClient.sendDatagramNoResponse(commandData)
    }
    
    /// Test connectivity to the server
    public func testConnection() async throws {
        try await datagramClient.testConnection()
    }
    
    // MARK: - Private Methods
    
    private func validateCommandAgainstSpec(_ spec: APISpecification, command: SocketCommand) throws {
        // Implementation would validate command against spec
        // For now, just check if channel exists
        guard spec.channels.keys.contains(command.channelId) else {
            throw UnixSockApiError.validationError("Channel \\(command.channelId) not found in API specification")
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
}