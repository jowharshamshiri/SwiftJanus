// NetworkFailureTests.swift
// Network failure scenario tests

import XCTest
import Foundation
@testable import SwiftJanus

@MainActor
final class NetworkFailureTests: XCTestCase {
    
    var testSocketPath: String!
    var testManifest: Manifest!
    var tempDir: URL!
    
    override func setUpWithError() throws {
        // Use shorter path to avoid Unix socket 108-character limit
        tempDir = URL(fileURLWithPath: "/tmp/janus-net-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        testSocketPath = tempDir.appendingPathComponent("janus-network-test.sock").path
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test Manifest
        let argManifest = ArgumentManifest(
            type: .string,
            required: false,
            validation: ValidationManifest(maxLength: 1000)
        )
        
        let requestManifest = RequestManifest(
            description: "Test request",
            args: ["data": argManifest],
            response: ResponseManifest(type: .object)
        )
        
        testManifest = Manifest(
            version: "1.0.0",
            models: ["testModel": ModelManifest(
                type: .object,
                properties: ["id": ArgumentManifest(type: .string, required: true)],
                description: "Test model"
            )]
        )
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    // MARK: - Connection Failure Tests
    
    func testConnectionToNonExistentSocket() async throws {
        let client = try await JanusClient(
            socketPath: "/tmp/definitely-does-not-exist-12345.sock",
        )
        
        do {
            _ = try await client.sendRequest("testRequest", args: ["data": AnyCodable("test")])
            XCTFail("Connection to non-existent socket should fail")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            // Expected
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            // Also acceptable
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            // Expected in SOCK_DGRAM architecture
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testConnectionToInvalidPath() async throws {
        let invalidPaths = [
            "/dev/null",              // Not a socket
            "/etc/passwd",            // Regular file (if exists)
            "/nonexistent/path/socket.sock",  // Invalid directory
            ""                        // Empty path
        ]
        
        for invalidPath in invalidPaths {
            do {
                let client = try await JanusClient(
                    socketPath: invalidPath,
                )
                
                do {
                    _ = try await client.sendRequest("testRequest")
                    XCTFail("Connection to invalid path should fail: \(invalidPath)")
                } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
                    // Expected
                } catch {
                    // Other socket errors are also acceptable
                }
            } catch {
                // Client creation might fail for some invalid paths, which is also fine
            }
        }
    }
    
    func testConnectionTimeout() async throws {
        // Test connection timeout behavior with non-existent socket
        // In SOCK_DGRAM architecture, timeout is handled by internal timeout manager
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        let startTime = Date()
        
        do {
            // Send request with very short timeout to test timeout mechanism
            _ = try await client.sendRequest("ping", timeout: 0.1)
            XCTFail("Request should timeout due to no server")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.handlerTimeout.rawValue {
            // This is the expected timeout behavior
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertGreaterThan(elapsedTime, 0.05, "Should have waited some time before timeout")
            XCTAssertLessThan(elapsedTime, 0.5, "Should timeout quickly")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            // In SOCK_DGRAM, immediate connection failure is also acceptable
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsedTime, 0.5, "Should fail quickly if no server exists")
        } catch {
            XCTFail("Expected timeout or server error, got: \(error)")
        }
    }
    
    func testRepeatedConnectionFailures() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test that repeated failures don't cause issues
        for i in 0..<10 {
            do {
                _ = try await client.sendRequest("testRequest", args: ["iteration": AnyCodable(i)])
                XCTFail("Connection should fail on iteration \(i)")
            } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
                // Expected - each attempt should fail cleanly
            } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
                // Expected in SOCK_DGRAM architecture
            } catch {
                XCTFail("Unexpected error on iteration \(i): \(error)")
            }
        }
    }
    
    // MARK: - Socket Permission Tests
    
