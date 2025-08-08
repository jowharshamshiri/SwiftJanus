// ResponseValidatorTests.swift
// Comprehensive tests for Swift ResponseValidator
// Validates all response validation scenarios against Manifests

import XCTest
@testable import SwiftJanus

final class ResponseValidatorTests: XCTestCase {
    var validator: ResponseValidator!
    var testManifest: Manifest!
    
    override func setUp() {
        super.setUp()
        
        // Create test Manifest matching TypeScript/Go test structure
        testManifest = Manifest(
            version: "1.0.0",
            name: "Test API",
            models: [
                    requests: [
                        "ping": RequestManifest(
                            name: "ping",
                            description: "Basic ping request",
                            response: ResponseManifest(
                                type: .object,
                                properties: [
                                    "status": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Status message"
                                    ),
                                    "echo": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Echo message"
                                    ),
                                    "timestamp": ArgumentManifest(
                                        type: .number,
                                        required: true,
                                        description: "Response timestamp"
                                    ),
                                    "server_id": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Server identifier"
                                    ),
                                    "request_count": ArgumentManifest(
                                        type: .number,
                                        required: false,
                                        description: "Request count"
                                    ),
                                    "metadata": ArgumentManifest(
                                        type: .object,
                                        required: false,
                                        description: "Optional metadata"
                                    )
                                ],
                                description: "Ping response"
                            )
                        ),
                        "get_info": RequestManifest(
                            name: "get_info",
                            description: "Get server information",
                            response: ResponseManifest(
                                type: .object,
                                properties: [
                                    "implementation": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Implementation language"
                                    ),
                                    "version": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Version string",
                                        validation: ValidationManifest(pattern: "^\\d+\\.\\d+\\.\\d+$")
                                    ),
                                    "protocol": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Protocol type",
                                        validation: ValidationManifest(enum: [AnyCodable("SOCK_DGRAM")])
                                    )
                                ],
                                description: "Server information"
                            )
                        ),
                        "range_test": RequestManifest(
                            name: "range_test",
                            description: "Numeric range validation test",
                            response: ResponseManifest(
                                type: .object,
                                properties: [
                                    "score": ArgumentManifest(
                                        type: .number,
                                        required: true,
                                        description: "Test score",
                                        validation: ValidationManifest(minimum: 0, maximum: 100)
                                    ),
                                    "grade": ArgumentManifest(
                                        type: .string,
                                        required: true,
                                        description: "Letter grade",
                                        validation: ValidationManifest(enum: [
                                            AnyCodable("A"), AnyCodable("B"), AnyCodable("C"), 
                                            AnyCodable("D"), AnyCodable("F")
                                        ])
                                    ),
                                    "count": ArgumentManifest(
                                        type: .integer,
                                        required: true,
                                        description: "Item count",
                                        validation: ValidationManifest(minimum: 1)
                                    )
                                ],
                                description: "Range test response"
                            )
                        ),
                        "array_test": RequestManifest(
                            name: "array_test",
                            description: "Array validation test",
                            response: ResponseManifest(
                                type: .object,
                                properties: [
                                    "items": ArgumentManifest(
                                        type: .array,
                                        required: true,
                                        description: "Array of strings",
                                        items: ArgumentManifest(type: .string, description: "String item")
                                    ),
                                    "numbers": ArgumentManifest(
                                        type: .array,
                                        required: false,
                                        description: "Array of numbers",
                                        items: ArgumentManifest(type: .number, description: "Number item")
                                    )
                                ],
                                description: "Array test response"
                            )
                        )
                    ]
                )
            ],
            models: [
                "UserInfo": ModelManifest(
                    type: .object,
                    properties: [
                        "id": ArgumentManifest(
                            type: .string,
                            required: true,
                            description: "User ID"
                        ),
                        "name": ArgumentManifest(
                            type: .string,
                            required: true,
                            description: "User name",
                            validation: ValidationManifest(minLength: 1, maxLength: 100)
                        ),
                        "age": ArgumentManifest(
                            type: .integer,
                            required: false,
                            description: "User age",
                            validation: ValidationManifest(minimum: 0, maximum: 150)
                        )
                    ],
                    required: ["id", "name"],
                    description: "User information model"
                )
            ]
        )
        
        validator = ResponseValidator(manifest: testManifest)
    }
    
    override func tearDown() {
        validator = nil
        testManifest = nil
        super.tearDown()
    }
    
    // MARK: - Basic Response Validation Tests
    
    func testValidateCorrectPingResponse() {
        let response: [String: Any] = [
            "status": "ok",
            "echo": "test message",
            "timestamp": 1234567890.0,
            "server_id": "server-001"
        ]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "ping")
        
        XCTAssertTrue(result.valid, "Expected valid response, got invalid with errors: \(result.errors)")
        XCTAssertEqual(result.errors.count, 0, "Expected no errors")
        XCTAssertEqual(result.fieldsValidated, 6, "Expected 6 fields validated")
        XCTAssertGreaterThan(result.validationTime, 0, "Expected positive validation time")
    }
    
    func testValidateResponseWithOptionalFields() {
        let response: [String: Any] = [
            "status": "ok",
            "echo": "test message",
            "timestamp": 1234567890.0,
            "server_id": "server-001",
            "request_count": 42.0,
            "metadata": ["custom": "data"]
        ]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "ping")
        
        XCTAssertTrue(result.valid, "Expected valid response, got invalid with errors: \(result.errors)")
        XCTAssertEqual(result.errors.count, 0, "Expected no errors")
    }
    
    func testFailValidationForMissingRequiredFields() {
        let response: [String: Any] = [
            "status": "ok",
            "echo": "test message"
            // Missing timestamp and server_id
        ]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "ping")
        
        XCTAssertFalse(result.valid, "Expected invalid response")
        XCTAssertEqual(result.errors.count, 2, "Expected 2 errors")
        
        let fieldNames = result.errors.map { $0.field }
        XCTAssertTrue(fieldNames.contains("timestamp"), "Expected timestamp error")
        XCTAssertTrue(fieldNames.contains("server_id"), "Expected server_id error")
        
        let hasRequiredFieldError = result.errors.allSatisfy { $0.message.contains("Required field is missing") }
        XCTAssertTrue(hasRequiredFieldError, "Expected required field error messages")
    }
    
    func testFailValidationForIncorrectTypes() {
        let response: [String: Any] = [
            "status": 123,         // Should be string
            "echo": true,          // Should be string
            "timestamp": "1234567890", // Should be number
            "server_id": NSNull()  // Should be string, null not allowed for required field
        ]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "ping")
        
        XCTAssertFalse(result.valid, "Expected invalid response")
        XCTAssertEqual(result.errors.count, 4, "Expected 4 errors")
    }
    
    // MARK: - Type-Manifestific Validation Tests
    
    func testValidateStringPatterns() {
        let validResponse: [String: Any] = [
            "implementation": "Swift",
            "version": "1.2.3",
            "protocol": "SOCK_DGRAM"
        ]
        
        let result = validator.validateRequestResponse(validResponse, channelId: "test", requestName: "get_info")
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        
        let invalidResponse: [String: Any] = [
            "implementation": "Swift",
            "version": "1.2", // Invalid pattern - should be x.y.z
            "protocol": "SOCK_DGRAM"
        ]
        
        let invalidResult = validator.validateRequestResponse(invalidResponse, channelId: "test", requestName: "get_info")
        XCTAssertFalse(invalidResult.valid, "Expected invalid response")
        
        let hasPatternError = invalidResult.errors.contains { 
            $0.field == "version" && $0.message.contains("pattern") 
        }
        XCTAssertTrue(hasPatternError, "Expected pattern validation error for version field")
    }
    
    func testValidateEnumValues() {
        let validResponse: [String: Any] = [
            "implementation": "Swift",
            "version": "1.0.0",
            "protocol": "SOCK_DGRAM"
        ]
        
        let result = validator.validateRequestResponse(validResponse, channelId: "test", requestName: "get_info")
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        
        let invalidResponse: [String: Any] = [
            "implementation": "Swift",
            "version": "1.0.0",
            "protocol": "SOCK_STREAM" // Invalid enum value
        ]
        
        let invalidResult = validator.validateRequestResponse(invalidResponse, channelId: "test", requestName: "get_info")
        XCTAssertFalse(invalidResult.valid, "Expected invalid response")
        
        let hasEnumError = invalidResult.errors.contains { 
            $0.field == "protocol" && $0.message.contains("enum") 
        }
        XCTAssertTrue(hasEnumError, "Expected enum validation error for protocol field")
    }
    
    func testValidateNumericRanges() {
        let validResponse: [String: Any] = [
            "score": 85.5,
            "grade": "B",
            "count": 10
        ]
        
        let result = validator.validateRequestResponse(validResponse, channelId: "test", requestName: "range_test")
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        
        let invalidResponse: [String: Any] = [
            "score": 150.0, // > maximum of 100
            "grade": "X",   // Invalid enum
            "count": 0      // < minimum of 1
        ]
        
        let invalidResult = validator.validateRequestResponse(invalidResponse, channelId: "test", requestName: "range_test")
        XCTAssertFalse(invalidResult.valid, "Expected invalid response")
        XCTAssertEqual(invalidResult.errors.count, 3, "Expected 3 errors")
        
        let hasScoreError = invalidResult.errors.contains { 
            $0.field == "score" && $0.message.contains("too large") 
        }
        let hasGradeError = invalidResult.errors.contains { 
            $0.field == "grade" && $0.message.contains("enum") 
        }
        let hasCountError = invalidResult.errors.contains { 
            $0.field == "count" && $0.message.contains("too small") 
        }
        
        XCTAssertTrue(hasScoreError, "Expected score error")
        XCTAssertTrue(hasGradeError, "Expected grade error")
        XCTAssertTrue(hasCountError, "Expected count error")
    }
    
    func testValidateIntegersVsNumbers() {
        let validResponse: [String: Any] = [
            "score": 85.5, // number is fine
            "grade": "B",
            "count": 10    // integer is fine
        ]
        
        let result = validator.validateRequestResponse(validResponse, channelId: "test", requestName: "range_test")
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        
        let invalidResponse: [String: Any] = [
            "score": 85,
            "grade": "B",
            "count": 10.5 // Should be integer, not float
        ]
        
        let invalidResult = validator.validateRequestResponse(invalidResponse, channelId: "test", requestName: "range_test")
        XCTAssertFalse(invalidResult.valid, "Expected invalid response")
        
        let hasIntegerError = invalidResult.errors.contains { 
            $0.field == "count" && $0.message.contains("integer") 
        }
        XCTAssertTrue(hasIntegerError, "Expected integer validation error for count field")
    }
    
    func testValidateArrays() {
        let validResponse: [String: Any] = [
            "items": ["hello", "world"],
            "numbers": [1, 2, 3.5]
        ]
        
        let result = validator.validateRequestResponse(validResponse, channelId: "test", requestName: "array_test")
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        
        let invalidResponse: [String: Any] = [
            "items": [123, true], // Should be strings
            "numbers": ["not", "numbers"] // Should be numbers
        ]
        
        let invalidResult = validator.validateRequestResponse(invalidResponse, channelId: "test", requestName: "array_test")
        
        // Array item validation is now implemented in Swift (matching Go/TypeScript)
        // This should validate individual item types and reject invalid arrays
        XCTAssertFalse(invalidResult.valid, "Expected invalid response for mismatched array item types")
        
        // Verify manifestific validation errors for array items
        XCTAssertTrue(invalidResult.errors.contains { $0.field.contains("[") }, 
                     "Should have array index validation errors")
    }
    
    // MARK: - Error Handling Tests
    
    func testHandleMissingChannel() {
        let response: [String: Any] = ["status": "ok"]
        
        let result = validator.validateRequestResponse(response, channelId: "nonexistent", requestName: "ping")
        
        XCTAssertFalse(result.valid, "Expected invalid response")
        XCTAssertEqual(result.errors.count, 1, "Expected 1 error")
        XCTAssertEqual(result.errors[0].field, "channelId", "Expected channelId field error")
        XCTAssertTrue(result.errors[0].message.contains("Channel 'nonexistent' not found"), "Expected channel not found message")
    }
    
    func testHandleMissingRequest() {
        let response: [String: Any] = ["status": "ok"]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "nonexistent")
        
        XCTAssertFalse(result.valid, "Expected invalid response")
        XCTAssertEqual(result.errors.count, 1, "Expected 1 error")
        XCTAssertEqual(result.errors[0].field, "request", "Expected request field error")
        XCTAssertTrue(result.errors[0].message.contains("Request 'nonexistent' not found"), "Expected request not found message")
    }
    
    func testHandleMissingResponseManifest() {
        // Create a request without response manifest
        var modifiedManifest = testManifest!
        var testChannel = modifiedManifest.channels["test"]!
        testChannel = ChannelManifest(
            name: testChannel.name,
            description: testChannel.description,
            requests: testChannel.requests.merging([
                "no_response": RequestManifest(
                    name: "no_response",
                    description: "Request without response manifest"
                    // No response field
                )
            ]) { _, new in new }
        )
        modifiedManifest = Manifest(
            version: modifiedManifest.version,
            name: modifiedManifest.name,
            channels: modifiedManifest.channels.merging(["test": testChannel]) { _, new in new },
            models: modifiedManifest.models
        )
        
        let modifiedValidator = ResponseValidator(manifest: modifiedManifest)
        let response: [String: Any] = ["status": "ok"]
        
        let result = modifiedValidator.validateRequestResponse(response, channelId: "test", requestName: "no_response")
        
        XCTAssertFalse(result.valid, "Expected invalid response")
        XCTAssertEqual(result.errors.count, 1, "Expected 1 error")
        XCTAssertEqual(result.errors[0].field, "response", "Expected response field error")
        XCTAssertTrue(result.errors[0].message.contains("No response manifest defined"), "Expected no response manifest message")
    }
    
    // MARK: - Performance Tests
    
    func testCompleteValidationWithinPerformanceRequirements() {
        let response: [String: Any] = [
            "status": "ok",
            "echo": "test message",
            "timestamp": 1234567890.0,
            "server_id": "server-001",
            "request_count": 42.0,
            "metadata": [
                "custom": "data",
                "nested": ["deep": "value"]
            ]
        ]
        
        let result = validator.validateRequestResponse(response, channelId: "test", requestName: "ping")
        
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        XCTAssertLessThan(result.validationTime, 2.0, "Expected validation time < 2ms, got \(result.validationTime) ms")
    }
    
    func testHandleLargeResponsesEfficiently() {
        let largeItems = (0..<1000).map { "item-\($0)" }
        let largeNumbers = (0..<1000).map { Double($0) }
        
        let largeResponse: [String: Any] = [
            "items": largeItems,
            "numbers": largeNumbers
        ]
        
        let result = validator.validateRequestResponse(largeResponse, channelId: "test", requestName: "array_test")
        
        XCTAssertTrue(result.valid, "Expected valid response, got errors: \(result.errors)")
        XCTAssertLessThan(result.validationTime, 10.0, "Expected validation time < 10ms for large response, got \(result.validationTime) ms")
    }
    
    // MARK: - Static Factory Method Tests
    
    func testCreateMissingManifestError() {
        let result = ResponseValidator.createMissingManifestError(channelId: "test", requestName: "unknown")
        
        XCTAssertFalse(result.valid, "Expected invalid result")
        XCTAssertEqual(result.errors.count, 1, "Expected 1 error")
        XCTAssertEqual(result.errors[0].field, "manifest", "Expected manifest field")
        XCTAssertTrue(result.errors[0].message.contains("No response manifest found"), "Expected no response manifest message")
        XCTAssertEqual(result.fieldsValidated, 0, "Expected 0 fields validated")
        XCTAssertEqual(result.validationTime, 0.0, "Expected 0 validation time")
    }
    
    func testCreateSuccessResult() {
        let result = ResponseValidator.createSuccessResult(fieldsValidated: 5, validationTime: 1.5)
        
        XCTAssertTrue(result.valid, "Expected valid result")
        XCTAssertEqual(result.errors.count, 0, "Expected 0 errors")
        XCTAssertEqual(result.fieldsValidated, 5, "Expected 5 fields validated")
        XCTAssertEqual(result.validationTime, 1.5, "Expected 1.5 validation time")
    }
    
    // MARK: - Model Reference Tests (Future Enhancement)
    
    func testHandleModelReferences() {
        // This test is a placeholder for model reference functionality
        // which could be implemented in the future by extending the current Manifest structure
        
        let response: [String: Any] = [
            "id": "user123",
            "name": "John Doe",
            "age": 30
        ]
        
        // For now, we just test that the system handles the UserInfo model structure correctly
        // when integrated with a ResponseManifest that references it
        XCTAssertNotNil(testManifest.models?["UserInfo"], "Expected UserInfo model to exist")
        
        let userModel = testManifest.models!["UserInfo"]!
        XCTAssertEqual(userModel.type, .object, "Expected object type")
        XCTAssertEqual(userModel.properties.count, 3, "Expected 3 properties")
        XCTAssertEqual(userModel.required?.count, 2, "Expected 2 required fields")
    }
}