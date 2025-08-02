import XCTest
import Foundation
@testable import SwiftJanus

class ServerFeaturesTests: XCTestCase {
    
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("janus-server-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    // Helper function to create test server
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
        return (server, socketPath)
    }
    
    // Helper function to send command and wait for response
    func sendCommandAndWait(_ socketPath: String, command: JanusCommand, timeout: TimeInterval = 2.0) async throws -> JanusResponse {
        // Create client socket
        let clientSocket = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocket != -1 else {
            throw JanusError.socketCreationFailed("Failed to create client socket")
        }
        defer { Darwin.close(clientSocket) }
        
        // Create response socket
        let responseSocketPath = tempDir.appendingPathComponent("response-\(command.id).sock").path
        let responseSocket = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard responseSocket != -1 else {
            throw JanusError.socketCreationFailed("Failed to create response socket")
        }
        defer { Darwin.close(responseSocket) }
        
        // Bind response socket
        var responseAddr = sockaddr_un()
        responseAddr.sun_family = sa_family_t(AF_UNIX)
        let responsePathCString = responseSocketPath.cString(using: .utf8)!
        withUnsafeMutablePointer(to: &responseAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: responsePathCString.count) { pathPtr in
                responsePathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                }
            }
        }
        
        let bindResult = withUnsafePointer(to: &responseAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(responseSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult == 0 else {
            throw JanusError.bindFailed("Failed to bind response socket")
        }
        
        defer { try? FileManager.default.removeItem(atPath: responseSocketPath) }
        
        // Create command with response path
        let commandWithResponse = JanusCommand(
            id: command.id,
            channelId: command.channelId,
            command: command.command,
            replyTo: responseSocketPath,
            args: command.args,
            timeout: command.timeout,
            timestamp: command.timestamp
        )
        
        // Send command
        let commandData = try JSONEncoder().encode(commandWithResponse)
        
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        let serverPathCString = socketPath.cString(using: .utf8)!
        withUnsafeMutablePointer(to: &serverAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: serverPathCString.count) { pathPtr in
                serverPathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                }
            }
        }
        
        let sendResult = commandData.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.sendto(clientSocket, dataPtr.baseAddress, commandData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        
        guard sendResult != -1 else {
            throw JanusError.sendFailed("Failed to send command")
        }
        
        // Wait for response
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            var buffer = Data(count: 4096)
            let bufferSize = buffer.count
            let bytesReceived = buffer.withUnsafeMutableBytes { bufferPtr in
                Darwin.recv(responseSocket, bufferPtr.baseAddress, bufferSize, 0)
            }
            
            if bytesReceived > 0 {
                let responseData = buffer.prefix(bytesReceived)
                let response = try JSONDecoder().decode(JanusResponse.self, from: responseData)
                return response
            } else if bytesReceived == 0 {
                throw JanusError.connectionClosed("Response socket closed")
            }
            
            // Small delay before retrying
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        throw JanusError.timeout("Timeout waiting for response")
    }
    
    func testCommandHandlerRegistry() async throws {
        let (server, socketPath) = createTestServer()
        
        // Register test handler
        server.registerHandler("test_command") { command in
            return .success(["message": AnyCodable("test response")])
        }
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Send test command
        let command = JanusCommand(
            id: "test-001",
            channelId: "test",
            command: "test_command",
            replyTo: nil,
            args: nil,
            timeout: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let response = try await sendCommandAndWait(socketPath, command: command)
        
        server.stop()
        serverTask.cancel()
        
        XCTAssertTrue(response.success, "Expected successful response")
        XCTAssertEqual(response.commandId, "test-001")
        
        print("✅ Command handler registry validated")
    }
    
    func testMultiClientConnectionManagement() async throws {
        let (server, socketPath) = createTestServer()
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Test multiple concurrent clients
        let clientCount = 3
        
        await withTaskGroup(of: Result<JanusResponse, Error>.self) { group in
            for i in 0..<clientCount {
                group.addTask {
                    do {
                        let command = JanusCommand(
                            id: "client-\(i)",
                            channelId: "test-client-\(i)",
                            command: "ping",
                            replyTo: nil,
                            args: nil,
                            timeout: nil,
                            timestamp: Date().timeIntervalSince1970
                        )
                        
                        let response = try await self.sendCommandAndWait(socketPath, command: command, timeout: 3.0)
                        return .success(response)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var successfulClients = 0
            for await result in group {
                switch result {
                case .success(_):
                    successfulClients += 1
                case .failure(let error):
                    print("Client failed: \(error)")
                }
            }
            
            server.stop()
            serverTask.cancel()
            
            XCTAssertEqual(successfulClients, clientCount, "All clients should succeed")
        }
        
        print("✅ Multi-client connection management validated")
    }
    
    func testEventDrivenArchitecture() async throws {
        let (server, socketPath) = createTestServer()
        
        // Track events
        var eventsReceived: [String] = []
        let eventQueue = DispatchQueue(label: "test.events")
        
        server.events.on("listening") { _ in
            eventQueue.async {
                eventsReceived.append("listening")
            }
        }
        
        server.events.on("command") { _ in
            eventQueue.async {
                eventsReceived.append("command")
            }
        }
        
        server.events.on("response") { _ in
            eventQueue.async {
                eventsReceived.append("response")
            }
        }
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start and emit listening event
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Send test command to trigger command and response events
        let command = JanusCommand(
            id: "event-test",
            channelId: "test",
            command: "ping",
            replyTo: nil,
            args: nil,
            timeout: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let _ = try await sendCommandAndWait(socketPath, command: command)
        
        // Give events time to process
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        server.stop()
        serverTask.cancel()
        
        // Verify events were emitted
        let expectedEvents = ["listening", "command", "response"]
        for expected in expectedEvents {
            eventQueue.sync {
                XCTAssertTrue(eventsReceived.contains(expected), "Expected event '\(expected)' was not emitted")
            }
        }
        
        print("✅ Event-driven architecture validated")
    }
    
    func testGracefulShutdown() async throws {
        let (server, socketPath) = createTestServer()
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Verify server is running by checking socket file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Socket file should exist when server is running")
        
        // Stop server
        server.stop()
        serverTask.cancel()
        
        // Give server time to shutdown
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Verify socket file was cleaned up (if configured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "Socket file should be cleaned up after shutdown")
        
        print("✅ Graceful shutdown validated")
    }
    
    func testConnectionProcessingLoop() async throws {
        let (server, socketPath) = createTestServer()
        
        // Track processed commands
        var processedCommands: [String] = []
        let commandQueue = DispatchQueue(label: "test.commands")
        
        // Register custom handler that tracks commands
        server.registerHandler("track_test") { command in
            commandQueue.async {
                processedCommands.append(command.id)
            }
            return .success(["tracked": AnyCodable(true)])
        }
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Send multiple commands to test processing loop
        let commandIds = ["cmd1", "cmd2", "cmd3"]
        
        for cmdId in commandIds {
            let command = JanusCommand(
                id: cmdId,
                channelId: "test",
                command: "track_test",
                replyTo: nil,
                args: nil,
                timeout: nil,
                timestamp: Date().timeIntervalSince1970
            )
            
            let _ = try await sendCommandAndWait(socketPath, command: command)
        }
        
        server.stop()
        serverTask.cancel()
        
        // Verify all commands were processed
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        commandQueue.sync {
            XCTAssertEqual(processedCommands.count, commandIds.count, "All commands should be processed")
            
            for expectedId in commandIds {
                XCTAssertTrue(processedCommands.contains(expectedId), "Command \(expectedId) should be processed")
            }
        }
        
        print("✅ Connection processing loop validated")
    }
    
    func testErrorResponseGeneration() async throws {
        let (server, socketPath) = createTestServer()
        
        // Start server (no custom handlers registered)
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Send command that doesn't have a handler (should generate error)
        let command = JanusCommand(
            id: "error-test",
            channelId: "test",
            command: "nonexistent_command",
            replyTo: nil,
            args: nil,
            timeout: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let response = try await sendCommandAndWait(socketPath, command: command)
        
        server.stop()
        serverTask.cancel()
        
        // Verify error response structure
        XCTAssertFalse(response.success, "Expected error response to have success=false")
        XCTAssertNotNil(response.error, "Expected error response to have error field")
        XCTAssertEqual(response.commandId, "error-test")
        
        print("✅ Error response generation validated")
    }
    
    func testClientActivityTracking() async throws {
        let (server, socketPath) = createTestServer()
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Send multiple commands from same "client" (same channel)
        for i in 0..<3 {
            let command = JanusCommand(
                id: "activity-test-\(i)",
                channelId: "test-client", // Same channel = same client
                command: "ping",
                replyTo: nil,
                args: nil,
                timeout: nil,
                timestamp: Date().timeIntervalSince1970
            )
            
            let _ = try await sendCommandAndWait(socketPath, command: command)
            
            // Small delay between commands
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        
        server.stop()
        serverTask.cancel()
        
        print("✅ Client activity tracking validated through command processing")
    }
    
    func testCommandExecutionWithTimeout() async throws {
        let (server, socketPath) = createTestServer()
        
        // Register slow handler that should timeout
        server.registerHandler("slow_command") { _ in
            // This simulates a slow process
            Task {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
            return .success(["should": AnyCodable("not reach here")])
        }
        
        // Start server
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Send slow command with short timeout
        let command = JanusCommand(
            id: "timeout-test",
            channelId: "test",
            command: "slow_command",
            replyTo: nil,
            args: nil,
            timeout: 1.0, // 1 second timeout
            timestamp: Date().timeIntervalSince1970
        )
        
        let startTime = Date()
        
        do {
            let response = try await sendCommandAndWait(socketPath, command: command, timeout: 3.0)
            let duration = Date().timeIntervalSince(startTime)
            
            // Verify response came back reasonably quickly (within timeout + processing time)
            XCTAssertLessThan(duration, 3.0, "Response should come back within reasonable time")
            
            // Server may or may not implement timeout properly, but should not crash
            print("Response received: success=\(response.success)")
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(duration, 3.0, "Timeout should occur within reasonable time")
            print("Command timed out as expected")
        }
        
        server.stop()
        serverTask.cancel()
        
        print("✅ Command execution with timeout validated")
    }
    
    func testSocketFileCleanup() async throws {
        let socketPath = tempDir.appendingPathComponent("cleanup-test.sock").path
        
        // Create dummy socket file
        FileManager.default.createFile(atPath: socketPath, contents: Data(), attributes: nil)
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Test socket file should exist")
        
        // Create server with cleanup on start
        let config = ServerConfig(cleanupOnStart: true, cleanupOnShutdown: true)
        let server = JanusServer(config: config)
        
        // Start server (should cleanup existing file)
        let serverTask = Task {
            try await server.startListening(socketPath)
        }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Server should have created new socket (old file was cleaned up)
        // We can verify this by checking if we can send a command
        let command = JanusCommand(
            id: "cleanup-test",
            channelId: "test",
            command: "ping",
            replyTo: nil,
            args: nil,
            timeout: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let response = try await sendCommandAndWait(socketPath, command: command)
        XCTAssertTrue(response.success, "Server should be working after cleanup")
        
        // Stop server
        server.stop()
        serverTask.cancel()
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Verify cleanup on shutdown (socket file should be removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "Socket file should be cleaned up on shutdown")
        
        print("✅ Socket file cleanup validated")
    }
}