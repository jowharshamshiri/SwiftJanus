import Foundation

/// Socket message envelope for framing
public struct SocketMessageEnvelope: Codable, Equatable {
    public let type: String      // "command" or "response"
    public let payload: String   // JSON payload as string
    
    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }
}

/// Message framing functionality with 4-byte length prefix
public class MessageFraming {
    private static let lengthPrefixSize: Int = 4
    private static let maxMessageSize: Int = 10 * 1024 * 1024 // 10MB default
    
    public init() {}
    
    /// Encode a message with 4-byte big-endian length prefix
    public func encodeMessage(_ message: MessageFramingMessage) throws -> Data {
        // Determine message type and serialize payload
        let messageType: String
        let payloadData: Data
        
        switch message {
        case .command(let cmd):
            messageType = "command"
            payloadData = try JSONEncoder().encode(cmd)
        case .response(let resp):
            messageType = "response"
            payloadData = try JSONEncoder().encode(resp)
        }
        
        // Create envelope with JSON payload
        let payloadString = String(data: payloadData, encoding: .utf8) ?? ""
        let envelope = SocketMessageEnvelope(type: messageType, payload: payloadString)
        
        // Serialize envelope to JSON
        let envelopeData = try JSONEncoder().encode(envelope)
        
        // Validate message size
        if envelopeData.count > Self.maxMessageSize {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Message size \(envelopeData.count) exceeds maximum \(Self.maxMessageSize)"
            )
        }
        
        // Create length prefix (4-byte big-endian)
        var lengthBytes = UInt32(envelopeData.count).bigEndian
        let lengthData = Data(bytes: &lengthBytes, count: Self.lengthPrefixSize)
        
        // Combine length prefix and message
        var result = Data(capacity: Self.lengthPrefixSize + envelopeData.count)
        result.append(lengthData)
        result.append(envelopeData)
        
