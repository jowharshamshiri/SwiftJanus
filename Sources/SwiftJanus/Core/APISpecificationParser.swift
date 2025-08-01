// APISpecificationParser.swift
// Parser for API specification documents (JSON/YAML)

import Foundation
import Yams

/// Parser for API specification documents
public final class APISpecificationParser {
    
    public init() {}
    
    /// Parse API specification from JSON data
    public func parseJSON(_ data: Data) throws -> APISpecification {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(APISpecification.self, from: data)
    }
    
    /// Parse API specification from JSON string
    public func parseJSON(_ jsonString: String) throws -> APISpecification {
        guard let data = jsonString.data(using: .utf8) else {
            throw APISpecificationError.invalidFormat("Invalid UTF-8 JSON string")
        }
        return try parseJSON(data)
    }
    
    /// Parse API specification from YAML data
    public func parseYAML(_ data: Data) throws -> APISpecification {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw APISpecificationError.invalidFormat("Invalid UTF-8 YAML data")
        }
        return try parseYAML(yamlString)
    }
    
    /// Parse API specification from YAML string
    public func parseYAML(_ yamlString: String) throws -> APISpecification {
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(APISpecification.self, from: yamlString)
        } catch {
            throw APISpecificationError.yamlParsingFailed(error)
        }
    }
    
    /// Parse API specification from file URL
    public func parseFromFile(at url: URL) throws -> APISpecification {
        let data = try Data(contentsOf: url)
        
        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "json":
            return try parseJSON(data)
        case "yaml", "yml":
            return try parseYAML(data)
        default:
            throw APISpecificationError.unsupportedFormat(fileExtension)
        }
    }
    
    /// Validate API specification structure
    public static func validate(_ spec: APISpecification) throws {
        // Validate version format
        guard !spec.version.isEmpty else {
            throw APISpecificationError.validationFailed("API version cannot be empty")
        }
        
        // Validate channels
        guard !spec.channels.isEmpty else {
            throw APISpecificationError.validationFailed("API must define at least one channel")
        }
        
        // Validate each channel
        for (channelId, channel) in spec.channels {
            try validateChannel(channelId: channelId, channel: channel, models: spec.models)
        }
    }
    
    private static func validateChannel(channelId: String, channel: ChannelSpec, models: [String: ModelSpec]?) throws {
        guard !channelId.isEmpty else {
            throw APISpecificationError.validationFailed("Channel ID cannot be empty")
        }
        
        guard !channel.commands.isEmpty else {
            throw APISpecificationError.validationFailed("Channel '\(channelId)' must define at least one command")
        }
        
        // Validate each command
        for (commandName, command) in channel.commands {
            try validateCommand(commandName: commandName, command: command, channelId: channelId, models: models)
        }
    }
    
    private static func validateCommand(commandName: String, command: CommandSpec, channelId: String, models: [String: ModelSpec]?) throws {
        guard !commandName.isEmpty else {
            throw APISpecificationError.validationFailed("Command name cannot be empty in channel '\(channelId)'")
        }
        
        // Reserved built-in commands cannot be defined in API specifications
        let reservedCommands: Set<String> = ["spec", "ping", "echo", "get_info", "validate", "slow_process"]
        if reservedCommands.contains(commandName) {
            throw APISpecificationError.validationFailed("Command '\(commandName)' is reserved and cannot be defined in API specification in channel '\(channelId)'")
        }
        
        // Validate arguments if present
        if let args = command.args {
            for (argName, argSpec) in args {
                try validateArgument(argName: argName, argSpec: argSpec, context: "command '\(commandName)' in channel '\(channelId)'", models: models)
            }
        }
        
        // Validate response if present
        if let response = command.response {
            try validateResponse(response: response, context: "command '\(commandName)' in channel '\(channelId)'", models: models)
        }
        
        // Validate error codes if present
        if let errorCodes = command.errorCodes {
            for errorCode in errorCodes {
                // Error codes are now just strings, no detailed spec validation needed
                if errorCode.isEmpty {
                    throw APISpecificationError.invalidFormat("Empty error code in command '\(commandName)' in channel '\(channelId)'")
                }
            }
        }
    }
    
    private static func validateArgument(argName: String, argSpec: ArgumentSpec, context: String, models: [String: ModelSpec]?) throws {
        guard !argName.isEmpty else {
            throw APISpecificationError.validationFailed("Argument name cannot be empty in \(context)")
        }
        
        // Validate type reference if it's a reference type
        if argSpec.type == .reference {
            // Implementation for model reference validation would go here
            // For now, we'll skip this validation
        }
        
        // Validate validation constraints if present
        if let validation = argSpec.validation {
            try validateValidationSpec(validation: validation, argName: argName, context: context)
        }
    }
    
    private static func validateResponse(response: ResponseSpec, context: String, models: [String: ModelSpec]?) throws {
        // Validate response properties if present
        if let properties = response.properties {
            for (propName, propSpec) in properties {
                try validateArgument(argName: propName, argSpec: propSpec, context: "response of \(context)", models: models)
            }
        }
    }
    
    private static func validateError(errorName: String, errorSpec: ErrorSpec, context: String) throws {
        guard !errorName.isEmpty else {
            throw APISpecificationError.validationFailed("Error name cannot be empty in \(context)")
        }
        
        guard !errorSpec.message.isEmpty else {
            throw APISpecificationError.validationFailed("Error message cannot be empty for error '\(errorName)' in \(context)")
        }
    }
    
    private static func validateValidationSpec(validation: ValidationSpec, argName: String, context: String) throws {
        // Validate string length constraints
        if let minLength = validation.minLength, let maxLength = validation.maxLength {
            guard minLength <= maxLength else {
                throw APISpecificationError.validationFailed("minLength cannot be greater than maxLength for argument '\(argName)' in \(context)")
            }
        }
        
        // Validate numeric constraints
        if let minimum = validation.minimum, let maximum = validation.maximum {
            guard minimum <= maximum else {
                throw APISpecificationError.validationFailed("minimum cannot be greater than maximum for argument '\(argName)' in \(context)")
            }
        }
        
        // Validate regex pattern if present
        if let pattern = validation.pattern {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw APISpecificationError.validationFailed("Invalid regex pattern '\(pattern)' for argument '\(argName)' in \(context): \(error.localizedDescription)")
            }
        }
    }
}

/// Errors that can occur during API specification parsing and validation
public enum APISpecificationError: Error, LocalizedError {
    case invalidFormat(String)
    case unsupportedFormat(String)
    case yamlParsingFailed(Error)
    case validationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let message):
            return "Invalid format: \(message)"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format). Supported formats: json, yaml, yml"
        case .yamlParsingFailed(let error):
            return "YAML parsing failed: \(error.localizedDescription)"
        case .validationFailed(let message):
            return "Validation failed: \(message)"
        }
    }
}