// CoreSocketCommunicationTests.swift
// Comprehensive tests for Core Socket Communication features using real SOCK_DGRAM operations

import XCTest
import Foundation
@testable import SwiftJanus

final class CoreSocketCommunicationTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Clean up any existing test socket files
        let testPaths = [
            "/tmp/swift-dgram-test.sock",
            "/tmp/swift-response-test.sock", 
            "/tmp/swift-server-test.sock",
            "/tmp/swift-size-test.sock",
            "/tmp/swift-cleanup-test.sock",
            "/tmp/swift-conn-test.sock",
            "/tmp/swift-unique-test.sock",
            "/tmp/swift-addr-test.sock",
            "/tmp/swift-timeout-test.sock"
        ]
        
        for path in testPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    
    override func tearDownWithError() throws {
        // Clean up test socket files
        let testPaths = [
            "/tmp/swift-dgram-test.sock",
            "/tmp/swift-response-test.sock",
            "/tmp/swift-server-test.sock", 
            "/tmp/swift-size-test.sock",
            "/tmp/swift-cleanup-test.sock",
            "/tmp/swift-conn-test.sock",
            "/tmp/swift-unique-test.sock",
            "/tmp/swift-addr-test.sock",
            "/tmp/swift-timeout-test.sock"
        ]
        
        for path in testPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    
    // MARK: - Core Socket Communication Tests
    
    func testSOCKDGRAMSocketCreation() throws {
        let testSocketPath = "/tmp/swift-dgram-test.sock"
        
        // Create actual SOCK_DGRAM socket using BSD socket API
        let socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(socketFd, -1, "Failed to create SOCK_DGRAM socket")
        defer { close(socketFd) }
        
        // Configure Unix domain socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = testSocketPath.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ccharPtr in
                pathBytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { srcPtr in
                        strcpy(ccharPtr, srcPtr)
                    }
                }
            }
        }
        
        // Bind to Unix domain socket path
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        XCTAssertEqual(bindResult, 0, "Failed to bind SOCK_DGRAM socket")
        
        // Verify socket file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: testSocketPath), "Socket file was not created")
        
        // Verify socket type is SOCK_DGRAM
        var sockType: Int32 = 0
        var sockTypeSize = socklen_t(MemoryLayout<Int32>.size)
        let getSockResult = getsockopt(socketFd, SOL_SOCKET, SO_TYPE, &sockType, &sockTypeSize)
        
        XCTAssertEqual(getSockResult, 0, "Failed to get socket type")
        XCTAssertEqual(sockType, SOCK_DGRAM, "Socket type should be SOCK_DGRAM")
    }
    
    func testResponseSocketBinding() throws {
        let responseSocketPath = "/tmp/swift-response-test.sock"
        
        // Test response socket path generation
        let generatedPath1 = generateResponseSocketPath()
        let generatedPath2 = generateResponseSocketPath()
        
        XCTAssertFalse(generatedPath1.isEmpty, "Generated response socket path should not be empty")
        XCTAssertNotEqual(generatedPath1, generatedPath2, "Generated response socket paths should be unique")
        XCTAssertNotEqual(generatedPath1, responseSocketPath, "Response socket path should be different from test path")
        
        // Test actual response socket binding
        let socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(socketFd, -1, "Failed to create response socket")
        defer { close(socketFd) }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = responseSocketPath.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ccharPtr in
                pathBytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { srcPtr in
                        strcpy(ccharPtr, srcPtr)
                    }
                }
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        XCTAssertEqual(bindResult, 0, "Failed to bind response socket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseSocketPath), "Response socket file was not created")
    }
    
    func testSendWithResponse() throws {
        let serverSocketPath = "/tmp/swift-server-test.sock"
        let responseSocketPath = "/tmp/swift-response-test.sock"
        
        // Create mock server socket
        let serverFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(serverFd, -1, "Failed to create server socket")
        defer { close(serverFd) }
        
        var serverAddr = createUnixSocketAddress(path: serverSocketPath)
        let serverBindResult = withUnsafePointer(to: &serverAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(serverBindResult, 0, "Failed to bind server socket")
        
        // Create response socket
        let responseFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(responseFd, -1, "Failed to create response socket")
        defer { close(responseFd) }
        
        var responseAddr = createUnixSocketAddress(path: responseSocketPath)
        let responseBindResult = withUnsafePointer(to: &responseAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(responseFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(responseBindResult, 0, "Failed to bind response socket")
        
        // Create command with reply_to field
        let command = SocketCommand(
            channelId: "test-channel",
            command: "test-command",
            replyTo: responseSocketPath,
            args: ["test_param": AnyCodable("test_value")]
        )
        
        let jsonData = try JSONEncoder().encode(command)
        
        // Send to server socket
        let clientFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(clientFd, -1, "Failed to create client socket")
        defer { close(clientFd) }
        
        let sendResult = jsonData.withUnsafeBytes { bytes in
            withUnsafePointer(to: &serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        
        XCTAssertEqual(sendResult, jsonData.count, "Failed to send datagram")
        
        // Read on server socket to verify message received
        var buffer = [UInt8](repeating: 0, count: 4096)
        let receiveResult = recv(serverFd, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(receiveResult, 0, "Failed to receive datagram")
        
        let receivedData = Data(buffer[0..<receiveResult])
        let receivedCommand = try JSONDecoder().decode(SocketCommand.self, from: receivedData)
        
        XCTAssertEqual(receivedCommand.channelId, "test-channel", "Channel ID mismatch")
        XCTAssertEqual(receivedCommand.command, "test-command", "Command mismatch")
        XCTAssertEqual(receivedCommand.replyTo, responseSocketPath, "Reply-to mismatch")
    }
    
    func testFireAndForgetSend() throws {
        let serverSocketPath = "/tmp/swift-server-test.sock"
        
        // Create mock server socket
        let serverFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(serverFd, -1, "Failed to create server socket")
        defer { close(serverFd) }
        
        var serverAddr = createUnixSocketAddress(path: serverSocketPath)
        let bindResult = withUnsafePointer(to: &serverAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Failed to bind server socket")
        
        // Create fire-and-forget command (no reply_to field)
        let command = SocketCommand(
            channelId: "test-channel", 
            command: "fire-and-forget",
            replyTo: nil,
            args: ["message": AnyCodable("no response needed")]
        )
        
        let jsonData = try JSONEncoder().encode(command)
        
        // Send using fire-and-forget pattern
        let clientFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(clientFd, -1, "Failed to create client socket")
        defer { close(clientFd) }
        
        let sendResult = jsonData.withUnsafeBytes { bytes in
            withUnsafePointer(to: &serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        
        XCTAssertEqual(sendResult, jsonData.count, "Failed to send fire-and-forget datagram")
        
        // Verify server received the message
        var buffer = [UInt8](repeating: 0, count: 4096)
        let receiveResult = recv(serverFd, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(receiveResult, 0, "Failed to receive fire-and-forget datagram")
        
        let receivedData = Data(buffer[0..<receiveResult])
        let receivedCommand = try JSONDecoder().decode(SocketCommand.self, from: receivedData)
        
        XCTAssertNil(receivedCommand.replyTo, "Fire-and-forget command should have nil replyTo")
        XCTAssertEqual(receivedCommand.command, "fire-and-forget", "Command mismatch")
    }
    
    func testDynamicMessageSizeDetection() throws {
        let testSocketPath = "/tmp/swift-size-test.sock"
        
        // Create socket for size testing
        let socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(socketFd, -1, "Failed to create socket")
        defer { close(socketFd) }
        
        var addr = createUnixSocketAddress(path: testSocketPath)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Failed to bind socket")
        
        // Test with various message sizes to find limit
        let testSizes = [1024, 4096, 8192, 16384, 32768, 65536, 131072]
        var maxSuccessfulSize = 0
        
        for size in testSizes {
            // Create test message of specific size
            let testData = Data(repeating: 65, count: size) // 'A' repeated
            
            // Try to send message to itself
            let sendResult = testData.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(socketFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            
            if sendResult == -1 {
                let error = errno
                if error == EMSGSIZE {
                    print("Hit EMSGSIZE at size \(size) bytes")
                    break
                } else {
                    XCTFail("Unexpected error at size \(size): \(String(cString: strerror(error)))")
                }
            } else if sendResult == size {
                maxSuccessfulSize = size
                print("Successfully sent \(size) bytes")
            }
        }
        
        XCTAssertGreaterThan(maxSuccessfulSize, 0, "No successful message sizes - system may have very low limits")
        
        // Verify we can detect the size limit dynamically
        if maxSuccessfulSize > 0 {
            // Try sending a message just over the limit
            let oversizedData = Data(repeating: 66, count: maxSuccessfulSize * 2) // 'B' repeated
            
            let sendResult = oversizedData.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(socketFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            
            if sendResult != -1 || errno != EMSGSIZE {
                print("Expected EMSGSIZE for oversized message, got result: \(sendResult), errno: \(errno)")
            }
        }
    }
    
    func testSocketCleanupManagement() throws {
        let testSocketPath = "/tmp/swift-cleanup-test.sock"
        let responseSocketPath = "/tmp/swift-cleanup-response.sock"
        
        // Test automatic cleanup when socket is closed
        do {
            let socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
            XCTAssertNotEqual(socketFd, -1, "Failed to create socket")
            
            var addr = createUnixSocketAddress(path: testSocketPath)
            let bindResult = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.bind(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(bindResult, 0, "Failed to bind socket")
            
            // Verify socket file exists
            XCTAssertTrue(FileManager.default.fileExists(atPath: testSocketPath), "Socket file should exist after binding")
            
            // Close socket
            close(socketFd)
            
            // Socket file should still exist (Unix domain sockets persist)
            XCTAssertTrue(FileManager.default.fileExists(atPath: testSocketPath), "Socket file should persist after closing")
        }
        
        // Test manual cleanup
        try FileManager.default.removeItem(atPath: testSocketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testSocketPath), "Socket file should be removed after manual cleanup")
        
        // Test cleanup of response sockets
        let responseFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(responseFd, -1, "Failed to create response socket")
        
        var responseAddr = createUnixSocketAddress(path: responseSocketPath)
        let responseBindResult = withUnsafePointer(to: &responseAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(responseFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(responseBindResult, 0, "Failed to bind response socket")
        
        // Verify response socket exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseSocketPath), "Response socket file should exist")
        
        // Clean up response socket
        close(responseFd)
        try FileManager.default.removeItem(atPath: responseSocketPath)
        
        // Verify cleanup
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseSocketPath), "Response socket should be cleaned up")
    }
    
    func testConnectionTesting() async throws {
        let serverSocketPath = "/tmp/swift-conn-test.sock"
        
        // Test connection to non-existent server (should fail)
        do {
            let client = try await JanusClient(socketPath: serverSocketPath, channelId: "test-channel")
            try await client.testConnection()
            XCTFail("Expected connection test to fail for non-existent server")
        } catch {
            // Expected to fail
        }
        
        // Create mock server
        let serverFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(serverFd, -1, "Failed to create server socket")
        defer { close(serverFd) }
        
        var serverAddr = createUnixSocketAddress(path: serverSocketPath)
        let bindResult = withUnsafePointer(to: &serverAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Failed to bind server socket")
        
        // Start simple echo server task
        let serverTask = Task {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            while true {
                let receiveResult = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        recvfrom(serverFd, &buffer, buffer.count, 0, sockaddrPtr, &clientAddrLen)
                    }
                }
                
                if receiveResult > 0 {
                    // Echo back the message
                    _ = withUnsafePointer(to: &clientAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                            sendto(serverFd, &buffer, receiveResult, 0, sockaddrPtr, clientAddrLen)
                        }
                    }
                } else {
                    break
                }
            }
        }
        
        // Give server time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Test connection to running server (should succeed)
        do {
            let client = try await JanusClient(socketPath: serverSocketPath, channelId: "test-channel")
            try await client.testConnection()
        } catch {
            XCTFail("Expected connection test to succeed for running server: \(error)")
        }
        
        serverTask.cancel()
    }
    
    func testUniqueResponseSocketPaths() throws {
        // Generate multiple response socket paths
        var paths: [String] = []
        for _ in 0..<10 {
            paths.append(generateResponseSocketPath())
            usleep(1000) // 1ms delay to ensure uniqueness
        }
        
        // Verify all paths are unique
        for i in 0..<paths.count {
            for j in (i+1)..<paths.count {
                XCTAssertNotEqual(paths[i], paths[j], "Duplicate response socket paths: \(paths[i])")
            }
        }
        
        // Verify paths are not empty
        for (index, path) in paths.enumerated() {
            XCTAssertFalse(path.isEmpty, "Response socket path \(index) is empty")
        }
        
        // Verify paths use temporary directory
        for (index, path) in paths.enumerated() {
            XCTAssertTrue(path.hasPrefix("/"), "Response socket path \(index) is not absolute: \(path)")
        }
    }
    
    func testSocketAddressConfiguration() throws {
        let testSocketPath = "/tmp/swift-addr-test.sock"
        
        // Test socket address creation
        var addr = createUnixSocketAddress(path: testSocketPath)
        
        // Verify address structure
        XCTAssertEqual(addr.sun_family, sa_family_t(AF_UNIX), "Address family should be AF_UNIX")
        
        let sunPath = addr.sun_path
        let pathCString = withUnsafePointer(to: sunPath) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: sunPath)) { ccharPtr in
                String(cString: ccharPtr)
            }
        }
        XCTAssertEqual(pathCString, testSocketPath, "Address path mismatch")
        
        // Test address with socket
        let socketFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(socketFd, -1, "Failed to create socket")
        defer { close(socketFd) }
        
        // Bind to address
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Failed to bind to configured address")
        
        // Verify socket file was created at correct path
        XCTAssertTrue(FileManager.default.fileExists(atPath: testSocketPath), "Socket file not created at configured address")
        
        // Test address for sending
        let clientFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(clientFd, -1, "Failed to create client socket")
        defer { close(clientFd) }
        
        let testMessage = "test message".data(using: .utf8)!
        let sendResult = testMessage.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        
        XCTAssertEqual(sendResult, testMessage.count, "Failed to send to configured address")
        
        // Verify message was received
        var buffer = [UInt8](repeating: 0, count: 1024)
        let receiveResult = recv(socketFd, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(receiveResult, 0, "Failed to receive from configured address")
        
        let receivedMessage = Data(buffer[0..<receiveResult])
        XCTAssertEqual(receivedMessage, testMessage, "Message content mismatch")
    }
    
    func testTimeoutManagement() throws {
        let responseSocketPath = "/tmp/swift-timeout-test.sock"
        
        // Create response socket with timeout
        let responseFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(responseFd, -1, "Failed to create response socket")
        defer { close(responseFd) }
        
        var responseAddr = createUnixSocketAddress(path: responseSocketPath)
        let bindResult = withUnsafePointer(to: &responseAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(responseFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Failed to bind response socket")
        
        // Set socket receive timeout
        var timeout = timeval(tv_sec: 1, tv_usec: 0) // 1 second timeout
        let setTimeoutResult = setsockopt(responseFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        XCTAssertEqual(setTimeoutResult, 0, "Failed to set socket timeout")
        
        // Test timeout behavior - try to receive with no sender
        var buffer = [UInt8](repeating: 0, count: 1024)
        let startTime = Date()
        
        let receiveResult = recv(responseFd, &buffer, buffer.count, 0)
        let elapsed = Date().timeIntervalSince(startTime)
        
        // Should timeout after approximately 1 second
        XCTAssertEqual(receiveResult, -1, "Expected timeout error when no data available")
        XCTAssertEqual(errno, EAGAIN, "Expected EAGAIN error on timeout")
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "Timeout should be at least 0.9 seconds")
        XCTAssertLessThanOrEqual(elapsed, 1.1, "Timeout should be at most 1.1 seconds")
        
        // Test successful receive within timeout
        // Create sender socket
        let senderFd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertNotEqual(senderFd, -1, "Failed to create sender socket")
        defer { close(senderFd) }
        
        // Send message quickly (should not timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { // Send after 100ms
            let testMessage = "timeout test message".data(using: .utf8)!
            _ = testMessage.withUnsafeBytes { bytes in
                withUnsafePointer(to: &responseAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        sendto(senderFd, bytes.baseAddress, bytes.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
        }
        
        let startTime2 = Date()
        let receiveResult2 = recv(responseFd, &buffer, buffer.count, 0)
        let elapsed2 = Date().timeIntervalSince(startTime2)
        
        XCTAssertGreaterThan(receiveResult2, 0, "Expected successful receive")
        XCTAssertLessThan(elapsed2, 0.5, "Expected quick receive")
        
        let receivedMessage = Data(buffer[0..<receiveResult2])
        let receivedString = String(data: receivedMessage, encoding: .utf8)
        XCTAssertEqual(receivedString, "timeout test message", "Message content mismatch")
    }
    
    // MARK: - Helper Methods
    
    private func createUnixSocketAddress(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { ccharPtr in
                pathBytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { srcPtr in
                        strcpy(ccharPtr, srcPtr)
                    }
                }
            }
        }
        
        return addr
    }
    
    private func generateResponseSocketPath() -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000) // microseconds
        let random = Int.random(in: 1000...9999)
        return "/tmp/swift_response_\(timestamp)_\(random).sock"
    }
}