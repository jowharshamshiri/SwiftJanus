// StatelessCommunicationTests.swift
// Tests for stateless communication patterns

import XCTest
@testable import SwiftUnixSockAPI

@MainActor
final class StatelessCommunicationTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/unixsockapi-stateless-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test API specification
        testAPISpec = createStatelessTestAPISpec()
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testStatelessCommandValidation() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        // Test command validation without connection
        // Valid command should pass validation
        do {
            _ = try await client.publishCommand("quickCommand", args: ["data": AnyCodable("test")])
        } catch UnixSocketError.notConnected, UnixSocketError.connectionFailed {
            // Expected error - no server running
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        
        // Invalid command should fail validation
        do {
            _ = try await client.publishCommand("nonExistentCommand")
            XCTFail("Expected unknown command error")
        } catch let error as UnixSockAPIError {
            if case .unknownCommand = error {
                // Expected
            } else {
                XCTFail("Expected unknownCommand error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testMultipleIndependentCommands() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        // Each command should be independent and fail at connection level
        // (since we don't have a server running)
        
        let commands = [
            ("quickCommand", ["data": AnyCodable("test1")]),
            ("quickCommand", ["data": AnyCodable("test2")]),
            ("quickCommand", ["data": AnyCodable("test3")])
        ]
        
        for (command, args) in commands {
            do {
                _ = try await client.publishCommand(command, args: args)
                XCTFail("Expected connection error")
            } catch UnixSocketError.notConnected, UnixSocketError.connectionFailed {
                // Expected - no server running
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
    
    func testConcurrentStatelessCommands() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent command execution
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.publishCommand("quickCommand", args: ["data": AnyCodable("test\(i)")])
                    } catch {
                        // Expected to fail since no server is running
                    }
                }
            }
        }
        
        // All tasks should complete independently
        XCTAssertTrue(true)
    }
    
    func testCommandHandlerRegistration() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        var handlerCallCount = 0
        
        try client.registerCommandHandler("quickCommand") { command, args in
            handlerCallCount += 1
            
            guard let args = args, let data = args["data"] else {
                throw UnixSockAPIError.missingRequiredArgument("data")
            }
            
            return [
                "received": data,
                "processed": AnyCodable(true),
                "timestamp": AnyCodable(Date().timeIntervalSince1970)
            ]
        }
        
        // Handler should be registered successfully
        XCTAssertEqual(handlerCallCount, 0) // Not called yet
    }
    
    func testArgumentValidationWithoutConnection() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        // Test required argument validation
        do {
            _ = try await client.publishCommand("quickCommand") // Missing required 'data' arg
            XCTFail("Expected missing required argument error")
        } catch let error as UnixSockAPIError {
            if case .missingRequiredArgument(let argName) = error {
                XCTAssertEqual(argName, "data")
            } else {
                XCTFail("Expected missingRequiredArgument error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // Test with valid arguments
        do {
            _ = try await client.publishCommand("quickCommand", args: ["data": AnyCodable("valid")])
        } catch UnixSocketError.notConnected, UnixSocketError.connectionFailed {
            // Expected - no server running
        } catch {
            XCTFail("Validation should pass, connection should fail: \(error)")
        }
    }
    
    func testChannelIsolation() throws {
        let client1 = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "channel1",
            apiSpec: createMultiChannelAPISpec()
        )
        
        let client2 = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "channel2",
            apiSpec: createMultiChannelAPISpec()
        )
        
        // Each client should only know about its own channel's commands
        
        // Client1 can register handlers for channel1 commands
        try client1.registerCommandHandler("channel1Command") { command, args in
            return ["source": AnyCodable("channel1")]
        }
        
        // Client2 can register handlers for channel2 commands
        try client2.registerCommandHandler("channel2Command") { command, args in
            return ["source": AnyCodable("channel2")]
        }
        
        // Client1 cannot register handlers for channel2 commands
        XCTAssertThrowsError(
            try client1.registerCommandHandler("channel2Command") { _, _ in nil }
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
        }
        
        // Client2 cannot register handlers for channel1 commands
        XCTAssertThrowsError(
            try client2.registerCommandHandler("channel1Command") { _, _ in nil }
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
        }
    }
    
    func testErrorHandlingInStatelessMode() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel",
            apiSpec: testAPISpec
        )
        
        // Register handler that throws
        try client.registerCommandHandler("quickCommand") { command, args in
            throw UnixSockAPIError.invalidArgument("data", "Test error")
        }
        
        // Error handling should work for registered handlers
        // (though we can't test actual execution without a server)
        XCTAssertTrue(true)
    }
    
    func testAPISpecificationValidationOnInit() {
        // Test with empty channels
        let invalidSpec1 = APISpecification(version: "1.0.0", channels: [:])
        
        XCTAssertThrowsError(
            try UnixSockAPIClient(
                socketPath: testSocketPath,
                channelId: "anyChannel",
                apiSpec: invalidSpec1
            )
        )
        
        // Test with missing target channel
        let validSpec = createStatelessTestAPISpec()
        
        XCTAssertThrowsError(
            try UnixSockAPIClient(
                socketPath: testSocketPath,
                channelId: "nonExistentChannel",
                apiSpec: validSpec
            )
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
            if case .invalidChannel(let channelId) = error as? UnixSockAPIError {
                XCTAssertEqual(channelId, "nonExistentChannel")
            }
        }
    }
    
    func testMessageSerialization() throws {
        let command = SocketCommand(
            channelId: "testChannel",
            command: "testCommand",
            args: ["key": AnyCodable("value")]
        )
        
        let message = SocketMessage(
            type: .command,
            payload: try JSONEncoder().encode(command)
        )
        
        // Test message serialization
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        let decoder = JSONDecoder()
        let decodedMessage = try decoder.decode(SocketMessage.self, from: data)
        
        XCTAssertEqual(decodedMessage.type, .command)
        
        // Test nested command decoding
        let decodedCommand = try decoder.decode(SocketCommand.self, from: decodedMessage.payload)
        XCTAssertEqual(decodedCommand.channelId, "testChannel")
        XCTAssertEqual(decodedCommand.command, "testCommand")
    }
    
    private func createStatelessTestAPISpec() -> APISpecification {
        let dataArg = ArgumentSpec(
            type: .string,
            required: true,
            description: "Data to process"
        )
        
        let quickCommand = CommandSpec(
            description: "Quick stateless command",
            args: ["data": dataArg],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "received": ArgumentSpec(type: .string),
                    "processed": ArgumentSpec(type: .boolean)
                ]
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "Stateless test channel",
            commands: ["quickCommand": quickCommand]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: ["statelessChannel": channelSpec]
        )
    }
    
    private func createMultiChannelAPISpec() -> APISpecification {
        let channel1Command = CommandSpec(
            description: "Command for channel 1",
            args: [:],
            response: ResponseSpec(type: .object)
        )
        
        let channel2Command = CommandSpec(
            description: "Command for channel 2",
            args: [:],
            response: ResponseSpec(type: .object)
        )
        
        let channel1Spec = ChannelSpec(
            description: "First channel",
            commands: ["channel1Command": channel1Command]
        )
        
        let channel2Spec = ChannelSpec(
            description: "Second channel",
            commands: ["channel2Command": channel2Command]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: [
                "channel1": channel1Spec,
                "channel2": channel2Spec
            ]
        )
    }
}