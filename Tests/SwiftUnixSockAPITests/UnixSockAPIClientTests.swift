// UnixSockAPIClientTests.swift
// Tests for high-level API client functionality

import XCTest
@testable import SwiftUnixSockAPI

@MainActor
final class UnixSockAPIClientTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/unixsockapi-client-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test API specification
        testAPISpec = createTestAPISpec()
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testClientInitializationWithValidSpec() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        XCTAssertNotNil(client)
    }
    
    func testClientInitializationWithInvalidChannel() {
        XCTAssertThrowsError(
            try UnixSockAPIClient(
                socketPath: testSocketPath,
                channelId: "nonExistentChannel",
                apiSpec: testAPISpec
            )
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
            if case .invalidChannel(let channelId) = error as? UnixSockAPIError {
                XCTAssertEqual(channelId, "nonExistentChannel")
            }
        }
    }
    
    func testClientInitializationWithInvalidSpec() {
        let invalidSpec = APISpecification(
            version: "",
            channels: [:]
        )
        
        XCTAssertThrowsError(
            try UnixSockAPIClient(
                socketPath: testSocketPath,
                channelId: "testChannel",
                apiSpec: invalidSpec
            )
        ) { error in
            // Should throw UnixSockAPIError.invalidChannel because the channel doesn't exist
            // This happens before API spec validation
            XCTAssertTrue(error is UnixSockAPIError)
        }
    }
    
    func testRegisterValidCommandHandler() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Should not throw
        try client.registerCommandHandler("getData") { command, args in
            return ["result": AnyCodable("test data")]
        }
    }
    
    func testRegisterInvalidCommandHandler() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        XCTAssertThrowsError(
            try client.registerCommandHandler("nonExistentCommand") { command, args in
                return nil
            }
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
            if case .unknownCommand(let commandName) = error as? UnixSockAPIError {
                XCTAssertEqual(commandName, "nonExistentCommand")
            }
        }
    }
    
    func testSocketCommandValidation() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test with missing required argument
        do {
            _ = try await client.publishCommand("getData")
            XCTFail("Expected missing required argument error")
        } catch let error as UnixSockAPIError {
            if case .missingRequiredArgument(let argName) = error {
                XCTAssertEqual(argName, "id")
            } else {
                XCTFail("Expected missingRequiredArgument error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // Test with unknown command
        do {
            _ = try await client.publishCommand("unknownCommand")
            XCTFail("Expected unknown command error")
        } catch let error as UnixSockAPIError {
            if case .unknownCommand(let commandName) = error {
                XCTAssertEqual(commandName, "unknownCommand")
            } else {
                XCTFail("Expected unknownCommand error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testCommandMessageSerialization() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // This test verifies that command serialization works without connecting
        // We can't actually send without a server, but we can test validation
        
        let args: [String: AnyCodable] = [
            "id": AnyCodable("test-id")
        ]
        
        // Should not throw for valid command and args
        do {
            _ = try await client.publishCommand("getData", args: args)
        } catch UnixSocketError.notConnected, UnixSocketError.connectionFailed {
            // Expected - we're not connected to a server
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testMultipleClientInstances() throws {
        let client1 = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let client2 = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Both clients should be created successfully
        XCTAssertNotNil(client1)
        XCTAssertNotNil(client2)
        
        // They should be able to register different handlers
        try client1.registerCommandHandler("getData") { command, args in
            return ["source": AnyCodable("client1")]
        }
        
        try client2.registerCommandHandler("getData") { command, args in
            return ["source": AnyCodable("client2")]
        }
    }
    
    func testCommandHandlerWithAsyncOperations() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        try client.registerCommandHandler("getData") { command, args in
            // Simulate async operation
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            
            guard let args = args, let id = args["id"] else {
                throw UnixSockAPIError.missingRequiredArgument("id")
            }
            
            return [
                "id": id,
                "data": AnyCodable("processed data"),
                "timestamp": AnyCodable(Date().timeIntervalSince1970)
            ]
        }
        
        // Handler registration should succeed
        XCTAssertTrue(true)
    }
    
    func testCommandHandlerErrorHandling() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        try client.registerCommandHandler("getData") { command, args in
            // Simulate error condition
            throw UnixSockAPIError.invalidArgument("id", "ID must be non-empty")
        }
        
        // Handler registration should succeed even if handler throws
        XCTAssertTrue(true)
    }
    
    func testAPISpecWithComplexArguments() throws {
        let complexSpec = createComplexAPISpec()
        
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "complexChannel",
            apiSpec: complexSpec
        )
        
        XCTAssertNotNil(client)
        
        try client.registerCommandHandler("processData") { command, args in
            guard let args = args else {
                throw UnixSockAPIError.missingRequiredArgument("data")
            }
            
            return [
                "processed": AnyCodable(true),
                "inputCount": AnyCodable(args.count)
            ]
        }
    }
    
    func testArgumentValidationConstraints() throws {
        let spec = createSpecWithValidation()
        
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "validationChannel",
            apiSpec: spec
        )
        
        // Register handler for validated command
        try client.registerCommandHandler("validateInput") { command, args in
            return ["valid": AnyCodable(true)]
        }
        
        XCTAssertNotNil(client)
    }
    
    private func createTestAPISpec() -> APISpecification {
        let idArg = ArgumentSpec(
            type: .string,
            required: true,
            description: "Unique identifier"
        )
        
        let getDataCommand = CommandSpec(
            description: "Retrieve data by ID",
            args: ["id": idArg],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "id": ArgumentSpec(type: .string),
                    "data": ArgumentSpec(type: .string)
                ]
            )
        )
        
        let setDataCommand = CommandSpec(
            description: "Store data with ID",
            args: [
                "id": ArgumentSpec(type: .string, required: true),
                "data": ArgumentSpec(type: .string, required: true)
            ],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "success": ArgumentSpec(type: .boolean)
                ]
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel for basic operations",
            commands: [
                "getData": getDataCommand,
                "setData": setDataCommand
            ]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
    
    private func createComplexAPISpec() -> APISpecification {
        let dataArg = ArgumentSpec(
            type: .array,
            required: true,
            description: "Array of data items"
        )
        
        let optionsArg = ArgumentSpec(
            type: .object,
            required: false,
            description: "Processing options"
        )
        
        let processCommand = CommandSpec(
            description: "Process complex data",
            args: [
                "data": dataArg,
                "options": optionsArg
            ],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "processed": ArgumentSpec(type: .boolean),
                    "results": ArgumentSpec(type: .array)
                ]
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "Complex operations channel",
            commands: ["processData": processCommand]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: ["complexChannel": channelSpec]
        )
    }
    
    private func createSpecWithValidation() -> APISpecification {
        let validatedArg = ArgumentSpec(
            type: .string,
            required: true,
            description: "String with validation",
            validation: ValidationSpec(
                minLength: 3,
                maxLength: 50,
                pattern: "^[a-zA-Z0-9_]+$"
            )
        )
        
        let numericArg = ArgumentSpec(
            type: .number,
            required: true,
            description: "Number with range",
            validation: ValidationSpec(
                minimum: 0.0,
                maximum: 100.0
            )
        )
        
        let validateCommand = CommandSpec(
            description: "Command with validated arguments",
            args: [
                "text": validatedArg,
                "value": numericArg
            ],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "valid": ArgumentSpec(type: .boolean)
                ]
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "Validation testing channel",
            commands: ["validateInput": validateCommand]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: ["validationChannel": channelSpec]
        )
    }
}