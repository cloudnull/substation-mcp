import Foundation

// MARK: - Volume

/// A Cinder volume.
public struct Volume: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var size: Int
    public var volumeType: String
    public var availabilityZone: String?
    public var bootable: Bool
    public var description: String
    public var multiattach: Bool
    public var metadata: [String: String]?
    public var sourceVolumeID: String?
    public var imageID: String?
    public var projectID: String
    public var attachments: [VolumeAttachment]
    public var created: String

    public struct VolumeAttachment: Sendable, Codable, Identifiable {
        public let id: String
        public var serverID: String?
        public var volumeID: String
        public var device: String

        enum CodingKeys: String, CodingKey {
            case id, device, volumeID = "volume_id"
            case serverID = "server_id"
        }
    }

    public init(
        id: String,
        name: String = "",
        status: String = "creating",
        size: Int = 1,
        volumeType: String = "lvmdriver-1",
        availabilityZone: String? = nil,
        bootable: Bool = false,
        description: String = "",
        multiattach: Bool = false,
        metadata: [String: String]? = nil,
        sourceVolumeID: String? = nil,
        imageID: String? = nil,
        projectID: String = "",
        attachments: [VolumeAttachment] = [],
        created: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.size = size
        self.volumeType = volumeType
        self.availabilityZone = availabilityZone
        self.bootable = bootable
        self.description = description
        self.multiattach = multiattach
        self.metadata = metadata
        self.sourceVolumeID = sourceVolumeID
        self.imageID = imageID
        self.projectID = projectID
        self.attachments = attachments
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, size, description, bootable, metadata, attachments
        case volumeType = "volume_type"
        case availabilityZone = "availability_zone"
        case multiattach
        case sourceVolumeID = "source_vol_id"
        case imageID = "image_id"
        case projectID = "os-vol-tenant-attr:tenant_id"
        case createdAt = "created_at"
    }

    /// Decodes a Bool from a JSON bool, or from a `"true"`/`"false"` string
    /// (Rackspace Cinder returns `bootable` as a string). Returns `nil` when
    /// the key is absent or the value is neither shape.
    private static func boolOrString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decode(Bool.self, forKey: key) { return b }
        if let s = try? c.decode(String.self, forKey: key) {
            return s.lowercased() == "true"
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // Rackspace Cinder's volume LIST (index) rows are minimal — only
        // `id`, `name`, `links` — with no `status`/`size`. Treat them as
        // absent ("" / 0) instead of 500'ing, like the other Rackspace
        // lenient-decode fixes (FlavorRef 3fb7621, ImageRef bare-string).
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        volumeType = try c.decodeIfPresent(String.self, forKey: .volumeType) ?? ""
        availabilityZone = try c.decodeIfPresent(String.self, forKey: .availabilityZone)
        bootable = Self.boolOrString(c, .bootable) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        multiattach = Self.boolOrString(c, .multiattach) ?? false
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata)
        sourceVolumeID = try c.decodeIfPresent(String.self, forKey: .sourceVolumeID)
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        attachments = try c.decodeIfPresent([VolumeAttachment].self, forKey: .attachments) ?? []
        created = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(size, forKey: .size)
        try c.encode(volumeType, forKey: .volumeType)
        try c.encodeIfPresent(availabilityZone, forKey: .availabilityZone)
        try c.encode(bootable, forKey: .bootable)
        try c.encode(description, forKey: .description)
        try c.encode(multiattach, forKey: .multiattach)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(sourceVolumeID, forKey: .sourceVolumeID)
        try c.encodeIfPresent(imageID, forKey: .imageID)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(created, forKey: .createdAt)
    }
}

public struct CreateVolumeSpec: Sendable {
    public var name: String
    public var size: Int
    public var volumeType: String
    public var imageID: String?
    public var sourceVolumeID: String?
    public var snapshotID: String?
    public var description: String
    public var availabilityZone: String?
    public var multiattach: Bool
    public var metadata: [String: String]

    public init(
        name: String = "",
        size: Int = 1,
        volumeType: String = "lvmdriver-1",
        imageID: String? = nil,
        sourceVolumeID: String? = nil,
        snapshotID: String? = nil,
        description: String = "",
        availabilityZone: String? = nil,
        multiattach: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.size = size
        self.volumeType = volumeType
        self.imageID = imageID
        self.sourceVolumeID = sourceVolumeID
        self.snapshotID = snapshotID
        self.description = description
        self.availabilityZone = availabilityZone
        self.multiattach = multiattach
        self.metadata = metadata
    }

