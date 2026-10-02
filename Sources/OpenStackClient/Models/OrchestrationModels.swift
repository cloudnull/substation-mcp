import Foundation

// MARK: - Heat (orchestration) models — phase 2
//
// Keystone service type: `orchestration`. API base path: `orchestration/v1`.
// Resources: stack (pollable — status CREATE_IN_PROGRESS ->
// CREATE_COMPLETE / UPDATE_IN_PROGRESS / DELETE_IN_PROGRESS). Stack outputs
// are a sub-collection fetched via an action.

public struct Stack: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var creation_time: String?
    public var updated_time: String?
    public var description: String?
    public var parameters: [String: String]?
    public var stack_resources_count: Int?

    public init(
        id: String,
        name: String,
        status: String = "CREATE_IN_PROGRESS",
        creation_time: String? = nil,
        updated_time: String? = nil,
        description: String? = nil,
        parameters: [String: String]? = nil,
        stack_resources_count: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.creation_time = creation_time
        self.updated_time = updated_time
        self.description = description
        self.parameters = parameters
        self.stack_resources_count = stack_resources_count
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case name = "stack_name"
        case creation_time, updated_time
        case description, parameters
        case stack_resources_count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "CREATE_IN_PROGRESS"
        creation_time = try c.decodeIfPresent(String.self, forKey: .creation_time)
        updated_time = try c.decodeIfPresent(String.self, forKey: .updated_time)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters)
        stack_resources_count = try c.decodeIfPresent(Int.self, forKey: .stack_resources_count)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(creation_time, forKey: .creation_time)
        try c.encodeIfPresent(updated_time, forKey: .updated_time)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(parameters, forKey: .parameters)
        try c.encodeIfPresent(stack_resources_count, forKey: .stack_resources_count)
    }
}

public struct StackOutput: Sendable, Codable {
    public let output_key: String
    public let output_value: String
    public let description: String?

    public init(output_key: String, output_value: String, description: String? = nil) {
        self.output_key = output_key
        self.output_value = output_value
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case output_key, output_value
        case description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output_key = try c.decode(String.self, forKey: .output_key)
        output_value = try c.decodeIfPresent(String.self, forKey: .output_value) ?? c.decodeIfPresent(Int.self, forKey: .output_value).map { String($0) } ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(output_key, forKey: .output_key)
        try c.encode(output_value, forKey: .output_value)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// Spec for creating a Heat stack from a template.
public struct CreateStackSpec: Sendable {
    public var name: String
    public var template: String
    public var parameters: [String: String]
    public var description: String?

    public init(name: String, template: String, parameters: [String: String] = [:], description: String? = nil) {
        self.name = name
        self.template = template
        self.parameters = parameters
        self.description = description
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"stack_name\":\"\(name)\"")
        // The template is a raw string; escape quotes/backslashes/newlines.
        let esc = template
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        parts.append("\"template_body\":\"\(esc)\"")
        if !parameters.isEmpty {
            let paramPairs = parameters.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"parameters\":{\(paramPairs)}")
        }
        if let d = description {
            let esc = d.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"description\":\"\(esc)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
