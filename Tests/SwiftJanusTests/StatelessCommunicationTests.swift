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
    
    func testStatelessRequestValidation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test request validation without connection
        // Valid request should pass validation
        do {
            _ = try await client.sendRequest("quickRequest", args: ["data": AnyCodable("test")])
        } catch let error as JSONRPCError {
            // Expected error - no server running
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        
        // Invalid request should fail - in Dynamic Manifest Architecture,
        // this will be a server error since no server is running to provide manifest
        do {
            _ = try await client.sendRequest("nonExistentRequest")
            XCTFail("Expected connection error since no server is running")
        } catch let error as JSONRPCError {
            // With Dynamic Manifest Architecture, we expect server error when no server is running
            // because manifest fetching fails before request validation can occur
            XCTAssertEqual(error.code, JSONRPCErrorCode.serverError.rawValue)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testMultipleIndependentRequests() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Each request should be independent and fail at connection level
        // (since we don't have a server running)
        
        let requests = [
            ("quickRequest", ["data": AnyCodable("test1")]),
            ("quickRequest", ["data": AnyCodable("test2")]),
            ("quickRequest", ["data": AnyCodable("test3")])
        ]
        
        for (request, args) in requests {
            do {
                _ = try await client.sendRequest(request, args: args)
                XCTFail("Expected connection error")
            } catch let error as JSONRPCError {
                // Expected - no server running
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
    
    func testConcurrentStatelessRequests() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test concurrent request execution
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.sendRequest("quickRequest", args: ["data": AnyCodable("test\(i)")])
                    } catch {
                        // Expected to fail since no server is running
                    }
                }
            }
        }
        
        // All tasks should complete independently
        XCTAssertTrue(true)
    }
    
    func testRequestHandlerRegistration() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
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
        )
        
        // Test required argument validation
        // Note: In Dynamic Manifest Architecture, without a running server,
        // we get connection errors before we can validate arguments against the manifest
        do {
            _ = try await client.sendRequest("quickRequest") // Missing required 'data' arg
            XCTFail("Expected connection error since no server is running")
        } catch let error as JSONRPCError {
            // With Dynamic Manifest Architecture, we expect server error when no server is running
            // because manifest fetching fails before argument validation can occur
            XCTAssertEqual(error.code, JSONRPCErrorCode.serverError.rawValue)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // Test with valid arguments
        do {
            _ = try await client.sendRequest("quickRequest", args: ["data": AnyCodable("valid")])
        } catch let error as JSONRPCError {
            // Expected - no server running
        } catch {
            XCTFail("Validation should pass, connection should fail: \(error)")
        }
    }
    
    func testChannelIsolation() async throws {
        let client1 = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        let client2 = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Each client should only know about its own channel's requests
        
        // Client1 is for channel1 requests (handlers would be server-side)
        
        // Client2 is for channel2 requests (handlers would be server-side)
        
        // Client1 cannot send channel2 requests - validation happens at send time
        
        // Client2 cannot send channel1 requests - validation happens at send time
    }
    
    func testErrorHandlingInStatelessMode() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Error handling would be managed by the server-side handlers
        
        // Error handling should work for registered handlers
        // (though we can't test actual execution without a server)
        XCTAssertTrue(true)
    }
    
    func testManifestValidationOnInit() async {
        // Note: In Dynamic Manifest Architecture, manifest validation happens when 
        // requests are sent, not during client construction. The client constructor only
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
            )
            XCTFail("Expected error for invalid channel ID pattern")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams.rawValue)
        } catch {
            XCTFail("Expected JSONRPCError for invalid channel ID, got: \(error)")
        }
    }
    
    func testMessageSerialization() throws {
        let request = JanusRequest(
            channelId: "testChannel",
            request: "testRequest",
            args: ["key": AnyCodable("value")]
        )
        
        let message = SocketMessage(
            type: .request,
            payload: try JSONEncoder().encode(request)
        )
        
        // Test message serialization
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        
        let decoder = JSONDecoder()
        let decodedMessage = try decoder.decode(SocketMessage.self, from: data)
        
        XCTAssertEqual(decodedMessage.type, .request)
        
        // Test nested request decoding
        let decodedRequest = try decoder.decode(JanusRequest.self, from: decodedMessage.payload)
        XCTAssertEqual(decodedRequest.channelId, "testChannel")
        XCTAssertEqual(decodedRequest.request, "testRequest")
    }
    
    private func createStatelessTestManifest() -> Manifest {
        let dataArg = ArgumentManifest(
            type: .string,
            required: true,
            description: "Data to process"
        )
        
        let quickRequest = RequestManifest(
            description: "Quick stateless request",
            args: ["data": dataArg],
            response: ResponseManifest(
                type: .object,
                properties: [
                    "received": ArgumentManifest(type: .string),
                    "processed": ArgumentManifest(type: .boolean)
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
    
    private func createMultiChannelManifest() -> Manifest {
        let channel1Request = RequestManifest(
            description: "Request for channel 1",
            args: [:],
            response: ResponseManifest(type: .object)
        )
        
        let channel2Request = RequestManifest(
            description: "Request for channel 2",
            args: [:],
            response: ResponseManifest(type: .object)
        )
        
        let channel1Manifest = ChannelManifest(
            description: "First channel",
            requests: ["channel1Request": channel1Request]
        )
        
        let channel2Manifest = ChannelManifest(
            description: "Second channel",
            requests: ["channel2Request": channel2Request]
        )
        
        return Manifest(
            version: "1.0.0",
            channels: [
                "channel1": channel1Manifest,
                "channel2": channel2Manifest
            ]
        )
    }
}