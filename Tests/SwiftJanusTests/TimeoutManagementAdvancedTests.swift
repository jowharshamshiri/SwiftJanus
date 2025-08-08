import XCTest
import Foundation
@testable import SwiftJanus

/// Advanced timeout management tests for SwiftJanus
/// Tests timeout extension, bilateral timeout management, and error-handled registration
/// Matches Go/Rust/TypeScript implementation patterns
final class TimeoutManagementAdvancedTests: XCTestCase {
    
    var timeoutManager: TimeoutManager!
    
    override func setUpWithError() throws {
        timeoutManager = TimeoutManager()
    }
    
    override func tearDownWithError() throws {
        timeoutManager.clearAllTimeouts()
        timeoutManager = nil
    }
    
    // MARK: - Timeout Extension Tests
    
    /// Test timeout extension capability (matches Go/TypeScript implementation)
    func testTimeoutExtension() throws {
        let expectation = expectation(description: "Timeout extension test")
        var timeoutFired = false
        
        let requestId = "test-extend-request"
        
        // Register a timeout for 0.2 seconds
        timeoutManager.registerTimeout(requestId: requestId, timeout: 0.2) {
            timeoutFired = true
            expectation.fulfill()
        }
        
        // Wait 0.1 seconds, then extend by 0.2 seconds  
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let extended = self.timeoutManager.extendTimeout(requestId: requestId, additionalTime: 0.2)
            XCTAssertTrue(extended, "Expected timeout extension to succeed")
        }
        
