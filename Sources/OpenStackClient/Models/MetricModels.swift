import Foundation

// MARK: - Gnocchi (metric) models — phase 2
//
// Keystone service type: `metric`. IAD3 advertises the catalog endpoint at the
// host root (no `/v1`), while the API lives under `/v1/...` — so the client
// sets `serviceRoot = "v1"` (the Neutron pattern) and the resolver prepends it.
// Metric list responses are a bare JSON array; the resource-type map
// (`GET /v1/resource`) is a `{name: href}` object.

public struct GnocchiMetric: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var unit: String?
    public var resourceID: String?
    public var archivePolicyName: String?
    public var creator: String?
    public var created: String?

    public init(
        id: String,
        name: String,
        unit: String? = nil,
        resourceID: String? = nil,
        archivePolicyName: String? = nil,
        creator: String? = nil,
        created: String? = nil
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.resourceID = resourceID
        self.archivePolicyName = archivePolicyName
        self.creator = creator
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, unit, creator, created
        case resourceID = "resource_id"
        case archivePolicy = "archive_policy"
    }

    struct ArchivePolicy: Decodable { let name: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        resourceID = try c.decodeIfPresent(String.self, forKey: .resourceID)
        archivePolicyName = try c.decodeIfPresent(ArchivePolicy.self, forKey: .archivePolicy)?.name
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        created = try c.decodeIfPresent(String.self, forKey: .created)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(resourceID, forKey: .resourceID)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encodeIfPresent(created, forKey: .created)
    }
}

/// One entry of Gnocchi's resource-type map (`GET /v1/resource`).
public struct GnocchiResourceType: Sendable, Codable, Identifiable {
    public let id: String   // the resource-type name (e.g. "instance")
    public var name: String // same as id; the name field is the type
    public var href: String

    public init(id: String, name: String, href: String) {
        self.id = id
        self.name = name
        self.href = href
    }

    enum CodingKeys: String, CodingKey { case id, name, href }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        href = try c.decode(String.self, forKey: .href)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(href, forKey: .href)
    }
}

/// One Gnocchi archive policy (`GET /v1/archive_policy`). The `definition`
/// steps are the legal granularities for measures aggregation, and
/// `aggregation_methods` the legal methods (e.g. IAD3's `ceilometer-low-rate`
/// offers only `rate:mean` and `mean` at `0:05:00`).
public struct GnocchiArchivePolicy: Sendable, Codable, Identifiable {
    public struct Definition: Sendable, Codable, Equatable {
        public var timespan: String
        public var granularity: String
        public var points: Int?

        public init(timespan: String, granularity: String, points: Int? = nil) {
            self.timespan = timespan
            self.granularity = granularity
            self.points = points
        }
    }

    public let id: String   // the policy name
    public var name: String
    public var backWindow: Int?
    public var definition: [Definition]
    public var aggregationMethods: [String]

    public init(
        name: String,
        backWindow: Int? = nil,
        definition: [Definition] = [],
        aggregationMethods: [String] = []
    ) {
        self.id = name
        self.name = name
        self.backWindow = backWindow
        self.definition = definition
        self.aggregationMethods = aggregationMethods
    }

    enum CodingKeys: String, CodingKey {
        case name, definition
        case backWindow = "back_window"
        case aggregationMethods = "aggregation_methods"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(String.self, forKey: .name)
        id = n
        name = n
        backWindow = try c.decodeIfPresent(Int.self, forKey: .backWindow)
        definition = try c.decodeIfPresent([Definition].self, forKey: .definition) ?? []
        aggregationMethods = try c.decodeIfPresent([String].self, forKey: .aggregationMethods) ?? []
    }
}
