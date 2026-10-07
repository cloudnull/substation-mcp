import Foundation

// MARK: - Placement models (resource providers, inventories, usages)
//
// Keystone service type: `placement`. The Placement API is served with no
// version path root (the endpoint URL IS the service root), so request paths
// are `/resource_providers`, `/resource_providers/{uuid}`, etc. directly.
//
// Resources:
// - resource_provider: the per-host (or aggregate) inventory entry. Its id is
//   the provider `uuid`; its name typically mirrors the compute host
//   (e.g. "compute://host-01"), which is how a server's hostId is correlated
//   with its GPU/RAM/vCPU inventory.
// - inventories: per-provider resource totals (VCPU, MEMORY_MB, DISK_GB, ...).
// - usages: per-provider allocated amounts (plain ints, one per resource).
//
// The `inventories` object is resource-name keyed and open-ended (GPU clouds
// add e.g. "GPU" or "ACPI:GPU" entries), so it decodes as a dictionary and is
// re-encoded verbatim — new resource types pass through without code changes.
// `usages` is the same shape minus the `{total, used, ...}` wrapper.

public struct PlacementResourceProvider: Sendable, Codable, Identifiable {
    public let uuid: String
    public var name: String
    public var generation: Int
    public var user: String?
    public var parent: String?
    public var project: String?
    public var traits: [String]?
    public var links: [PlacementLink]?

    public init(
        uuid: String,
        name: String = "",
        generation: Int = 0,
        user: String? = nil,
        parent: String? = nil,
        project: String? = nil,
        traits: [String]? = nil,
        links: [PlacementLink]? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.generation = generation
        self.user = user
        self.parent = parent
        self.project = project
        self.traits = traits
        self.links = links
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, generation, user, parent, project, traits, links
    }

    public var id: String { uuid }
}

public struct PlacementLink: Sendable, Codable {
    public var rel: String
    public var href: String

    public init(rel: String, href: String) {
        self.rel = rel
        self.href = href
    }
}

/// One entry of a provider's `inventories` object: total capacity plus the
/// (provider-level) allocated amount.
public struct PlacementInventoryResource: Sendable, Codable {
    public var total: Int?
    public var reserved: Int?
    public var allocatable: Int?
    public var aggregate: Bool?
    public var unit: String?
    public var min_unit: Int?
    public var is_parent: Bool?

    public init(
        total: Int? = nil,
        reserved: Int? = nil,
        allocatable: Int? = nil,
        aggregate: Bool? = nil,
        unit: String? = nil,
        min_unit: Int? = nil,
        is_parent: Bool? = nil
    ) {
        self.total = total
        self.reserved = reserved
        self.allocatable = allocatable
        self.aggregate = aggregate
        self.unit = unit
        self.min_unit = min_unit
        self.is_parent = is_parent
    }

    enum CodingKeys: String, CodingKey {
        case total, reserved, allocatable, aggregate, unit
        case min_unit
        case is_parent
    }
}

/// A resource provider's inventory: resource-name -> resource entry.
///
/// Open-ended on purpose (GPU/PCI clouds extend the map with custom keys),
/// so it round-trips verbatim.
public struct PlacementInventories: Sendable, Codable {
    public var resources: [String: PlacementInventoryResource]

    public init(resources: [String: PlacementInventoryResource] = [:]) {
        self.resources = resources
    }

    public init(from decoder: Decoder) throws {
        resources = try decoder.singleValueContainer().decode([String: PlacementInventoryResource].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(resources)
    }
}

/// A resource provider's usages: resource-name -> allocated amount.
///
/// Open-ended on purpose, mirroring `PlacementInventories`.
public struct PlacementUsages: Sendable, Codable {
    public var resources: [String: Int]

    public init(resources: [String: Int] = [:]) {
        self.resources = resources
    }

    public init(from decoder: Decoder) throws {
        resources = try decoder.singleValueContainer().decode([String: Int].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(resources)
    }
}
