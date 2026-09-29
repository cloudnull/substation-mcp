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
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

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
        protected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        properties = try c.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        created = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updated = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

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
        try c.encode(protected, forKey: .protected)
        try c.encode(tags, forKey: .tags)
        try c.encode(properties, forKey: .properties)
        try c.encode(created, forKey: .createdAt)
        try c.encode(updated, forKey: .updatedAt)
    }
}

public struct CreateImageSpec: Sendable {
    public var name: String
    public var visibility: String
    public var diskFormat: String
    public var containerFormat: String
    public var minRAM: Int
    public var properties: [String: String]

    public init(
        name: String = "",
        diskFormat: String = "raw",
        containerFormat: String = "bare",
        visibility: String = "private",
        minRAM: Int = 0,
        properties: [String: String] = [:]
    ) {
        self.name = name
        self.visibility = visibility
        self.diskFormat = diskFormat
        self.containerFormat = containerFormat
        self.minRAM = minRAM
        self.properties = properties
    }

    func body() -> String {
        var parts: [String] = [
            "\"visibility\":\"\(visibility)\"",
            "\"disk_format\":\"\(diskFormat)\"",
            "\"container_format\":\"\(containerFormat)\""
        ]
        if !name.isEmpty { parts.append("\"name\":\"\(name)\"") }
        if minRAM > 0 { parts.append("\"min_ram\":\(minRAM)") }
        if !properties.isEmpty {
            let props = properties.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"properties\":{\(props)}")
        }
        return "{\"image\":{\(parts.joined(separator: ","))}}"
    }
}
