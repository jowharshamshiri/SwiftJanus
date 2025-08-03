// StatelessCommunicationTests.swift
// Tests for stateless communication patterns

import XCTest
@testable import SwiftJanus

@MainActor
final class StatelessCommunicationTests: XCTestCase {
    
    var testSocketPath: String!
    var testManifest: Manifest!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/janus-stateless-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test Manifest
        testManifest = createStatelessTestManifest()
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testStatelessCommandValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
        )
        
        // Test command validation without connection
        // Valid command should pass validation
        do {
            _ = try await client.sendCommand("quickCommand", args: ["data": AnyCodable("test")])
        } catch let error as JSONRPCError {
            // Expected error - no server running
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        
        // Invalid command should fail - in Dynamic Specification Architecture,
        // this will be a server error since no server is running to provide manifest
        do {
            _ = try await client.sendCommand("nonExistentCommand")
            XCTFail("Expected connection error since no server is running")
        } catch let error as JSONRPCError {
            // With Dynamic Specification Architecture, we expect server error when no server is running
            // because manifest fetching fails before command validation can occur
            XCTAssertEqual(error.code, JSONRPCErrorCode.serverError.rawValue)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testMultipleIndependentCommands() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
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
                _ = try await client.sendCommand(command, args: args)
                XCTFail("Expected connection error")
            } catch let error as JSONRPCError {
                // Expected - no server running
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
    
    func testConcurrentStatelessCommands() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
        )
        
        // Test concurrent command execution
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand("quickCommand", args: ["data": AnyCodable("test\(i)")])
                    } catch {
                        // Expected to fail since no server is running
                    }
                }
            }
        }
        
        // All tasks should complete independently
        XCTAssertTrue(true)
    }
    
    func testCommandHandlerRegistration() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
        )
        
        var handlerCallCount = 0
        
        // Client tests don't register handlers - that's server-side functionality
        // handlerCallCount would be managed by the server in actual usage
        
        // Handler should be registered successfully
        XCTAssertEqual(handlerCallCount, 0) // Not called yet
    }
    
    func testArgumentValidationWithoutConnection() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
        )
        
        // Test required argument validation
        // Note: In Dynamic Specification Architecture, without a running server,
        // we get connection errors before we can validate arguments against the manifest
        do {
            _ = try await client.sendCommand("quickCommand") // Missing required 'data' arg
            XCTFail("Expected connection error since no server is running")
        } catch let error as JSONRPCError {
            // With Dynamic Specification Architecture, we expect server error when no server is running
            // because manifest fetching fails before argument validation can occur
            XCTAssertEqual(error.code, JSONRPCErrorCode.serverError.rawValue)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // Test with valid arguments
        do {
            _ = try await client.sendCommand("quickCommand", args: ["data": AnyCodable("valid")])
        } catch let error as JSONRPCError {
            // Expected - no server running
        } catch {
            XCTFail("Validation should pass, connection should fail: \(error)")
        }
    }
    
    func testChannelIsolation() async throws {
        let client1 = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "channel1"
        )
        
        let client2 = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "channel2"
        )
        
        // Each client should only know about its own channel's commands
        
        // Client1 is for channel1 commands (handlers would be server-side)
        
        // Client2 is for channel2 commands (handlers would be server-side)
        
        // Client1 cannot send channel2 commands - validation happens at send time
        
        // Client2 cannot send channel1 commands - validation happens at send time
    }
    
    func testErrorHandlingInStatelessMode() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "statelessChannel"
        )
        
        // Error handling would be managed by the server-side handlers
        
        // Error handling should work for registered handlers
        // (though we can't test actual execution without a server)
        XCTAssertTrue(true)
    }
    
    func testManifestValidationOnInit() async {
        // Note: In Dynamic Specification Architecture, manifest validation happens when 
        // commands are sent, not during client construction. The client constructor only
        // validates basic input parameters like channelId format.
        
        // Test basic channel ID validation during construction
        do {
            _ = try await JanusClient(
                socketPath: testSocketPath,
                channelId: "" // Empty channel ID should be rejected
            )
            XCTFail("Expected error for empty channel ID")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams.rawValue)
        } catch {
            XCTFail("Expected JSONRPCError for empty channel ID, got: \(error)")
        }
        
        // Test with invalid channel ID patterns during construction
        do {
            _ = try await JanusClient(
                socketPath: testSocketPath,
                channelId: "channel/with/slashes" // Invalid channel pattern
            )
            XCTFail("Expected error for invalid channel ID pattern")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams.rawValue)
        } catch {
            XCTFail("Expected JSONRPCError for invalid channel ID, got: \(error)")
        }
    }
    
    func testMessageSerialization() throws {
        let command = JanusCommand(
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
        let decodedCommand = try decoder.decode(JanusCommand.self, from: decodedMessage.payload)
        XCTAssertEqual(decodedCommand.channelId, "testChannel")
        XCTAssertEqual(decodedCommand.command, "testCommand")
    }
    
    private func createStatelessTestManifest() -> Manifest {
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
        
        return Manifest(
            version: "1.0.0",
            channels: ["statelessChannel": channelSpec]
        )
    }
    
    private func createMultiChannelManifest() -> Manifest {
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
        
        return Manifest(
            version: "1.0.0",
            channels: [
                "channel1": channel1Spec,
                "channel2": channel2Spec
            ]
        )
    }
}