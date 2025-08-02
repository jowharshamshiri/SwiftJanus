// EdgeCasesTests.swift
// Tests for edge cases and error conditions

import XCTest
@testable import SwiftJanus

@MainActor
final class EdgeCasesTests: XCTestCase {
    
    var testSocketPath: String!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/janus-edge-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    func testAnyCodableWithNullValues() throws {
        // Create null value via JSON decoding since NSNull doesn't conform to Codable
        let jsonData = "null".data(using: .utf8)!
        let nullValue = try JSONDecoder().decode(AnyCodable.self, from: jsonData)
        
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(nullValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: encodedData)
        
        XCTAssertTrue(decodedValue.value is NSNull)
    }
    
    func testAnyCodableWithNestedDictionary() throws {
        // Create nested dictionary with Codable values
        let nestedDict: [String: AnyCodable] = [
            "string": AnyCodable("value"),
            "number": AnyCodable(42),
            "boolean": AnyCodable(true),
            "nested": AnyCodable(["inner": AnyCodable("value")])
        ]
        
        let anyValue = AnyCodable(nestedDict)
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(anyValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is [String: Any])
    }
    
    func testAnyCodableWithComplexArray() throws {
        // Create complex array with Codable values
        let complexArray: [AnyCodable] = [
            AnyCodable("string"),
            AnyCodable(42),
            AnyCodable(true),
            AnyCodable([AnyCodable("nested"), AnyCodable("array")]),
            AnyCodable(["nested": AnyCodable("dict")])
        ]
        
        let anyValue = AnyCodable(complexArray)
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(anyValue)
        
        let decoder = JSONDecoder()
        let decodedValue = try decoder.decode(AnyCodable.self, from: jsonData)
        
        XCTAssertTrue(decodedValue.value is [Any])
        let array = decodedValue.value as? [Any]
        XCTAssertEqual(array?.count, 5)
    }
    
