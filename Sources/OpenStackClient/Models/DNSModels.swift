import Foundation

// MARK: - Designate (DNS) models — phase 2
//
// Keystone service type: `dns`. API base path: `designate/v3`. Designate
// resources: zone (pollable — status lifecycle pending -> active /
// pending_delete) and recordset (records live under a zone).

public struct Zone: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var email: String?
    public var status: String
    public var ttl: Int?
    public var actions: [[String: String]]?
    public var created_at: String?
    public var updated_at: String?

    public init(
        id: String,
        name: String,
        email: String? = nil,
        status: String = "pending",
        ttl: Int? = nil,
        actions: [[String: String]]? = nil,
        created_at: String? = nil,
        updated_at: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.status = status
        self.ttl = ttl
        self.actions = actions
        self.created_at = created_at
        self.updated_at = updated_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email, status, ttl, actions
        case created_at, updated_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        ttl = try c.decodeIfPresent(Int.self, forKey: .ttl)
        actions = try c.decodeIfPresent([[String: String]].self, forKey: .actions)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(ttl, forKey: .ttl)
        try c.encodeIfPresent(actions, forKey: .actions)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(updated_at, forKey: .updated_at)
    }
}

public struct RecordSet: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var type: String
    public var ttl: Int?
    public var records: [String]
    public var zone_id: String?
    public var status: String?

    public init(
        id: String,
        name: String,
        type: String,
        ttl: Int? = nil,
        records: [String] = [],
        zone_id: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.ttl = ttl
        self.records = records
        self.zone_id = zone_id
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, ttl, records
        case zone_id, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        ttl = try c.decodeIfPresent(Int.self, forKey: .ttl)
        records = try c.decodeIfPresent([String].self, forKey: .records) ?? []
        zone_id = try c.decodeIfPresent(String.self, forKey: .zone_id)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(ttl, forKey: .ttl)
        try c.encode(records, forKey: .records)
        try c.encodeIfPresent(zone_id, forKey: .zone_id)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

/// Spec for creating a DNS zone.
public struct CreateZoneSpec: Sendable {
    public var name: String
    public var email: String?
    public var ttl: Int?

    public init(name: String, email: String? = nil, ttl: Int? = nil) {
        self.name = name
        self.email = email
        self.ttl = ttl
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(name)\"")
        if let e = email { parts.append("\"email\":\"\(e)\"") }
        if let t = ttl { parts.append("\"ttl\":\(t)") }
        return "{\"zone\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// Spec for creating a DNS record set (under a zone).
public struct CreateRecordSetSpec: Sendable {
    public var zone_id: String?
    public var name: String
    public var type: String
    public var ttl: Int?
    public var records: [String]

    public init(zone_id: String? = nil, name: String, type: String, ttl: Int? = nil, records: [String] = []) {
        self.zone_id = zone_id
        self.name = name
        self.type = type
        self.ttl = ttl
        self.records = records
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(name)\"")
        parts.append("\"type\":\"\(type)\"")
        if let t = ttl { parts.append("\"ttl\":\(t)") }
        let recs = records.map { "\"\($0)\"" }.joined(separator: ",")
        parts.append("\"records\":[\(recs)]")
        if let z = zone_id { parts.append("\"zone_id\":\"\(z)\"") }
        return "{\"recordset\":{" + parts.joined(separator: ",") + "}}"
    }
}
