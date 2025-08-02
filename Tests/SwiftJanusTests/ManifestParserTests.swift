// ManifestParserTests.swift
// Tests for Manifest parsing and validation

import XCTest
@testable import SwiftJanus

final class ManifestParserTests: XCTestCase {
    
    func testParseJSONSpecification() throws {
        let jsonString = """
        {
            "version": "1.0.0",
            "channels": {
                "testChannel": {
                    "description": "Test channel",
                    "commands": {
                        "getData": {
                            "description": "Get data command",
                            "args": {
                                "id": {
                                    "type": "string",
                                    "required": true,
                                    "description": "Data ID"
                                }
                            },
                            "response": {
                                "type": "object",
                                "properties": {
                                    "data": {
                                        "type": "string",
                                        "required": false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        
        let parser = ManifestParser()
        let manifest = try parser.parseJSON(jsonString)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.channels.count, 1)
        XCTAssertNotNil(manifest.channels["testChannel"])
        
        let channel = manifest.channels["testChannel"]!
        XCTAssertEqual(channel.description, "Test channel")
        XCTAssertEqual(channel.commands.count, 1)
        XCTAssertNotNil(channel.commands["getData"])
        
        let command = channel.commands["getData"]!
        XCTAssertEqual(command.description, "Get data command")
        XCTAssertNotNil(command.args)
        XCTAssertEqual(command.args?.count, 1)
        
        let arg = command.args!["id"]!
        XCTAssertEqual(arg.type, ArgumentType.string)
        XCTAssertTrue(arg.required)
    }
    
    func testParseYAMLSpecification() throws {
        let yamlString = """
        version: "1.0.0"
        channels:
          testChannel:
            description: "Test channel"
            commands:
              getData:
                description: "Get data command"
                args:
                  id:
                    type: "string"
                    required: true
                    description: "Data ID"
                response:
                  type: "object"
                  properties:
                    data:
                      type: "string"
                      required: false
        """
        
        let parser = ManifestParser()
        let manifest = try parser.parseYAML(yamlString)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.channels.count, 1)
        XCTAssertNotNil(manifest.channels["testChannel"])
    }
    
    func testValidateValidSpecification() throws {
        let manifest = createValidManifest()
        
        // Should not throw
        try ManifestParser.validate(manifest)
    }
    
    func testValidateSpecificationWithEmptyVersion() {
        let manifest = Manifest(
            version: "",
            channels: ["test": ChannelSpec(commands: ["cmd": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("version cannot be empty"))
            }
        }
    }
    
    func testValidateSpecificationWithNoChannels() {
        let manifest = Manifest(
            version: "1.0.0",
            channels: [:]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("at least one channel"))
            }
        }
    }
    
    func testValidateSpecificationWithEmptyChannelId() {
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["": ChannelSpec(commands: ["cmd": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("Channel ID cannot be empty"))
            }
        }
    }
    
    func testValidateSpecificationWithNoCommands() {
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: [:])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("at least one command"))
            }
        }
    }
    
    func testValidateSpecificationWithEmptyCommandName() {
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("Command name cannot be empty"))
            }
        }
    }
    
    func testValidateSpecificationWithInvalidValidation() {
        let invalidValidation = ValidationSpec(
            minLength: 10,
            maxLength: 5 // maxLength < minLength
        )
        
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            validation: invalidValidation
        )
        
        let commandSpec = CommandSpec(
            args: ["invalidArg": argSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["testCommand": commandSpec])]
        )
        
        XCTAssertThrowsError(try ManifestParser.validate(manifest)) { error in
            XCTAssertTrue(error is ManifestError)
            if case .validationFailed(let message) = error as? ManifestError {
                XCTAssertTrue(message.contains("minLength cannot be greater than maxLength"))
            }
        }
    }
    
    func testValidateSpecificationWithInvalidRegexPattern() {
        let invalidValidation = ValidationSpec(
            pattern: "[invalid regex pattern"
        )
        
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            validation: invalidValidation
        )
        
        let commandSpec = CommandSpec(
            args: ["invalidArg": argSpec]
        )
        
        let manifest = Manifest(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["testCommand": commandSpec])]
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
            "channels": {
                "testChannel": {
                    "commands": {
                        "testCommand": {}
                    }
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
        XCTAssertEqual(manifest.channels.count, 1)
    }
    
    func testParseFromYAMLFile() throws {
        let yamlContent = """
        version: "1.0.0"
        channels:
          testChannel:
            commands:
              testCommand: {}
        """
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.yaml")
        
        try yamlContent.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let parser = ManifestParser()
        let manifest = try parser.parseFromFile(at: tempURL)
        
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.channels.count, 1)
    }
    
    private func createValidManifest() -> Manifest {
        let argSpec = ArgumentSpec(
            type: .string,
            required: true,
            description: "Valid argument",
            validation: ValidationSpec(
                minLength: 1,
                maxLength: 100,
                pattern: "^[a-zA-Z0-9]+$"
            )
        )
        
        let commandSpec = CommandSpec(
            description: "Valid command",
            args: ["validArg": argSpec],
            response: ResponseSpec(
                type: .object,
                description: "Valid response"
            ),
            errorCodes: ["badRequest"]
        )
        
        let channelSpec = ChannelSpec(
            description: "Valid channel",
            commands: ["validCommand": commandSpec]
        )
        
        return Manifest(
            version: "1.0.0",
            channels: ["validChannel": channelSpec]
        )
    }
}