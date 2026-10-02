import Foundation

// MARK: - Barbican (key manager) models — phase 2
//
// Keystone service type: `key-manager`. API base path: `barbican/v1`.
// Resources: `secret` (with a status lifecycle: inactive -> active -> expired /
// deleted) and `container` (a group of secrets). Secrets are pollable.

public struct Secret: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var type: String
    public var status: String
    public var algorithm: String?
    public var bit_size: Int?
    public var mode: String?
    public var created_at: String?
    public var updated_at: String?
    public var is_secret: Bool?
    public var visibility: String?

    public init(
        id: String,
        name: String? = nil,
        type: String,
        status: String = "inactive",
        algorithm: String? = nil,
        bit_size: Int? = nil,
        mode: String? = nil,
        created_at: String? = nil,
        updated_at: String? = nil,
        is_secret: Bool? = nil,
        visibility: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
        self.algorithm = algorithm
        self.bit_size = bit_size
        self.mode = mode
        self.created_at = created_at
        self.updated_at = updated_at
        self.is_secret = is_secret
        self.visibility = visibility
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, status, algorithm
        case bit_size, mode, created_at, updated_at
        case is_secret, visibility
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "opaque"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "inactive"
        algorithm = try c.decodeIfPresent(String.self, forKey: .algorithm)
        bit_size = try c.decodeIfPresent(Int.self, forKey: .bit_size)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try c.decodeIfPresent(String.self, forKey: .updated_at)
        is_secret = try c.decodeIfPresent(Bool.self, forKey: .is_secret)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(algorithm, forKey: .algorithm)
        try c.encodeIfPresent(bit_size, forKey: .bit_size)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(updated_at, forKey: .updated_at)
        try c.encodeIfPresent(is_secret, forKey: .is_secret)
        try c.encodeIfPresent(visibility, forKey: .visibility)
    }
}

public struct SecretContainer: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var type: String?
    public var secret_refs: [String]?

    public init(id: String, name: String? = nil, type: String? = nil, secret_refs: [String]? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.secret_refs = secret_refs
    }

    enum CodingKeys: String, CodingKey { case id, name, type; case secret_refs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        secret_refs = try c.decodeIfPresent([String].self, forKey: .secret_refs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(secret_refs, forKey: .secret_refs)
    }
}

/// Barbican secret payload (the GET /v1/secrets/{id} returns `payload` +
/// `payload_content_type`; for `opaque` types the payload is a base64 string).
public struct SecretPayload: Sendable, Codable {
    public var payload: String?
    public var payloadContentType: String?

    public init(payload: String? = nil, payloadContentType: String? = nil) {
        self.payload = payload
        self.payloadContentType = payloadContentType
    }

    enum CodingKeys: String, CodingKey { case payload; case payloadContentType = "payload_content_type" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        payload = try c.decodeIfPresent(String.self, forKey: .payload)
        payloadContentType = try c.decodeIfPresent(String.self, forKey: .payloadContentType)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(payload, forKey: .payload)
        try c.encodeIfPresent(payloadContentType, forKey: .payloadContentType)
    }
}

/// Spec for creating a Barbican secret. `opaque` secrets carry a base64
/// `secret` payload; symmetric/asymmetric keys are generated server-side and
/// only take name/type/algorithm/bit_size/mode.
public struct CreateSecretSpec: Sendable {
    public var name: String?
    public var type: String
    public var algorithm: String?
    public var bit_size: Int?
    public var mode: String?
    public var secret: String?      // base64 payload for opaque secrets
    public var visibility: String?

    public init(name: String? = nil, type: String = "opaque", algorithm: String? = nil, bit_size: Int? = nil, mode: String? = nil, secret: String? = nil, visibility: String? = nil) {
        self.name = name
        self.type = type
        self.algorithm = algorithm
        self.bit_size = bit_size
        self.mode = mode
        self.secret = secret
        self.visibility = visibility
    }

    public func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        parts.append("\"type\":\"\(type)\"")
        if let algorithm { parts.append("\"algorithm\":\"\(algorithm)\"") }
        if let bit_size { parts.append("\"bit_size\":\(bit_size)") }
        if let mode { parts.append("\"mode\":\"\(mode)\"") }
        if let secret { parts.append("\"secret\":\"\(secret)\"") }
        if let visibility { parts.append("\"visibility\":\"\(visibility)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
