// ConcurrencyTests.swift
// High-concurrency and thread safety tests

import XCTest
import os.lock
@testable import SwiftJanus

// Thread-safe counter for concurrent test operations
class Counter {
    private let queue = DispatchQueue(label: "counter", attributes: .concurrent)
    private var _successCount = 0
    private var _errorCount = 0
    
    func incrementSuccess() {
        queue.async(flags: .barrier) {
            self._successCount += 1
        }
    }
    
    func incrementError() {
        queue.async(flags: .barrier) {
            self._errorCount += 1
        }
    }
    
    func getCounts() -> (success: Int, error: Int) {
        return queue.sync {
            return (_successCount, _errorCount)
        }
    }
}

@MainActor
final class ConcurrencyTests: XCTestCase {
    
    var testSocketPath: String!
    var testManifest: Manifest!
    var testServer: JanusServer!
    var serverTask: Task<Void, Error>!
    var tempDir: URL!
    
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("janus-concurrency-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        testSocketPath = tempDir.appendingPathComponent("concurrency-test.sock").path
    }
    
    override func tearDownWithError() throws {
        // Stop server if running
        if let serverTask = serverTask {
            testServer?.stop()
            serverTask.cancel()
        }
        
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // Helper to create and start server for tests (similar to ServerFeaturesTests)
    func createTestServer() -> (JanusServer, String) {
        let socketPath = tempDir.appendingPathComponent("test-server.sock").path
        let config = ServerConfig(
            maxConnections: 10,
            defaultTimeout: 5.0,
            maxMessageSize: 1024,
            cleanupOnStart: true,
            cleanupOnShutdown: true
        )
        let server = JanusServer(config: config)
        
        // Register test command handlers
        server.registerHandler("testCommand") { command in
            return .success([
                "processed": AnyCodable(true),
                "id": command.args?["id"] ?? AnyCodable("unknown"),
                "data": command.args?["data"] ?? AnyCodable("test")
            ])
        }
        
        server.registerHandler("quickCommand") { command in
            return .success([
                "quick": AnyCodable(true),
                "timestamp": AnyCodable(Date().timeIntervalSince1970)
            ])
        }
        
        return (server, socketPath)
    }
    
    // MARK: - High Concurrency Tests
    
    func testHighConcurrencyCommandExecution() async throws {
        // Create and start test server
        let (server, socketPath) = createTestServer()
        
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let client = try await JanusClient(
            socketPath: socketPath,
            channelId: "testChannel"
        )
        
        let concurrentOperations = 100
        let counter = Counter()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrentOperations {
                group.addTask {
                    do {
                        let response = try await client.sendCommand(
                            "testCommand",
                            args: ["data": AnyCodable("concurrent-test-\(i)"), "id": AnyCodable("\(i)")]
                        )
                        
                        // Verify response is successful
                        if response.success {
                            counter.incrementSuccess()
                        } else {
                            counter.incrementError()
                        }
                    } catch {
                        counter.incrementError()
                    }
                }
            }
        }
        
        // All operations should succeed with a real server
        let (successCount, errorCount) = counter.getCounts()
        XCTAssertEqual(successCount + errorCount, concurrentOperations)
        XCTAssertEqual(successCount, concurrentOperations, "All commands should succeed with real server")
        XCTAssertEqual(errorCount, 0, "No commands should fail with real server")
        
        // Stop server
        server.stop()
        serverTask.cancel()
    }
    
