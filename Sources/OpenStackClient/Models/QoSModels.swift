import Foundation

// MARK: - Neutron QoS

/// A Neutron QoS policy (`/v2.0/qos/policies`, extension alias `qos`).
///
/// Rules are heterogeneous per rule type, so they are passed through unmodeled
/// as `RawJSONValue` (open key sets: bandwidth_limit carries max_kbps/
/// max_burst_kbps/direction, dscp_marking carries dscp_mark, minimum_bandwidth
/// carries min_kbps/direction, and clouds add more via rule-types discovery).
public struct QoSPolicy: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var description: String
    public var shared: Bool
    public var projectID: String
    public var rules: [RawJSONValue]
    public var tags: [String]

    public init(
        id: String,
        name: String = "",
        description: String = "",
        shared: Bool = false,
        projectID: String = "",
        rules: [RawJSONValue] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.shared = shared
        self.projectID = projectID
        self.rules = rules
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, shared, rules, tags
        case projectID = "project_id"
    }
}

/// One Neutron QoS rule type (`/v2.0/qos/rule-types`). The `type` is the rule
/// discriminator; remaining keys are the type's attribute schema, passed
/// through unmodeled.
public struct QoSRuleType: Sendable, Codable {
    public var type: String
    public var raw: [String: RawJSONValue]

    public init(type: String, raw: [String: RawJSONValue] = [:]) {
        self.type = type
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let type = (try? container.decode(String.self, forKey: DynamicKey(stringValue: "type"))) ?? ""
        var rest: [String: RawJSONValue] = [:]
        for key in container.allKeys where key.stringValue != "type" {
            if let v = try? container.decode(RawJSONValue.self, forKey: key) {
                rest[key.stringValue] = v
            }
        }
        self.type = type
        self.raw = rest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(type, forKey: DynamicKey(stringValue: "type"))
        for (k, v) in raw {
            try container.encode(v, forKey: DynamicKey(stringValue: k))
        }
    }
}

/// A QoS rule in wire form. The `type` key selects the rule kind; the rest of
/// the object is the type's attributes (validated server-side against
/// rule-types).
public struct QoSRuleSpec: Sendable {
    public var type: String
    public var attributes: [String: RawJSONValue]

    public init(type: String, attributes: [String: RawJSONValue] = [:]) {
        self.type = type
        self.attributes = attributes
    }

    func body() -> String {
        var parts: [String] = ["\"type\":\"\(type)\""]
        for (k, v) in attributes.sorted(by: { $0.key < $1.key }) {
            if let data = try? JSONEncoder().encode(v),
               let s = String(data: data, encoding: .utf8) {
                parts.append("\"\(k)\":\(s)")
            }
        }
        return "{\(parts.joined(separator: ","))}"
    }
}

/// Keyed-coding helper for open JSON objects.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - CloudFormation (heat-cfn)

/// A CloudFormation stack as returned by heat-cfn (PascalCase wire fields).
///
/// Response shapes differ per action: ListStacks returns summary rows
/// (StackId/StackName/StackStatus/CreationTime), DescribeStacks returns full
/// rows (adds TemplateDescription, Parameters, Outputs, Tags). All optional
/// fields decode to nil/empty so one type covers both.
public struct CFNStack: Sendable, Codable, Identifiable {
    public var stackID: String
    public var stackName: String
    public var stackStatus: String
    public var stackStatusReason: String?
    public var creationTime: String
    public var deletionTime: String?
    public var templateDescription: String?
    public var parameters: [CFNParameter]
    public var outputs: [CFNOutput]
    public var tags: [CFNTag]

    public var id: String { stackID }

    public init(
        stackID: String,
        stackName: String = "",
        stackStatus: String = "CREATE_IN_PROGRESS",
        stackStatusReason: String? = nil,
        creationTime: String = "",
        deletionTime: String? = nil,
        templateDescription: String? = nil,
        parameters: [CFNParameter] = [],
        outputs: [CFNOutput] = [],
        tags: [CFNTag] = []
    ) {
        self.stackID = stackID
        self.stackName = stackName
        self.stackStatus = stackStatus
        self.stackStatusReason = stackStatusReason
        self.creationTime = creationTime
        self.deletionTime = deletionTime
        self.templateDescription = templateDescription
        self.parameters = parameters
        self.outputs = outputs
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case stackID = "StackId"
        case stackName = "StackName"
        case stackStatus = "StackStatus"
        case stackStatusReason = "StackStatusReason"
        case creationTime = "CreationTime"
        case deletionTime = "DeletionTime"
        case templateDescription = "TemplateDescription"
        case parameters = "Parameters"
        case outputs = "Outputs"
        case tags = "Tags"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stackID = try c.decode(String.self, forKey: .stackID)
        stackName = try c.decodeIfPresent(String.self, forKey: .stackName) ?? ""
        stackStatus = try c.decodeIfPresent(String.self, forKey: .stackStatus) ?? "UNKNOWN"
        stackStatusReason = try c.decodeIfPresent(String.self, forKey: .stackStatusReason)
        creationTime = try c.decodeIfPresent(String.self, forKey: .creationTime) ?? ""
        deletionTime = try c.decodeIfPresent(String.self, forKey: .deletionTime)
        templateDescription = try c.decodeIfPresent(String.self, forKey: .templateDescription)
        parameters = try c.decodeIfPresent([CFNParameter].self, forKey: .parameters) ?? []
        outputs = try c.decodeIfPresent([CFNOutput].self, forKey: .outputs) ?? []
        tags = try c.decodeIfPresent([CFNTag].self, forKey: .tags) ?? []
    }
}

public struct CFNParameter: Sendable, Codable {
    public var key: String
    public var value: String

    enum CodingKeys: String, CodingKey {
        case key = "ParameterKey"
        case value = "ParameterValue"
    }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct CFNOutput: Sendable, Codable {
    public var outputKey: String
    public var outputValue: String
    public var description: String?

    enum CodingKeys: String, CodingKey {
        case outputKey = "OutputKey"
        case outputValue = "OutputValue"
        case description = "Description"
    }

    public init(outputKey: String, outputValue: String, description: String? = nil) {
        self.outputKey = outputKey
        self.outputValue = outputValue
        self.description = description
    }
}

public struct CFNTag: Sendable, Codable {
    public var key: String
    public var value: String

    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case value = "Value"
    }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Inputs for `CreateStack`. `templateBody` is the JSON/YAML template;
/// `templateURL` is an alternative (mutually exclusive server-side).
public struct CreateCFNStackSpec: Sendable {
    public var stackName: String
    public var templateBody: String?
    public var templateURL: String?
    public var parameters: [String: String]
    public var tags: [String: String]
    public var disableRollback: Bool

    public init(
        stackName: String,
        templateBody: String? = nil,
        templateURL: String? = nil,
        parameters: [String: String] = [:],
        tags: [String: String] = [:],
        disableRollback: Bool = false
    ) {
        self.stackName = stackName
        self.templateBody = templateBody
        self.templateURL = templateURL
        self.parameters = parameters
        self.tags = tags
        self.disableRollback = disableRollback
    }
}
