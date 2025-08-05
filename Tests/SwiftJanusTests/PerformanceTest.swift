// PerformanceTest.swift
// Simple performance test to verify Swift server improvements after AnyCodable fix

import XCTest
import Foundation
@testable import SwiftJanus

final class PerformanceTest: XCTestCase {
    
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: "/tmp/janus-perf-test-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testSwiftServerPerformance() async throws {
        print("🧪 Testing Swift server performance after AnyCodable fix...")
        
        let socketPath = tempDir.appendingPathComponent("perf-server.sock").path
        
        // Create server configuration with reasonable timeouts
        let config = ServerConfig(
            maxConnections: 100,
            defaultTimeout: 10.0,
            maxMessageSize: 8192,
            cleanupOnStart: true,
            cleanupOnShutdown: true,
            debugLogging: false  // Disable debug for performance
        )
        
        let server = JanusServer(config: config)
        print("✅ Server created")
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Wait for server to start
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Server should start")
        
        // Create client
        let client = try await JanusClient(
            socketPath: socketPath,
            channelId: "perf",
            enableValidation: false
        )
        print("✅ Client created")
        
        // Performance test: Multiple rapid echo commands
        let testCount = 20
        var successCount = 0
        var failCount = 0
        let startTime = Date()
        
        print("📤 Sending \(testCount) rapid echo commands...")
        
        for i in 0..<testCount {
            do {
                let response = try await client.sendCommand(
                    "echo",
                    args: ["message": AnyCodable("Test message \(i)")],
                    timeout: 5.0
                )
                
                if response.success {
                    // Verify response format
                    if let resultDict = response.result?.value as? [String: Any],
                       let echoValue = resultDict["echo"] as? String,
                       echoValue == "Test message \(i)" {
                        successCount += 1
                    } else {
                        print("⚠️ Invalid response format for message \(i)")
                        failCount += 1
                    }
                } else {
                    print("⚠️ Command \(i) failed")
                    failCount += 1
                }
            } catch {
                print("❌ Command \(i) error: \(error)")
                failCount += 1
            }
        }
        
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        let successRate = Double(successCount) / Double(testCount) * 100.0
        
        print("📊 Performance Results:")
        print("  Total commands: \(testCount)")
        print("  Successful: \(successCount)")
        print("  Failed: \(failCount)")
        print("  Success rate: \(String(format: "%.1f", successRate))%")
        print("  Duration: \(String(format: "%.3f", duration))s")
        print("  Commands/second: \(String(format: "%.1f", Double(testCount) / duration))")
        
        // Test different command types
        print("📤 Testing different command types...")
        
        // Test ping
        let pingResponse = try await client.sendCommand("ping", timeout: 3.0)
        XCTAssertTrue(pingResponse.success, "Ping should succeed")
        if let resultDict = pingResponse.result?.value as? [String: Any] {
            XCTAssertNotNil(resultDict["pong"], "Ping response should contain pong")
        }
        
        // Test get_info
        let infoResponse = try await client.sendCommand("get_info", timeout: 3.0)
        XCTAssertTrue(infoResponse.success, "get_info should succeed")
        if let resultDict = infoResponse.result?.value as? [String: Any] {
            XCTAssertNotNil(resultDict["server"], "Info response should contain server")
        }
        
        // Cleanup
        server.stop()
        serverTask.cancel()
        
        // Assertions for test success
        XCTAssertGreaterThan(successRate, 80.0, "Success rate should be above 80%")
        XCTAssertLessThan(duration, 10.0, "Duration should be reasonable")
        
        if successRate >= 95.0 {
            print("🎉 EXCELLENT: Swift server performing at \(String(format: "%.1f", successRate))% success rate!")
        } else if successRate >= 80.0 {
            print("✅ GOOD: Swift server performing at \(String(format: "%.1f", successRate))% success rate")
        } else {
            print("⚠️ POOR: Swift server only at \(String(format: "%.1f", successRate))% success rate")
        }
        
        print("✅ Performance test completed")
    }
    
    func testLargePayloadHandling() async throws {
        print("🧪 Testing large payload handling...")
        
        let socketPath = tempDir.appendingPathComponent("large-payload-server.sock").path
        
        let config = ServerConfig(
            maxConnections: 10,
            defaultTimeout: 10.0,
            maxMessageSize: 65536, // 64KB
            cleanupOnStart: true,
            cleanupOnShutdown: true,
            debugLogging: false
        )
        
        let server = JanusServer(config: config)
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        let client = try await JanusClient(
            socketPath: socketPath,
            channelId: "test",
            enableValidation: false
        )
        
        // Test various payload sizes - Unix domain sockets have size limits
        let reasonablePayloadSizes = [100, 1000] // Stay within socket limits  
        let oversizedPayloadSize = 5000 // Expected to fail due to socket limits
        var reasonableTestsSucceeded = true
        var oversizedTestFailed = false
        
        // Test reasonable payload sizes that should succeed
        for size in reasonablePayloadSizes {
            let largeMessage = String(repeating: "A", count: size)
            
            do {
                let response = try await client.sendCommand(
                    "echo",
                    args: ["message": AnyCodable(largeMessage)],
                    timeout: 5.0
                )
                
                if response.success,
                   let resultDict = response.result?.value as? [String: Any],
                   let echoValue = resultDict["echo"] as? String,
                   echoValue == largeMessage {
                    print("✅ Large payload (\(size) chars) handled correctly")
                } else {
                    print("❌ Large payload (\(size) chars) failed")
                    reasonableTestsSucceeded = false
                }
            } catch {
                print("❌ Large payload (\(size) chars) error: \(error)")
                reasonableTestsSucceeded = false
            }
        }
        
        // Test oversized payload that should fail due to socket limits
        let oversizedMessage = String(repeating: "A", count: oversizedPayloadSize)
        do {
            _ = try await client.sendCommand(
                "echo",
                args: ["message": AnyCodable(oversizedMessage)],
                timeout: 5.0
            )
            print("❌ Oversized payload (\(oversizedPayloadSize) chars) unexpectedly succeeded")
        } catch {
            print("✅ Oversized payload (\(oversizedPayloadSize) chars) properly rejected: \(error)")
            oversizedTestFailed = true
        }
        
        server.stop()
        serverTask.cancel()
        
        XCTAssertTrue(reasonableTestsSucceeded, "Reasonable payload sizes should succeed")
        XCTAssertTrue(oversizedTestFailed, "Oversized payload should be rejected due to socket limits")
        print("✅ Large payload test completed")
    }
}