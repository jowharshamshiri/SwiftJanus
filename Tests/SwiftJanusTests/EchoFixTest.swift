// EchoFixTest.swift
// Simple test to verify JanusServer echo fix works properly
// This tests the actual JanusServer class (not the SwiftJanusDgram command line tool)

import XCTest
import Foundation
@testable import SwiftJanus

final class EchoFixTest: XCTestCase {
    
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        // Use shorter path to avoid Unix socket 108-character limit
        tempDir = URL(fileURLWithPath: "/tmp/janus-echo-test-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testJanusServerEchoFix() async throws {
        print("🧪 Testing JanusServer echo fix...")
        
        let socketPath = tempDir.appendingPathComponent("test-server.sock").path
        
        // Create server configuration with debug logging
        let config = ServerConfig(
            maxConnections: 10,
            defaultTimeout: 5.0,
            maxMessageSize: 1024,
            cleanupOnStart: true,
            cleanupOnShutdown: true,
            debugLogging: true  // Enable debug logging to see what's happening
        )
        
        // Create server
        let server = JanusServer(config: config)
        print("✅ JanusServer created")
        
        // Start server in background task
        let serverTask = Task {
            do {
                try await server.startListening(socketPath)
            } catch {
                print("❌ Server failed to start: \(error)")
            }
        }
        
        // Give server time to start
        print("⏳ Waiting for server to start...")
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        
        // Verify socket file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Socket file should be created")
        print("✅ Socket file created at \(socketPath)")
        
        // Create client
        let client = try await JanusClient(
            socketPath: socketPath,
            channelId: "test",
            enableValidation: false  // Disable validation for simple test
        )
        print("✅ JanusClient created")
        
        // Test echo command
        print("📤 Sending echo command...")
        let testMessage = "Hello from test!"
        let echoArgs = ["message": AnyCodable(testMessage)]
        print("  Args being sent: \(echoArgs)")
        
        let response = try await client.sendCommand(
            "echo", 
            args: echoArgs,
            timeout: 3.0
        )
        
        print("📥 Received response:")
        print("  Success: \(response.success)")
        print("  Command ID: \(response.commandId)")
        print("  Channel ID: \(response.channelId)")
        
        // Verify response is successful
        XCTAssertTrue(response.success, "Echo command should succeed")
        XCTAssertEqual(response.channelId, "test", "Channel ID should match")
        
        // Check result format
        XCTAssertNotNil(response.result, "Response should have a result")
        
        if let result = response.result?.value as? [String: Any] {
            print("  Result: \(result)")
            
            // Check if echo response contains expected fields
            if let echo = result["echo"] as? String {
                print("✅ Echo message: \(echo)")
                XCTAssertEqual(echo, "Hello from test!", "Echo message should match input")
                print("🎉 Echo fix working correctly!")
            } else {
                XCTFail("Response should contain 'echo' field with string value")
            }
            
            // Check for timestamp field
            XCTAssertNotNil(result["timestamp"], "Response should contain timestamp field")
            if let timestamp = result["timestamp"] {
                print("✅ Timestamp field present: \(timestamp)")
            }
        } else {
            XCTFail("Response result should be a dictionary, got: \(response.result?.value ?? "nil")")
        }
        
        // Test ping command for comparison
        print("📤 Sending ping command for comparison...")
        let pingResponse = try await client.sendCommand("ping", timeout: 3.0)
        
        print("📥 Ping response:")
        print("  Success: \(pingResponse.success)")
        
        XCTAssertTrue(pingResponse.success, "Ping command should succeed")
        
        if let result = pingResponse.result?.value as? [String: Any] {
            print("  Result: \(result)")
            XCTAssertNotNil(result["pong"], "Ping response should contain 'pong' field")
            XCTAssertNotNil(result["timestamp"], "Ping response should contain timestamp field")
        } else {
            XCTFail("Ping result should be a dictionary")
        }
        
        // Cleanup
        print("🧹 Cleaning up...")
        server.stop() 
        serverTask.cancel()
        
        // Give server time to shutdown
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        print("✅ Test completed successfully!")
    }
}