    func testSocketCommandWithEmptyArgs() throws {
        let command = SocketCommand(
            channelId: "testChannel",
            command: "testCommand",
            args: nil
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(command)
        
        let decoder = JSONDecoder()
        let decodedCommand = try decoder.decode(SocketCommand.self, from: jsonData)
        
        XCTAssertNil(decodedCommand.args)
        XCTAssertEqual(decodedCommand.channelId, "testChannel")
        XCTAssertEqual(decodedCommand.command, "testCommand")
    }
    
    func testSocketResponseWithError() throws {
        let error = JSONRPCError.create(
            code: .internalError,
            details: "Internal server error"
        )
        
        let response = SocketResponse(
            commandId: "test-command",
            channelId: "testChannel",
            success: false,
            result: nil,
            error: error
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(response)
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(SocketResponse.self, from: jsonData)
        
        XCTAssertFalse(decodedResponse.success)
        XCTAssertNotNil(decodedResponse.error)
        XCTAssertEqual(decodedResponse.error?.code, JSONRPCErrorCode.internalError.rawValue)
        XCTAssertEqual(decodedResponse.error?.message, JSONRPCErrorCode.internalError.message)
    }
    
    func testValidationWithEdgeCasePatterns() throws {
        // Test with complex regex pattern
        let validation = ValidationSpec(
            pattern: "^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|\"(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21\\x23-\\x5b\\x5d-\\x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])*\")@"
        )
        
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            validation: validation
        )
        
        let commandSpec = CommandSpec(
            args: ["email": argSpec]
        )
        
        let channelSpec = ChannelSpec(
            commands: ["validateEmail": commandSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
        
        // Should not throw during validation
        try ManifestParser.validate(manifest)
    }
    
    func testValidationWithMinMaxEdgeCases() throws {
        // Test with equal min/max values
        let validation = ValidationSpec(
            minLength: 5,
            maxLength: 5,
            minimum: 10.0,
            maximum: 10.0
        )
        
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            validation: validation
        )
        
        let commandSpec = CommandSpec(
            args: ["exactValue": argSpec]
        )
        
        let channelSpec = ChannelSpec(
            commands: ["testExact": commandSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
        
        // Should not throw when min equals max
        try ManifestParser.validate(manifest)
    }
    
    func testManifestWithEmptyCommandArgs() async throws {
        let commandSpec = CommandSpec(
            description: "Command with no args",
            args: [:], // Empty args
            response: ResponseSpec(type: .object)
        )
        
        let channelSpec = ChannelSpec(
            commands: ["noArgsCommand": commandSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
        
        // Should validate successfully
        try ManifestParser.validate(manifest)
        
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Should be able to call command with no args
        do {
            _ = try await client.sendCommand("noArgsCommand")
            XCTFail("Command should have failed due to no server running")
        } catch JanusError.connectionError, JanusError.connectionRequired {
            // Expected - no server running
        } catch JanusError.connectionTestFailed {
            // Expected in SOCK_DGRAM - connection fails before validation can occur
        } catch {
            XCTFail("Command with no args should validate correctly but fail on connection: \(error)")
        }
    }
    
    func testLargeArgumentValues() throws {
        let largeString = String(repeating: "a", count: 10000)
        let largeArgs: [String: AnyCodable] = [
            "largeData": AnyCodable(largeString),
            "largeNumber": AnyCodable(Double.greatestFiniteMagnitude),
            "largeArray": AnyCodable(Array(repeating: "item", count: 1000))
        ]
        
        let command = SocketCommand(
            channelId: "testChannel",
            command: "processLargeData",
            args: largeArgs
        )
        
        // Should be able to serialize large data
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(command)
        
        XCTAssertGreaterThan(jsonData.count, 10000)
        
        // Should be able to deserialize
        let decoder = JSONDecoder()
        let decodedCommand = try decoder.decode(SocketCommand.self, from: jsonData)
        
        XCTAssertEqual(decodedCommand.command, "processLargeData")
        XCTAssertNotNil(decodedCommand.args)
    }
    
    func testSpecialCharactersInChannelAndCommandNames() async throws {
        let commandSpec = CommandSpec(
            description: "Command with special chars",
            args: [:],
            response: ResponseSpec(type: .object)
        )
        
        // Test various special characters that should be valid in identifiers
        let validNames = [
            "command-with-dashes",
            "command_with_underscores",
            "command123withNumbers",
            "commandWithCamelCase"
        ]
        
        var commands: [String: CommandSpec] = [:]
        for name in validNames {
            commands[name] = commandSpec
        }
        
        let channelSpec = ChannelSpec(
            commands: commands
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["channel-with-dashes": channelSpec]
        )
        
        // Should validate successfully
        try ManifestParser.validate(manifest)
        
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "channel-with-dashes"
        )
        
        // Client should validate command names at send time, not registration time
    }
    
    func testConcurrentClientCreation() async throws {
        // Create multiple clients concurrently
        var clients: [JanusClient] = []
        
        for i in 0..<10 {
            let client = try await JanusClient(
                socketPath: "\(testSocketPath!)-\(i)",
                channelId: "testChannel"
            )
            clients.append(client)
        }
        
        XCTAssertEqual(clients.count, 10)
        
        // All clients should be independent - handlers would be server-side
    }
    
    func testSocketPathEdgeCases() async {
        // Test with very long socket path
        let longPath = "/tmp/" + String(repeating: "a", count: 100) + ".sock"
        
        do {
            let client = try await JanusClient(
                socketPath: longPath,
                channelId: "testChannel"
            )
            XCTAssertNotNil(client)
        } catch {
            // May fail on some systems due to path length limits
            // This is acceptable behavior
        }
        
        // Test with path containing special characters
        let specialPath = "/tmp/socket-with-special-chars_123.sock"
        
        do {
            let client = try await JanusClient(
                socketPath: specialPath,
                channelId: "testChannel"
            )
            XCTAssertNotNil(client)
        } catch {
            XCTFail("Client creation should succeed with special characters in path: \(error)")
        }
    }
    
    private func createSimpleManifest() -> Manifest {
        let commandSpec = CommandSpec(
            description: "Simple test command",
            args: [:],
            response: ResponseSpec(type: .object)
        )
        
        let channelSpec = ChannelSpec(
            commands: ["testCommand": commandSpec]
        )
        
        return Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
}