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
    
    func testJanusRequestWithEmptyArgs() throws {
        let request = JanusRequest(
            channelId: "testChannel",
            request: "testRequest",
            args: nil
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(request)
        
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(JanusRequest.self, from: jsonData)
        
        XCTAssertNil(decodedRequest.args)
        XCTAssertEqual(decodedRequest.channelId, "testChannel")
        XCTAssertEqual(decodedRequest.request, "testRequest")
    }
    
    func testJanusResponseWithError() throws {
        let error = JSONRPCError.create(
            code: .internalError,
            details: "Internal server error"
        )
        
        let response = JanusResponse(
            requestId: "test-request",
            channelId: "testChannel",
            success: false,
            result: nil,
            error: error
        )
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(response)
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(JanusResponse.self, from: jsonData)
        
        XCTAssertFalse(decodedResponse.success)
        XCTAssertNotNil(decodedResponse.error)
        XCTAssertEqual(decodedResponse.error?.code, JSONRPCErrorCode.internalError.rawValue)
        XCTAssertEqual(decodedResponse.error?.message, JSONRPCErrorCode.internalError.message)
    }
    
    func testValidationWithEdgeCasePatterns() throws {
        // Test with complex regex pattern
        let validation = ValidationManifest(
            pattern: "^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|\"(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21\\x23-\\x5b\\x5d-\\x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])*\")@"
        )
        
        let argManifest = ArgumentManifest(
            type: .string,
            required: true,
            validation: validation
        )
        
        let requestManifest = RequestManifest(
            args: ["email": argManifest]
        )
        
        let channelManifest = ChannelManifest(
            requests: ["validateEmail": requestManifest]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelManifest]
        )
        
        // Should not throw during validation
        try ManifestParser.validate(manifest)
    }
    
    func testValidationWithMinMaxEdgeCases() throws {
        // Test with equal min/max values
        let validation = ValidationManifest(
            minLength: 5,
            maxLength: 5,
            minimum: 10.0,
            maximum: 10.0
        )
        
        let argManifest = ArgumentManifest(
            type: .string,
            required: true,
            validation: validation
        )
        
        let requestManifest = RequestManifest(
            args: ["exactValue": argManifest]
        )
        
        let channelManifest = ChannelManifest(
            requests: ["testExact": requestManifest]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelManifest]
        )
        
        // Should not throw when min equals max
        try ManifestParser.validate(manifest)
    }
    
    func testManifestWithEmptyRequestArgs() async throws {
        let requestManifest = RequestManifest(
            description: "Request with no args",
            args: [:], // Empty args
            response: ResponseManifest(type: .object)
        )
        
        let channelManifest = ChannelManifest(
            requests: ["noArgsRequest": requestManifest]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": channelManifest]
        )
        
        // Should validate successfully
        try ManifestParser.validate(manifest)
        
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Should be able to call request with no args
        do {
            _ = try await client.sendRequest("noArgsRequest")
            XCTFail("Request should have failed due to no server running")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue || error.code == JSONRPCErrorCode.socketError.rawValue {
            // Expected - no server running or socket connection failed
        } catch {
            XCTFail("Request with no args should validate correctly but fail on connection: \(error)")
        }
    }
    
    func testLargeArgumentValues() throws {
        let largeString = String(repeating: "a", count: 10000)
        let largeArgs: [String: AnyCodable] = [
            "largeData": AnyCodable(largeString),
            "largeNumber": AnyCodable(Double.greatestFiniteMagnitude),
            "largeArray": AnyCodable(Array(repeating: "item", count: 1000))
        ]
        
        let request = JanusRequest(
            channelId: "testChannel",
            request: "processLargeData",
            args: largeArgs
        )
        
        // Should be able to serialize large data
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(request)
        
        XCTAssertGreaterThan(jsonData.count, 10000)
        
        // Should be able to deserialize
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(JanusRequest.self, from: jsonData)
        
        XCTAssertEqual(decodedRequest.request, "processLargeData")
        XCTAssertNotNil(decodedRequest.args)
    }
    
    func testManifestialCharactersInChannelAndRequestNames() async throws {
        let requestManifest = RequestManifest(
            description: "Request with manifestial chars",
            args: [:],
            response: ResponseManifest(type: .object)
        )
        
        // Test various manifestial characters that should be valid in identifiers
        let validNames = [
            "request-with-dashes",
            "request_with_underscores",
            "request123withNumbers",
            "requestWithCamelCase"
        ]
        
        var requests: [String: RequestManifest] = [:]
        for name in validNames {
            requests[name] = requestManifest
        }
        
        let channelManifest = ChannelManifest(
            requests: requests
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["channel-with-dashes": channelManifest]
        )
        
        // Should validate successfully
        try ManifestParser.validate(manifest)
        
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Client should validate request names at send time, not registration time
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
            )
            XCTAssertNotNil(client)
        } catch {
            // May fail on some systems due to path length limits
            // This is acceptable behavior
        }
        
        // Test with path containing manifestial characters
        let manifestialPath = "/tmp/socket-with-manifestial-chars_123.sock"
        
        do {
            let client = try await JanusClient(
                socketPath: manifestialPath,
            )
            XCTAssertNotNil(client)
        } catch {
            XCTFail("Client creation should succeed with manifestial characters in path: \(error)")
        }
    }
    
    private func createSimpleManifest() -> Manifest {
        let requestManifest = RequestManifest(
            description: "Simple test request",
            args: [:],
            response: ResponseManifest(type: .object)
        )
        
        return Manifest(
            version: "1.0.0",
            models: ["testModel": ModelManifest(
                type: .object,
                properties: [
                    "id": ArgumentManifest(type: .string, required: true),
                    "data": ArgumentManifest(type: .string)
                ]
            )]
        )
    }
}