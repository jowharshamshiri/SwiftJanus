// AnyCodableDebugTest.swift
// Debug test for AnyCodable serialization issues

import XCTest
import Foundation
@testable import SwiftJanus

final class AnyCodableDebugTest: XCTestCase {
    
    func testAnyCodableDirectSerialization() throws {
        print("🧪 Testing AnyCodable direct serialization...")
        
        // Test simple string
        let stringValue = AnyCodable("Hello from test!")
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(stringValue)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        print("Encoded string: \(jsonString)")
        
        let decoder = JSONDecoder()
        let decodedString = try decoder.decode(AnyCodable.self, from: jsonData)
        print("Decoded string value: \(decodedString.value)")
        print("Decoded string type: \(type(of: decodedString.value))")
        
        XCTAssertEqual(decodedString.value as? String, "Hello from test!")
        
        // Test simple number
        let numberValue = AnyCodable(1754404646.8755422)
        let numberData = try encoder.encode(numberValue)
        let numberString = String(data: numberData, encoding: .utf8)!
        print("Encoded number: \(numberString)")
        
        let decodedNumber = try decoder.decode(AnyCodable.self, from: numberData)
        print("Decoded number value: \(decodedNumber.value)")
        print("Decoded number type: \(type(of: decodedNumber.value))")
        
        if let doubleValue = decodedNumber.value as? Double {
            XCTAssertEqual(doubleValue, 1754404646.8755422, accuracy: 0.001)
        } else {
            XCTFail("Decoded number should be Double, got: \(type(of: decodedNumber.value))")
        }
    }
    
    func testAnyCodableDictionarySerialization() throws {
        print("🧪 Testing AnyCodable dictionary serialization...")
        
        // Test dictionary like echo response
        let echoResult = [
            "echo": AnyCodable("Hello from test!"),
            "timestamp": AnyCodable(1754404646.8755422)
        ]
        
        let wrappedResult = AnyCodable(echoResult)
        print("Original wrapped result: \(wrappedResult)")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(wrappedResult)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        print("Encoded JSON:\n\(jsonString)")
        
        let decoder = JSONDecoder() 
        let decodedResult = try decoder.decode(AnyCodable.self, from: jsonData)
        print("Decoded result value: \(decodedResult.value)")
        print("Decoded result type: \(type(of: decodedResult.value))")
        
        if let resultDict = decodedResult.value as? [String: Any] {
            print("Result dictionary keys: \(resultDict.keys)")
            for (key, value) in resultDict {
                print("  \(key): \(value) (type: \(type(of: value)))")
            }
            
            XCTAssertNotNil(resultDict["echo"], "Should contain echo field")
            XCTAssertNotNil(resultDict["timestamp"], "Should contain timestamp field")
            
            let echoValue = resultDict["echo"]
            let timestampValue = resultDict["timestamp"]
            
            XCTAssertEqual(echoValue as? String, "Hello from test!", "Echo value should be correct")
            if let timestampDouble = timestampValue as? Double {
                XCTAssertEqual(timestampDouble, 1754404646.8755422, accuracy: 0.001, "Timestamp should be correct")
            } else {
                XCTFail("Timestamp should be Double, got: \(type(of: timestampValue))")
            }
        } else {
            XCTFail("Decoded result should be a dictionary")
        }
    }
    
    func testJanusResponseSerialization() throws {
        print("🧪 Testing JanusResponse serialization...")
        
        // Create response like the server does
        let echoResult = [
            "echo": AnyCodable("Hello from test!"),
            "timestamp": AnyCodable(Date().timeIntervalSince1970)
        ]
        
        let response = JanusResponse(
            requestId: "test-id",
            channelId: "test",
            success: true,
            result: AnyCodable(echoResult),
            error: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        print("Original response result: \(response.result?.value ?? "nil")")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(response)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        print("Encoded JanusResponse JSON:\n\(jsonString)")
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(JanusResponse.self, from: jsonData)
        
        print("Decoded response result: \(decodedResponse.result?.value ?? "nil")")
        
        XCTAssertTrue(decodedResponse.success, "Response should be successful")
        XCTAssertNotNil(decodedResponse.result, "Response should have result")
        
        if let resultDict = decodedResponse.result?.value as? [String: Any] {
            print("Decoded result dictionary: \(resultDict)")
            XCTAssertNotNil(resultDict["echo"], "Should contain echo field")
            XCTAssertNotNil(resultDict["timestamp"], "Should contain timestamp field")
        } else {
            XCTFail("Decoded response result should be a dictionary, got: \(type(of: decodedResponse.result?.value))")
        }
    }
}