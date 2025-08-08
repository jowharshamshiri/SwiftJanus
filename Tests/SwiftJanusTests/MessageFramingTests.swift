import XCTest
@testable import SwiftJanus

final class MessageFramingTests: XCTestCase {
    var framing: MessageFraming!
    
    override func setUp() {
        super.setUp()
        framing = MessageFraming()
    }
    
    override func tearDown() {
        framing = nil
        super.tearDown()
    }
    
    // MARK: - Encode Message Tests
    
    func testEncodeMessage_Request() {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(request)
        
        XCTAssertNoThrow(try {
            let encoded = try framing.encodeMessage(message)
            XCTAssertGreaterThan(encoded.count, 4) // At least length prefix + content
            
            // Check length prefix (first 4 bytes)
            let lengthData = encoded.prefix(4)
            let messageLength = lengthData.withUnsafeBytes { bytes in
                UInt32(bigEndian: bytes.load(as: UInt32.self))
            }
            XCTAssertEqual(Int(messageLength), encoded.count - 4)
        }())
    }
    
    func testEncodeMessage_Response() {
        let response = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let message = MessageFramingMessage.response(response)
        
        XCTAssertNoThrow(try {
            let encoded = try framing.encodeMessage(message)
            XCTAssertGreaterThan(encoded.count, 4)
        }())
    }
    
    func testEncodeMessage_TooLarge() {
        // Create a request with very large args
        let largeData = String(repeating: "x", count: 20 * 1024 * 1024) // 20MB
        let request = JanusRequest(
            id: "test-id",
            channelId: "test-service",
            request: "large",
            args: ["data": AnyCodable(largeData)],
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(request)
        
        XCTAssertThrowsError(try framing.encodeMessage(message)) { error in
            // Validate error code instead of error message content
            if let jsonRPCError = error as? JSONRPCError {
                XCTAssertEqual(jsonRPCError.code, -32011) // MessageFramingError code
            } else {
                XCTFail("Expected JSONRPCError with MessageFramingError code")
            }
        }
    }
    
    // MARK: - Decode Message Tests
    
    func testDecodeMessage_Request() throws {
        let originalRequest = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(originalRequest)
        let encoded = try framing.encodeMessage(message)
        
        let result = try framing.decodeMessage(encoded)
        XCTAssertTrue(result.remainingBuffer.isEmpty)
        
        guard case let .request(decodedRequest) = result.message else {
            XCTFail("Expected request message")
            return
        }
        
        XCTAssertEqual(decodedRequest.id, originalRequest.id)
        XCTAssertEqual(decodedRequest.channelId, originalRequest.channelId)
        XCTAssertEqual(decodedRequest.request, originalRequest.request)
    }
    
    func testDecodeMessage_Response() throws {
        let originalResponse = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let message = MessageFramingMessage.response(originalResponse)
        let encoded = try framing.encodeMessage(message)
        
        let result = try framing.decodeMessage(encoded)
        XCTAssertTrue(result.remainingBuffer.isEmpty)
        
        guard case let .response(decodedResponse) = result.message else {
            XCTFail("Expected response message")
            return
        }
        
        XCTAssertEqual(decodedResponse.requestId, originalResponse.requestId)
        XCTAssertEqual(decodedResponse.success, originalResponse.success)
    }
    
    func testDecodeMessage_MultipleMessages() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let response = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let encoded1 = try framing.encodeMessage(.request(request))
        let encoded2 = try framing.encodeMessage(.response(response))
        
        var combined = Data()
        combined.append(encoded1)
        combined.append(encoded2)
        
        // Extract first message
        let result1 = try framing.decodeMessage(combined)
        guard case .request = result1.message else {
            XCTFail("First message should be a request")
            return
        }
        
        // Extract second message
        let result2 = try framing.decodeMessage(result1.remainingBuffer)
        guard case .response = result2.message else {
            XCTFail("Second message should be a response")
            return
        }
        
        XCTAssertTrue(result2.remainingBuffer.isEmpty)
    }
    
    func testDecodeMessage_IncompleteLengthPrefix() {
        let shortBuffer = Data([0x00, 0x00]) // Only 2 bytes
        
        XCTAssertThrowsError(try framing.decodeMessage(shortBuffer)) { error in
            // Validate error code instead of error message content
            if let jsonRPCError = error as? JSONRPCError {
                XCTAssertEqual(jsonRPCError.code, -32011) // MessageFramingError code
            } else {
                XCTFail("Expected JSONRPCError with MessageFramingError code")
            }
        }
    }
    
    func testDecodeMessage_IncompleteMessage() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let encoded = try framing.encodeMessage(.request(request))
        let truncated = encoded.prefix(encoded.count - 10) // Remove last 10 bytes
        
