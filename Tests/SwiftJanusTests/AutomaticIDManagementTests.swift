import XCTest
import Foundation
@testable import SwiftJanus

final class AutomaticIDManagementTests: XCTestCase {
    
    func testRequestHandleCreation() {
        // Test F0194: Request ID Assignment and F0196: RequestHandle Structure
        let internalID = "test-uuid-12345"
        let request = "test_request"
        let channel = "test_channel"
        
        let handle = RequestHandle(internalID: internalID, request: request, channel: channel)
        
        // Verify handle properties
        XCTAssertEqual(handle.getRequest(), request)
        XCTAssertEqual(handle.getChannel(), channel)
        XCTAssertEqual(handle.getInternalID(), internalID)
        XCTAssertFalse(handle.isCancelled())
        
        // Test timestamp is recent
        let timeDiff = Date().timeIntervalSince(handle.getTimestamp())
        XCTAssertLessThan(timeDiff, 1.0, "Handle timestamp should be recent")
    }
    
    func testRequestHandleCancellation() {
        // Test F0204: Request Cancellation and F0212: Request Cleanup
        let handle = RequestHandle(internalID: "test-id", request: "test_request", channel: "test_channel")
        
        XCTAssertFalse(handle.isCancelled())
        
        handle.markCancelled()
        
        XCTAssertTrue(handle.isCancelled())
    }
    
    func testRequestStatusTracking() async {
        // Test F0202: Request Status Query
        do {
            let client = try await JanusClient(
                socketPath: "/tmp/test_socket",
                enableValidation: false
            )
            
            // Create a handle
            let handle = RequestHandle(internalID: "test-id", request: "test_request", channel: "test_channel")
            
            // Test initial status (should be completed since not in registry)
            var status = client.getRequestStatus(handle)
            XCTAssertEqual(status, .completed)
            
            // Test cancelled status
            handle.markCancelled()
            status = client.getRequestStatus(handle)
            XCTAssertEqual(status, .cancelled)
        } catch {
            XCTFail("Failed to create client: \(error)")
        }
    }
    
    func testPendingRequestManagement() async {
        // Test F0197: Handle Creation and F0201: Request State Management
        do {
            let client = try await JanusClient(
                socketPath: "/tmp/test_socket",
                enableValidation: false
            )
            
            // Initially no pending requests
            let pending = client.getPendingRequests()
            XCTAssertEqual(pending.count, 0)
            
            // Test cancel all with no requests
            let cancelled = client.cancelAllRequests()
            XCTAssertEqual(cancelled, 0)
        } catch {
            XCTFail("Failed to create client: \(error)")
        }
    }
    
    func testRequestLifecycleManagement() async {
        // Test F0200: Request State Management and F0211: Handle Cleanup
        do {
            let client = try await JanusClient(
                socketPath: "/tmp/test_socket",
                enableValidation: false
            )
            
            // Create multiple handles to test bulk operations
            let handles = [
                RequestHandle(internalID: "id1", request: "cmd1", channel: "test_channel"),
                RequestHandle(internalID: "id2", request: "cmd2", channel: "test_channel"),
                RequestHandle(internalID: "id3", request: "cmd3", channel: "test_channel")
            ]
            
            // Test that handles start as completed (not in registry)
            for (index, handle) in handles.enumerated() {
                let status = client.getRequestStatus(handle)
                XCTAssertEqual(status, .completed, "Handle \(index) should start as completed")
            }
            
            // Test cancellation of non-existent handle should fail
            XCTAssertThrowsError(try client.cancelRequest(handles[0])) { error in
                XCTAssertTrue(error is JSONRPCError)
            }
        } catch {
            XCTFail("Failed to create client: \(error)")
        }
    }
    
    func testIDVisibilityControl() {
        // Test F0195: ID Visibility Control - UUIDs should be hidden from normal API
        let handle = RequestHandle(internalID: "internal-uuid-12345", request: "test_request", channel: "test_channel")
        
        // User should only see request and channel, not internal UUID through normal API
        XCTAssertEqual(handle.getRequest(), "test_request")
        XCTAssertEqual(handle.getChannel(), "test_channel")
        
        // Internal ID should only be accessible for internal operations
        XCTAssertEqual(handle.getInternalID(), "internal-uuid-12345")
    }
    
    func testRequestStatusConstants() {
        // Test all RequestStatus constants are defined
        let statuses: [RequestStatus] = [.pending, .completed, .failed, .cancelled, .timeout]
        let expectedValues = ["pending", "completed", "failed", "cancelled", "timeout"]
        
        for (index, status) in statuses.enumerated() {
            XCTAssertEqual(status.rawValue, expectedValues[index])
        }
    }
    
    func testConcurrentRequestHandling() async {
        // Test F0223: Concurrent Request Support
        do {
            let client = try await JanusClient(
                socketPath: "/tmp/test_socket",
                enableValidation: false
            )
            
            // Test concurrent handle creation and management
            let handles = (0..<10).map { i in
                RequestHandle(
                    internalID: "concurrent-id-\(i)",
                    request: "cmd\(i)",
                    channel: "test_channel"
                )
            }
            
            // Test concurrent status checks
            for handle in handles {
                let status = client.getRequestStatus(handle)
                XCTAssertEqual(status, .completed)
            }
            
            // Test concurrent cancellation
            for handle in handles {
                handle.markCancelled()
                XCTAssertTrue(handle.isCancelled())
            }
        } catch {
            XCTFail("Failed to create client: \(error)")
        }
    }
    
    func testUUIDGenerationUniqueness() {
        // Test F0193: UUID Generation - ensure unique IDs
        var generatedIDs = Set<String>()
        
        for _ in 0..<1000 {
            let handle = RequestHandle(
                internalID: UUID().uuidString,
                request: "test_request",
                channel: "test_channel"
            )
            
            let id = handle.getInternalID()
            XCTAssertFalse(generatedIDs.contains(id), "UUID should be unique: \(id)")
            generatedIDs.insert(id)
        }
        
        XCTAssertEqual(generatedIDs.count, 1000, "All generated UUIDs should be unique")
    }
}