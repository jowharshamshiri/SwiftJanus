import XCTest
@testable import SwiftJanus

/**
 * Comprehensive RequestHandler Tests for Swift Janus Implementation
 * Tests all direct value response handlers, async patterns, error handling, and JSON-RPC error mapping
 * Matches Go and TypeScript test coverage for cross-platform parity
 */
final class RequestHandlerTests: XCTestCase {
    
    // MARK: - Helper Functions
    
    private func createTestRequest(
        id: String = "test-id",
        channelId: String = "test-channel", 
        request: String = "test-request",
        args: [String: AnyCodable] = [:],
        replyTo: String = "/tmp/test-reply.sock"
    ) -> JanusRequest {
        return JanusRequest(
            id: id,
            channelId: channelId,
            request: request,
            replyTo: replyTo,
            args: args,
            timestamp: Date().timeIntervalSince1970
        )
    }
    
    // MARK: - Direct Value Handler Tests
    
    func testBoolHandler() async {
        // Test boolean handler returning true
        let handler = boolHandler { _ in
            return .success(true)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, true, "Boolean handler should return true")
        case .error(let error):
            XCTFail("Boolean handler should not return error: \(error)")
        }
    }
    
    func testStringHandler() async {
        // Test string handler returning test response
        let handler = stringHandler { _ in
            return .success("test response")
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, "test response", "String handler should return 'test response'")
        case .error(let error):
            XCTFail("String handler should not return error: \(error)")
        }
    }
    
    func testIntHandler() async {
        // Test integer handler returning 42
        let handler = intHandler { _ in
            return .success(42)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, 42, "Int handler should return 42")
        case .error(let error):
            XCTFail("Int handler should not return error: \(error)")
        }
    }
    
    func testDoubleHandler() async {
        // Test double handler returning 3.14
        let handler = doubleHandler { _ in
            return .success(3.14)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, 3.14, accuracy: 0.001, "Double handler should return 3.14")
        case .error(let error):
            XCTFail("Double handler should not return error: \(error)")
        }
    }
    
    func testArrayHandler() async {
        // Test array handler returning mixed array
        let testArray = ["item1", "item2", "item3"]
        let handler = arrayHandler { _ in
            return .success(testArray)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, testArray, "Array handler should return test array")
        case .error(let error):
            XCTFail("Array handler should not return error: \(error)")
        }
    }
    
    func testObjectHandler() async {
        // Test custom object handler
        struct TestUser: Codable, Equatable {
            let id: Int
            let name: String
        }
        
        let testUser = TestUser(id: 123, name: "Test User")
        let handler = objectHandler { _ in
            return .success(testUser)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, testUser, "Object handler should return test user")
        case .error(let error):
            XCTFail("Object handler should not return error: \(error)")
        }
    }
    
    // MARK: - Async Handler Tests
    
    func testAsyncBoolHandler() async {
        // Test async boolean handler with timing verification
        let handler = asyncBoolHandler { _ in
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
            return .success(true)
        }
        
        let request = createTestRequest()
        let startTime = Date()
        let result = await handler.handle(request)
        let duration = Date().timeIntervalSince(startTime)
        
        // Verify it took some time (async execution)
        XCTAssertGreaterThan(duration, 0.01, "Async execution should take at least 10ms")
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, true, "Async boolean handler should return true")
        case .error(let error):
            XCTFail("Async boolean handler should not return error: \(error)")
        }
    }
    
    func testAsyncStringHandler() async {
        // Test async string handler with timing verification
        let handler = asyncStringHandler { _ in
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
            return .success("async response")
        }
        
        let request = createTestRequest()
        let startTime = Date()
        let result = await handler.handle(request)
        let duration = Date().timeIntervalSince(startTime)
        
        // Verify it took some time (async execution) 
        XCTAssertGreaterThan(duration, 0.01, "Async execution should take at least 10ms")
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, "async response", "Async string handler should return 'async response'")
        case .error(let error):
            XCTFail("Async string handler should not return error: \(error)")
        }
    }
    
    func testAsyncIntHandler() async {
        // Test async integer handler
        let handler = asyncIntHandler { _ in
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
            return .success(99)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, 99, "Async int handler should return 99")
        case .error(let error):
            XCTFail("Async int handler should not return error: \(error)")
        }
    }
    
    func testAsyncDoubleHandler() async {
        // Test async double handler
        let handler = asyncDoubleHandler { _ in
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
            return .success(2.718)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, 2.718, accuracy: 0.001, "Async double handler should return 2.718")
        case .error(let error):
            XCTFail("Async double handler should not return error: \(error)")
        }
    }
    
    func testAsyncArrayHandler() async {
        // Test async array handler
        let testArray = [1, 2, 3, 4, 5]
        let handler = asyncArrayHandler { _ in
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
            return .success(testArray)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, testArray, "Async array handler should return test array")
        case .error(let error):
            XCTFail("Async array handler should not return error: \(error)")
        }
    }
    
    func testAsyncObjectHandler() async {
        // Test async custom object handler
        struct TestResponse: Codable, Equatable {
            let success: Bool
            let message: String
            let data: [String: Int]
        }
        
        let testResponse = TestResponse(
            success: true,
            message: "Operation completed",
            data: ["userId": 456]
        )
        
        let handler = asyncObjectHandler { _ in
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
            return .success(testResponse)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, testResponse, "Async object handler should return test response")
        case .error(let error):
            XCTFail("Async object handler should not return error: \(error)")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testSyncHandlerErrorHandling() async {
        // Test synchronous handler error handling
        let handler = stringHandler { _ in
            return .failure(NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "sync handler error"]))
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success:
            XCTFail("Handler should return error, not success")
        case .error(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.internalError.rawValue, "Error should map to internal error")
            XCTAssertNotNil(error.data?.details, "Error should have details")
        }
    }
    
    func testAsyncHandlerErrorHandling() async {
        // Test asynchronous handler error handling
        let handler = asyncStringHandler { _ in
            return .failure(NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "async handler error"]))
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success:
            XCTFail("Async handler should return error, not success")
        case .error(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.internalError.rawValue, "Error should map to internal error")
            XCTAssertNotNil(error.data?.details, "Error should have details")
        }
    }
    
    func testJSONRPCErrorHandling() async {
        // Test JSON-RPC error handling
        let handler = stringHandler { _ in
            let jsonrpcError = JSONRPCError.create(
                code: .invalidParams,
                details: "Invalid parameters provided"
            )
            return .failure(jsonrpcError)
        }
        
        let request = createTestRequest()
        let result = await handler.handle(request)
        
        switch result {
        case .success:
            XCTFail("Handler should return JSON-RPC error, not success")
        case .error(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams.rawValue, "Error code should be invalid params")
            XCTAssertEqual(error.data?.details, "Invalid parameters provided", "Should preserve custom error message")
        }
    }
    
    // MARK: - Handler Registry Tests
    
    func testHandlerRegistry() async {
        let registry = HandlerRegistry(maxHandlers: 10)
        
        // Test handler registration
        let handler = stringHandler { _ in
            return .success("registry test")
        }
        
        do {
            try await registry.registerHandler("test-request", handler: handler)
        } catch {
            XCTFail("Handler registration should not fail: \(error)")
            return
        }
        
        // Test handler existence
        let hasHandler = await registry.hasHandler("test-request")
        XCTAssertTrue(hasHandler, "Registry should have registered handler")
        
        // Test handler execution
        let request = createTestRequest(request: "test-request")
        let result = await registry.executeHandler("test-request", request)
        
        switch result {
        case .success(let value):
            if let stringValue = value as? String {
                XCTAssertEqual(stringValue, "registry test", "Handler should return expected value")
            } else {
                XCTFail("Result should be string type")
            }
        case .failure(let error):
            XCTFail("Handler execution should not fail: \(error)")
        }
        
        // Test handler count
        let count = await registry.handlerCount()
        XCTAssertEqual(count, 1, "Registry should have 1 handler")
        
        // Test handler unregistration
        let removed = await registry.unregisterHandler("test-request")
        XCTAssertTrue(removed, "Handler should be successfully unregistered")
        
        let hasHandlerAfterRemoval = await registry.hasHandler("test-request")
        XCTAssertFalse(hasHandlerAfterRemoval, "Registry should not have handler after removal")
    }
    
    func testHandlerRegistryLimits() async {
        let registry = HandlerRegistry(maxHandlers: 2)
        
        // Register maximum number of handlers
        let handler1 = stringHandler { _ in .success("handler1") }
        let handler2 = stringHandler { _ in .success("handler2") }
        let handler3 = stringHandler { _ in .success("handler3") }
        
        do {
            try await registry.registerHandler("cmd1", handler: handler1)
            try await registry.registerHandler("cmd2", handler: handler2)
        } catch {
            XCTFail("First two registrations should succeed: \(error)")
            return
        }
        
        // Third registration should fail
        do {
            try await registry.registerHandler("cmd3", handler: handler3)
            XCTFail("Third registration should fail due to limit")
        } catch {
            // Expected error - limit exceeded
            XCTAssertTrue(error is JSONRPCError, "Error should be JSONRPCError type")
        }
        
        let count = await registry.handlerCount()
        XCTAssertEqual(count, 2, "Registry should have exactly 2 handlers")
    }
    
    func testHandlerRegistryNotFound() async {
        let registry = HandlerRegistry()
        
        let request = createTestRequest(request: "nonexistent-request")
        let result = await registry.executeHandler("nonexistent-request", request)
        
        switch result {
        case .success:
            XCTFail("Execution should fail for nonexistent handler")
        case .failure(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.methodNotFound.rawValue, "Error should be method not found")
            XCTAssertTrue(error.data?.details?.contains("Request not found") == true, "Error should mention request not found")
        }
    }
    
    // MARK: - Handler Arguments Tests
    
    func testHandlerArgumentAccess() async {
        // Test handler can access and process request arguments
        struct ProcessedData: Codable, Equatable {
            let processedName: String
            let processedAge: Int
            let originalRequest: String
        }
        
        let handler: SyncHandler<ProcessedData> = objectHandler { request in
            guard let args = request.args,
                  let name = args["name"]?.value as? String,
                  let ageDouble = args["age"]?.value as? Double else {
                return .failure(NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing required arguments"]))
            }
            
            let processedData = ProcessedData(
                processedName: "Hello, \(name)",
                processedAge: Int(ageDouble) + 1,
                originalRequest: request.request
            )
            
            return .success(processedData)
        }
        
        let request = createTestRequest(
            request: "process-user",
            args: ["name": AnyCodable("John"), "age": AnyCodable(25.0)]
        )
        
        let result = await handler.handle(request)
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value.processedName, "Hello, John", "Name should be processed correctly")
            XCTAssertEqual(value.processedAge, 26, "Age should be incremented by 1")
            XCTAssertEqual(value.originalRequest, "process-user", "Original request should be preserved")
        case .error(let error):
            XCTFail("Handler should not return error: \(error)")
        }
    }
    
    func testHandlerArgumentValidation() async {
        // Test handler validates required arguments
        let handler = stringHandler { request in
            guard let args = request.args,
                  let name = args["name"]?.value as? String,
                  args["age"]?.value as? Double != nil else {
                return .failure(JSONRPCError.create(
                    code: .invalidParams,
                    details: "Missing required arguments: name and age"
                ))
            }
            
            return .success("Hello, \(name)")
        }
        
        // Test with missing age argument
        let request = createTestRequest(args: ["name": AnyCodable("John")])
        let result = await handler.handle(request)
        
        switch result {
        case .success:
            XCTFail("Handler should return error for missing arguments")
        case .error(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams.rawValue, "Error should be invalid params")
            XCTAssertTrue(error.data?.details?.contains("Missing required arguments") == true, "Error should mention missing arguments")
        }
    }
    
    // MARK: - HandlerResult Utility Tests
    
    func testHandlerResultSuccess() {
        let result = HandlerResult<String>.withValue("test value")
        
        switch result {
        case .success(let value):
            XCTAssertEqual(value, "test value", "HandlerResult should contain test value")
        case .error:
            XCTFail("HandlerResult should be success, not error")
        }
    }
    
    func testHandlerResultError() {
        let error = JSONRPCError.create(code: .internalError, details: "Test error")
        let result = HandlerResult<String>.withError(error)
        
        switch result {
        case .success:
            XCTFail("HandlerResult should be error, not success")
        case .error(let resultError):
            XCTAssertEqual(resultError.code, JSONRPCErrorCode.internalError.rawValue, "HandlerResult should contain error")
            XCTAssertEqual(resultError.data?.details, "Test error", "Error should have correct details")
        }
    }
    
    func testHandlerResultFromSwiftResult() {
        // Test success case
        let successResult: Result<String, Error> = .success("success value")
        let handlerResult = HandlerResult.from(successResult)
        
        switch handlerResult {
        case .success(let value):
            XCTAssertEqual(value, "success value", "HandlerResult should contain success value")
        case .error:
            XCTFail("HandlerResult should be success")
        }
        
        // Test error case
        let errorResult: Result<String, Error> = .failure(NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "test error"]))
        let handlerErrorResult = HandlerResult.from(errorResult)
        
        switch handlerErrorResult {
        case .success:
            XCTFail("HandlerResult should be error")
        case .error(let error):
            XCTAssertEqual(error.code, JSONRPCErrorCode.internalError.rawValue, "Error should be mapped to internal error")
            XCTAssertNotNil(error.data?.details, "Error should have details")
        }
    }
}