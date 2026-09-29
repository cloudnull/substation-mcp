import Foundation

/// A small JSON-Schema subset sufficient for validating OpenStack resource
/// create/update specs. Supports: `type`, `properties`, `required`, `items`,
/// `enum`, `description`, `additionalProperties`.
///
/// Validation returns `[ValidationIssue]` with the failing path, expected
/// type, found type, and the schema fragment so the model can self-correct
/// in one turn (spec §8.2).
///
/// This is a class (not a struct) because the schema is recursive
/// (properties are nested schemas, items is a nested schema).
public final class JSONSchema: @unchecked Sendable {
    /// The expected JSON type name: "string", "integer", "number", "boolean", "object", "array".
    public let type: String?
    /// Object properties, keyed by property name.
    public let properties: [String: JSONSchema]?
    /// Required property names for object types.
    public let required: [String]?
    /// The item schema for array types.
    public let items: JSONSchema?
    /// Enumerated allowed values (for string/integer types).
    public let enumValues: [JSONValue]?
    /// Human-readable description.
    public let description: String?
    /// Whether additional properties are allowed on objects. `nil` = allow.
    public let additionalProperties: Bool?

    public init(
        type: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        items: JSONSchema? = nil,
        enumValues: [JSONValue]? = nil,
        description: String? = nil,
        additionalProperties: Bool? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
        self.description = description
        self.additionalProperties = additionalProperties
    }

    // MARK: - Validation

    /// A single validation issue: the failing path, what was expected, what
    /// was found, and the relevant schema fragment.
    public struct ValidationIssue: Sendable, Equatable {
        public let path: String
        public let expected: String
        public let found: String
        public let fragment: String

        public init(path: String, expected: String, found: String, fragment: String) {
            self.path = path
            self.expected = expected
            self.found = found
            self.fragment = fragment
        }
    }

    /// Validate a JSON object against this schema. Returns an empty array on
    /// success, or one issue per problem on failure.
    public func validate(_ value: JSONValue) -> [ValidationIssue] {
        validate(value: value, schema: self, path: "$")
    }

    private func validate(value: JSONValue, schema: JSONSchema, path: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // Check type
        if let expectedType = schema.type {
            let actualType = JSONSchema.typeName(of: value)
            if actualType != expectedType {
                issues.append(.init(
                    path: path,
                    expected: expectedType,
                    found: actualType,
                    fragment: schema.fragment
                ))
                return issues
            }
        }

        // Check enum
        if let enumValues = schema.enumValues {
            if !enumValues.contains(value) {
                let allowed = enumValues.map { $0.jsonDescription }.joined(separator: ", ")
                issues.append(.init(
                    path: path,
                    expected: "one of [\(allowed)]",
                    found: value.jsonDescription,
                    fragment: schema.fragment
                ))
            }
        }

        // Recurse into object properties
        if let properties = schema.properties, case .object(let obj) = value {
            if let required = schema.required {
                for field in required {
                    if obj[field] == nil {
                        issues.append(.init(
                            path: "\(path).\(field)",
                            expected: schema.properties?[field]?.type ?? "any",
                            found: "missing",
                            fragment: "required: \(required.joined(separator: ", "))"
                        ))
                    }
                }
            }

            for (key, val) in obj {
                if let propSchema = properties[key] {
                    issues.append(contentsOf: validate(value: val, schema: propSchema, path: "\(path).\(key)"))
                } else if schema.additionalProperties == false {
                    issues.append(.init(
                        path: "\(path).\(key)",
                        expected: "known property",
                        found: "unknown property '\(key)'",
                        fragment: "allowed: \(properties.keys.sorted().joined(separator: ", "))"
                    ))
                }
            }
        }

        // Recurse into array items
        if let items = schema.items, case .array(let arr) = value {
            for (i, element) in arr.enumerated() {
                issues.append(contentsOf: validate(value: element, schema: items, path: "\(path)[\(i)]"))
            }
        }

        return issues
    }

    /// The JSON type name for a value.
    static func typeName(of value: JSONValue) -> String {
        switch value {
        case .string: return "string"
        case .integer: return "integer"
        case .float: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// A short fragment of the schema for error messages.
    var fragment: String {
        var parts: [String] = []
        if let type { parts.append("type: \(type)") }
        if let required, !required.isEmpty { parts.append("required: [\(required.joined(separator: ", "))]") }
        if let enumValues { parts.append("enum: [\(enumValues.map { $0.jsonDescription }.joined(separator: ", "))]") }
        if let properties { parts.append("properties: [\(properties.keys.sorted().joined(separator: ", "))]") }
        if let description { parts.append(description) }
        return parts.isEmpty ? "{}" : parts.joined(separator: "; ")
    }
}
