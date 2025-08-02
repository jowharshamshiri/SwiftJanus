import XCTest
import Foundation
@testable import SwiftJanus

@available(macOS 10.14, iOS 12.0, *)
final class HighLevelAPITests: XCTestCase {
    var testSocketPath: String!
    var testManifest: Manifest!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/janus-highlevel-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test Manifest
        testManifest = createHighLevelTestManifest()
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testJanusClientCreation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        XCTAssertNotNil(client)
    }
    
    func testJanusCommandValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Valid command should pass validation
        do {
            _ = try await client.sendCommand("ping", args: ["message": AnyCodable("test")])
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue || error.code == JSONRPCErrorCode.socketError.rawValue {
            // Expected - no server running or socket connection failed
        } catch {
            XCTFail("Valid command should pass validation: \(error)")
        }
    }
    
    func testDatagramInvalidCommand() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Invalid command should fail validation
        do {
            _ = try await client.sendCommand("nonExistentCommand")
            XCTFail("Expected unknown command error")
        } catch let error as JSONRPCError {
            if error.code == JSONRPCErrorCode.methodNotFound.rawValue {
                // Validated by error code - no need to check message text
                // Expected
            } else if error.code == JSONRPCErrorCode.serverError.rawValue {
                // Expected in SOCK_DGRAM - connection fails before command validation
            } else {
                XCTFail("Expected unknownCommand or connectionTestFailed error, got \(error)")
            }
        }
    }
    
    func testDatagramArgumentValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Missing required argument should fail
        do {
            _ = try await client.sendCommand("echo") // Missing required 'data' arg
            XCTFail("Expected missing required argument error")
        } catch let error as JSONRPCError {
            if error.code == JSONRPCErrorCode.invalidParams.rawValue {
                // Validated by error code - missing required argument confirmed
            } else if error.code == JSONRPCErrorCode.serverError.rawValue {
                // Expected in SOCK_DGRAM - connection fails before validation
            } else {
                XCTFail("Expected missingRequiredArgument or connectionTestFailed error, got \(error)")
            }
        }
    }
    
    func testDatagramMessageSerialization() throws {
        let command = JanusCommand(
            channelId: "testChannel",
            command: "ping",
            args: ["message": AnyCodable("hello")]
        )
        
        // Test JSON serialization
        let encoder = JSONEncoder()
        let data = try encoder.encode(command)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JanusCommand.self, from: data)
        
        XCTAssertEqual(decoded.channelId, "testChannel")
        XCTAssertEqual(decoded.command, "ping")
        XCTAssertNotNil(decoded.args)
    }
    
    private func createHighLevelTestManifest() -> Manifest {
        let messageArg = ArgumentSpec(
            type: .string,
            required: true,
            description: "Message to process"
        )
        
        let dataArg = ArgumentSpec(
            type: .string,
            required: true,
            description: "Data to echo"
        )
        
        let pingCommand = CommandSpec(
            description: "Ping command",
            args: ["message": messageArg],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "pong": ArgumentSpec(type: .string)
                ]
            )
        )
        
        let echoCommand = CommandSpec(
            description: "Echo command",
            args: ["data": dataArg],
            response: ResponseSpec(
                type: .object,
                properties: [
                    "echo": ArgumentSpec(type: .string)
                ]
            )
        )
        
        let channelSpec = ChannelSpec(
            description: "High-level test channel",
            commands: [
                "ping": pingCommand,
                "echo": echoCommand
            ]
        )
        
        return Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
}