import Foundation

// MARK: - Freezer (backup) models — phase 2
//
// Keystone service type: `backup`. IAD3 advertises the catalog endpoint at the
// host root (no version); the API lives under `/v1.0/...`, so the client sets
// `serviceRoot = "v1.0"` (the Gnocchi/Neutron pattern). Freezer addresses items
// by `backup_id`, and list responses are keyed envelopes (`{"backups":[...]}`).

public struct FreezerBackup: Sendable, Codable, Identifiable {
    public let id: String
    public var projectID: String?
    public var volumeID: String?
    public var status: String
    public var size: Int?
    public var lastBackup: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String,
        projectID: String? = nil,
        volumeID: String? = nil,
        status: String = "backup",
        size: Int? = nil,
        lastBackup: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.volumeID = volumeID
        self.status = status
        self.size = size
        self.lastBackup = lastBackup
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id = "backup_id"
        case projectID = "project_id"
        case volumeID = "volume_id"
        case status, size
        case lastBackup = "last_backup"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        volumeID = try c.decodeIfPresent(String.self, forKey: .volumeID)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "backup"
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        lastBackup = try c.decodeIfPresent(String.self, forKey: .lastBackup)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(volumeID, forKey: .volumeID)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(lastBackup, forKey: .lastBackup)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

public struct FreezerSchedule: Sendable, Codable, Identifiable {
    public let id: String
    public var volumeID: String?
    public var projectID: String?
    public var backupIntervalHours: Int?
    public var status: String?

    public init(id: String, volumeID: String? = nil, projectID: String? = nil, backupIntervalHours: Int? = nil, status: String? = nil) {
        self.id = id
        self.volumeID = volumeID
        self.projectID = projectID
        self.backupIntervalHours = backupIntervalHours
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case volumeID = "volume_id"
        case projectID = "project_id"
        case backupIntervalHours = "backup_interval_hours"
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        volumeID = try c.decodeIfPresent(String.self, forKey: .volumeID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        backupIntervalHours = try c.decodeIfPresent(Int.self, forKey: .backupIntervalHours)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(volumeID, forKey: .volumeID)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(backupIntervalHours, forKey: .backupIntervalHours)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

/// Spec for creating a Freezer backup.
public struct CreateFreezerBackupSpec: Sendable {
    public var volumeID: String

    public init(volumeID: String) {
        self.volumeID = volumeID
    }

    public func body() -> String {
        "{\"backup\":{\"volume_id\":\"\(volumeID)\"}}"
    }
}
