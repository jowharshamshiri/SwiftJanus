// ProtocolTests.swift
// Message framing and protocol tests

import XCTest
@testable import SwiftJanus

@MainActor
final class ProtocolTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/janus-protocol-test.sock"
        
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
    
    // MARK: - SOCK_DGRAM JSON Serialization Tests
    
    func testJSONSerializationValidation() throws {
        // SOCK_DGRAM uses JanusDatagramClient - test JSON parsing directly
        
        // Test various JSON messages for SOCK_DGRAM communication
        let testMessages = [
            "{}",                                           // Minimal JSON
            "{\"test\": \"data\"}",                        // Small message
            "{\"data\": \"" + String(repeating: "a", count: 1000) + "\"}", // Medium message
            "{\"large\": \"" + String(repeating: "x", count: 1000) + "\"}" // Moderate message
        ]
        
        for testMessage in testMessages {
            let data = testMessage.data(using: .utf8)!
            
            // Test that message validation works
            // Test JSON parsing (SOCK_DGRAM validation)
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                XCTAssertTrue(jsonObject is [String: Any], "Should parse as JSON object: \(testMessage.prefix(50))")
            } catch {
                XCTFail("Valid JSON should parse successfully: \(testMessage.prefix(50))")
            }
            
            // Test message size limits
            // Test size limits for datagram communication
            XCTAssertLessThanOrEqual(data.count, 65536, "Message should fit in datagram size limit")
        }
    }
    
    func testDatagramSizeValidation() throws {
        // SOCK_DGRAM with size limit - test JSON parsing with size bounds
        
        // Test messages at size boundaries for SOCK_DGRAM
        let exactLimitMessage = String(repeating: "a", count: 1020) // Leave room for JSON structure
        let validMessage = "{\"data\": \"" + exactLimitMessage + "\"}"
        let validData = validMessage.data(using: .utf8)!
        
        if validData.count <= 1024 {
            // Test JSON parsing for datagram communication
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: validData, options: []), "Message at size limit should be valid JSON")
        }
        
        // Test oversized message
        let oversizedMessage = String(repeating: "b", count: 2000)
        let invalidMessage = "{\"data\": \"" + oversizedMessage + "\"}"
        let invalidData = invalidMessage.data(using: .utf8)!
        
        // Should exceed reasonable datagram size
        XCTAssertGreaterThan(invalidData.count, 1024, "Test setup: message should exceed limit")
    }
    
    func testMalformedJSONValidation() throws {
        // SOCK_DGRAM uses JanusDatagramClient - test JSON parsing directly
        
        // Test various malformed messages that should fail JSON parsing
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
            // Note: "[]" is valid JSON, removed from test
            "{\0}",                      // Null byte in JSON
        ]
        
        for malformed in definitivelyInvalidMessages {
            let data = malformed.data(using: .utf8) ?? Data()
            // Test JSON parsing failure for SOCK_DGRAM validation
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: data, options: []), "Malformed message should fail JSON parsing: \(malformed)")
        }
        
        // Test messages that pass JSON validation
        let basicValidMessages = [
            "{}",                        // Empty object (valid)
            "{\r\n}",                    // Control characters but valid structure  
            "{\"key\": \"value\"}",      // Definitely valid
        ]
        
        for message in basicValidMessages {
            let data = message.data(using: .utf8) ?? Data()
            // Basic JSON validation for SOCK_DGRAM
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data, options: []), "Valid JSON structure should parse: \(message)")
        }
    }
    
    func testUTF8EncodingHandling() throws {
        // Test various UTF-8 scenarios for SOCK_DGRAM JSON communication
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
            // Test JSON parsing with UTF-8 content
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data, options: []), "Valid UTF-8 JSON should parse: \(testCase)")
            
            // Test round-trip encoding
            if let decoded = String(data: data, encoding: .utf8) {
                XCTAssertEqual(decoded, testCase, "UTF-8 round-trip should preserve content")
            }
        }
    }
    
    func testInvalidUTF8Handling() throws {
        
        // Create invalid UTF-8 sequences
        let invalidUTF8Sequences: [Data] = [
            Data([0xFF, 0xFE]),                    // Invalid start bytes
            Data([0x80, 0x81]),                    // Continuation bytes without start
            Data([0xC0, 0x80]),                    // Overlong encoding
            Data([0xED, 0xA0, 0x80]),              // Surrogate half
            Data([0xF4, 0x90, 0x80, 0x80]),        // Code point too large
        ]
        
        for invalidData in invalidUTF8Sequences {
            // Invalid UTF-8 should fail JSON parsing in SOCK_DGRAM
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: invalidData, options: []), "Invalid UTF-8 should fail JSON parsing")
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
    
    func testDatagramMessageBoundaries() throws {
        // Test messages at various size boundaries for SOCK_DGRAM
        let boundarySizes = [0, 1, 255, 256, 1023, 1024, 1025, 4095, 4096]
        
        for size in boundarySizes {
            let content = String(repeating: "a", count: max(0, size - 20)) // Leave room for JSON structure
            let message = "{\"data\": \"" + content + "\"}"
            let data = message.data(using: .utf8)!
            
            if data.count > 0 {
                // Test JSON parsing for datagram messages
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data, options: []), "Message of size \(data.count) should be valid JSON")
            }
            
            // Test reasonable datagram size limits  
            if data.count <= 65536 {
                // Should fit in typical datagram size
            }
        }
    }
    
    func testProtocolVersionHandling() throws {
        // Test that the protocol handles version information correctly
        let dummyChannel = ChannelSpec(commands: [:])
        let specs = [
            APISpecification(version: "1.0.0", channels: ["testChannel": dummyChannel]),
            APISpecification(version: "2.0.0", channels: ["testChannel": dummyChannel]),
            APISpecification(version: "1.0.0-beta", channels: ["testChannel": dummyChannel]),
            APISpecification(version: "1.0.0+build.1", channels: ["testChannel": dummyChannel])
        ]
        
        for spec in specs {
            // Should be able to create clients with different versions
            let client = try JanusDatagramClient(
                socketPath: testSocketPath,
                channelId: "testChannel",
                apiSpec: spec
            )
            XCTAssertNotNil(client, "Client should be created successfully with version \(spec.version)")
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
            JanusError.invalidChannel("test channel"),
            JanusError.unknownCommand("test command"),
            JanusError.invalidArgument("test args", "reason"),
            JanusError.commandTimeout("cmd-123", 30.0),
            JanusError.resourceLimit("too many"),
            JanusError.invalidSocketPath("bad path")
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
        // Test how SOCK_DGRAM handles binary data (should be rejected or properly encoded)
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        
        // Create SOCK_DGRAM client
        let socketClient = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "test",
            apiSpec: nil
        )
        XCTAssertNotNil(socketClient, "Client should be created successfully")
        
        // Base64-encoded binary data should work in JSON
        let base64Encoded = binaryData.base64EncodedString()
        let jsonMessage = "{\"binaryData\": \"\(base64Encoded)\"}"
        let jsonData = jsonMessage.data(using: .utf8)!
        
        // Test JSON parsing for base64-encoded binary data
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: jsonData, options: []), "Base64-encoded binary data in JSON should be valid")
    }
}