    func body() -> String {
        var parts: [String] = [
            "\"size\":\(size)",
            "\"volume_type\":\"\(volumeType)\""
        ]
        if !name.isEmpty { parts.append("\"name\":\"\(name)\"") }
        if !description.isEmpty { parts.append("\"description\":\"\(description)\"") }
        if let imageID { parts.append("\"image_id\":\"\(imageID)\"") }
        if let sourceVolumeID { parts.append("\"source_vol_id\":\"\(sourceVolumeID)\"") }
        if let snapshotID { parts.append("\"snapshot_id\":\"\(snapshotID)\"") }
        if let availabilityZone { parts.append("\"availability_zone\":\"\(availabilityZone)\"") }
        parts.append("\"multiattach\":\(multiattach)")
        if !metadata.isEmpty {
            let meta = metadata.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"metadata\":{\(meta)}")
        }
        return "{\"volume\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Volume Type

public struct VolumeType: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var extra_specs: [String: String]?

    public init(id: String, name: String = "", extra_specs: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.extra_specs = extra_specs
    }
}

public struct CreateVolumeTypeSpec: Sendable {
    public var name: String
    public var extra_specs: [String: String]

    public init(name: String, extra_specs: [String: String] = [:]) {
        self.name = name
        self.extra_specs = extra_specs
    }

    func body() -> String {
        var parts: [String] = ["\"name\":\"\(name)\""]
        if !extra_specs.isEmpty {
            let specs = extra_specs.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"extra_specs\":{\(specs)}")
        }
        return "{\"volumeType\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Snapshot

public struct Snapshot: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var volumeID: String
    public var size: Int
    public var description: String
    public var force: Bool
    public var created: String

    public init(
        id: String,
        name: String = "",
        status: String = "creating",
        volumeID: String = "",
        size: Int = 0,
        description: String = "",
        force: Bool = false,
        created: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.volumeID = volumeID
        self.size = size
        self.description = description
        self.force = force
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, size, description, force
        case volumeID = "volume_id"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decode(String.self, forKey: .status)
        volumeID = try c.decode(String.self, forKey: .volumeID)
        size = try c.decode(Int.self, forKey: .size)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
        created = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(volumeID, forKey: .volumeID)
        try c.encode(size, forKey: .size)
        try c.encode(description, forKey: .description)
        try c.encode(force, forKey: .force)
        try c.encode(created, forKey: .createdAt)
    }
}

public struct CreateSnapshotSpec: Sendable {
    public var volumeID: String
    public var name: String
    public var description: String
    public var force: Bool

    public init(volumeID: String, name: String = "", description: String = "", force: Bool = false) {
        self.volumeID = volumeID
        self.name = name
        self.description = description
        self.force = force
    }

    func body() -> String {
        var parts: [String] = ["\"volume_id\":\"\(volumeID)\""]
        if !name.isEmpty { parts.append("\"name\":\"\(name)\"") }
        if !description.isEmpty { parts.append("\"description\":\"\(description)\"") }
        if force { parts.append("\"force\":true") }
        return "{\"snapshot\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Backup

public struct Backup: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var volumeID: String
    public var size: Int
    public var description: String
    public var created: String

    public init(
        id: String,
        name: String = "",
        status: String = "creating",
        volumeID: String = "",
        size: Int = 0,
        description: String = "",
        created: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.volumeID = volumeID
        self.size = size
        self.description = description
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, size, description
        case volumeID = "volume_id"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decode(String.self, forKey: .status)
        volumeID = try c.decode(String.self, forKey: .volumeID)
        size = try c.decode(Int.self, forKey: .size)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        created = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(volumeID, forKey: .volumeID)
        try c.encode(size, forKey: .size)
        try c.encode(description, forKey: .description)
        try c.encode(created, forKey: .createdAt)
    }
}

public struct CreateBackupSpec: Sendable {
    public var volumeID: String
    public var name: String
    public var description: String

    public init(volumeID: String, name: String = "", description: String = "") {
        self.volumeID = volumeID
        self.name = name
        self.description = description
    }

    func body() -> String {
        var parts: [String] = ["\"volume_id\":\"\(volumeID)\""]
        if !name.isEmpty { parts.append("\"name\":\"\(name)\"") }
        if !description.isEmpty { parts.append("\"description\":\"\(description)\"") }
        return "{\"backup\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Quota

public struct VolumeQuota: Sendable, Codable {
    public var volumes: Int
    public var gigabytes: Int
    public var snapshots: Int

    public init(volumes: Int = 0, gigabytes: Int = 0, snapshots: Int = 0) {
        self.volumes = volumes
        self.gigabytes = gigabytes
        self.snapshots = snapshots
    }
}
