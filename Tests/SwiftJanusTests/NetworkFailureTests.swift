// NetworkFailureTests.swift
// Network failure scenario tests

import XCTest
@testable import SwiftJanus

@MainActor
final class NetworkFailureTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/janus-network-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test API specification
        let argSpec = ArgumentSpec(
            type: .string,
            required: false,
            validation: ValidationSpec(maxLength: 1000)
        )
        
        let commandSpec = CommandSpec(
            description: "Test command",
            args: ["data": argSpec],
            response: ResponseSpec(type: .object)
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel",
            commands: ["testCommand": commandSpec]
        )
        
        testAPISpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": channelSpec]
        )
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    // MARK: - Connection Failure Tests
    
    func testConnectionToNonExistentSocket() async throws {
        let client = try JanusDatagramClient(
            socketPath: "/tmp/definitely-does-not-exist-12345.sock",
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        do {
            _ = try await client.sendCommand("testCommand", args: ["data": AnyCodable("test")])
            XCTFail("Connection to non-existent socket should fail")
        } catch JanusError.connectionError {
            // Expected
        } catch JanusError.connectionRequired {
            // Also acceptable
        } catch JanusError.connectionTestFailed {
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
                let client = try JanusDatagramClient(
                    socketPath: invalidPath,
                    channelId: "testChannel",
                    apiSpec: testAPISpec
                )
                
                do {
                    _ = try await client.sendCommand("testCommand")
                    XCTFail("Connection to invalid path should fail: \(invalidPath)")
                } catch JanusError.connectionError, JanusError.connectionRequired {
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
        // Connection timeout is handled internally by the datagram client
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let startTime = Date()
        
        do {
            _ = try await client.sendCommand("testCommand")
            XCTFail("Connection should timeout")
        } catch JanusError.connectionError(let message) {
            // Should timeout quickly or fail immediately in SOCK_DGRAM
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsedTime, 1.0, "Connection should timeout quickly or fail immediately")
            XCTAssertTrue(message.contains("timeout") || message.contains("Network is down") || message.contains("No such file or directory"), 
                         "Error should indicate timeout, network failure, or socket not found")
        } catch JanusError.connectionTestFailed {
            // Expected in SOCK_DGRAM architecture - connection test fails immediately
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testRepeatedConnectionFailures() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test that repeated failures don't cause issues
        for i in 0..<10 {
            do {
                _ = try await client.sendCommand("testCommand", args: ["iteration": AnyCodable(i)])
                XCTFail("Connection should fail on iteration \(i)")
            } catch JanusError.connectionError, JanusError.connectionRequired {
                // Expected - each attempt should fail cleanly
            } catch JanusError.connectionTestFailed {
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
                let client = try JanusDatagramClient(
                    socketPath: restrictedPath,
                    channelId: "testChannel",
                    apiSpec: testAPISpec
                )
                
                do {
                    _ = try await client.sendCommand("testCommand")
                    // Might succeed if we actually have permission, that's okay
                } catch JanusError.connectionError {
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
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Try to create many connections simultaneously
        // This may hit system limits and cause failures
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand("testCommand", args: ["id": AnyCodable(i)])
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
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Create memory pressure during network operations
        let largeData = String(repeating: "data", count: 100000) // ~400KB per operation
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    // Create temporary memory pressure
                    let temporaryData = Array(repeating: largeData, count: 10) // ~4MB per task
                    
                    do {
                        _ = try await client.sendCommand(
                            "testCommand", 
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
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let startTime = Date()
        
        do {
            _ = try await client.sendCommand("testCommand")
            XCTFail("Should timeout in slow network conditions")
        } catch JanusError.connectionError {
            let elapsedTime = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsedTime, 0.5, "Should timeout quickly in slow conditions")
        } catch JanusError.connectionTestFailed {
            // Expected in SOCK_DGRAM architecture
        } catch {
            XCTFail("Unexpected error in slow network test: \(error)")
        }
    }
    
    func testNetworkInterruption() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Simulate network interruption by attempting multiple operations
        // that will fail at different stages
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
                            "testCommand",
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
    
    func testSocketAlreadyInUse() throws {
        // This test verifies behavior when trying to use the same socket path
        // from multiple clients (though our library is client-side only)
        
        let client1 = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let client2 = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Both clients should be created successfully
        // (they're both client-side and will try to connect when needed)
        XCTAssertNotNil(client1)
        XCTAssertNotNil(client2)
    }
    
    func testSocketPathChanges() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test behavior when socket path becomes invalid after client creation
        // (simulate filesystem changes)
        
        // First operation
        do {
            _ = try await client.sendCommand("testCommand")
        } catch {
            // Expected to fail - no server
        }
        
        // Change file system (simulate socket being removed/changed)
        try FileManager.default.createDirectory(atPath: testSocketPath, 
                                              withIntermediateDirectories: false, 
                                              attributes: nil)
        
        // Second operation (socket path now points to directory)
        do {
            _ = try await client.sendCommand("testCommand")
        } catch {
            // Should fail gracefully with appropriate error
        }
        
        // Cleanup
        try? FileManager.default.removeItem(atPath: testSocketPath)
    }
    
    // MARK: - Error Recovery Tests
    
    func testErrorRecoverySequence() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test sequence: failure -> retry -> failure -> retry
        let operations = [
            "operation1", "operation2", "operation3", "operation4", "operation5"
        ]
        
        for operation in operations {
            do {
                _ = try await client.sendCommand("testCommand", args: ["op": AnyCodable(operation)])
            } catch {
                // Each failure should be independent
                // The client should remain in a valid state for the next operation
            }
        }
        
        // After all failures, client should still be usable
        do {
            _ = try await client.sendCommand("testCommand", args: ["final": AnyCodable("test")])
        } catch {
            // Expected to fail, but should not crash
        }
    }
    
    func testConcurrentFailureHandling() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent operations that all fail
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
                            "testCommand",
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
            _ = try await client.sendCommand("testCommand", args: ["post": AnyCodable("concurrent")])
        } catch {
            // Expected to fail, but should not be in a broken state
        }
    }
    
    // MARK: - Edge Case Network Scenarios
    
    func testVeryLongSocketPath() throws {
        // Test socket path at system limits (Unix sockets typically have ~108 char limit)
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        
        do {
            let client = try JanusDatagramClient(
                socketPath: longPath,
                channelId: "testChannel",
                apiSpec: testAPISpec
            )
            
            // If client creation succeeds, try to use it
            Task {
                do {
                    _ = try await client.sendCommand("testCommand")
                } catch {
                    // Expected to fail due to path length or no server
                }
            }
        } catch {
            // Client creation might fail due to path validation, which is fine
            XCTAssertTrue(error is JanusError, "Should be a validation error")
        }
    }
    
    func testSocketPathWithSpecialCharacters() async throws {
        let specialPaths = [
            "/tmp/socket with spaces.sock",
            "/tmp/socket-with-dashes.sock",
            "/tmp/socket_with_underscores.sock",
            "/tmp/socket.with.dots.sock",
            "/tmp/socket123numbers.sock"
        ]
        
        for specialPath in specialPaths {
            do {
                let client = try JanusDatagramClient(
                    socketPath: specialPath,
                    channelId: "testChannel",
                    apiSpec: testAPISpec
                )
                
                do {
                    _ = try await client.sendCommand("testCommand")
                } catch {
                    // Expected to fail due to no server, but path handling should work
                }
            } catch {
                // Some special characters might be rejected by validation
                // This is acceptable behavior
            }
        }
    }
    
    func testRapidConnectionCycling() async throws {
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test rapid connect/disconnect cycles
        for cycle in 0..<20 {
            let startTime = Date()
            
            do {
                _ = try await client.sendCommand("testCommand", args: ["cycle": AnyCodable(cycle)])
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
        let manyClients = (0..<100).map { i in
            try? JanusDatagramClient(
                socketPath: "\(testSocketPath!)-\(i)",
                channelId: "testChannel",
                apiSpec: testAPISpec
            )
        }.compactMap { $0 }
        
        // Try to use all clients simultaneously
        await withTaskGroup(of: Void.self) { group in
            for (index, client) in manyClients.enumerated() {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
                            "testCommand",
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
        let client = try JanusDatagramClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
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
                _ = try await client.sendCommand(
                    "testCommand",
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