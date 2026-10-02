import Foundation

// MARK: - Magnum (container infrastructure) models — phase 2
//
// Keystone service type: `container`. API base path: `container`.
// Resources: baymodel, bay, cluster. Cluster is pollable (status
// lifecycle creating -> active / error).

public struct MagnumCluster: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var master_count: Int
    public var node_count: Int
    public var server_group: String?
    public var cluster_template_id: String?
    public var created_at: String?
    public var updated_at: String?

    public init(
        id: String,
        name: String,
        status: String = "CREATING",
        master_count: Int = 1,
        node_count: Int = 0,
        server_group: String? = nil,
        cluster_template_id: String? = nil,
        created_at: String? = nil,
        updated_at: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.master_count = master_count
        self.node_count = node_count
        self.server_group = server_group
        self.cluster_template_id = cluster_template_id
        self.created_at = created_at
        self.updated_at = updated_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case master_count, node_count
        case server_group
        case cluster_template_id
        case created_at, updated_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "CREATING"
        master_count = try c.decodeIfPresent(Int.self, forKey: .master_count) ?? 1
        node_count = try c.decodeIfPresent(Int.self, forKey: .node_count) ?? 0
        server_group = try c.decodeIfPresent(String.self, forKey: .server_group)
        cluster_template_id = try c.decodeIfPresent(String.self, forKey: .cluster_template_id)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(master_count, forKey: .master_count)
        try c.encode(node_count, forKey: .node_count)
        try c.encodeIfPresent(server_group, forKey: .server_group)
        try c.encodeIfPresent(cluster_template_id, forKey: .cluster_template_id)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(updated_at, forKey: .updated_at)
    }
}

public struct MagnumClusterTemplate: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var master_count: Int
    public var node_count: Int
    public var created_at: String?

    public init(id: String, name: String, master_count: Int = 1, node_count: Int = 0, created_at: String? = nil) {
        self.id = id
        self.name = name
        self.master_count = master_count
        self.node_count = node_count
        self.created_at = created_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case master_count, node_count
        case created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        master_count = try c.decodeIfPresent(Int.self, forKey: .master_count) ?? 1
        node_count = try c.decodeIfPresent(Int.self, forKey: .node_count) ?? 0
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(master_count, forKey: .master_count)
        try c.encode(node_count, forKey: .node_count)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }
}

/// Spec for creating a container (cluster) from a cluster template.
public struct CreateMagnumClusterSpec: Sendable {
    public var name: String
    public var cluster_template_id: String?
    public var master_count: Int?
    public var node_count: Int?
    public var server_group: String?

    public init(name: String, cluster_template_id: String? = nil, master_count: Int? = nil, node_count: Int? = nil, server_group: String? = nil) {
        self.name = name
        self.cluster_template_id = cluster_template_id
        self.master_count = master_count
        self.node_count = node_count
        self.server_group = server_group
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(name)\"")
        if let ct = cluster_template_id { parts.append("\"cluster_template_id\":\"\(ct)\"") }
        if let mc = master_count { parts.append("\"master_count\":\(mc)") }
        if let nc = node_count { parts.append("\"node_count\":\(nc)") }
        if let sg = server_group { parts.append("\"server_group\":\"\(sg)\"") }
        return "{\"container\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// Spec for creating a cluster template.
public struct CreateMagnumClusterTemplateSpec: Sendable {
    public var name: String
    public var master_count: Int
    public var node_count: Int

    public init(name: String, master_count: Int = 1, node_count: Int = 0) {
        self.name = name
        self.master_count = master_count
        self.node_count = node_count
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(name)\"")
        parts.append("\"master_count\":\(master_count)")
        parts.append("\"node_count\":\(node_count)")
        return "{\"cluster_template\":{" + parts.joined(separator: ",") + "}}"
    }
}
