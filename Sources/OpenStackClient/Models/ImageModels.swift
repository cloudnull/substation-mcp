import Foundation

// MARK: - Image

/// A Glance image.
public struct Image: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var statusReason: String?
    public var visibility: String
    public var diskFormat: String
    public var containerFormat: String
    public var size: Int
    public var minRAM: Int
    public var minDisk: Int
    public var protected: Bool
    public var tags: [String]
    public var properties: [String: String]
    public var created: String
    public var updated: String

    public init(
        id: String,
        name: String = "",
        status: String = "queued",
        statusReason: String? = nil,
        visibility: String = "private",
        diskFormat: String = "raw",
        containerFormat: String = "bare",
        size: Int = 0,
        minRAM: Int = 0,
        minDisk: Int = 0,
        protected: Bool = false,
        tags: [String] = [],
        properties: [String: String] = [:],
        created: String = "",
        updated: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.statusReason = statusReason
        self.visibility = visibility
        self.diskFormat = diskFormat
        self.containerFormat = containerFormat
        self.size = size
        self.minRAM = minRAM
        self.minDisk = minDisk
        self.protected = protected
        self.tags = tags
        self.properties = properties
        self.created = created
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, visibility, size, tags, protected, properties
        case statusReason = "status_reason"
        case diskFormat = "disk_format"
        case containerFormat = "container_format"
        case minRAM = "min_ram"
        case minDisk = "min_disk"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Glance's wire attributes, i.e. every key that is NOT a custom property.
    /// Its schema declares `additionalProperties: {"type": "string"}`, so any
    /// other top-level key is a custom property, and Glance never replies with a
    /// nested `properties` object at all.
    private static let wireAttributes: Set<String> = [
        "id", "name", "status", "status_reason", "visibility", "disk_format",
        "container_format", "size", "min_ram", "min_disk", "protected", "tags",
        "created_at", "updated_at", "owner", "schema", "direct_url", "self",
        "file", "virtual_size", "checksum", "os_hash_algo", "os_hash_value",
        "imports", "os_hidden", "locations", "stores", "os_glance_granted_till",
        "os_glance_importing_to_stores", "os_glance_failed_import"
    ]

    /// Decodes Glance's FLAT image representation: the declared attributes come
    /// from their keys, and every remaining top-level string key is a custom
    /// property folded into `properties`. A nested `properties` object is also
    /// accepted, so a test double that replies that way still round-trips.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decode(String.self, forKey: .status)
        statusReason = try c.decodeIfPresent(String.self, forKey: .statusReason)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        diskFormat = try c.decodeIfPresent(String.self, forKey: .diskFormat) ?? ""
        containerFormat = try c.decodeIfPresent(String.self, forKey: .containerFormat) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        minRAM = try c.decodeIfPresent(Int.self, forKey: .minRAM) ?? 0
        minDisk = try c.decodeIfPresent(Int.self, forKey: .minDisk) ?? 0
        protected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        var props = try c.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        let any = try decoder.container(keyedBy: JSONAnyKey.self)
        for key in any.allKeys {
            let raw = key.stringValue
            guard !Self.wireAttributes.contains(raw) else { continue }
            if let s = try? any.decode(String.self, forKey: key) {
                props[raw] = s
            }
        }
        properties = props
        created = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updated = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    /// Encodes back the way Glance replies: declared attributes under their own
    /// keys, custom properties as additional TOP-LEVEL string keys, and no
    /// nested `properties` object. Keeping the reply shape faithful is what stops
    /// the test double from looking right while a live cloud returns something the
    /// decoder would ignore.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(statusReason, forKey: .statusReason)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(diskFormat, forKey: .diskFormat)
        try c.encode(containerFormat, forKey: .containerFormat)
        try c.encode(size, forKey: .size)
        try c.encode(minRAM, forKey: .minRAM)
        try c.encode(minDisk, forKey: .minDisk)
        try c.encode(protected, forKey: .protected)
        try c.encode(tags, forKey: .tags)
        try c.encode(created, forKey: .createdAt)
        try c.encode(updated, forKey: .updatedAt)
        var any = encoder.container(keyedBy: JSONAnyKey.self)
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            try any.encode(value, forKey: JSONAnyKey(stringValue: key)!)
        }
    }
}

/// A coding key that accepts any string, for the attributes a schema-declared
/// `additionalProperties` map allows on Glance's image representation.
struct JSONAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct CreateImageSpec: Sendable {
    public var name: String
    public var visibility: String
    public var diskFormat: String
    public var containerFormat: String
    public var minRAM: Int
    public var minDisk: Int
    public var protected: Bool
    public var tags: [String]
    public var properties: [String: String]

    public init(
        name: String = "",
        diskFormat: String = "raw",
        containerFormat: String = "bare",
        visibility: String = "private",
        minRAM: Int = 0,
        minDisk: Int = 0,
        protected: Bool = false,
        tags: [String] = [],
        properties: [String: String] = [:]
    ) {
        self.name = name
        self.visibility = visibility
        self.diskFormat = diskFormat
        self.containerFormat = containerFormat
        self.minRAM = minRAM
        self.minDisk = minDisk
        self.protected = protected
        self.tags = tags
        self.properties = properties
    }

    /// The `POST /v2/images` request body.
    ///
    /// Glance v2 takes the image's attributes at the TOP LEVEL: the schema's
    /// `additionalProperties` is `{"type": "string"}` because custom properties
    /// are top-level string keys. A `{"image": {...}}` wrapper — the shape Nova
    /// and Cinder use — is therefore rejected outright: Glance reads `image` as
    /// a custom property and fails it with
    /// `Provided object does not match schema 'image': {...} is not of type 'string'`.
    /// Same for custom properties: nesting them under `properties` would make
    /// `properties` itself a non-string custom property.
    ///
    /// `tags` is deliberately absent. Glance's create schema does not accept it;
    /// tags go through `PUT /v2/images/{id}/tags` (see `ImageRegion.addTags`).
    func body() -> String {
        var parts: [String] = [
            "\"visibility\":\"\(jsonEscape(visibility))\"",
            "\"disk_format\":\"\(jsonEscape(diskFormat))\"",
            "\"container_format\":\"\(jsonEscape(containerFormat))\""
        ]
        if !name.isEmpty { parts.append("\"name\":\"\(jsonEscape(name))\"") }
        if minRAM > 0 { parts.append("\"min_ram\":\(minRAM)") }
        if minDisk > 0 { parts.append("\"min_disk\":\(minDisk)") }
        if protected { parts.append("\"protected\":true") }
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            parts.append("\"\(jsonEscape(key))\":\"\(jsonEscape(value))\"")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}
