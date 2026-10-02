import Foundation

// MARK: - Swift (object storage) models — phase 2
//
// Keystone service type: `object-store`. API base path: `swift/v1`. The
// object-storage REST surface is account/container/object; the MCP catalog
// exposes two resources — `container` and `object` — with list/get/create/
// delete (object create = PUT).

public struct Container: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var count: Int?
    public var bytes: Int?
    public var created: String?
    public var updated: String?
    public var quotaBytes: Int?

    public init(
        id: String,
        name: String,
        count: Int? = nil,
        bytes: Int? = nil,
        created: String? = nil,
        updated: String? = nil,
        quotaBytes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.count = count
        self.bytes = bytes
        self.created = created
        self.updated = updated
        self.quotaBytes = quotaBytes
    }

    // The container list response is a bare array of [name, count, bytes]
    // triples (the X-Container-Meta-* headers carry the rest). We model the
    // wire shape with a dedicated list element and convert to Container.
    enum CodingKeys: String, CodingKey {
        case name, count, bytes, created, updated
        case quotaBytes = "quota_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = name
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        quotaBytes = try c.decodeIfPresent(Int.self, forKey: .quotaBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(count, forKey: .count)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(updated, forKey: .updated)
        try c.encodeIfPresent(quotaBytes, forKey: .quotaBytes)
    }
}

/// A Swift container list element is `[name, count, bytes]`.
public struct ContainerListElement: Sendable, Codable {
    public var name: String
    public var count: Int?
    public var bytes: Int?

    public init(name: String, count: Int? = nil, bytes: Int? = nil) {
        self.name = name
        self.count = count
        self.bytes = bytes
    }

    public var container: Container {
        Container(id: name, name: name, count: count, bytes: bytes)
    }
}

public struct Object: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var size: Int?
    public var hash: String?
    public var contentType: String?
    public var deleted: Bool?
    public var lastModified: String?
    public var metadata: [String: String]?

    public init(
        id: String,
        name: String,
        size: Int? = nil,
        hash: String? = nil,
        contentType: String? = nil,
        deleted: Bool? = nil,
        lastModified: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.hash = hash
        self.contentType = contentType
        self.deleted = deleted
        self.lastModified = lastModified
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case name, hash, size, deleted
        case contentType = "content_type"
        case lastModified = "last_modified"
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = name
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(deleted, forKey: .deleted)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Spec for creating a Swift container. Container creation is a PUT to
/// `/v1/<account>/<container>` with an empty body; optional X-Container-Meta
/// headers carry metadata and the X-Container-Quota-Bytes header carries the
/// quota.
public struct CreateContainerSpec: Sendable {
    public var name: String
    public var metadata: [String: String]
    public var quotaBytes: Int?

    public init(name: String, metadata: [String: String] = [:], quotaBytes: Int? = nil) {
        self.name = name
        self.metadata = metadata
        self.quotaBytes = quotaBytes
    }

    /// Extra headers for a container create (X-Container-Meta-<key>, plus the
    /// quota header). Swift container creation is a header-driven PUT, so the
    /// "body" is the header set.
    public func headers() -> [(String, String)] {
        var out: [(String, String)] = metadata.map { ("X-Container-Meta-\($0.key)", $0.value) }
        if let quotaBytes {
            out.append(("X-Container-Quota-Bytes", String(quotaBytes)))
        }
        return out
    }
}

/// Spec for putting an object. The object body is the (base64) payload; the
/// Content-Type and X-Object-Meta-* headers are set at PUT time.
public struct CreateObjectSpec: Sendable {
    public var container: String
    public var name: String
    public var content: String
    public var contentType: String
    public var metadata: [String: String]

    public init(container: String, name: String, content: String, contentType: String = "application/octet-stream", metadata: [String: String] = [:]) {
        self.container = container
        self.name = name
        self.content = content
        self.contentType = contentType
        self.metadata = metadata
    }

    public func headers() -> [(String, String)] {
        var out: [(String, String)] = [("Content-Type", contentType)]
        out.append(contentsOf: metadata.map { ("X-Object-Meta-\($0.key)", $0.value) })
        return out
    }
}
