import Foundation

// MARK: - Manila (shared file systems) models — phase 2
//
// Keystone service type: `sharev2`. API base path: `share/v2`.
// Resources: share (pollable — status lifecycle creating -> available)
// and share_access (permission on a share).

public struct Share: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var share_size: Int
    public var share_type: String
    public var description: String?
    public var is_public: Bool?
    public var created_at: String?

    public init(
        id: String,
        name: String,
        status: String = "available",
        share_size: Int = 1,
        share_type: String = "generic",
        description: String? = nil,
        is_public: Bool? = false,
        created_at: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.share_size = share_size
        self.share_type = share_type
        self.description = description
        self.is_public = is_public
        self.created_at = created_at
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case share_size, share_type
        case description
        case is_public
        case created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "available"
        share_size = try c.decodeIfPresent(Int.self, forKey: .share_size) ?? 1
        share_type = try c.decodeIfPresent(String.self, forKey: .share_type) ?? "generic"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        is_public = try c.decodeIfPresent(Bool.self, forKey: .is_public)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(share_size, forKey: .share_size)
        try c.encode(share_type, forKey: .share_type)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(is_public, forKey: .is_public)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }
}

public struct ShareAccess: Sendable, Codable, Identifiable {
    public let id: String
    public var share_id: String
    public var access_to: String
    public var access_type: String
    public var access_protocol: String
    public var state: String?

    public init(
        id: String,
        share_id: String,
        access_to: String,
        access_type: String = "ip",
        access_protocol: String = "nfs",
        state: String? = "accessible"
    ) {
        self.id = id
        self.share_id = share_id
        self.access_to = access_to
        self.access_type = access_type
        self.access_protocol = access_protocol
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id
        case share_id, access_to
        case access_type, access_protocol
        case state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        share_id = try c.decode(String.self, forKey: .share_id)
        access_to = try c.decode(String.self, forKey: .access_to)
        access_type = try c.decodeIfPresent(String.self, forKey: .access_type) ?? "ip"
        access_protocol = try c.decodeIfPresent(String.self, forKey: .access_protocol) ?? "nfs"
        state = try c.decodeIfPresent(String.self, forKey: .state)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(share_id, forKey: .share_id)
        try c.encode(access_to, forKey: .access_to)
        try c.encode(access_type, forKey: .access_type)
        try c.encode(access_protocol, forKey: .access_protocol)
        try c.encodeIfPresent(state, forKey: .state)
    }
}

/// Spec for creating a Manila share.
public struct CreateShareSpec: Sendable {
    public var name: String
    public var share_size: Int
    public var share_type: String
    public var description: String?
    public var is_public: Bool?

    public init(name: String, share_size: Int = 1, share_type: String = "generic", description: String? = nil, is_public: Bool? = false) {
        self.name = name
        self.share_size = share_size
        self.share_type = share_type
        self.description = description
        self.is_public = is_public
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"name\":\"\(name)\"")
        parts.append("\"share_size\":\(share_size)")
        parts.append("\"share_type\":\"\(share_type)\"")
        if let d = description {
            let esc = d.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"description\":\"\(esc)\"")
        }
        if let pub = is_public { parts.append("\"is_public\":\(pub)") }
        return "{\"share\":{" + parts.joined(separator: ",") + "}}"
    }
}

/// Spec for granting access to a Manila share.
public struct CreateShareAccessSpec: Sendable {
    public var share_id: String
    public var access_to: String
    public var access_type: String
    public var access_protocol: String?

    public init(share_id: String, access_to: String, access_type: String = "ip", access_protocol: String? = "nfs") {
        self.share_id = share_id
        self.access_to = access_to
        self.access_type = access_type
        self.access_protocol = access_protocol
    }

    public func body() -> String {
        var parts: [String] = []
        parts.append("\"share_id\":\"\(share_id)\"")
        parts.append("\"access_to\":\"\(access_to)\"")
        parts.append("\"access_type\":\"\(access_type)\"")
        if let p = access_protocol { parts.append("\"access_protocol\":\"\(p)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
