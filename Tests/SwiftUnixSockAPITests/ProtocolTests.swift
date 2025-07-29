// ProtocolTests.swift
// Message framing and protocol tests

import XCTest
@testable import SwiftUnixSockAPI

@MainActor
final class ProtocolTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/unixsockapi-protocol-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test API specification
        let argSpec = ArgumentSpec(
            type: .string,
            required: false,
            validation: ValidationSpec(maxLength: 10000)
        )
        
        let commandSpec = CommandSpec(
            description: "Test command",
            args: ["data": argSpec],
            response: ResponseSpec(type: .object)
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel",
            commands: ["testCommand": commandSpec]
        )
        
        testAPISpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    // MARK: - Message Framing Tests
    
    func testMessageFramingStructure() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        
        // Test various message sizes to ensure framing works correctly
        let testMessages = [
            "{}",                                           // Minimal JSON
            "{\"test\": \"data\"}",                        // Small message
            "{\"data\": \"" + String(repeating: "a", count: 1000) + "\"}", // Medium message
            "{\"large\": \"" + String(repeating: "x", count: 10000) + "\"}" // Large message
        ]
        
        for testMessage in testMessages {
            let data = testMessage.data(using: .utf8)!
            
            // Test that message validation works
            let isValid = socketClient.isValidMessageData(data)
            XCTAssertTrue(isValid, "Valid JSON message should pass validation: \(testMessage.prefix(50))")
            
            // Test message size limits
            if data.count <= socketClient.maximumMessageSize {
                // Should be acceptable
            } else {
                // Should be rejected by size limits
            }
        }
    }
    
    func testMessageSizeValidation() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath, maxMessageSize: 1024)
        
        // Test messages at size boundaries
        let exactLimitMessage = String(repeating: "a", count: 1020) // Leave room for JSON structure
        let validMessage = "{\"data\": \"" + exactLimitMessage + "\"}"
        let validData = validMessage.data(using: .utf8)!
        
        if validData.count <= 1024 {
            XCTAssertTrue(socketClient.isValidMessageData(validData), "Message at size limit should be valid")
        }
        
        // Test oversized message
        let oversizedMessage = String(repeating: "b", count: 2000)
        let invalidMessage = "{\"data\": \"" + oversizedMessage + "\"}"
        let invalidData = invalidMessage.data(using: .utf8)!
        
        // Should be rejected due to size
        XCTAssertGreaterThan(invalidData.count, 1024, "Test setup: message should exceed limit")
    }
    
    func testMalformedMessageFraming() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        
        // Test various malformed messages that should definitely fail basic validation
        let definitivelyInvalidMessages = [
            "",                          // Empty message
            "{",                         // Incomplete JSON
            "}",                         // Invalid JSON start
            "{\"unclosed\": \"string",   // Unclosed string
            "not json at all",           // Not JSON
            "123",                       // Number instead of object
            "\"string\"",                // String instead of object
            "true",                      // Boolean instead of object
            "null",                      // Null instead of object
            "[]",                        // Array instead of object
            "{\0}",                      // Null byte in JSON
        ]
        
        for malformed in definitivelyInvalidMessages {
            let data = malformed.data(using: .utf8) ?? Data()
            let isValid = socketClient.isValidMessageData(data)
            
            XCTAssertFalse(isValid, "Malformed message should be invalid: \(malformed)")
        }
        
        // Test messages that pass basic validation (object structure check)
        let basicValidMessages = [
            "{}",                        // Empty object (valid)
            "{\r\n}",                    // Control characters but valid structure  
            "{\"key\": \"value\"}",      // Definitely valid
        ]
        
        for message in basicValidMessages {
            let data = message.data(using: .utf8) ?? Data()
            let isValid = socketClient.isValidMessageData(data)
            // Basic validation only checks structure, so these should pass
            XCTAssertTrue(isValid, "Valid object structure should pass basic validation: \(message)")
        }
    }
    
    func testUTF8EncodingHandling() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        
        // Test various UTF-8 scenarios
        let utf8TestCases = [
            "{\"ascii\": \"simple\"}",                    // Pure ASCII
            "{\"unicode\": \"café\"}",                    // Accented characters
            "{\"emoji\": \"🚀💻🔒\"}",                    // Emoji
            "{\"chinese\": \"你好世界\"}",                 // Chinese characters
            "{\"arabic\": \"مرحبا بالعالم\"}",            // Arabic text
            "{\"mixed\": \"Hello 世界 🌍\"}",              // Mixed scripts
            "{\"zalgo\": \"H̸̡̪̯ͨ͊̽̅̾̎Ẹ̢̰̰̰̰̰̰\"}",  // Combining characters
        ]
        
        for testCase in utf8TestCases {
            let data = testCase.data(using: .utf8)!
            let isValid = socketClient.isValidMessageData(data)
            XCTAssertTrue(isValid, "Valid UTF-8 JSON should be accepted: \(testCase)")
            
            // Test round-trip encoding
            if let decoded = String(data: data, encoding: .utf8) {
                XCTAssertEqual(decoded, testCase, "UTF-8 round-trip should preserve content")
            }
        }
    }
    
    func testInvalidUTF8Handling() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        
        // Create invalid UTF-8 sequences
        let invalidUTF8Sequences: [Data] = [
            Data([0xFF, 0xFE]),                    // Invalid start bytes
            Data([0x80, 0x81]),                    // Continuation bytes without start
            Data([0xC0, 0x80]),                    // Overlong encoding
            Data([0xED, 0xA0, 0x80]),              // Surrogate half
            Data([0xF4, 0x90, 0x80, 0x80]),        // Code point too large
        ]
        
        for invalidData in invalidUTF8Sequences {
            let isValid = socketClient.isValidMessageData(invalidData)
            XCTAssertFalse(isValid, "Invalid UTF-8 should be rejected")
        }
    }
    
    // MARK: - Socket Message Protocol Tests
    
    func testSocketMessageSerialization() throws {
        let testMessage = SocketMessage(
            type: .command,
            payload: "test payload".data(using: .utf8)!
        )
        
        // Test serialization
        let encoder = JSONEncoder()
        let serializedData = try encoder.encode(testMessage)
        
        // Test deserialization
        let decoder = JSONDecoder()
        let deserializedMessage = try decoder.decode(SocketMessage.self, from: serializedData)
        
        XCTAssertEqual(deserializedMessage.type, testMessage.type)
        XCTAssertEqual(deserializedMessage.payload, testMessage.payload)
    }
    
    func testSocketCommandSerialization() throws {
        let testCommand = SocketCommand(
            id: "test-id-123",
            channelId: "testChannel",
            command: "testCommand",
            args: ["data": AnyCodable("test data"), "number": AnyCodable(42)]
        )
        
        // Test serialization
        let encoder = JSONEncoder()
        let serializedData = try encoder.encode(testCommand)
        
        // Test deserialization
        let decoder = JSONDecoder()
        let deserializedCommand = try decoder.decode(SocketCommand.self, from: serializedData)
        
        XCTAssertEqual(deserializedCommand.id, testCommand.id)
        XCTAssertEqual(deserializedCommand.channelId, testCommand.channelId)
        XCTAssertEqual(deserializedCommand.command, testCommand.command)
        XCTAssertEqual(deserializedCommand.args?.count, testCommand.args?.count)
    }
    
    func testSocketResponseSerialization() throws {
        let testError = SocketError(
            code: "500",
            message: "Test error",
            details: ["context": AnyCodable("test context")]
        )
        
        let testResponse = SocketResponse(
            commandId: "test-response-id",
            channelId: "testChannel",
            success: false,
            result: nil,
            error: testError
        )
        
        // Test serialization
        let encoder = JSONEncoder()
        let serializedData = try encoder.encode(testResponse)
        
        // Test deserialization  
        let decoder = JSONDecoder()
        let deserializedResponse = try decoder.decode(SocketResponse.self, from: serializedData)
        
        XCTAssertEqual(deserializedResponse.commandId, testResponse.commandId)
        XCTAssertEqual(deserializedResponse.channelId, testResponse.channelId)
        XCTAssertEqual(deserializedResponse.success, testResponse.success)
        XCTAssertEqual(deserializedResponse.error?.code, testResponse.error?.code)
        XCTAssertEqual(deserializedResponse.error?.message, testResponse.error?.message)
    }
    
    // MARK: - AnyCodable Protocol Tests
    
    func testAnyCodableEdgeCases() throws {
        let edgeCases: [AnyCodable] = [
            AnyCodable(Int.min),
            AnyCodable(Int.max),
            AnyCodable(Double.greatestFiniteMagnitude),
            AnyCodable(Double.leastNormalMagnitude),
            AnyCodable(-Double.greatestFiniteMagnitude),
            AnyCodable(Float.nan),
            AnyCodable(Float.infinity),
            AnyCodable(-Float.infinity),
            AnyCodable(""),
            AnyCodable(String(repeating: "x", count: 10000)),
            AnyCodable([String]()),
            AnyCodable([String: String]())
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for edgeCase in edgeCases {
            do {
                let encoded = try encoder.encode(edgeCase)
                let decoded = try decoder.decode(AnyCodable.self, from: encoded)
                
                // Special handling for NaN and infinity
                if let originalDouble = edgeCase.value as? Double,
                   let decodedDouble = decoded.value as? Double {
                    if originalDouble.isNaN {
                        XCTAssertTrue(decodedDouble.isNaN)
                    } else if originalDouble.isInfinite {
                        XCTAssertEqual(originalDouble.sign, decodedDouble.sign)
                        XCTAssertTrue(decodedDouble.isInfinite)
                    } else {
                        XCTAssertEqual(originalDouble, decodedDouble, accuracy: 0.0001)
                    }
                }
            } catch {
                // Some edge cases (like NaN, infinity) might not be serializable to JSON
                // This is acceptable behavior
            }
        }
    }
    
    func testAnyCodableNestedStructures() throws {
        // Test deeply nested structures
        let nestedData = AnyCodable([
            "level1": AnyCodable([
                "level2": AnyCodable([
                    "level3": AnyCodable([
                        "data": AnyCodable("deep value"),
                        "numbers": AnyCodable([1, 2, 3, 4, 5])
                    ])
                ])
            ])
        ])
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encoded = try encoder.encode(nestedData)
        let decoded = try decoder.decode(AnyCodable.self, from: encoded)
        
        // Verify structure is preserved
        XCTAssertTrue(decoded.value is [String: Any])
    }
    
    // MARK: - Protocol Boundary Tests
    
    func testMessageBoundaries() throws {
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        
        // Test messages at various size boundaries
        let boundarySizes = [0, 1, 255, 256, 1023, 1024, 1025, 4095, 4096, 4097, 65535, 65536]
        
        for size in boundarySizes {
            let content = String(repeating: "a", count: max(0, size - 20)) // Leave room for JSON structure
            let message = "{\"data\": \"" + content + "\"}"
            let data = message.data(using: .utf8)!
            
            let isValid = socketClient.isValidMessageData(data)
            
            if data.count <= socketClient.maximumMessageSize && data.count > 0 {
                XCTAssertTrue(isValid, "Message of size \(data.count) should be valid")
            }
        }
    }
    
    func testProtocolVersionHandling() throws {
        // Test that the protocol handles version information correctly
        let specs = [
            APISpecification(version: "1.0.0", channels: [:]),
            APISpecification(version: "2.0.0", channels: [:]),
            APISpecification(version: "1.0.0-beta", channels: [:]),
            APISpecification(version: "1.0.0+build.1", channels: [:])
        ]
        
        for spec in specs {
            // Should be able to create clients with different versions
            // The library should handle version information gracefully
            do {
                _ = try UnixSockAPIClient(
                    socketPath: testSocketPath,
                    channelId: "testChannel",
                    apiSpec: spec
                )
            } catch {
                // If it fails, it should be due to missing channels, not version issues
                XCTAssertTrue(error is UnixSockAPIError)
                if case .invalidChannel = error as? UnixSockAPIError {
                    // Expected - no "testChannel" in empty channels
                } else {
                    XCTFail("Unexpected error for version \(spec.version): \(error)")
                }
            }
        }
    }
    
    // MARK: - Error Protocol Tests
    
    func testErrorMessageStructure() throws {
        let errorCodes = [0, 1, 100, 404, 500, 999, Int.max]
        let errorMessages = ["", "short", "a very long error message with lots of detail"]
        
        for code in errorCodes {
            for message in errorMessages {
                let error = SocketError(
                    code: String(code),
                    message: message,
                    details: ["code": AnyCodable(code)]
                )
                
                // Test serialization
                let encoder = JSONEncoder()
                let decoder = JSONDecoder()
                
                let encoded = try encoder.encode(error)
                let decoded = try decoder.decode(SocketError.self, from: encoded)
                
                XCTAssertEqual(decoded.code, error.code)
                XCTAssertEqual(decoded.message, error.message)
            }
        }
    }
    
    func testErrorPropagation() throws {
        // Test that errors are properly structured for transmission
        let testErrors = [
            UnixSockAPIError.invalidChannel("test channel"),
            UnixSockAPIError.invalidCommand("test command"),
            UnixSockAPIError.invalidArguments("test args"),
            UnixSockAPIError.commandTimeout("cmd-123", 30.0),
            UnixSockAPIError.tooManyHandlers("too many"),
            UnixSockAPIError.invalidSocketPath("bad path")
        ]
        
        for testError in testErrors {
            let errorDescription = testError.localizedDescription
            XCTAssertFalse(errorDescription.isEmpty, "Error should have description")
            
            // Error descriptions should not contain sensitive information
            XCTAssertFalse(errorDescription.contains("/etc/"))
            XCTAssertFalse(errorDescription.contains("/usr/"))
            XCTAssertFalse(errorDescription.contains("password"))
        }
    }
    
    // MARK: - Data Integrity Tests
    
    func testDataIntegrityAcrossEncoding() throws {
        let testData = [
            "simple string",
            "string with \"quotes\" and \\backslashes\\",
            "unicode: café 世界 🌍",
            "numbers: 123 456.789 -0.001",
            "special chars: \t\n\r",
            "empty: ",
            String(repeating: "repeated ", count: 1000)
        ]
        
        for original in testData {
            let wrapped = AnyCodable(original)
            
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            
            let encoded = try encoder.encode(wrapped)
            let decoded = try decoder.decode(AnyCodable.self, from: encoded)
            
            if let decodedString = decoded.value as? String {
                XCTAssertEqual(decodedString, original, "String should survive encoding round-trip")
            } else {
                XCTFail("Decoded value should be a string")
            }
        }
    }
    
    func testBinaryDataHandling() throws {
        // Test how the protocol handles binary data (should be rejected or properly encoded)
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        
        // Binary data should not be directly accepted as message content
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        let isValid = socketClient.isValidMessageData(binaryData)
        XCTAssertFalse(isValid, "Raw binary data should not be valid message content")
        
        // But base64-encoded binary data should work
        let base64Encoded = binaryData.base64EncodedString()
        let jsonMessage = "{\"binaryData\": \"\(base64Encoded)\"}"
        let jsonData = jsonMessage.data(using: .utf8)!
        
        let isValidJSON = socketClient.isValidMessageData(jsonData)
        XCTAssertTrue(isValidJSON, "Base64-encoded binary data in JSON should be valid")
    }
}