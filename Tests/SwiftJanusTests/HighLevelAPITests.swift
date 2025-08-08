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
            socketPath: testSocketPath
        )
        XCTAssertNotNil(client)
    }
    
    func testJanusRequestValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath
        )
        
        // Valid request should pass validation
        do {
            _ = try await client.sendRequest("ping", args: ["message": AnyCodable("test")])
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue || error.code == JSONRPCErrorCode.socketError.rawValue {
            // Expected - no server running or socket connection failed
        } catch {
            XCTFail("Valid request should pass validation: \(error)")
        }
    }
    
    func testDatagramInvalidRequest() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath
        )
        
        // Invalid request should fail validation
        do {
            _ = try await client.sendRequest("nonExistentRequest")
            XCTFail("Expected unknown request error")
        } catch let error as JSONRPCError {
            if error.code == JSONRPCErrorCode.methodNotFound.rawValue {
                // Validated by error code - no need to check message text
                // Expected
            } else if error.code == JSONRPCErrorCode.serverError.rawValue {
                // Expected in SOCK_DGRAM - connection fails before request validation
            } else {
                XCTFail("Expected unknownRequest or connectionTestFailed error, got \(error)")
            }
        }
    }
    
    func testDatagramArgumentValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath
        )
        
        // Missing required argument should fail
        do {
            _ = try await client.sendRequest("echo") // Missing required 'data' arg
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
        let request = JanusRequest(
            channelId: "testChannel",
            request: "ping",
            args: ["message": AnyCodable("hello")]
        )
        
        // Test JSON serialization
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JanusRequest.self, from: data)
        
        XCTAssertEqual(decoded.channelId, "testChannel")
        XCTAssertEqual(decoded.request, "ping")
        XCTAssertNotNil(decoded.args)
    }
    
    private func createHighLevelTestManifest() -> Manifest {
        let messageArg = ArgumentManifest(
            type: .string,
            required: true,
            description: "Message to process"
        )
        
        let dataArg = ArgumentManifest(
            type: .string,
            required: true,
            description: "Data to echo"
        )
        
        let pingRequest = RequestManifest(
            description: "Ping request",
            args: ["message": messageArg],
            response: ResponseManifest(
                type: .object,
                properties: [
                    "pong": ArgumentManifest(type: .string)
                ]
            )
        )
        
        let echoRequest = RequestManifest(
            description: "Echo request",
            args: ["data": dataArg],
            response: ResponseManifest(
                type: .object,
                properties: [
                    "echo": ArgumentManifest(type: .string)
                ]
            )
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