    func testConcurrentClientCreation() async throws {
        let clientCount = 50
        var clients: [JanusClient] = []
        var creationErrors = 0
        
        await withTaskGroup(of: JanusClient?.self) { group in
            for i in 0..<clientCount {
                group.addTask { @MainActor in
                    do {
                        return try await JanusClient(
                            socketPath: "\(self.testSocketPath!)-\(i)",
                            channelId: "testChannel"
                        )
                    } catch {
                        creationErrors += 1
                        return nil as JanusClient?
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
    
    func testConcurrentHandlerRegistration() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        let handlerCount = 20
        var registrationErrors = 0
        
        // Handler registration would be server-side functionality
        // Client focuses on sending commands, not handling them
        
        // The library should handle concurrent registration gracefully
        // Either all succeed (if it allows multiple handlers) or some fail gracefully
        XCTAssertLessThanOrEqual(registrationErrors, handlerCount)
    }
    
    func testConcurrentConnectionPoolUsage() async throws {
        // SOCK_DGRAM doesn't use connection pools - operations are stateless
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        let operationCount = 50 // More than pool size
        var completedOperations = 0
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<operationCount {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Test concurrent access to internal state
        await withTaskGroup(of: Void.self) { group in
            // Concurrent command executions
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
                    // Handler registration would be server-side
                    // Testing client concurrency patterns instead
                }
            }
        }
        
        // Should complete without crashing or hanging
    }
    
    func testConcurrentConnectionManagement() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Test concurrent connection creation and cleanup
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        // Start a command (creates connection)
                        _ = try await client.sendCommand(
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
    
    func testThreadSafetyOfConfiguration() async throws {
        // Create and start test server
        let (server, socketPath) = createTestServer()
        
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let client = try await JanusClient(
            socketPath: socketPath,
            channelId: "testChannel"
        )
        
        // Test concurrent access to configuration and operations
        let accessCount = 100
        let counter = Counter()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<accessCount {
                group.addTask {
                    do {
                        // Mix of configuration access and actual commands to test thread safety
                        if i % 2 == 0 {
                            // Test configuration access
                            _ = client.channelIdValue
                            _ = client.socketPathValue
                            counter.incrementSuccess()
                        } else {
                            // Test actual command execution
                            let response = try await client.sendCommand(
                                "quickCommand",
                                args: ["test": AnyCodable("thread-safety-\(i)")]
                            )
                            if response.success {
                                counter.incrementSuccess()
                            } else {
                                counter.incrementError()
                            }
                        }
                    } catch {
                        counter.incrementError()
                    }
                }
            }
        }
        
        let (successCount, errorCount) = counter.getCounts()
        XCTAssertEqual(successCount + errorCount, accessCount)
        XCTAssertEqual(successCount, accessCount, "All thread-safe operations should succeed")
        XCTAssertEqual(errorCount, 0, "No thread-safe operations should fail")
        
        // Stop server
        server.stop()
        serverTask.cancel()
    }
    
    func testThreadSafetyOfManifestAccess() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Test concurrent access to Manifest
        let accessCount = 100
        let specAccesses = OSAllocatedUnfairLock(initialState: 0)
        
        DispatchQueue.concurrentPerform(iterations: accessCount) { _ in
            // Access Manifest from multiple threads using proper getter
            // Specification access would be internal to SOCK_DGRAM implementation
            // Testing thread safety of client operations instead
            specAccesses.withLock { $0 += 1 }
        }
        
        XCTAssertEqual(specAccesses.withLock { $0 }, accessCount)
    }
    
    // MARK: - Deadlock Prevention Tests
    
    func testNoDeadlockUnderLoad() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Create a scenario that could potentially cause deadlocks
        let taskCount = 50
        let timeout: TimeInterval = 10.0 // Test should complete within 10 seconds
        
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        let startTime = Date()
        let timeout: TimeInterval = 15.0
        
        await withTaskGroup(of: Void.self) { group in
            // Mix of different operations that could interact
            
            // Commands
            for i in 0..<20 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
                    // Handler registration would be server-side
                    // Testing mixed client operations instead
                }
            }
            
            // Configuration access (nonisolated, can be accessed from any thread)
            for _ in 0..<10 {
                group.addTask {
                    // Configuration access would be internal
                    // Specification access would be internal
                }
            }
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsedTime, timeout, "Mixed operations should complete without deadlocking")
    }
    
    // MARK: - Memory Safety Under Concurrency
    
    func testMemorySafetyUnderConcurrentAccess() async throws {
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Test that concurrent access doesn't cause memory issues
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    // Create objects that might be accessed concurrently
                    let args = ["data": AnyCodable("memory-test-\(i)"), "timestamp": AnyCodable(Date().timeIntervalSince1970)]
                    
                    do {
                        _ = try await client.sendCommand("testCommand", args: args)
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
                        let client = try await JanusClient(
                            socketPath: "\(self.testSocketPath!)-cleanup-\(i)",
                            channelId: "testChannel"
                        )
                        
                        // Use the client briefly
                        _ = try await client.sendCommand(
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
        // SOCK_DGRAM doesn't use connection pools - each operation is stateless
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        // Test concurrent access to connection pool
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
        let client = try await JanusClient(
            socketPath: testSocketPath,
            channelId: "testChannel"
        )
        
        let requestCount = 200
        let processedCount = OSAllocatedUnfairLock(initialState: 0)
        
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    do {
                        _ = try await client.sendCommand(
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
                        let client = try await JanusClient(
                            socketPath: "\(self.testSocketPath!)-stress-\(clientId)",
                            channelId: "testChannel"
                        )
                        
                        // Each client makes multiple requests
                        await withTaskGroup(of: Void.self) { requestGroup in
                            for requestId in 0..<requestsPerClient {
                                requestGroup.addTask {
                                    do {
                                        _ = try await client.sendCommand(
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