    func testSocketPermissionDenied() async throws {
        // Try to connect to a socket path where we don't have permission
        let restrictedPaths = [
            "/root/restricted.sock",      // Root directory (likely no permission)
            "/usr/restricted.sock",       // System directory (likely no permission) 
            "/var/run/restricted.sock"    // May be restricted depending on system
        ]
        
        for restrictedPath in restrictedPaths {
            do {
                let client = try await JanusClient(
                    socketPath: restrictedPath,
                )
                
                do {
                    _ = try await client.sendRequest("testRequest")
                    // Might succeed if we actually have permission, that's okay
                } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
                    // Expected - permission denied or path doesn't exist
                } catch {
                    // Other errors are also acceptable for permission issues
                }
            } catch {
                // Client creation might fail due to path validation, which is fine
            }
        }
    }
    
    // MARK: - Resource Exhaustion Simulation
    
    func testFileDescriptorExhaustion() async throws {
        // Test behavior when system runs out of file descriptors
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Try to create many connections simultaneously
        // This may hit system limits and cause failures
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    do {
                        _ = try await client.sendRequest("testRequest", args: ["id": AnyCodable(i)])
                    } catch {
                        // Expected to fail due to resource limits or no server
                        // The important thing is that it fails gracefully
                    }
                }
            }
        }
        
        // Should complete without hanging or crashing
    }
    
    func testMemoryPressureHandling() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Create memory pressure during network operations
        let largeData = String(repeating: "data", count: 100000) // ~400KB per operation
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    // Create temporary memory pressure
                    let temporaryData = Array(repeating: largeData, count: 10) // ~4MB per task
                    
                    do {
                        _ = try await client.sendRequest(
                            "testRequest", 
                            args: ["data": AnyCodable("test\(i)"), "large": AnyCodable(temporaryData.joined())]
                        )
                    } catch {
                        // Expected to fail, but should handle memory pressure gracefully
                    }
                }
            }
        }
    }
    
    // MARK: - Network Condition Simulation
    
    func testSlowNetworkConditions() async throws {
        // Simulate slow network by using very short timeouts
        // SOCK_DGRAM timeout handling is built into the client
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        let startTime = Date()
        
        do {
            _ = try await client.sendRequest("testRequest")
            XCTFail("Should timeout in slow network conditions")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsedTime, 0.5, "Should timeout quickly in slow conditions")
        } catch let error as JSONRPCError where error.code == JSONRPCErrorCode.serverError.rawValue {
            // Expected in SOCK_DGRAM architecture
        } catch {
            XCTFail("Unexpected error in slow network test: \(error)")
        }
    }
    
    func testNetworkInterruption() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Simulate network interruption by attempting multiple operations
        // that will fail at different stages
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.sendRequest(
                            "testRequest",
                            args: ["data": AnyCodable("interruption-test-\(i)")]
                        )
                    } catch {
                        // Each failure simulates a network interruption
                        // Should handle gracefully without affecting other operations
                    }
                }
            }
        }
    }
    
    // MARK: - Socket State Tests
    
    func testSocketAlreadyInUse() async throws {
        // This test verifies behavior when trying to use the same socket path
        // from multiple clients (though our library is client-side only)
        
        let client1 = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        let client2 = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Both clients should be created successfully
        // (they're both client-side and will try to connect when needed)
        XCTAssertNotNil(client1)
        XCTAssertNotNil(client2)
    }
    
    func testSocketPathChanges() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test behavior when socket path becomes invalid after client creation
        // (simulate filesystem changes)
        
        // First operation
        do {
            _ = try await client.sendRequest("testRequest")
        } catch {
            // Expected to fail - no server
        }
        
        // Change file system (simulate socket being removed/changed)
        try FileManager.default.createDirectory(atPath: testSocketPath, 
                                              withIntermediateDirectories: false, 
                                              attributes: nil)
        
        // Second operation (socket path now points to directory)
        do {
            _ = try await client.sendRequest("testRequest")
        } catch {
            // Should fail gracefully with appropriate error
        }
        
        // Cleanup
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    // MARK: - Error Recovery Tests
    
    func testErrorRecoverySequence() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test sequence: failure -> retry -> failure -> retry
        let operations = [
            "operation1", "operation2", "operation3", "operation4", "operation5"
        ]
        
        for operation in operations {
            do {
                _ = try await client.sendRequest("testRequest", args: ["op": AnyCodable(operation)])
            } catch {
                // Each failure should be independent
                // The client should remain in a valid state for the next operation
            }
        }
        
        // After all failures, client should still be usable
        do {
            _ = try await client.sendRequest("testRequest", args: ["final": AnyCodable("test")])
        } catch {
            // Expected to fail, but should not crash
        }
    }
    
    func testConcurrentFailureHandling() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test concurrent operations that all fail
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        _ = try await client.sendRequest(
                            "testRequest",
                            args: ["concurrentFailure": AnyCodable(i)]
                        )
                    } catch {
                        // All should fail, but handle concurrently without issues
                    }
                }
            }
        }
        
        // After concurrent failures, client should still be functional
        do {
            _ = try await client.sendRequest("testRequest", args: ["post": AnyCodable("concurrent")])
        } catch {
            // Expected to fail, but should not be in a broken state
        }
    }
    
    // MARK: - Edge Case Network Scenarios
    
    func testVeryLongSocketPath() async throws {
        // Test socket path at system limits (Unix sockets typically have ~108 char limit)
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        
        do {
            let client = try await JanusClient(
                socketPath: longPath,
            )
            
            // If client creation succeeds, try to use it
            Task {
                do {
                    _ = try await client.sendRequest("testRequest")
                } catch {
                    // Expected to fail due to path length or no server
                }
            }
        } catch {
            // Client creation might fail due to path validation, which is fine
            XCTAssertTrue(error is JSONRPCError, "Should be a validation error")
        }
    }
    
    func testSocketPathWithManifestialCharacters() async throws {
        let manifestialPaths = [
            "/tmp/socket with spaces.sock",
            "/tmp/socket-with-dashes.sock",
            "/tmp/socket_with_underscores.sock",
            "/tmp/socket.with.dots.sock",
            "/tmp/socket123numbers.sock"
        ]
        
        for manifestialPath in manifestialPaths {
            do {
                let client = try await JanusClient(
                    socketPath: manifestialPath,
                )
                
                do {
                    _ = try await client.sendRequest("testRequest")
                } catch {
                    // Expected to fail due to no server, but path handling should work
                }
            } catch {
                // Some manifestial characters might be rejected by validation
                // This is acceptable behavior
            }
        }
    }
    
    func testRapidConnectionCycling() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test rapid connect/disconnect cycles
        for cycle in 0..<20 {
            let startTime = Date()
            
            do {
                _ = try await client.sendRequest("testRequest", args: ["cycle": AnyCodable(cycle)])
            } catch {
                // Expected to fail quickly
            }
            
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsedTime, 2.0, "Each cycle should complete quickly")
        }
    }
    
    // MARK: - System Resource Tests
    
    func testSystemLimitHandling() async throws {
        // Test behavior when approaching system limits
        var manyClients: [JanusClient] = []
        
        for i in 0..<100 {
            do {
                let client = try await JanusClient(
                    socketPath: "\(testSocketPath!)-\(i)"
                )
                manyClients.append(client)
            } catch {
                // Expected to fail at some point due to system limits
                break
            }
        }
        
        // Try to use all clients simultaneously
        await withTaskGroup(of: Void.self) { group in
            for (index, client) in manyClients.enumerated() {
                group.addTask {
                    do {
                        _ = try await client.sendRequest(
                            "testRequest",
                            args: ["clientIndex": AnyCodable(index)]
                        )
                    } catch {
                        // Expected to fail, but should not crash system
                    }
                }
            }
        }
        
        XCTAssertGreaterThan(manyClients.count, 50, "Should be able to create many clients")
    }
    
    func testGracefulDegradation() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
        )
        
        // Test that failures don't cause permanent damage
        let testSequence = [
            "initial test",
            "after first failure",
            "after second failure", 
            "recovery test",
            "final test"
        ]
        
        for (index, testName) in testSequence.enumerated() {
            do {
                _ = try await client.sendRequest(
                    "testRequest",
                    args: ["test": AnyCodable(testName), "index": AnyCodable(index)]
                )
            } catch {
                // Each failure should be handled gracefully
                // Client should remain in valid state for next operation
            }
            
            // Brief pause between operations
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}