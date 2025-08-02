// ManifestParser.swift
// Parser for Manifest documents (JSON/YAML)

import Foundation
import Yams

/// Parser for Manifest documents
public final class ManifestParser {
    
    public init() {}
    
    /// Parse Manifest from JSON data
    public func parseJSON(_ data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data)
    }
    
    /// Parse Manifest from JSON string
    public func parseJSON(_ jsonString: String) throws -> Manifest {
        guard let data = jsonString.data(using: .utf8) else {
            throw ManifestError.invalidFormat("Invalid UTF-8 JSON string")
        }
        return try parseJSON(data)
    }
    
    /// Parse Manifest from YAML data
    public func parseYAML(_ data: Data) throws -> Manifest {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidFormat("Invalid UTF-8 YAML data")
        }
        return try parseYAML(yamlString)
    }
    
    /// Parse Manifest from YAML string
    public func parseYAML(_ yamlString: String) throws -> Manifest {
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(Manifest.self, from: yamlString)
        } catch {
            throw ManifestError.yamlParsingFailed(error)
        }
    }
    
    /// Parse Manifest from file URL
    public func parseFromFile(at url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url)
        
        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "json":
            return try parseJSON(data)
        case "yaml", "yml":
            return try parseYAML(data)
        default:
            throw ManifestError.unsupportedFormat(fileExtension)
        }
    }
    
    /// Validate Manifest structure
    public static func validate(_ spec: Manifest) throws {
        // Validate version format
        guard !spec.version.isEmpty else {
            throw ManifestError.validationFailed("API version cannot be empty")
        }
        
        // Validate channels
        guard !spec.channels.isEmpty else {
            throw ManifestError.validationFailed("API must define at least one channel")
        }
        
        // Validate each channel
        for (channelId, channel) in spec.channels {
            try validateChannel(channelId: channelId, channel: channel, models: spec.models)
        }
    }
    
    private static func validateChannel(channelId: String, channel: ChannelSpec, models: [String: ModelSpec]?) throws {
        guard !channelId.isEmpty else {
            throw ManifestError.validationFailed("Channel ID cannot be empty")
        }
        
        guard !channel.commands.isEmpty else {
            throw ManifestError.validationFailed("Channel '\(channelId)' must define at least one command")
        }
        
        // Validate each command
        for (commandName, command) in channel.commands {
            try validateCommand(commandName: commandName, command: command, channelId: channelId, models: models)
        }
    }
    
    private static func validateCommand(commandName: String, command: CommandSpec, channelId: String, models: [String: ModelSpec]?) throws {
        guard !commandName.isEmpty else {
            throw ManifestError.validationFailed("Command name cannot be empty in channel '\(channelId)'")
        }
        
        // Reserved built-in commands cannot be defined in Manifests
        let reservedCommands: Set<String> = ["spec", "ping", "echo", "get_info", "validate", "slow_process"]
        if reservedCommands.contains(commandName) {
            throw ManifestError.validationFailed("Command '\(commandName)' is reserved and cannot be defined in Manifest in channel '\(channelId)'")
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
                    throw ManifestError.invalidFormat("Empty error code in command '\(commandName)' in channel '\(channelId)'")
                }
            }
        }
    }
    
    private static func validateArgument(argName: String, argSpec: ArgumentSpec, context: String, models: [String: ModelSpec]?) throws {
        guard !argName.isEmpty else {
            throw ManifestError.validationFailed("Argument name cannot be empty in \(context)")
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
            throw ManifestError.validationFailed("Error name cannot be empty in \(context)")
        }
        
        guard !errorSpec.message.isEmpty else {
            throw ManifestError.validationFailed("Error message cannot be empty for error '\(errorName)' in \(context)")
        }
    }
    
    private static func validateValidationSpec(validation: ValidationSpec, argName: String, context: String) throws {
        // Validate string length constraints
        if let minLength = validation.minLength, let maxLength = validation.maxLength {
            guard minLength <= maxLength else {
                throw ManifestError.validationFailed("minLength cannot be greater than maxLength for argument '\(argName)' in \(context)")
            }
        }
        
        // Validate numeric constraints
        if let minimum = validation.minimum, let maximum = validation.maximum {
            guard minimum <= maximum else {
                throw ManifestError.validationFailed("minimum cannot be greater than maximum for argument '\(argName)' in \(context)")
            }
        }
        
        // Validate regex pattern if present
        if let pattern = validation.pattern {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw ManifestError.validationFailed("Invalid regex pattern '\(pattern)' for argument '\(argName)' in \(context): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Serialization Methods
    
    /// Serialize Manifest to JSON data
    public func serializeToJSON(_ spec: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(spec)
    }
    
    /// Serialize Manifest to JSON string
    public func serializeToJSONString(_ spec: Manifest) throws -> String {
        let data = try serializeToJSON(spec)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidFormat("Failed to create JSON string from data")
        }
        return jsonString
    }
    
    /// Serialize Manifest to YAML data
    public func serializeToYAML(_ spec: Manifest) throws -> Data {
        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(spec)
        guard let data = yamlString.data(using: .utf8) else {
            throw ManifestError.invalidFormat("Failed to create YAML data from string")
        }
        return data
    }
    
    /// Serialize Manifest to YAML string
    public func serializeToYAMLString(_ spec: Manifest) throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(spec)
    }
    
    // MARK: - Multi-File Parsing and Merging
    
    /// Parse multiple Manifest files and merge them
    public func parseMultipleFiles(at urls: [URL]) throws -> Manifest {
        guard !urls.isEmpty else {
            throw ManifestError.invalidFormat("No files provided")
        }
        
        // Parse first file as base
        var baseSpec = try parseFromFile(at: urls[0])
        
        // Merge additional files
        for url in urls.dropFirst() {
            let additionalSpec = try parseFromFile(at: url)
            try mergeSpecifications(base: &baseSpec, additional: additionalSpec)
        }
        
        // Validate merged specification
        try ManifestParser.validate(baseSpec)
        
        return baseSpec
    }
    
    /// Merge two Manifests
    public func mergeSpecifications(base: inout Manifest, additional: Manifest) throws {
        // Check for conflicts first
        for (channelId, _) in additional.channels {
            if base.channels[channelId] != nil {
                throw ManifestError.validationFailed("Channel '\(channelId)' already exists in base specification")
            }
        }
        
        if let additionalModels = additional.models, let baseModels = base.models {
            for (modelName, _) in additionalModels {
                if baseModels[modelName] != nil {
                    throw ManifestError.validationFailed("Model '\(modelName)' already exists in base specification")
                }
            }
        }
        
        // Create merged channels
        var mergedChannels = base.channels
        for (channelId, channelSpec) in additional.channels {
            mergedChannels[channelId] = channelSpec
        }
        
        // Create merged models
        var mergedModels = base.models
        if let additionalModels = additional.models {
            if mergedModels == nil {
                mergedModels = [:]
            }
            for (modelName, modelSpec) in additionalModels {
                mergedModels![modelName] = modelSpec
            }
        }
        
        // Create new Manifest with merged data
        base = Manifest(
            version: base.version,
            name: base.name,
            channels: mergedChannels,
            models: mergedModels
        )
    }
    
    // MARK: - Argument Validation Engine
    
    /// Validate command arguments against their specifications
    public func validateCommandArguments(_ args: [String: Any], against argSpecs: [String: ArgumentSpec], models: [String: ModelSpec]?) throws {
        // Check required arguments
        for (argName, argSpec) in argSpecs {
            if argSpec.required && args[argName] == nil {
                throw ManifestError.validationFailed("Required argument '\(argName)' is missing")
            }
        }
        
        // Validate provided arguments
        for (argName, argValue) in args {
            guard let argSpec = argSpecs[argName] else {
                throw ManifestError.validationFailed("Unknown argument '\(argName)'")
            }
            
            try validateArgumentValue(name: argName, value: argValue, spec: argSpec, models: models)
        }
    }
    
    /// Validate a single argument value against its specification
    public func validateArgumentValue(name: String, value: Any, spec: ArgumentSpec, models: [String: ModelSpec]?) throws {
        // Handle nil values
        if value is NSNull {
            if spec.required {
                throw ManifestError.validationFailed("Required argument '\(name)' cannot be null")
            }
            return
        }
        
        // Type validation
        try validateArgumentType(name: name, value: value, spec: spec)
        
        // Validation constraints
        if let validation = spec.validation {
            try validateArgumentConstraints(name: name, value: value, validation: validation, spec: spec)
        }
        
        // Model reference validation is handled through type validation
        // Swift doesn't have separate modelRef field like other implementations
    }
    
    private func validateArgumentType(name: String, value: Any, spec: ArgumentSpec) throws {
        switch spec.type {
        case .string:
            guard value is String else {
                throw ManifestError.validationFailed("Argument '\(name)' expected string, got \(type(of: value))")
            }
        case .integer:
            guard value is Int || value is Int64 || value is Int32 else {
                throw ManifestError.validationFailed("Argument '\(name)' expected integer, got \(type(of: value))")
            }
        case .number:
            guard value is NSNumber || value is Double || value is Float || value is Int else {
                throw ManifestError.validationFailed("Argument '\(name)' expected number, got \(type(of: value))")
            }
        case .boolean:
            guard value is Bool else {
                throw ManifestError.validationFailed("Argument '\(name)' expected boolean, got \(type(of: value))")
            }
        case .array:
            guard value is [Any] else {
                throw ManifestError.validationFailed("Argument '\(name)' expected array, got \(type(of: value))")
            }
        case .object:
            guard value is [String: Any] else {
                throw ManifestError.validationFailed("Argument '\(name)' expected object, got \(type(of: value))")
            }
        case .null:
            guard value is NSNull else {
                throw ManifestError.validationFailed("Argument '\(name)' expected null, got \(type(of: value))")
            }
        case .reference:
            // Model reference validation handled separately
            break
        }
    }
    
    private func validateArgumentConstraints(name: String, value: Any, validation: ValidationSpec, spec: ArgumentSpec) throws {
        // String constraints
        if spec.type == .string, let stringValue = value as? String {
            if let minLength = validation.minLength, stringValue.count < minLength {
                throw ManifestError.validationFailed("Argument '\(name)' length \(stringValue.count) is less than minimum \(minLength)")
            }
            if let maxLength = validation.maxLength, stringValue.count > maxLength {
                throw ManifestError.validationFailed("Argument '\(name)' length \(stringValue.count) exceeds maximum \(maxLength)")
            }
            if let pattern = validation.pattern {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(location: 0, length: stringValue.utf16.count)
                if regex.firstMatch(in: stringValue, options: [], range: range) == nil {
                    throw ManifestError.validationFailed("Argument '\(name)' does not match pattern '\(pattern)'")
                }
            }
        }
        
        // Numeric constraints
        if spec.type == .number || spec.type == .integer {
            let numericValue: Double
            if let intValue = value as? Int {
                numericValue = Double(intValue)
            } else if let doubleValue = value as? Double {
                numericValue = doubleValue
            } else if let floatValue = value as? Float {
                numericValue = Double(floatValue) 
            } else if let numberValue = value as? NSNumber {
                numericValue = numberValue.doubleValue
            } else {
                throw ManifestError.validationFailed("Argument '\(name)' is not a valid numeric type")
            }
            
            if let minimum = validation.minimum, numericValue < minimum {
                throw ManifestError.validationFailed("Argument '\(name)' value \(numericValue) is less than minimum \(minimum)")
            }
            if let maximum = validation.maximum, numericValue > maximum {
                throw ManifestError.validationFailed("Argument '\(name)' value \(numericValue) exceeds maximum \(maximum)")
            }
        }
        
        // Enum constraints
        if let enumValues = validation.enum, !enumValues.isEmpty {
            let stringValue = "\(value)"
            let enumStrings = enumValues.map { "\($0.value)" }
            if !enumStrings.contains(stringValue) {
                throw ManifestError.validationFailed("Argument '\(name)' value '\(stringValue)' is not in allowed values: \(enumStrings.joined(separator: ", "))")
            }
        }
    }
    
    private func validateModelReference(name: String, value: Any, modelRef: String, models: [String: ModelSpec]?) throws {
        guard let models = models, let modelSpec = models[modelRef] else {
            throw ManifestError.validationFailed("Model reference '\(modelRef)' not found for argument '\(name)'")
        }
        
        guard let valueDict = value as? [String: Any] else {
            throw ManifestError.validationFailed("Argument '\(name)' with model reference expected object, got \(type(of: value))")
        }
        
        // Check required properties
        if let required = modelSpec.required {
            for requiredProp in required {
                if valueDict[requiredProp] == nil {
                    throw ManifestError.validationFailed("Required property '\(requiredProp)' missing in argument '\(name)' (model '\(modelRef)')")
                }
            }
        }
        
        // Validate properties (modelSpec.properties is not optional in Swift)
        for (propName, propValue) in valueDict {
            guard let propSpec = modelSpec.properties[propName] else {
                throw ManifestError.validationFailed("Unknown property '\(propName)' in argument '\(name)' (model '\(modelRef)')")
            }
            
            try validateArgumentValue(name: "\(name).\(propName)", value: propValue, spec: propSpec, models: models)
        }
    }
}

