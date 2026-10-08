import Foundation

// MARK: - Trove (database) models — phase 2
//
// Keystone service type: `database`. IAD3 catalog endpoint URL carries the
// project-scoped version root (e.g. `.../v1.0/<project>`), so the client's
// basePath is dropped in favour of the catalog URL (Heat pattern). List
// responses are keyed envelopes (`{"instances":[...]}`), single items return
// the bare object.

public struct DatabaseInstance: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var status: String
    public var flavorRef: String?
    public var volumeSize: Int?
    public var ip: [String]?
    public var versionNumber: String?
    public var created: String?
    public var updated: String?

    public init(
        id: String,
        name: String? = nil,
        status: String = "BUILD",
        flavorRef: String? = nil,
        volumeSize: Int? = nil,
        ip: [String]? = nil,
        versionNumber: String? = nil,
        created: String? = nil,
        updated: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.flavorRef = flavorRef
        self.volumeSize = volumeSize
        self.ip = ip
        self.versionNumber = versionNumber
        self.created = created
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case flavorRef = "flavorRef"
        case ip, created, updated
        case versionNumber = "versionNumber"
        case volume
    }

    struct Volume: Decodable { let size: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .volume) // older Trove: name was under volume
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "BUILD"
        flavorRef = try c.decodeIfPresent(String.self, forKey: .flavorRef)
        ip = try c.decodeIfPresent([String].self, forKey: .ip)
        versionNumber = try c.decodeIfPresent(String.self, forKey: .versionNumber)
        created = try c.decodeIfPresent(String.self, forKey: .created)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        volumeSize = try c.decodeIfPresent(Volume.self, forKey: .volume)?.size
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(flavorRef, forKey: .flavorRef)
        try c.encodeIfPresent(ip, forKey: .ip)
        try c.encodeIfPresent(versionNumber, forKey: .versionNumber)
        try c.encodeIfPresent(created, forKey: .created)
        try c.encodeIfPresent(updated, forKey: .updated)
    }
}

public struct DatabaseFlavor: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var vcpus: Int?
    public var ram: Int?
    public var disk: Int?

    public init(id: String, name: String? = nil, vcpus: Int? = nil, ram: Int? = nil, disk: Int? = nil) {
        self.id = id
        self.name = name
        self.vcpus = vcpus
        self.ram = ram
        self.disk = disk
    }

    enum CodingKeys: String, CodingKey { case id, name, vcpus, ram, disk }

    /// IAD3 Trove returns `id: null` in flavor lists (a nonstandard shape);
    /// the real id is in `str_id` or the `links[self].href` last path segment.
    private struct FlavorRaw: Decodable {
        let id: String?
        let str_id: String?
        let name: String?
        let vcpus: Int?
        let ram: Int?
        let disk: Int?
        let links: [Link]?
        struct Link: Decodable { let rel: String?; let href: String? }

        enum CodingKeys: String, CodingKey { case id, str_id, name, vcpus, ram, disk, links }
    }

    public init(from decoder: Decoder) throws {
        let raw = try FlavorRaw(from: decoder)
        // Derive a stable id from str_id, else the self-link href, else "".
        if let sid = raw.str_id, !sid.isEmpty {
            id = sid
        } else if let href = raw.links?.first(where: { $0.rel == "self" })?.href,
                  let comp = href.split(separator: "/").last, !comp.isEmpty {
            id = String(comp)
        } else {
            id = raw.id ?? ""
        }
        name = raw.name
        vcpus = raw.vcpus
        ram = raw.ram
        disk = raw.disk
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(vcpus, forKey: .vcpus)
        try c.encodeIfPresent(ram, forKey: .ram)
        try c.encodeIfPresent(disk, forKey: .disk)
    }
}

public struct DatabaseDatastore: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

/// Spec for creating a Trove database instance.
public struct CreateDatabaseInstanceSpec: Sendable {
    public var name: String
    public var flavorRef: String
    public var volumeSize: Int
    public var datastore: String

    public init(name: String, flavorRef: String, volumeSize: Int = 1, datastore: String = "mysql") {
        self.name = name
        self.flavorRef = flavorRef
        self.volumeSize = volumeSize
        self.datastore = datastore
    }

    public func body() -> String {
        let esc = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"instance":{"name":"\(esc)","flavorRef":"\(flavorRef)","volume":{"size":\(volumeSize)}},"datastore":{"type":"\(datastore)"}}
        """
    }
}
