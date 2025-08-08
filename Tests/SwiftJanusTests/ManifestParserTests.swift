// ManifestParserTests.swift
// Tests for Manifest parsing and validation

import XCTest
@testable import SwiftJanus

final class ManifestParserTests: XCTestCase {
    
    func testParseJSONManifest() throws {
        let jsonString = """
        {
            "version": "1.0.0",
            "models": {
                "testModel": {
                    "type": "object",
                    "properties": {
                        "id": {
                            "type": "string",
                            "required": true,
                            "description": "Data ID"
                        },
                        "data": {
                            "type": "string",
                            "required": false
                        }
                    }
                }
            }
        }
        """
        
        let parser = ManifestParser()
        let manifest = try parser.parseJSON(jsonString)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.models?.count, 1)
        XCTAssertNotNil(manifest.models?["testModel"])
        
        let model = manifest.models!["testModel"]!
        XCTAssertEqual(model.type, ArgumentType.object)
        XCTAssertEqual(model.properties.count, 2)
        
        let idProp = model.properties["id"]!
        XCTAssertEqual(idProp.type, ArgumentType.string)
        XCTAssertTrue(idProp.required)
        XCTAssertEqual(idProp.description, "Data ID")
        
        let dataProp = model.properties["data"]!
        XCTAssertEqual(dataProp.type, ArgumentType.string)
        XCTAssertFalse(dataProp.required)
    }
    
    func testParseYAMLManifest() throws {
        let yamlString = """
        version: "1.0.0"
        models:
          testModel:
            type: "object"
            properties:
              id:
                type: "string"
                required: true
                description: "Data ID"
              data:
                type: "string"
                required: false
        """
        
        let parser = ManifestParser()
        let manifest = try parser.parseYAML(yamlString)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.models?.count, 1)
        XCTAssertNotNil(manifest.models?["testModel"])
    }
    
    func testValidateValidManifest() throws {
        let manifest = createValidManifest()
        
        // Should not throw
        try ManifestParser.validate(manifest)
    }
    
    func testValidateManifestWithEmptyVersion() {
        let manifest = Manifest(
            version: "",
            models: ["test": ModelManifest(type: .object, properties: [:])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("version cannot be empty"))
            }
        }
    }
    
    func testValidateManifestWithNoModels() {
        let manifest = Manifest(
            version: "1.0.0",
            models: [:]
        )
        
        // No models is actually valid in the new structure
        XCTAssertNoThrow(try ManifestParser.validate(manifest))
    }
    
    func testValidateManifestWithEmptyModelId() {
        let manifest = Manifest(
            version: "1.0.0",
            models: ["": ModelManifest(type: .object, properties: [:])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("Model ID cannot be empty"))
            }
        }
    }
    
    // Removed testValidateManifestWithNoRequests and testValidateManifestWithEmptyRequestName
    // since requests are no longer part of the manifest structure
    
    func testValidateManifestWithInvalidValidation() {
        let invalidValidation = ValidationManifest(
            minLength: 10,
            maxLength: 5 // maxLength < minLength
        )
        
        let argManifest = ArgumentManifest(
            type: .string,
            required: true,
            validation: invalidValidation
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            models: ["testModel": ModelManifest(
                type: .object,
                properties: ["invalidArg": argManifest]
            )]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("minLength cannot be greater than maxLength"))
            }
        }
    }
    
    func testValidateManifestWithInvalidRegexPattern() {
        let invalidValidation = ValidationManifest(
            pattern: "[invalid regex pattern"
        )
        
        let argManifest = ArgumentManifest(
            type: .string,
            required: true,
            validation: invalidValidation
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            models: ["testModel": ModelManifest(
                type: .object,
                properties: ["invalidArg": argManifest]
            )]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("Invalid regex pattern"))
            }
        }
    }
    
    func testParseInvalidJSON() {
        let invalidJson = "{ invalid json }"
        
        let parser = ManifestParser()
        XCTAssertThrowsError(try parser.parseJSON(invalidJson)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
    
    func testParseUnsupportedFileFormat() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.txt")
        
        try! "test content".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let parser = ManifestParser()
        XCTAssertThrowsError(try parser.parseFromFile(at: tempURL)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .unsupportedFormat(let format) = error as? ManifestError {
                XCTAssertEqual(format, "txt")
            }
        }
    }
    
    func testParseFromJSONFile() throws {
        let jsonContent = """
        {
            "version": "1.0.0",
            "models": {
                "testModel": {
                    "type": "object",
                    "properties": {}
                }
            }
        }
        """
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.json")
        
        try jsonContent.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let parser = ManifestParser()
        let manifest = try parser.parseFromFile(at: tempURL)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.models?.count, 1)
    }
    
    func testParseFromYAMLFile() throws {
        let yamlContent = """
        version: "1.0.0"
        models:
          testModel:
            type: "object"
            properties: {}
        """
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.yaml")
        
        try yamlContent.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let parser = ManifestParser()
        let manifest = try parser.parseFromFile(at: tempURL)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.models?.count, 1)
    }
    
    private func createValidManifest() -> Manifest {
        let argManifest = ArgumentManifest(
            type: .string,
            required: true,
            description: "Valid argument",
            validation: ValidationManifest(
                minLength: 1,
                maxLength: 100,
                pattern: "^[a-zA-Z0-9]+$"
            )
        )
        
        return Manifest(
            version: "1.0.0",
            models: ["validModel": ModelManifest(
                type: .object,
                properties: ["validArg": argManifest],
                description: "Valid model"
            )]
        )
    }
}