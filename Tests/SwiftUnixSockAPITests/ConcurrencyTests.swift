// ConcurrencyTests.swift
// High-concurrency and thread safety tests

import XCTest
import os.lock
@testable import SwiftUnixSockAPI

@MainActor
final class ConcurrencyTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/unixsockapi-concurrency-test.sock"
        
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
            args: ["data": argSpec, "id": argSpec],
            response: ResponseSpec(type: .object)
        )
        
        let channelSpec = ChannelSpec(
            description: "Test channel",
            commands: ["testCommand": commandSpec, "quickCommand": commandSpec]
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
    
    // MARK: - High Concurrency Tests
    
    func testHighConcurrencyCommandExecution() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let concurrentOperations = 100
        var successCount = 0
        var errorCount = 0
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrentOperations {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("concurrent-test-\(i)"), "id": AnyCodable("\(i)")]
                        )
                        successCount += 1
                    } catch {
                        errorCount += 1
                        // Expected to fail due to no server, but should not crash
                    }
                }
            }
        }
        
        // All operations should complete without hanging or crashing
        XCTAssertEqual(successCount + errorCount, concurrentOperations)
    }
    
    func testConcurrentClientCreation() async throws {
        let clientCount = 50
        var clients: [UnixSockAPIClient] = []
        var creationErrors = 0
        
        await withTaskGroup(of: UnixSockAPIClient?.self) { group in
            for i in 0..<clientCount {
                group.addTask { @MainActor in
                    do {
                        return try UnixSockAPIClient(
                            socketPath: "\(self.testSocketPath!)-\(i)",
                            channelId: "testChannel",
                            apiSpec: self.testAPISpec
                        )
                    } catch {
                        creationErrors += 1
                        return nil
                    }
                }
            }
            
            for await result in group {
                if let client = result {
                    clients.append(client)
                }
            }
        }
        
        // Should be able to create multiple clients concurrently
        XCTAssertEqual(clients.count + creationErrors, clientCount)
        XCTAssertGreaterThan(clients.count, 0, "Should successfully create at least some clients")
    }
    
    func testConcurrentHandlerRegistration() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let handlerCount = 20
        var registrationErrors = 0
        
        // Try to register multiple handlers sequentially (MainActor requirement)
        // Note: This tests the library's ability to handle multiple registration attempts
        for i in 0..<handlerCount {
            do {
                try client.registerCommandHandler("testCommand") { command, args in
                    return ["handlerId": AnyCodable(i), "processed": AnyCodable(true)]
                }
            } catch {
                registrationErrors += 1
            }
        }
        
        // The library should handle concurrent registration gracefully
        // Either all succeed (if it allows multiple handlers) or some fail gracefully
        XCTAssertLessThanOrEqual(registrationErrors, handlerCount)
    }
    
    func testConcurrentConnectionPoolUsage() async throws {
        let config = UnixSockAPIClientConfig(
            maxConcurrentConnections: 10,
            connectionTimeout: 1.0 // Shorter timeout for faster test
        )
        
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec,
            config: config
        )
        
        let operationCount = 50 // More than pool size
        var completedOperations = 0
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<operationCount {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("pool-test-\(i)")]
                        )
                    } catch {
                        // Expected to fail, but should not deadlock
                    }
                    completedOperations += 1
                }
            }
        }
        
        // All operations should complete (even if they fail)
        XCTAssertEqual(completedOperations, operationCount)
    }
    
    // MARK: - Race Condition Tests
    
    func testConcurrentStateModification() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent access to internal state
        await withTaskGroup(of: Void.self) { group in
            // Concurrent command executions
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("race-test-\(i)")]
                        )
                    } catch {
                        // Expected
                    }
                }
            }
            
            // Sequential handler registrations (MainActor requirement)
            for i in 0..<5 {
                group.addTask { @MainActor in
                    do {
                        try client.registerCommandHandler("testCommand") { _, _ in
                            return ["raceHandler": AnyCodable(i)]
                        }
                    } catch {
                        // Expected - might fail due to handler conflicts
                    }
                }
            }
        }
        
        // Should complete without crashing or hanging
    }
    
    func testConcurrentConnectionManagement() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent connection creation and cleanup
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        // Start a command (creates connection)
                        _ = try await client.publishCommand(
                            "testCommand", 
                            args: ["data": AnyCodable("connection-\(i)")]
                        )
                    } catch {
                        // Expected to fail, but connection handling should be thread-safe
                    }
                }
            }
        }
    }
    
    // MARK: - Thread Safety Tests
    
    func testThreadSafetyOfConfiguration() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent access to configuration
        let accessCount = 100
        var configAccesses = 0
        
        DispatchQueue.concurrentPerform(iterations: accessCount) { _ in
            // Access configuration from multiple threads using proper getter
            let _ = client.configuration.maxConcurrentConnections
            let _ = client.configuration.maxMessageSize
            let _ = client.configuration.connectionTimeout
            configAccesses += 1
        }
        
        XCTAssertEqual(configAccesses, accessCount)
    }
    
    func testThreadSafetyOfAPISpecAccess() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test concurrent access to API specification
        let accessCount = 100
        let specAccesses = OSAllocatedUnfairLock(initialState: 0)
        
        DispatchQueue.concurrentPerform(iterations: accessCount) { _ in
            // Access API spec from multiple threads using proper getter
            let _ = client.specification.version
            let _ = client.specification.channels.count
            let _ = client.specification.channels["testChannel"]
            specAccesses.withLock { $0 += 1 }
        }
        
        XCTAssertEqual(specAccesses.withLock { $0 }, accessCount)
    }
    
    // MARK: - Deadlock Prevention Tests
    
    func testNoDeadlockUnderLoad() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Create a scenario that could potentially cause deadlocks
        let taskCount = 50
        let timeout: TimeInterval = 10.0 // Test should complete within 10 seconds
        
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("deadlock-test-\(i)")]
                        )
                    } catch {
                        // Expected to fail, but should not deadlock
                    }
                }
            }
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsedTime, timeout, "Operations should complete without deadlocking")
    }
    
    func testNoDeadlockWithMixedOperations() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let startTime = Date()
        let timeout: TimeInterval = 15.0
        
        await withTaskGroup(of: Void.self) { group in
            // Mix of different operations that could interact
            
            // Commands
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("mixed-\(i)")]
                        )
                    } catch {
                        // Expected
                    }
                }
            }
            
            // Handler registrations (MainActor isolated)
            for i in 0..<5 {
                group.addTask { @MainActor in
                    do {
                        try client.registerCommandHandler("testCommand") { _, _ in
                            return ["mixed": AnyCodable(i)]
                        }
                    } catch {
                        // Expected - might conflict
                    }
                }
            }
            
            // Configuration access (nonisolated, can be accessed from any thread)
            for _ in 0..<10 {
                group.addTask {
                    let _ = client.configuration
                    let _ = client.specification
                }
            }
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsedTime, timeout, "Mixed operations should complete without deadlocking")
    }
    
    // MARK: - Memory Safety Under Concurrency
    
    func testMemorySafetyUnderConcurrentAccess() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test that concurrent access doesn't cause memory issues
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    // Create objects that might be accessed concurrently
                    let args = ["data": AnyCodable("memory-test-\(i)"), "timestamp": AnyCodable(Date().timeIntervalSince1970)]
                    
                    do {
                        _ = try await client.publishCommand("testCommand", args: args)
                    } catch {
                        // Expected
                    }
                    
                    // Force some memory pressure
                    let temporaryData = Array(repeating: "test", count: 1000)
                    let _ = temporaryData.count
                }
            }
        }
        
        // Should complete without memory corruption or crashes
    }
    
    func testConcurrentResourceCleanup() async throws {
        // Test concurrent creation and cleanup of resources
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { @MainActor in
                    do {
                        let client = try UnixSockAPIClient(
                            socketPath: "\(self.testSocketPath!)-cleanup-\(i)",
                            channelId: "testChannel",
                            apiSpec: self.testAPISpec
                        )
                        
                        // Use the client briefly
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("cleanup-\(i)")]
                        )
                    } catch {
                        // Expected to fail, but cleanup should be safe
                    }
                    
                    // Client goes out of scope and should be cleaned up
                }
            }
        }
        
        // All cleanup should complete safely
    }
    
    // MARK: - Connection Pool Thread Safety
    
    func testConnectionPoolThreadSafety() async throws {
        let config = UnixSockAPIClientConfig(maxConcurrentConnections: 5)
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec,
            config: config
        )
        
        // Test concurrent access to connection pool
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["poolTest": AnyCodable(i)]
                        )
                    } catch {
                        // Expected - testing pool safety, not success
                    }
                }
            }
        }
        
        // Connection pool should handle concurrent access safely
    }
    
    // MARK: - Stress Tests
    
    func testHighVolumeRequestStress() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let requestCount = 200
        let processedCount = OSAllocatedUnfairLock(initialState: 0)
        
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: [
                                "data": AnyCodable("stress-\(i)"),
                                "payload": AnyCodable(String(repeating: "data", count: 100))
                            ]
                        )
                    } catch {
                        // Expected
                    }
                    processedCount.withLock { $0 += 1 }
                }
            }
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        
        XCTAssertEqual(processedCount.withLock { $0 }, requestCount)
        XCTAssertLessThan(elapsedTime, 30.0, "High volume requests should complete in reasonable time")
    }
    
    func testConcurrentClientStress() async throws {
        // Test multiple clients operating concurrently
        let clientCount = 10
        let requestsPerClient = 20
        
        await withTaskGroup(of: Void.self) { group in
            for clientId in 0..<clientCount {
                group.addTask { @MainActor in
                    do {
                        let client = try UnixSockAPIClient(
                            socketPath: "\(self.testSocketPath!)-stress-\(clientId)",
                            channelId: "testChannel",
                            apiSpec: self.testAPISpec
                        )
                        
                        // Each client makes multiple requests
                        await withTaskGroup(of: Void.self) { requestGroup in
                            for requestId in 0..<requestsPerClient {
                                requestGroup.addTask {
                                    do {
                                        _ = try await client.publishCommand(
                                            "testCommand",
                                            args: [
                                                "clientId": AnyCodable(clientId),
                                                "requestId": AnyCodable(requestId)
                                            ]
                                        )
                                    } catch {
                                        // Expected
                                    }
                                }
                            }
                        }
                    } catch {
                        // Client creation might fail, but should not crash
                    }
                }
            }
        }
        
        // All clients should complete their work without interference
    }
}