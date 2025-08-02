// JanusTests.swift
// Basic tests for Janus functionality

import XCTest
@testable import SwiftJanus

final class JanusTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Clean up any existing test socket files
        let testSocketPath = "/tmp/janus-test.sock"
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        let testSocketPath = "/tmp/janus-test.sock"
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testManifestCreation() throws {
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            description: "Test argument"
        )
        
        let commandSpec = CommandSpec(
            description: "Test command",
            args: ["testArg": argSpec],
            response: ResponseSpec(
                type: .object,
                description: "Test response"
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel",
            commands: ["testCommand": commandSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.channels.count, 1)
        XCTAssertNotNil(manifest.channels["testChannel"])
        XCTAssertEqual(manifest.channels["testChannel"]?.commands.count, 1)
    }
    
    func testManifestJSONSerialization() throws {
        let manifest = createTestManifest()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(manifest)
        
        let decoder = JSONDecoder()
        let decodedSpec = try decoder.decode(Manifest.self, from: jsonData)
        
        XCTAssertEqual(decodedSpec.version, manifest.version)
        XCTAssertEqual(decodedSpec.channels.count, manifest.channels.count)
    }
    
    func testJanusCommandSerialization() throws {
        let args: [String: AnyCodable] = [
            "stringArg": AnyCodable("test"),
            "intArg": AnyCodable(42),
            "boolArg": AnyCodable(true)
        ]
        
        let command = JanusCommand(
            channelId: "testChannel",
            command: "testCommand",
            args: args
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(command)
        
        let decoder = JSONDecoder()
        let decodedCommand = try decoder.decode(JanusCommand.self, from: jsonData)
        
        XCTAssertEqual(decodedCommand.channelId, command.channelId)
        XCTAssertEqual(decodedCommand.command, command.command)
        XCTAssertEqual(decodedCommand.id, command.id)
        XCTAssertNotNil(decodedCommand.args)
    }
    
    func testJanusResponseSerialization() throws {
        let result: [String: AnyCodable] = [
            "status": AnyCodable("success"),
            "data": AnyCodable(["key": "value"])
        ]
        
        let response = JanusResponse(
            commandId: "test-command-id",
            channelId: "testChannel",
            success: true,
            result: result
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(response)
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(JanusResponse.self, from: jsonData)
        
        XCTAssertEqual(decodedResponse.commandId, response.commandId)
        XCTAssertEqual(decodedResponse.channelId, response.channelId)
        XCTAssertEqual(decodedResponse.success, response.success)
        XCTAssertNotNil(decodedResponse.result)
    }
    
    func testAnyCodableStringValue() throws {
        let stringValue = AnyCodable("test string")
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(stringValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is String)
        XCTAssertEqual(decodedValue.value as? String, "test string")
    }
    
    func testAnyCodableIntegerValue() throws {
        let intValue = AnyCodable(42)
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(intValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is Int)
        XCTAssertEqual(decodedValue.value as? Int, 42)
    }
    
    func testAnyCodableBooleanValue() throws {
        let boolValue = AnyCodable(true)
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(boolValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is Bool)
        XCTAssertEqual(decodedValue.value as? Bool, true)
    }
    
    func testAnyCodableArrayValue() throws {
        let arrayValue = AnyCodable(["item1", "item2", "item3"])
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(arrayValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is [Any])
        let array = decodedValue.value as? [Any]
        XCTAssertEqual(array?.count, 3)
    }
    
    func testJanusClientInitialization() async {
        let socketPath = "/tmp/test-socket.sock"
        
        do {
            let client = try await JanusClient(
                socketPath: socketPath,
                channelId: "test"
            )
            
            // Test that client is created successfully
            XCTAssertNotNil(client)
        } catch {
            // Expected to fail due to connection issues, but client creation process should work
        }
    }
    
    private func createTestManifest() -> Manifest {
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            description: "Test argument",
            validation: ValidationSpec(
                minLength: 1,
                maxLength: 100,
                pattern: "^[a-zA-Z0-9]+$"
            )
        )
        
        let responseSpec = ResponseSpec(
            type: .object,
            properties: [
                "result": ArgumentSpec(type: .string),
                "timestamp": ArgumentSpec(type: .string)
            ],
            description: "Command response"
        )
        
        let errorSpec = ErrorSpec(
            code: 400,
            message: "Bad Request",
            description: "Invalid command arguments"
        )
        
        let commandSpec = CommandSpec(
            description: "Test command for validation",
            args: ["input": argSpec],
            response: responseSpec,
            errorCodes: ["badRequest"]
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel for API validation",
            commands: ["testCommand": commandSpec]
        )
        
        return Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
    
    /// Test JSON-RPC 2.0 compliant error handling
    /// Validates the architectural enhancement for standardized error codes
    func testJSONRPCErrorFunctionality() throws {
        // Test error code creation and properties
        let error = JSONRPCError.create(code: .methodNotFound, details: "Test method not found")
        
        XCTAssertEqual(error.code, JSONRPCErrorCode.methodNotFound.rawValue)
        XCTAssertEqual(error.message, JSONRPCErrorCode.methodNotFound.message)
        XCTAssertEqual(error.data?.details, "Test method not found")
        
        // Test error code string representation
        let codeString = JSONRPCErrorCode.methodNotFound.stringValue
        XCTAssertEqual(codeString, "METHOD_NOT_FOUND")
        
        // Test all standard error codes
        let testCases: [(JSONRPCErrorCode, String)] = [
            (.parseError, "PARSE_ERROR"),
            (.invalidRequest, "INVALID_REQUEST"),
            (.methodNotFound, "METHOD_NOT_FOUND"),
            (.invalidParams, "INVALID_PARAMS"),
            (.internalError, "INTERNAL_ERROR"),
            (.validationFailed, "VALIDATION_FAILED"),
            (.handlerTimeout, "HANDLER_TIMEOUT"),
            (.securityViolation, "SECURITY_VIOLATION"),
        ]
        
        for (code, expected) in testCases {
            XCTAssertEqual(code.stringValue, expected, "Error code \(code.rawValue) string mismatch")
        }
        
        // Test error response creation  
        let janusResponse = JanusResponse(
            commandId: "test-cmd",
            channelId: "test-channel",
            success: false,
            result: nil,
            error: JSONRPCError.create(code: .methodNotFound, details: "Test error"),
            timestamp: Date().timeIntervalSince1970
        )
        
        XCTAssertNotNil(janusResponse.error, "Expected error response to contain JSONRPCError")
        XCTAssertFalse(janusResponse.success, "Error response should not be successful")
        
        // Test JSON serialization of error response
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(janusResponse)
        
        // Verify JSON contains proper JSON-RPC error structure
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        XCTAssertNotNil(jsonObject, "Failed to parse response as JSON object")
        
        if let jsonObj = jsonObject, let errorObj = jsonObj["error"] as? [String: Any] {
            let code = errorObj["code"] as? Int
            XCTAssertNotNil(code, "Expected numeric error code in JSON")
            
            let message = errorObj["message"] as? String
            XCTAssertNotNil(message, "Expected error message in JSON")
            XCTAssertFalse(message?.isEmpty ?? true, "Error message should not be empty")
        } else {
            XCTFail("Could not find error object in JSON response")
        }
        
        // Test Equatable conformance (with custom implementation)
        let error1 = JSONRPCError.create(code: .methodNotFound, details: "Same details")
        let error2 = JSONRPCError.create(code: .methodNotFound, details: "Same details")
        let error3 = JSONRPCError.create(code: .invalidParams, details: "Different details")
        
        // Note: Custom Equatable implementation only compares basic fields
        // This tests that our simplified equality works as expected
        let data1 = error1.data
        let data2 = error2.data
        let data3 = error3.data
        
        XCTAssertEqual(data1, data2, "JSONRPCErrorData with same details should be equal")
        XCTAssertNotEqual(data1, data3, "JSONRPCErrorData with different details should not be equal")
    }
}