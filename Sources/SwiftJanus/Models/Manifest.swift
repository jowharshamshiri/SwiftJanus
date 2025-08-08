// Manifest.swift
// Manifest models for Janus

import Foundation

// MARK: - Utility Types

/// Box class to enable recursive type definitions in structs
public final class Box<T>: Codable, Sendable where T: Codable & Sendable {
    public let value: T
    
    public init(_ value: T) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(T.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Core Manifest

/// Represents the complete Manifest document
public struct Manifest: Codable, Sendable {
    public let version: String
    public let name: String?
    public let models: [String: ModelManifest]?
    
    public init(version: String, name: String? = nil, models: [String: ModelManifest]? = nil) {
        self.version = version
        self.name = name
        self.models = models
    }
}

// ChannelManifest REMOVED - Channels are completely removed from protocol

/// Manifest for a request within a channel
public struct RequestManifest: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let args: [String: ArgumentManifest]?
    public let response: ResponseManifest?
    public let errorCodes: [String]?
    
    public init(
        name: String? = nil,
        description: String? = nil,
        args: [String: ArgumentManifest]? = nil,
        response: ResponseManifest? = nil,
        errorCodes: [String]? = nil
    ) {
        self.name = name
        self.description = description
        self.args = args
        self.response = response
        self.errorCodes = errorCodes
    }
}

/// Manifest for request arguments  
public struct ArgumentManifest: Codable, Sendable {
    public let type: ArgumentType
    private let _required: Bool?
    public let description: String?
    public let defaultValue: AnyCodable?
    public let validation: ValidationManifest?
    public let items: Box<ArgumentManifest>?  // For array types - matches Go implementation
    
    // Computed property that defaults to false like Go
    public var required: Bool {
        return _required ?? false
    }
    
    private enum CodingKeys: String, CodingKey {
        case type
        case _required = "required"
        case description
        case defaultValue
        case validation
        case items
    }
    
    public init(
        type: ArgumentType,
        required: Bool = false,
        description: String? = nil,
        defaultValue: AnyCodable? = nil,
        validation: ValidationManifest? = nil,
        items: ArgumentManifest? = nil
    ) {
        self.type = type
        self._required = required
        self.description = description
        self.defaultValue = defaultValue
        self.validation = validation
        self.items = items.map { Box($0) }
    }
}

/// Manifest for request responses
public struct ResponseManifest: Codable, Sendable {
    public let type: ArgumentType?
    public let properties: [String: ArgumentManifest]?
    public let description: String?
    public let items: Box<ArgumentManifest>?  // For array response types - matches Go implementation
    
    public init(
        type: ArgumentType? = nil,
        properties: [String: ArgumentManifest]? = nil,
        description: String? = nil,
        items: ArgumentManifest? = nil
    ) {
        self.type = type
        self.properties = properties
        self.description = description
        self.items = items.map { Box($0) }
    }
}

/// Manifest for error responses
public struct ErrorManifest: Codable, Sendable {
    public let code: Int
    public let message: String
    public let description: String?
    
    public init(code: Int, message: String, description: String? = nil) {
        self.code = code
        self.message = message
        self.description = description
    }
}

/// Validation constraints for arguments
public struct ValidationManifest: Codable, Sendable {
    public let minLength: Int?
    public let maxLength: Int?
    public let pattern: String?
    public let minimum: Double?
    public let maximum: Double?
    public let `enum`: [AnyCodable]?
    
    public init(
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        `enum`: [AnyCodable]? = nil
    ) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.minimum = minimum
        self.maximum = maximum
        self.`enum` = `enum`
    }
}

/// Data model manifest for complex types
public struct ModelManifest: Codable, Sendable {
    public let type: ArgumentType
    public let properties: [String: ArgumentManifest]
    public let required: [String]?
    public let description: String?
    
    public init(
        type: ArgumentType,
        properties: [String: ArgumentManifest],
        required: [String]? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.description = description
    }
}

/// Supported argument/response types
public enum ArgumentType: String, Codable, Sendable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
    case null
    case reference // For model references like "$ref": "#/models/MyModel"
}

/// Type-erased Codable wrapper for dynamic values
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any
    
    public init<T: Codable>(_ value: T) {
        self.value = value
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let stringValue as String:
            try container.encode(stringValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            let encodableArray = arrayValue.compactMap { item -> AnyCodable? in
                // Handle AnyCodable values directly to avoid double-wrapping
                if let anyCodableItem = item as? AnyCodable {
                    return anyCodableItem
                } else if let codableItem = item as? (any Codable) {
                    return AnyCodable(codableItem)
                }
                return nil
            }
            try container.encode(encodableArray)
        case let dictValue as [String: Any]:
            let encodableDict = dictValue.compactMapValues { item -> AnyCodable? in
                // Handle AnyCodable values directly to avoid double-wrapping
                if let anyCodableItem = item as? AnyCodable {
                    return anyCodableItem
                } else if let codableItem = item as? (any Codable) {
                    return AnyCodable(codableItem)
                }
                return nil
            }
            try container.encode(encodableDict)
        default:
            try container.encodeNil()
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}