        return result
    }
    
    /// Decode a message from buffer with length prefix
    public func decodeMessage(_ buffer: Data) throws -> (message: MessageFramingMessage, remainingBuffer: Data) {
        // Check if we have at least the length prefix
        if buffer.count < Self.lengthPrefixSize {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Buffer too small for length prefix: \(buffer.count) < \(Self.lengthPrefixSize)"
            )
        }
        
        // Read message length from big-endian prefix
        let lengthBytes = buffer.prefix(Self.lengthPrefixSize)
        let messageLength = lengthBytes.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        
        // Validate message length
        if messageLength > Self.maxMessageSize {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Message length \(messageLength) exceeds maximum \(Self.maxMessageSize)"
            )
        }
        
        if messageLength == 0 {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Message length cannot be zero"
            )
        }
        
        // Check if we have the complete message
        let totalRequired = Self.lengthPrefixSize + Int(messageLength)
        if buffer.count < totalRequired {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Buffer too small for complete message: \(buffer.count) < \(totalRequired)"
            )
        }
        
        // Extract message data
        let messageBuffer = buffer.subdata(in: Self.lengthPrefixSize..<Self.lengthPrefixSize + Int(messageLength))
        let remainingBuffer = buffer.subdata(in: Self.lengthPrefixSize + Int(messageLength)..<buffer.count)
        
        // Parse JSON envelope
        let envelope: SocketMessageEnvelope
        do {
            envelope = try JSONDecoder().decode(SocketMessageEnvelope.self, from: messageBuffer)
        } catch {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Failed to parse message envelope JSON: \(error.localizedDescription)"
            )
        }
        
        // Validate envelope structure
        if envelope.type.isEmpty || envelope.payload.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Message envelope missing required fields (type, payload)"
            )
        }
        
        if envelope.type != "command" && envelope.type != "response" {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Invalid message type: \(envelope.type)"
            )
        }
        
        // Parse payload JSON directly
        let payloadData = envelope.payload.data(using: .utf8) ?? Data()
        let message: MessageFramingMessage
        
        if envelope.type == "command" {
            do {
                let cmd = try JSONDecoder().decode(JanusCommand.self, from: payloadData)
                try validateCommandStructure(cmd)
                message = .command(cmd)
            } catch {
                throw JSONRPCError.create(
                    code: .messageFramingError,
                    details: "Failed to parse command payload JSON: \(error.localizedDescription)"
                )
            }
        } else {
            do {
                let resp = try JSONDecoder().decode(JanusResponse.self, from: payloadData)
                try validateResponseStructure(resp)
                message = .response(resp)
            } catch {
                throw JSONRPCError.create(
                    code: .messageFramingError,
                    details: "Failed to parse response payload JSON: \(error.localizedDescription)"
                )
            }
        }
        
        return (message: message, remainingBuffer: remainingBuffer)
    }
    
    /// Extract complete messages from a buffer, handling partial messages
    public func extractMessages(_ buffer: Data) throws -> (messages: [MessageFramingMessage], remainingBuffer: Data) {
        var messages: [MessageFramingMessage] = []
        var currentBuffer = buffer
        
        while !currentBuffer.isEmpty {
            do {
                let result = try decodeMessage(currentBuffer)
                messages.append(result.message)
                currentBuffer = result.remainingBuffer
            } catch let error as JSONRPCError {
                if let details = error.data?.details, 
                   details.contains("Buffer too small for length prefix") || details.contains("Buffer too small for complete message") {
                    // Not enough data for complete message, save remaining buffer
                    break
                }
                throw error
            }
        }
        
        return (messages: messages, remainingBuffer: currentBuffer)
    }
    
    /// Calculate the total size needed for a message when framed
    public func calculateFramedSize(_ message: MessageFramingMessage) throws -> Int {
        let encoded = try encodeMessage(message)
        return encoded.count
    }
    
    /// Create a direct JSON message for simple cases (without envelope)
    public func encodeDirectMessage(_ message: MessageFramingMessage) throws -> Data {
        // Serialize message to JSON
        let messageData: Data
        switch message {
        case .command(let cmd):
            messageData = try JSONEncoder().encode(cmd)
        case .response(let resp):
            messageData = try JSONEncoder().encode(resp)
        }
        
        // Validate message size
        if messageData.count > Self.maxMessageSize {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Message size \(messageData.count) exceeds maximum \(Self.maxMessageSize)"
            )
        }
        
        // Create length prefix and combine
        var lengthBytes = UInt32(messageData.count).bigEndian
        let lengthData = Data(bytes: &lengthBytes, count: Self.lengthPrefixSize)
        
        var result = Data(capacity: Self.lengthPrefixSize + messageData.count)
        result.append(lengthData)
        result.append(messageData)
        
        return result
    }
    
    /// Decode a direct JSON message (without envelope)
    public func decodeDirectMessage(_ buffer: Data) throws -> (message: MessageFramingMessage, remainingBuffer: Data) {
        // Check length prefix
        if buffer.count < Self.lengthPrefixSize {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Buffer too small for length prefix: \(buffer.count) < \(Self.lengthPrefixSize)"
            )
        }
        
        let lengthBytes = buffer.prefix(Self.lengthPrefixSize)
        let messageLength = lengthBytes.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(as: UInt32.self))
        }
        let totalRequired = Self.lengthPrefixSize + Int(messageLength)
        
        if buffer.count < totalRequired {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Buffer too small for complete message: \(buffer.count) < \(totalRequired)"
            )
        }
        
        // Extract and parse message
        let messageBuffer = buffer.subdata(in: Self.lengthPrefixSize..<Self.lengthPrefixSize + Int(messageLength))
        let remainingBuffer = buffer.subdata(in: Self.lengthPrefixSize + Int(messageLength)..<buffer.count)
        
        // Try to determine message type by looking for key fields
        let rawValue: [String: Any]
        do {
            rawValue = try JSONSerialization.jsonObject(with: messageBuffer) as? [String: Any] ?? [:]
        } catch {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Failed to parse message JSON: \(error.localizedDescription)"
            )
        }
        
        // Determine message type and parse accordingly
        let message: MessageFramingMessage
        if rawValue["command"] != nil {
            do {
                let cmd = try JSONDecoder().decode(JanusCommand.self, from: messageBuffer)
                message = .command(cmd)
            } catch {
                throw JSONRPCError.create(
                    code: .messageFramingError,
                    details: "Failed to parse command: \(error.localizedDescription)"
                )
            }
        } else if rawValue["commandId"] != nil {
            do {
                let resp = try JSONDecoder().decode(JanusResponse.self, from: messageBuffer)
                message = .response(resp)
            } catch {
                throw JSONRPCError.create(
                    code: .messageFramingError,
                    details: "Failed to parse response: \(error.localizedDescription)"
                )
            }
        } else {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Cannot determine message type"
            )
        }
        
        return (message: message, remainingBuffer: remainingBuffer)
    }
    
    // MARK: - Private Validation Methods
    
    private func validateCommandStructure(_ cmd: JanusCommand) throws {
        if cmd.id.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Command missing required string field: id"
            )
        }
        if cmd.channelId.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Command missing required string field: channelId"
            )
        }
        if cmd.command.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Command missing required string field: command"
            )
        }
    }
    
    private func validateResponseStructure(_ resp: JanusResponse) throws {
        if resp.commandId.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Response missing required field: commandId"
            )
        }
        if resp.channelId.isEmpty {
            throw JSONRPCError.create(
                code: .messageFramingError,
                details: "Response missing required field: channelId"
            )
        }
    }
}

/// Message enum for framing operations
public enum MessageFramingMessage: Equatable {
    case command(JanusCommand)
    case response(JanusResponse)
    
    public static func == (lhs: MessageFramingMessage, rhs: MessageFramingMessage) -> Bool {
        switch (lhs, rhs) {
        case (.command(let lhsCmd), .command(let rhsCmd)):
            return lhsCmd.id == rhsCmd.id &&
                   lhsCmd.channelId == rhsCmd.channelId &&
                   lhsCmd.command == rhsCmd.command &&
                   lhsCmd.replyTo == rhsCmd.replyTo &&
                   lhsCmd.timeout == rhsCmd.timeout &&
                   lhsCmd.timestamp == rhsCmd.timestamp
                   // Note: Skipping args comparison due to AnyCodable complexity
        case (.response(let lhsResp), .response(let rhsResp)):
            return lhsResp.commandId == rhsResp.commandId &&
                   lhsResp.channelId == rhsResp.channelId &&
                   lhsResp.success == rhsResp.success &&
                   lhsResp.timestamp == rhsResp.timestamp
                   // Note: Skipping result and error comparison due to AnyCodable complexity
        default:
            return false
        }
    }
}