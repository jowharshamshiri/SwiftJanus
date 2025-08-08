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
    public static func validate(_ manifest: Manifest) throws {
        // Validate version format
        guard !manifest.version.isEmpty else {
            throw ManifestError.validationFailed("API version cannot be empty")
        }
        
        // Channel validation removed - channels no longer part of protocol
    }
    
    // validateChannel removed - channels no longer part of protocol
    
    // Channel-based validation removed - server handles validation
    private static func validateArgument(argName: String, argManifest: ArgumentManifest, context: String, models: [String: ModelManifest]?) throws {
        guard !argName.isEmpty else {
            throw ManifestError.validationFailed("Argument name cannot be empty in \(context)")
        }
        
        // Validate type reference if it's a reference type
        if argManifest.type == .reference {
            // Implementation for model reference validation would go here
            // For now, we'll skip this validation
        }
        
        // Validate validation constraints if present
        if let validation = argManifest.validation {
            try validateValidationManifest(validation: validation, argName: argName, context: context)
        }
    }
    
    private static func validateResponse(response: ResponseManifest, context: String, models: [String: ModelManifest]?) throws {
        // Validate response properties if present
        if let properties = response.properties {
            for (propName, propManifest) in properties {
                try validateArgument(argName: propName, argManifest: propManifest, context: "response of \(context)", models: models)
            }
        }
    }
    
    private static func validateError(errorName: String, errorManifest: ErrorManifest, context: String) throws {
        guard !errorName.isEmpty else {
            throw ManifestError.validationFailed("Error name cannot be empty in \(context)")
        }
        
        guard !errorManifest.message.isEmpty else {
            throw ManifestError.validationFailed("Error message cannot be empty for error '\(errorName)' in \(context)")
        }
    }
    
    private static func validateValidationManifest(validation: ValidationManifest, argName: String, context: String) throws {
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
    public func serializeToJSON(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }
    
    /// Serialize Manifest to JSON string
    public func serializeToJSONString(_ manifest: Manifest) throws -> String {
        let data = try serializeToJSON(manifest)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidFormat("Failed to create JSON string from data")
        }
        return jsonString
    }
    
    /// Serialize Manifest to YAML data
    public func serializeToYAML(_ manifest: Manifest) throws -> Data {
        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(manifest)
        guard let data = yamlString.data(using: .utf8) else {
            throw ManifestError.invalidFormat("Failed to create YAML data from string")
        }
        return data
    }
    
    /// Serialize Manifest to YAML string
    public func serializeToYAMLString(_ manifest: Manifest) throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(manifest)
    }
    
    // MARK: - Multi-File Parsing and Merging
    
    /// Parse multiple Manifest files and merge them
    public func parseMultipleFiles(at urls: [URL]) throws -> Manifest {
        guard !urls.isEmpty else {
            throw ManifestError.invalidFormat("No files provided")
        }
        
        // Parse first file as base
        var baseManifest = try parseFromFile(at: urls[0])
        
        // Merge additional files
        for url in urls.dropFirst() {
            let additionalManifest = try parseFromFile(at: url)
            try mergeManifests(base: &baseManifest, additional: additionalManifest)
        }
        
        // Validate merged manifest
        try ManifestParser.validate(baseManifest)
        
        return baseManifest
    }
    
    /// Merge two Manifests
    public func mergeManifests(base: inout Manifest, additional: Manifest) throws {
        // Channel conflict checking removed - channels no longer part of protocol
        
        if let additionalModels = additional.models, let baseModels = base.models {
            for (modelName, _) in additionalModels {
                if baseModels[modelName] != nil {
                    throw ManifestError.validationFailed("Model '\(modelName)' already exists in base manifest")
                }
            }
        }
        
        // Channel merging removed - channels no longer part of protocol
        
        // Create merged models
        var mergedModels = base.models
        if let additionalModels = additional.models {
            if mergedModels == nil {
                mergedModels = [:]
            }
            for (modelName, modelManifest) in additionalModels {
                mergedModels![modelName] = modelManifest
            }
        }
        
        // Create new Manifest with merged data
        base = Manifest(
            version: base.version,
            name: base.name,
            models: mergedModels
        )
    }
    
    // MARK: - Argument Validation Engine
    
    /// Validate request arguments against their manifests
    public func validateRequestArguments(_ args: [String: Any], against argManifests: [String: ArgumentManifest], models: [String: ModelManifest]?) throws {
        // Check required arguments
        for (argName, argManifest) in argManifests {
            if argManifest.required && args[argName] == nil {
                throw ManifestError.validationFailed("Required argument '\(argName)' is missing")
            }
        }
        
        // Validate provided arguments
        for (argName, argValue) in args {
            guard let argManifest = argManifests[argName] else {
                throw ManifestError.validationFailed("Unknown argument '\(argName)'")
            }
            
            try validateArgumentValue(name: argName, value: argValue, manifest: argManifest, models: models)
        }
    }
    
    /// Validate a single argument value against its manifest
    public func validateArgumentValue(name: String, value: Any, manifest: ArgumentManifest, models: [String: ModelManifest]?) throws {
        // Handle nil values
        if value is NSNull {
            if manifest.required {
                throw ManifestError.validationFailed("Required argument '\(name)' cannot be null")
            }
            return
        }
        
        // Type validation
        try validateArgumentType(name: name, value: value, manifest: manifest)
        
        // Validation constraints
        if let validation = manifest.validation {
            try validateArgumentConstraints(name: name, value: value, validation: validation, manifest: manifest)
        }
        
        // Model reference validation is handled through type validation
        // Swift doesn't have separate modelRef field like other implementations
    }
    
    private func validateArgumentType(name: String, value: Any, manifest: ArgumentManifest) throws {
        switch manifest.type {
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
    
    private func validateArgumentConstraints(name: String, value: Any, validation: ValidationManifest, manifest: ArgumentManifest) throws {
        // String constraints
        if manifest.type == .string, let stringValue = value as? String {
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
        if manifest.type == .number || manifest.type == .integer {
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
    
    private func validateModelReference(name: String, value: Any, modelRef: String, models: [String: ModelManifest]?) throws {
        guard let models = models, let modelManifest = models[modelRef] else {
            throw ManifestError.validationFailed("Model reference '\(modelRef)' not found for argument '\(name)'")
        }
        
        guard let valueDict = value as? [String: Any] else {
            throw ManifestError.validationFailed("Argument '\(name)' with model reference expected object, got \(type(of: value))")
        }
        
        // Check required properties
        if let required = modelManifest.required {
            for requiredProp in required {
                if valueDict[requiredProp] == nil {
                    throw ManifestError.validationFailed("Required property '\(requiredProp)' missing in argument '\(name)' (model '\(modelRef)')")
                }
            }
        }
        
        // Validate properties (modelManifest.properties is not optional in Swift)
        for (propName, propValue) in valueDict {
            guard let propManifest = modelManifest.properties[propName] else {
                throw ManifestError.validationFailed("Unknown property '\(propName)' in argument '\(name)' (model '\(modelRef)')")
            }
            
            try validateArgumentValue(name: "\(name).\(propName)", value: propValue, manifest: propManifest, models: models)
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
    public static func serializeToJSON(_ manifest: Manifest) throws -> Data {
        let parser = ManifestParser()
        return try parser.serializeToJSON(manifest)
    }
    
    /// Static method for JSON string serialization
    public static func serializeToJSONString(_ manifest: Manifest) throws -> String {
        let parser = ManifestParser()
        return try parser.serializeToJSONString(manifest)
    }
    
    /// Static method for YAML serialization
    public static func serializeToYAML(_ manifest: Manifest) throws -> Data {
        let parser = ManifestParser()
        return try parser.serializeToYAML(manifest)
    }
    
    /// Static method for YAML string serialization
    public static func serializeToYAMLString(_ manifest: Manifest) throws -> String {
        let parser = ManifestParser()
        return try parser.serializeToYAMLString(manifest)
    }
    
    /// Static method for multi-file parsing
    public static func parseMultipleFiles(at urls: [URL]) throws -> Manifest {
        let parser = ManifestParser()
        return try parser.parseMultipleFiles(at: urls)
    }
    
    /// Static method for manifest merging
    public static func mergeManifests(base: inout Manifest, additional: Manifest) throws {
        let parser = ManifestParser()
        try parser.mergeManifests(base: &base, additional: additional)
    }
    
    /// Static method for argument validation
    public static func validateRequestArguments(_ args: [String: Any], against argManifests: [String: ArgumentManifest], models: [String: ModelManifest]?) throws {
        let parser = ManifestParser()
        try parser.validateRequestArguments(args, against: argManifests, models: models)
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