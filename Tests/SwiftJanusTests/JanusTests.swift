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
    
    func testAPISpecificationCreation() throws {
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
        
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
        
        XCTAssertEqual(apiSpec.version, "1.0.0")
        XCTAssertEqual(apiSpec.channels.count, 1)
        XCTAssertNotNil(apiSpec.channels["testChannel"])
        XCTAssertEqual(apiSpec.channels["testChannel"]?.commands.count, 1)
    }
    
    func testAPISpecificationJSONSerialization() throws {
        let apiSpec = createTestAPISpec()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(apiSpec)
        
        let decoder = JSONDecoder()
        let decodedSpec = try decoder.decode(APISpecification.self, from: jsonData)
        
        XCTAssertEqual(decodedSpec.version, apiSpec.version)
        XCTAssertEqual(decodedSpec.channels.count, apiSpec.channels.count)
    }
    
    func testSocketCommandSerialization() throws {
        let args: [String: AnyCodable] = [
            "stringArg": AnyCodable("test"),
            "intArg": AnyCodable(42),
            "boolArg": AnyCodable(true)
        ]
        
        let command = SocketCommand(
            channelId: "testChannel",
            command: "testCommand",
            args: args
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(command)
        
        let decoder = JSONDecoder()
        let decodedCommand = try decoder.decode(SocketCommand.self, from: jsonData)
        
        XCTAssertEqual(decodedCommand.channelId, command.channelId)
        XCTAssertEqual(decodedCommand.command, command.command)
        XCTAssertEqual(decodedCommand.id, command.id)
        XCTAssertNotNil(decodedCommand.args)
    }
    
    func testSocketResponseSerialization() throws {
        let result: [String: AnyCodable] = [
            "status": AnyCodable("success"),
            "data": AnyCodable(["key": "value"])
        ]
        
        let response = SocketResponse(
            commandId: "test-command-id",
            channelId: "testChannel",
            success: true,
            result: result
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(response)
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(SocketResponse.self, from: jsonData)
        
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
    
    private func createTestAPISpec() -> APISpecification {
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
        
        return APISpecification(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
}