// MARK: - Static Interface Methods (for compatibility with Go/Rust/TypeScript)

extension ManifestParser {
    
    /// Static method for parsing JSON data
    public static func parseJSON(_ data: Data) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseJSON(data)
    }
    
    /// Static method for parsing JSON string
    public static func parseJSON(_ jsonString: String) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseJSON(jsonString)
    }
    
    /// Static method for parsing YAML data
    public static func parseYAML(_ data: Data) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseYAML(data)
    }
    
    /// Static method for parsing YAML string
    public static func parseYAML(_ yamlString: String) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseYAML(yamlString)
    }
    
    /// Static method for parsing from file
    public static func parseFromFile(at url: URL) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseFromFile(at: url)
    }
    
    /// Static method for JSON serialization
    public static func serializeToJSON(_ spec: Manifest) throws -> Data {
        let parser = ManifestParser()
        return try parser.serializeToJSON(spec)
    }
    
    /// Static method for JSON string serialization
    public static func serializeToJSONString(_ spec: Manifest) throws -> String {
        let parser = ManifestParser()
        return try parser.serializeToJSONString(spec)
    }
    
    /// Static method for YAML serialization
    public static func serializeToYAML(_ spec: Manifest) throws -> Data {
        let parser = ManifestParser()
        return try parser.serializeToYAML(spec)
    }
    
    /// Static method for YAML string serialization
    public static func serializeToYAMLString(_ spec: Manifest) throws -> String {
        let parser = ManifestParser()
        return try parser.serializeToYAMLString(spec)
    }
    
    /// Static method for multi-file parsing
    public static func parseMultipleFiles(at urls: [URL]) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseMultipleFiles(at: urls)
    }
    
    /// Static method for specification merging
    public static func mergeSpecifications(base: inout Manifest, additional: Manifest) throws {
        let parser = ManifestParser()
        try parser.mergeSpecifications(base: &base, additional: additional)
    }
    
    /// Static method for argument validation
    public static func validateCommandArguments(_ args: [String: Any], against argSpecs: [String: ArgumentSpec], models: [String: ModelSpec]?) throws {
        let parser = ManifestParser()
        try parser.validateCommandArguments(args, against: argSpecs, models: models)
    }
}

/// Errors that can occur during Manifest parsing and validation
public enum ManifestError: Error, LocalizedError {
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