        XCTAssertThrowsError(try framing.decodeMessage(truncated)) { error in
            // Validate error code instead of error message content
            if let jsonRPCError = error as? JSONRPCError {
                XCTAssertEqual(jsonRPCError.code, -32011) // MessageFramingError code
            } else {
                XCTFail("Expected JSONRPCError with MessageFramingError code")
            }
        }
    }
    
    func testDecodeMessage_ZeroLength() {
        let zeroLengthBuffer = Data([0x00, 0x00, 0x00, 0x00]) // 0 length
        
        XCTAssertThrowsError(try framing.decodeMessage(zeroLengthBuffer)) { error in
            // Validate error code instead of error message content
            if let jsonRPCError = error as? JSONRPCError {
                XCTAssertEqual(jsonRPCError.code, -32011) // MessageFramingError code
            } else {
                XCTFail("Expected JSONRPCError with MessageFramingError code")
            }
        }
    }
    
    // MARK: - Extract Messages Tests
    
    func testExtractMessages_MultipleComplete() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let response = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let encoded1 = try framing.encodeMessage(.request(request))
        let encoded2 = try framing.encodeMessage(.response(response))
        
        var combined = Data()
        combined.append(encoded1)
        combined.append(encoded2)
        
        let result = try framing.extractMessages(combined)
        
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.remainingBuffer.isEmpty)
        
        guard case .request = result.messages[0],
              case .response = result.messages[1] else {
            XCTFail("Expected request and response messages")
            return
        }
    }
    
    func testExtractMessages_PartialMessage() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let response = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let encoded1 = try framing.encodeMessage(.request(request))
        let encoded2 = try framing.encodeMessage(.response(response))
        
        var combined = Data()
        combined.append(encoded1)
        combined.append(encoded2)
        
        // Take only part of the second message
        let partial = combined.prefix(encoded1.count + 10)
        
        let result = try framing.extractMessages(partial)
        
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.remainingBuffer.count, 10) // Partial second message
        
        guard case .request = result.messages[0] else {
            XCTFail("Expected request message")
            return
        }
    }
    
    func testExtractMessages_EmptyBuffer() throws {
        let result = try framing.extractMessages(Data())
        
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertTrue(result.remainingBuffer.isEmpty)
    }
    
    func testExtractMessages_PartialLengthPrefix() throws {
        let partial = Data([0x00, 0x00]) // Incomplete length prefix
        
        let result = try framing.extractMessages(partial)
        
        XCTAssertEqual(result.messages.count, 0)
        XCTAssertEqual(result.remainingBuffer, partial)
    }
    
    // MARK: - Calculate Framed Size Tests
    
    func testCalculateFramedSize() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(request)
        let size = try framing.calculateFramedSize(message)
        let encoded = try framing.encodeMessage(message)
        
        XCTAssertEqual(size, encoded.count)
    }
    
    // MARK: - Direct Message Tests
    
    func testEncodeDirectMessage() throws {
        let request = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(request)
        let directEncoded = try framing.encodeDirectMessage(message)
        
        XCTAssertGreaterThan(directEncoded.count, 4)
        
        // Should be smaller than envelope version (no envelope overhead)
        let envelopeEncoded = try framing.encodeMessage(message)
        XCTAssertLessThan(directEncoded.count, envelopeEncoded.count)
    }
    
    func testDecodeDirectMessage() throws {
        let originalRequest = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(originalRequest)
        let encoded = try framing.encodeDirectMessage(message)
        
        let result = try framing.decodeDirectMessage(encoded)
        XCTAssertTrue(result.remainingBuffer.isEmpty)
        
        guard case let .request(decodedRequest) = result.message else {
            XCTFail("Expected request message")
            return
        }
        
        XCTAssertEqual(decodedRequest.id, originalRequest.id)
        XCTAssertEqual(decodedRequest.channelId, originalRequest.channelId)
        XCTAssertEqual(decodedRequest.request, originalRequest.request)
    }
    
    func testDirectRoundtripRequest() throws {
        let originalRequest = JanusRequest(
            id: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            request: "ping",
            args: nil,
            timeout: nil,
            timestamp: 1722248200
        )
        
        let message = MessageFramingMessage.request(originalRequest)
        let encoded = try framing.encodeDirectMessage(message)
        let result = try framing.decodeDirectMessage(encoded)
        
        guard case let .request(decodedRequest) = result.message else {
            XCTFail("Expected request message")
            return
        }
        
        // Compare JSON representations for deep equality
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        
        let originalJSON = try encoder.encode(originalRequest)
        let decodedJSON = try encoder.encode(decodedRequest)
        
        XCTAssertEqual(originalJSON, decodedJSON)
    }
    
    func testDirectRoundtripResponse() throws {
        let originalResponse = JanusResponse(
            requestId: "550e8400-e29b-41d4-a716-446655440000",
            channelId: "test-service",
            success: true,
            result: AnyCodable(["pong": AnyCodable(true)]),
            error: nil,
            timestamp: 1722248201
        )
        
        let message = MessageFramingMessage.response(originalResponse)
        let encoded = try framing.encodeDirectMessage(message)
        let result = try framing.decodeDirectMessage(encoded)
        
        guard case let .response(decodedResponse) = result.message else {
            XCTFail("Expected response message")
            return
        }
        
        // Compare key fields for equality (JSON comparison more complex for responses with Any types)
        XCTAssertEqual(decodedResponse.requestId, originalResponse.requestId)
        XCTAssertEqual(decodedResponse.channelId, originalResponse.channelId)
        XCTAssertEqual(decodedResponse.success, originalResponse.success)
        XCTAssertEqual(decodedResponse.timestamp, originalResponse.timestamp)
    }
}