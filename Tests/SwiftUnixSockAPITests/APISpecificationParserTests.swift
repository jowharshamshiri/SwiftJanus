// APISpecificationParserTests.swift
// Tests for API specification parsing and validation

import XCTest
@testable import SwiftUnixSockAPI

final class APISpecificationParserTests: XCTestCase {
    
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
        
        let apiSpec = try APISpecificationParser.parseJSON(jsonString)
        
        XCTAssertEqual(apiSpec.version, "1.0.0")
        XCTAssertEqual(apiSpec.channels.count, 1)
        XCTAssertNotNil(apiSpec.channels["testChannel"])
        
        let channel = apiSpec.channels["testChannel"]!
        XCTAssertEqual(channel.description, "Test channel")
        XCTAssertEqual(channel.commands.count, 1)
        XCTAssertNotNil(channel.commands["getData"])
        
        let command = channel.commands["getData"]!
        XCTAssertEqual(command.description, "Get data command")
        XCTAssertNotNil(command.args)
        XCTAssertEqual(command.args?.count, 1)
        
        let arg = command.args!["id"]!
        XCTAssertEqual(arg.type, .string)
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
        
        let apiSpec = try APISpecificationParser.parseYAML(yamlString)
        
        XCTAssertEqual(apiSpec.version, "1.0.0")
        XCTAssertEqual(apiSpec.channels.count, 1)
        XCTAssertNotNil(apiSpec.channels["testChannel"])
    }
    
    func testValidateValidSpecification() throws {
        let apiSpec = createValidAPISpecification()
        
        // Should not throw
        try APISpecificationParser.validate(apiSpec)
    }
    
    func testValidateSpecificationWithEmptyVersion() {
        let apiSpec = APISpecification(
            version: "",
            channels: ["test": ChannelSpec(commands: ["cmd": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
                XCTAssertTrue(message.contains("version cannot be empty"))
            }
        }
    }
    
    func testValidateSpecificationWithNoChannels() {
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: [:]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
                XCTAssertTrue(message.contains("at least one channel"))
            }
        }
    }
    
    func testValidateSpecificationWithEmptyChannelId() {
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["": ChannelSpec(commands: ["cmd": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
                XCTAssertTrue(message.contains("Channel ID cannot be empty"))
            }
        }
    }
    
    func testValidateSpecificationWithNoCommands() {
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: [:])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
                XCTAssertTrue(message.contains("at least one command"))
            }
        }
    }
    
    func testValidateSpecificationWithEmptyCommandName() {
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["": CommandSpec()])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
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
        
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["testCommand": commandSpec])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
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
        
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["testChannel": ChannelSpec(commands: ["testCommand": commandSpec])]
        )
        
        XCTAssertThrowsError(try APISpecificationParser.validate(apiSpec)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .validationFailed(let message) = error as? APISpecificationError {
                XCTAssertTrue(message.contains("Invalid regex pattern"))
            }
        }
    }
    
    func testParseInvalidJSON() {
        let invalidJson = "{ invalid json }"
        
        XCTAssertThrowsError(try APISpecificationParser.parseJSON(invalidJson)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
    
    func testParseUnsupportedFileFormat() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.txt")
        
        try! "test content".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        XCTAssertThrowsError(try APISpecificationParser.parseFromFile(at: tempURL)) { error in
            XCTAssertTrue(error is APISpecificationError)
            if case .unsupportedFormat(let format) = error as? APISpecificationError {
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
        
        let apiSpec = try APISpecificationParser.parseFromFile(at: tempURL)
        
        XCTAssertEqual(apiSpec.version, "1.0.0")
        XCTAssertEqual(apiSpec.channels.count, 1)
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
        
        let apiSpec = try APISpecificationParser.parseFromFile(at: tempURL)
        
        XCTAssertEqual(apiSpec.version, "1.0.0")
        XCTAssertEqual(apiSpec.channels.count, 1)
    }
    
    private func createValidAPISpecification() -> APISpecification {
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
            errorCodes: [
                "badRequest": ErrorSpec(
                    code: 400,
                    message: "Bad Request"
                )
            ]
        )
        
        let channelSpec = ChannelSpec(
            description: "Valid channel",
            commands: ["validCommand": commandSpec]
        )
        
        return APISpecification(
            version: "1.0.0",
            channels: ["validChannel": channelSpec]
        )
    }
}