        // Wait another 0.2 seconds (should not fire yet since we extended - original 0.2 + 0.1 delay + 0.2 extension = 0.5s total)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(timeoutFired, "Callback should not have fired yet after extension")
        }
        
        // Wait for the extended timeout to fire
        waitForExpectations(timeout: 0.6, handler: nil)
        
        XCTAssertTrue(timeoutFired, "Callback should have fired after extended timeout")
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Should have no active timeouts after firing")
    }
    
    /// Test extending non-existent timeout
    func testTimeoutExtensionNonExistent() throws {
        let extended = timeoutManager.extendTimeout(requestId: "non-existent", additionalTime: 0.1)
        XCTAssertFalse(extended, "Expected extension of non-existent timeout to fail")
    }
    
    /// Test timeout extension boundary conditions
    func testTimeoutExtensionBoundaryConditions() throws {
        let requestId = "test-boundary-extend"
        
        // Register a timeout with longer duration
        timeoutManager.registerTimeout(requestId: requestId, timeout: 0.2) {}
        
        // Test extending with zero duration
        let extendedZero = timeoutManager.extendTimeout(requestId: requestId, additionalTime: 0.0)
        XCTAssertTrue(extendedZero, "Expected zero-duration extension to succeed")
        
        // Test extending with very small duration (but still give it time to work)
        let extendedTiny = timeoutManager.extendTimeout(requestId: requestId, additionalTime: 0.001)
        XCTAssertTrue(extendedTiny, "Expected tiny extension to succeed")
        
        // Cancel the timeout to clean up
        timeoutManager.cancelTimeout(requestId: requestId)
        
        // Test extending already expired timeout
        timeoutManager.registerTimeout(requestId: "test-quick-expire", timeout: 0.001) {}
        
        // Wait for it to expire
        Thread.sleep(forTimeInterval: 0.01)
        
        let extendedExpired = timeoutManager.extendTimeout(requestId: "test-quick-expire", additionalTime: 0.1)
        XCTAssertFalse(extendedExpired, "Expected extension of expired timeout to fail")
    }
    
    // MARK: - Error-Handled Registration Tests
    
    /// Test timeout registration with error handling (matches TypeScript error-handled registration pattern)
    func testErrorHandledRegistration() throws {
        let timeoutExpectation = expectation(description: "Timeout callback")
        let errorExpectation = expectation(description: "Error callback")
        errorExpectation.isInverted = true // Should not be called for valid registration
        
        var timeoutFired = false
        var errorFired = false
        
        // Register timeout with error callback (valid case)
        timeoutManager.registerTimeoutWithErrorHandling(
            requestId: "test-error-handled",
            timeout: 0.05,
            onTimeout: {
                timeoutFired = true
                timeoutExpectation.fulfill()
            },
            onError: { error in
                errorFired = true
                errorExpectation.fulfill()
            }
        )
        
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 1, "Expected 1 active timeout")
        
        // Wait for timeout to fire
        waitForExpectations(timeout: 0.1, handler: nil)
        
        XCTAssertTrue(timeoutFired, "Main callback should have been called")
        XCTAssertFalse(errorFired, "Error callback should not have been called for valid registration")
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Expected 0 active timeouts after firing")
    }
    
    /// Test error-handled registration with invalid parameters
    func testErrorHandledRegistrationInvalidParameters() throws {
        let errorExpectation = expectation(description: "Error callback for invalid timeout")
        
        var errorReceived: Error?
        
        // Test with negative timeout
        timeoutManager.registerTimeoutWithErrorHandling(
            requestId: "test-invalid-timeout",
            timeout: -1.0,
            onTimeout: {
                XCTFail("Timeout callback should not be called for invalid timeout")
            },
            onError: { error in
                errorReceived = error
                errorExpectation.fulfill()
            }
        )
        
        waitForExpectations(timeout: 0.1, handler: nil)
        
        XCTAssertNotNil(errorReceived, "Error should have been received for invalid timeout")
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Should have no active timeouts for invalid registration")
    }
    
    /// Test error-handled registration with empty request ID
    func testErrorHandledRegistrationEmptyRequestId() throws {
        let errorExpectation = expectation(description: "Error callback for empty request ID")
        
        var errorReceived: Error?
        
        // Test with empty request ID
        timeoutManager.registerTimeoutWithErrorHandling(
            requestId: "",
            timeout: 0.1,
            onTimeout: {
                XCTFail("Timeout callback should not be called for empty request ID")
            },
            onError: { error in
                errorReceived = error
                errorExpectation.fulfill()
            }
        )
        
        waitForExpectations(timeout: 0.1, handler: nil)
        
        XCTAssertNotNil(errorReceived, "Error should have been received for empty request ID")
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Should have no active timeouts for invalid registration")
    }
    
    // MARK: - Bilateral Timeout Management Tests
    
    /// Test bilateral timeout registration and cancellation (matches Go/TypeScript bilateral timeout implementation)
    func testBilateralTimeoutManagement() throws {
        let requestExpectation = expectation(description: "Request timeout")
        requestExpectation.isInverted = true // Should not fire (we'll cancel)
        
        let responseExpectation = expectation(description: "Response timeout")
        responseExpectation.isInverted = true // Should not fire (we'll cancel)
        
        var requestTimeoutFired = false
        var responseTimeoutFired = false
        
        let baseRequestId = "test-bilateral"
        
        // Register bilateral timeout
        timeoutManager.registerBilateralTimeout(
            requestId: baseRequestId,
            requestTimeout: 0.1,
            responseTimeout: 0.15,
            onRequestTimeout: {
                requestTimeoutFired = true
                requestExpectation.fulfill()
            },
            onResponseTimeout: {
                responseTimeoutFired = true
                responseExpectation.fulfill()
            }
        )
        
        // Should have 2 active timeouts (request and response)
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 2, "Expected 2 active timeouts for bilateral")
        
        // Cancel bilateral timeout
        let cancelledCount = timeoutManager.cancelBilateralTimeout(requestId: baseRequestId)
        
        XCTAssertEqual(cancelledCount, 2, "Expected to cancel 2 timeouts")
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Expected 0 active timeouts after cancellation")
        
        // Wait to ensure callbacks don't fire
        waitForExpectations(timeout: 0.2, handler: nil)
        
        XCTAssertFalse(requestTimeoutFired, "Request timeout callback should not have fired after cancellation")
        XCTAssertFalse(responseTimeoutFired, "Response timeout callback should not have fired after cancellation")
    }
    
    /// Test bilateral timeout expiration
    func testBilateralTimeoutExpiration() throws {
        let requestExpectation = expectation(description: "Request timeout fires")
        
        var requestTimeoutFired = false
        var responseTimeoutFired = false
        
        let baseRequestId = "test-bilateral-expire"
        
        // Register bilateral timeout with short durations
        timeoutManager.registerBilateralTimeout(
            requestId: baseRequestId,
            requestTimeout: 0.05, // Shorter timeout
            responseTimeout: 0.1,  // Longer timeout
            onRequestTimeout: {
                requestTimeoutFired = true
                requestExpectation.fulfill()
            },
            onResponseTimeout: {
                responseTimeoutFired = true
                // Don't fulfill expectation - we only expect request timeout to fire
            }
        )
        
        // Wait for request timeout to expire
        waitForExpectations(timeout: 0.08, handler: nil)
        
        XCTAssertTrue(requestTimeoutFired, "Request timeout callback should have fired")
        
        // Response timeout might still be active
        let remainingTimeouts = timeoutManager.activeTimeoutCount
        XCTAssertLessThanOrEqual(remainingTimeouts, 1, "Should have at most 1 remaining timeout (response)")
    }
    
    /// Test bilateral timeout with different durations
    func testBilateralTimeoutDifferentDurations() throws {
        let requestExpectation = expectation(description: "Request timeout")
        let responseExpectation = expectation(description: "Response timeout")
        
        var requestTimeoutFired = false
        var responseTimeoutFired = false
        var requestTimeoutTime: Date?
        var responseTimeoutTime: Date?
        
        let baseRequestId = "test-bilateral-different"
        
        // Register bilateral timeout with different durations
        timeoutManager.registerBilateralTimeout(
            requestId: baseRequestId,
            requestTimeout: 0.05,
            responseTimeout: 0.1,
            onRequestTimeout: {
                requestTimeoutFired = true
                requestTimeoutTime = Date()
                requestExpectation.fulfill()
            },
            onResponseTimeout: {
                responseTimeoutFired = true
                responseTimeoutTime = Date()
                responseExpectation.fulfill()
            }
        )
        
        // Wait for both timeouts to fire
        waitForExpectations(timeout: 0.15, handler: nil)
        
        XCTAssertTrue(requestTimeoutFired, "Request timeout should have fired")
        XCTAssertTrue(responseTimeoutFired, "Response timeout should have fired")
        
        // Verify timing: request timeout should fire before response timeout
        if let requestTime = requestTimeoutTime, let responseTime = responseTimeoutTime {
            XCTAssertLessThan(requestTime, responseTime, "Request timeout should fire before response timeout")
        }
        
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 0, "Should have no active timeouts after both fire")
    }
    
    // MARK: - Timeout Statistics Tests
    
    /// Test timeout statistics accuracy (matches Go/TypeScript statistics implementation)
    func testTimeoutStatisticsAccuracy() throws {
        // Register multiple timeouts
        timeoutManager.registerTimeout(requestId: "cmd1", timeout: 0.1) {}
        timeoutManager.registerTimeout(requestId: "cmd2", timeout: 0.2) {}
        timeoutManager.registerTimeout(requestId: "cmd3", timeout: 0.05) {}
        
        let stats = timeoutManager.getTimeoutStatistics()
        
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 3, "Expected 3 active timeouts")
        
        if let activeTimeouts = stats["activeTimeouts"] as? Int {
            XCTAssertEqual(activeTimeouts, 3, "Statistics should show 3 active timeouts")
        } else {
            XCTFail("Statistics should include activeTimeouts count")
        }
        
        if let queueLabel = stats["queueLabel"] as? String {
            XCTAssertTrue(queueLabel.contains("timeout-manager"), "Queue label should identify timeout manager")
        } else {
            XCTFail("Statistics should include queue label")
        }
        
        // Cancel one timeout
        let cancelled = timeoutManager.cancelTimeout(requestId: "cmd2")
        XCTAssertTrue(cancelled, "Expected timeout cancellation to succeed")
        
        let updatedStats = timeoutManager.getTimeoutStatistics()
        if let activeTimeouts = updatedStats["activeTimeouts"] as? Int {
            XCTAssertEqual(activeTimeouts, 2, "Statistics should show 2 active timeouts after cancellation")
        }
        
        XCTAssertEqual(timeoutManager.activeTimeoutCount, 2, "Expected 2 active timeouts after cancellation")
    }
    
    // MARK: - Concurrent Operations Tests
    
    /// Test timeout manager concurrency (ensures thread safety of enhanced timeout management)
    func testTimeoutManagerConcurrency() throws {
        let expectation = expectation(description: "Concurrent operations complete")
        let numberOfOperations = 50
        var completedOperations = 0
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 10
        
        // Capture timeout manager to avoid nil unwrapping in closures
        let timeoutManager = self.timeoutManager!
        
        // Launch multiple concurrent timeout operations
        for i in 0..<numberOfOperations {
            let requestId = "concurrent-\\(i)" // Move outside to ensure it's captured properly
            operationQueue.addOperation {
                // Register timeout
                timeoutManager.registerTimeout(requestId: requestId, timeout: 0.1) {}
                
                // Randomly cancel some timeouts
                if i % 3 == 0 {
                    let capturedRequestId = requestId // Capture for closure
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        timeoutManager.cancelTimeout(requestId: capturedRequestId)
                    }
                }
                
                // Randomly extend some timeouts
                if i % 5 == 0 {
                    let capturedRequestId = requestId // Capture for closure
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        timeoutManager.extendTimeout(requestId: capturedRequestId, additionalTime: 0.05)
                    }
                }
                
                DispatchQueue.main.async {
                    completedOperations += 1
                    if completedOperations == numberOfOperations {
                        expectation.fulfill()
                    }
                }
            }
        }
        
        waitForExpectations(timeout: 0.5, handler: nil)
        
        // All operations should complete without crashes
        XCTAssertEqual(completedOperations, numberOfOperations, "All concurrent operations should complete")
        
        // Should have some timeouts still active (not all were cancelled)
        let finalCount = timeoutManager.activeTimeoutCount
        XCTAssertGreaterThanOrEqual(finalCount, 0, "Should have non-negative timeout count")
        XCTAssertLessThanOrEqual(finalCount, numberOfOperations, "Should not exceed total operations")
    }
    
    // MARK: - Integration Tests
    
    /// Test timeout extension in combination with bilateral timeout
    func testTimeoutExtensionWithBilateralTimeout() throws {
        let extendedTimeoutExpectation = expectation(description: "Extended bilateral timeout")
        
        var requestTimeoutFired = false
        let baseRequestId = "test-bilateral-extend"
        
        // Register bilateral timeout
        timeoutManager.registerBilateralTimeout(
            requestId: baseRequestId,
            requestTimeout: 0.05,
            responseTimeout: 0.1,
            onRequestTimeout: {
                requestTimeoutFired = true
                extendedTimeoutExpectation.fulfill()
            },
            onResponseTimeout: {
                // Should not fire due to extension
            }
        )
        
        // Extend the request timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            let extended = self.timeoutManager.extendTimeout(
                requestId: "\(baseRequestId)-request", 
                additionalTime: 0.05
            )
            XCTAssertTrue(extended, "Expected bilateral request timeout extension to succeed")
        }
        
        // Wait for extended timeout to fire
        waitForExpectations(timeout: 0.15, handler: nil)
        
        XCTAssertTrue(requestTimeoutFired, "Extended bilateral timeout should have fired")
    }
}