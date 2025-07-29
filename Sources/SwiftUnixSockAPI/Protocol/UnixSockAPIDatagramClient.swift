import Foundation

/// Socket command for SOCK_DGRAM communication
public struct SocketCommand: Codable {
    public let id: String
    public let channelId: String
    public let command: String
    public let replyTo: String?
    public let args: [String: AnyCodable]?
    public let timeout: Double?
    public let timestamp: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case channelId
        case command
        case replyTo = "reply_to"
        case args
        case timeout
        case timestamp
    }
    
    public init(id: String, channelId: String, command: String, replyTo: String? = nil, args: [String: AnyCodable]? = nil, timeout: Double? = nil) {
        self.id = id
        self.channelId = channelId
        self.command = command
        self.replyTo = replyTo
        self.args = args
        self.timeout = timeout
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}

/// Socket response for SOCK_DGRAM communication
public struct SocketResponse: Codable {
    public let commandId: String
    public let channelId: String
    public let success: Bool
    public let result: [String: AnyCodable]?
    public let error: SocketError?
    public let timestamp: String
    
    enum CodingKeys: String, CodingKey {
        case commandId
        case channelId
        case success
        case result
        case error
        case timestamp
    }
}

/// Socket error information
public struct SocketError: Codable, Error {
    public let code: String
    public let message: String
    public let details: String?
    
    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

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

/// Type-erased codable value for JSON serialization
public struct AnyCodable: Codable {
    public let value: Any
    
    public init<T>(_ value: T?) where T: Codable {
        self.value = value ?? ()
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.init(())
        } else if let bool = try? container.decode(Bool.self) {
            self.init(bool)
        } else if let int = try? container.decode(Int.self) {
            self.init(int)
        } else if let double = try? container.decode(Double.self) {
            self.init(double)
        } else if let string = try? container.decode(String.self) {
            self.init(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self.init(array)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.init(dictionary)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let dictionary as [String: AnyCodable]:
            try container.encode(dictionary)
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded")
            throw EncodingError.invalidValue(value, context)
        }
    }
}