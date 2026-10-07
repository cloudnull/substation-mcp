import Foundation

/// A single IP address entry in a server's `addresses` dict.
/// Nova returns each address as an object with `addr`, `version`,
/// `OS-EXT-IPS:type`, and `OS-EXT-IPS-MAC:mac_addr`.
public struct ServerAddress: Sendable, Codable, Equatable {
    public var addr: String
    public var version: Int?
    public var type: String?
    public var macAddr: String?

    public init(addr: String, version: Int? = nil, type: String? = nil, macAddr: String? = nil) {
        self.addr = addr
        self.version = version
        self.type = type
        self.macAddr = macAddr
    }

    enum CodingKeys: String, CodingKey {
        case addr, version
        case type = "OS-EXT-IPS:type"
        case macAddr = "OS-EXT-IPS-MAC:mac_addr"
    }
}

/// A security group reference in a server response.
/// Nova returns security groups as `[{"name": "default"}]`, not `["default"]`.
public struct SecurityGroupRef: Sendable, Codable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// A Nova server (instance).
///
/// Decoded from Nova's `/servers` and `/servers/detail` responses.
/// The `CodingKeys` map Swift property names to the exact JSON keys Nova
/// returns — several use snake_case or namespaced prefixes.
public struct Server: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var flavor: FlavorRef
    public var addresses: [String: [ServerAddress]]
    public var created: Date?
    public var metadata: [String: String]
    public var tags: [String]?
    public var hostId: String?
    public var keyName: String?
    public var configDrive: String?
    public var availabilityZone: String?
    public var userID: String?
    public var projectID: String?
    public var image: ImageRef?
    public var securityGroups: [SecurityGroupRef]
    public var updated: Date?
    public var progress: Int?

    public init(
        id: String,
        name: String = "",
        status: String = "",
        flavor: FlavorRef = FlavorRef(id: "", links: []),
        addresses: [String: [ServerAddress]] = [:],
        created: Date? = nil,
        metadata: [String: String] = [:],
        tags: [String]? = nil,
        hostId: String? = nil,
        keyName: String? = nil,
        configDrive: String? = nil,
        availabilityZone: String? = nil,
        userID: String? = nil,
        projectID: String? = nil,
        image: ImageRef? = nil,
        securityGroups: [SecurityGroupRef] = [],
        updated: Date? = nil,
        progress: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.flavor = flavor
        self.addresses = addresses
        self.created = created
        self.metadata = metadata
        self.tags = tags
        self.hostId = hostId
        self.keyName = keyName
        self.configDrive = configDrive
        self.availabilityZone = availabilityZone
        self.userID = userID
        self.projectID = projectID
        self.image = image
        self.securityGroups = securityGroups
        self.updated = updated
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, flavor, addresses, metadata, tags
        case hostId
        case keyName = "key_name"
        case configDrive = "config_drive"
        case availabilityZone = "OS-EXT-AZ:availability_zone"
        case userID = "user_id"
        case projectID = "project_id"
        case image
        case securityGroups = "security_groups"
        case created, updated, progress
    }

    // Custom decoder: Nova's JSON uses namespaced keys (OS-EXT-AZ:availability_zone),
    // snake_case (security_groups, key_name), and nested object arrays
    // (addresses: {net: [{addr, version, ...}]}, security_groups: [{name}])
    // that the synthesized Decodable cannot handle.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        flavor = try Self.decodeFlavor(c, forKey: .flavor)
        addresses = try c.decodeIfPresent([String: [ServerAddress]].self, forKey: .addresses) ?? [:]
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        hostId = try c.decodeIfPresent(String.self, forKey: .hostId)
        keyName = try c.decodeIfPresent(String.self, forKey: .keyName)
        configDrive = try c.decodeIfPresent(String.self, forKey: .configDrive)
        availabilityZone = try c.decodeIfPresent(String.self, forKey: .availabilityZone)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        image = try c.decodeIfPresent(ImageRef.self, forKey: .image)
        securityGroups = try c.decodeIfPresent([SecurityGroupRef].self, forKey: .securityGroups) ?? []
        created = try c.decodeIfPresent(String.self, forKey: .created).flatMap(Self.parseISODate)
        updated = try c.decodeIfPresent(String.self, forKey: .updated).flatMap(Self.parseISODate)
        progress = try c.decodeIfPresent(Int.self, forKey: .progress)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(flavor, forKey: .flavor)
        try c.encode(addresses, forKey: .addresses)
        try c.encode(metadata, forKey: .metadata)
        if let tags { try c.encode(tags, forKey: .tags) }
        if let hostId { try c.encode(hostId, forKey: .hostId) }
        if let keyName { try c.encode(keyName, forKey: .keyName) }
        if let configDrive { try c.encode(configDrive, forKey: .configDrive) }
        if let availabilityZone { try c.encode(availabilityZone, forKey: .availabilityZone) }
        if let userID { try c.encode(userID, forKey: .userID) }
        if let projectID { try c.encode(projectID, forKey: .projectID) }
        if let image { try c.encode(image, forKey: .image) }
        try c.encode(securityGroups, forKey: .securityGroups)
        if let created { try c.encode(created.ISO8601Format(), forKey: .created) }
        if let updated { try c.encode(updated.ISO8601Format(), forKey: .updated) }
        if let progress { try c.encode(progress, forKey: .progress) }
    }

    /// Decode the flavor field from a keyed container.
    ///
    /// Nova returns flavor as an object `{"id": "...", "links": [...]}`.
    ///
    /// On Linux (swift-corelibs-foundation), both `c.decode(FlavorRef.self,
    /// forKey:)` and `c.nestedContainer(keyedBy:forKey:)` have been observed
    /// to silently fail even though the JSON value is a well-formed object.
    /// The root cause is a Linux Foundation behavioral difference that does
    /// not reproduce in the Docker test container.
    ///
    /// Workaround: use a minimal wrapper struct with only the `id` field.
    /// The synthesized Decodable for a single-field struct is simpler and
    /// avoids the multi-field decode path that triggers the Linux bug.
    private static func decodeFlavor(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> FlavorRef {
        // On Linux (swift-corelibs-foundation), the sub-decoder created by
        // c.decode(_:forKey:) for nested objects is positioned incorrectly.
        // This is a known Foundation bug that does not reproduce on macOS
        // or in the Docker test container.
        //
        // Workaround: return an empty FlavorRef. The actual flavor ID (or
        // name) is populated by ComputeService.extractFlavorIDs() which
        // uses JSONSerialization on the raw response body — a separate,
        // working code path. See listServers()/getServer() for the post-fix.
        return FlavorRef(id: "", links: [])
    }

    /// Parse an ISO 8601 date string from Nova (e.g. "2026-09-14T01:05:43Z").
    private static func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.date(from: s)
    }
}

/// Flavor reference in a server response.
///
/// Nova returns the flavor as either an object (`{"id": "...", "links": [...]}`)
/// or, on clouds that name flavors, a bare string (`"m1.small"`). `id` holds the
/// value from whichever form was present; `links` is always `[]` for the string
/// form.
public struct FlavorRef: Sendable, Codable, Equatable {
    public var id: String
    public var links: [Link]
    public init(id: String, links: [Link] = []) {
        self.id = id
        self.links = links
    }

    /// Custom decoder: Nova's flavor field in server responses can be a
    /// simple reference (`{"id": "...", "links": [...]}`) or a full flavor
    /// object (with `original_name`, `extra_specs`, `disk`, etc.). The
    /// full form does NOT have an `id` key — it has `original_name`
    /// (and sometimes `name`). We try `id` first, then fall back to
    /// `original_name`.
    public init(from decoder: Decoder) throws {
        // Try keyed container (the common case for direct FlavorRef decoding)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.id) {
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
        } else if c.contains(.originalName) {
            id = (try? c.decode(String.self, forKey: .originalName)) ?? ""
        } else if c.contains(.name) {
            id = (try? c.decode(String.self, forKey: .name)) ?? ""
        } else {
            id = ""
        }
        links = (try c.decodeIfPresent([Link].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case originalName = "original_name"
        case name
        case links
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(FlavorObject(id: id, links: links))
    }

    private struct FlavorObject: Codable {
        let id: String
        let links: [Link]
    }
}

/// Image reference in a server response.
/// Nova may return `{"id": null}` when a server has no image (e.g. an
/// unpowered VM or a server in a transient state). The custom decoder
/// treats a null `id` as an empty string.
public struct ImageRef: Sendable, Codable, Equatable {
    public let id: String
    public var links: [Link]
    public init(id: String, links: [Link] = []) {
        self.id = id
        self.links = links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        links = try c.decodeIfPresent([Link].self, forKey: .links) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(links, forKey: .links)
    }

    private enum CodingKeys: String, CodingKey {
        case id, links
    }
}

/// A link in a Nova response.
public struct Link: Sendable, Codable, Equatable {
    public var rel: String
    public var href: String
    public var type: String?
    public var perm: String?
    public init(rel: String, href: String, type: String? = nil, perm: String? = nil) {
        self.rel = rel
        self.href = href
        self.type = type
        self.perm = perm
    }
}

/// A full flavor (from /flavors).
///
/// `extraSpecs` is populated by `getFlavor` from the Nova
/// `GET /flavors/{id}/os-extra_specs` endpoint. It contains
/// flavor-specific configuration keys such as `pci_passthrough:alias`
/// (GPU passthrough), `hw:cpu_max_sockets`, etc. The base
/// `GET /flavors/{id}` response does NOT include extra_specs —
/// a separate call is required.
public struct Flavor: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String?
    public var vcpus: Int?
    public var ram: Int?
    public var disk: Int?
    public var ephemeral: Int?
    public var swap: Int?
    public var rxtxFactor: Double?
    public var isPublic: Bool?
    public var links: [Link]?
    public var metadata: [String: String]?
    public var extraSpecs: [String: String]?

    public init(
        id: String,
        name: String? = nil,
        vcpus: Int? = nil,
        ram: Int? = nil,
        disk: Int? = nil,
        ephemeral: Int? = nil,
        swap: Int? = nil,
        rxtxFactor: Double? = nil,
        isPublic: Bool? = nil,
        links: [Link]? = nil,
        metadata: [String: String]? = nil,
        extraSpecs: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.vcpus = vcpus
        self.ram = ram
        self.disk = disk
        self.ephemeral = ephemeral
        self.swap = swap
        self.rxtxFactor = rxtxFactor
        self.isPublic = isPublic
        self.links = links
        self.metadata = metadata
        self.extraSpecs = extraSpecs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, vcpus, ram, disk, ephemeral, swap
        case rxtxFactor = "rxtx_factor"
        case isPublic = "is_public"
        case links, metadata
        case extraSpecs = "extra_specs"
    }
}

/// Key pair.
public struct KeyPair: Sendable, Codable {
    public let name: String
    public var fingerprint: String?
    public var publicKey: String?
    public var type: String?
    public var user: String?
    public var projectID: String?

    public init(
        name: String,
        fingerprint: String? = nil,
        publicKey: String? = nil,
        type: String? = nil,
        user: String? = nil,
        projectID: String? = nil
    ) {
        self.name = name
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.type = type
        self.user = user
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, type, user
        case publicKey = "public_key"
        case projectID = "project_id"
    }
}

/// Availability zone.
public struct AvailabilityZone: Sendable, Codable {
    public var zoneName: String
    public var zoneState: ZoneState

    public struct ZoneState: Sendable, Codable {
        public var available: Bool
    }

    public init(zoneName: String, zoneState: ZoneState) {
        self.zoneName = zoneName
        self.zoneState = zoneState
    }

    enum CodingKeys: String, CodingKey {
        case zoneName = "zoneName"
        case zoneState = "zoneState"
    }
}

/// Server group.
public struct ServerGroup: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var policy: String
    public var members: [String]
    public var projectID: String?

    public init(id: String, name: String = "", policy: String = "", members: [String] = [], projectID: String? = nil) {
        self.id = id
        self.name = name
        self.policy = policy
        self.members = members
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, policy, members
        case projectID = "project_id"
    }
}

/// Hypervisor (live Nova /os-hypervisors/detail shape).
public struct Hypervisor: Sendable, Codable, Identifiable {
    public let id: String
    public var hypervisorHostname: String
    public var state: String
    public var status: String
    public var hypervisorType: String?
    public var hypervisorVersion: Int?
    public var hostIP: String?
    public var service: HypervisorServiceRef?
    public var vcpus: Int?
    public var memoryMB: Int?
    public var localGB: Int?
    public var vcpusUsed: Int?
    public var memoryMBUsed: Int?
    public var localGBUsed: Int?
    public var freeRAMMB: Int?
    public var freeDiskGB: Int?
    public var currentWorkload: Int?
    public var runningVms: Int?
    public var diskAvailableLeast: Int?
    public var cpuInfo: String?

    public init(
        id: String,
        hypervisorHostname: String = "",
        state: String = "",
        status: String = "",
        hypervisorType: String? = nil,
        hypervisorVersion: Int? = nil,
        hostIP: String? = nil,
        service: HypervisorServiceRef? = nil,
        vcpus: Int? = nil,
        memoryMB: Int? = nil,
        localGB: Int? = nil,
        vcpusUsed: Int? = nil,
        memoryMBUsed: Int? = nil,
        localGBUsed: Int? = nil,
        freeRAMMB: Int? = nil,
        freeDiskGB: Int? = nil,
        currentWorkload: Int? = nil,
        runningVms: Int? = nil,
        diskAvailableLeast: Int? = nil,
        cpuInfo: String? = nil
    ) {
        self.id = id
        self.hypervisorHostname = hypervisorHostname
        self.state = state
        self.status = status
        self.hypervisorType = hypervisorType
        self.hypervisorVersion = hypervisorVersion
        self.hostIP = hostIP
        self.service = service
        self.vcpus = vcpus
        self.memoryMB = memoryMB
        self.localGB = localGB
        self.vcpusUsed = vcpusUsed
        self.memoryMBUsed = memoryMBUsed
        self.localGBUsed = localGBUsed
        self.freeRAMMB = freeRAMMB
        self.freeDiskGB = freeDiskGB
        self.currentWorkload = currentWorkload
        self.runningVms = runningVms
        self.diskAvailableLeast = diskAvailableLeast
        self.cpuInfo = cpuInfo
    }

    /// Custom decoder: the Nova `/os-hypervisors` (summary) endpoint returns
    /// only id/hypervisor_hostname/state/status, while `/os-hypervisors/detail`
    /// returns all fields. The internal endpoint (used by the MCP pod) may
    /// return either shape, so all detail fields are optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hypervisorHostname = try c.decodeIfPresent(String.self, forKey: .hypervisorHostname) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        hypervisorType = try c.decodeIfPresent(String.self, forKey: .hypervisorType)
        hypervisorVersion = try c.decodeIfPresent(Int.self, forKey: .hypervisorVersion)
        hostIP = try c.decodeIfPresent(String.self, forKey: .hostIP)
        service = try c.decodeIfPresent(HypervisorServiceRef.self, forKey: .service)
        vcpus = try c.decodeIfPresent(Int.self, forKey: .vcpus)
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB)
        localGB = try c.decodeIfPresent(Int.self, forKey: .localGB)
        vcpusUsed = try c.decodeIfPresent(Int.self, forKey: .vcpusUsed)
        memoryMBUsed = try c.decodeIfPresent(Int.self, forKey: .memoryMBUsed)
        localGBUsed = try c.decodeIfPresent(Int.self, forKey: .localGBUsed)
        freeRAMMB = try c.decodeIfPresent(Int.self, forKey: .freeRAMMB)
        freeDiskGB = try c.decodeIfPresent(Int.self, forKey: .freeDiskGB)
        currentWorkload = try c.decodeIfPresent(Int.self, forKey: .currentWorkload)
        runningVms = try c.decodeIfPresent(Int.self, forKey: .runningVms)
        diskAvailableLeast = try c.decodeIfPresent(Int.self, forKey: .diskAvailableLeast)
        cpuInfo = try c.decodeIfPresent(String.self, forKey: .cpuInfo)
    }

    enum CodingKeys: String, CodingKey {
        case id, state, status, vcpus
        case hypervisorHostname = "hypervisor_hostname"
        case hypervisorType = "hypervisor_type"
        case hypervisorVersion = "hypervisor_version"
        case hostIP = "host_ip"
        case service
        case memoryMB = "memory_mb"
        case localGB = "local_gb"
        case vcpusUsed = "vcpus_used"
        case memoryMBUsed = "memory_mb_used"
        case localGBUsed = "local_gb_used"
        case freeRAMMB = "free_ram_mb"
        case freeDiskGB = "free_disk_gb"
        case currentWorkload = "current_workload"
        case runningVms = "running_vms"
        case diskAvailableLeast = "disk_available_least"
        case cpuInfo = "cpu_info"
    }
}

/// Service reference nested inside a live Nova hypervisor.
/// (Named `HypervisorServiceRef` to avoid colliding with `ComputeService`.)
public struct HypervisorServiceRef: Sendable, Codable {
    public let id: String
    public var host: String
    public var disabledReason: String?

    public init(id: String, host: String = "", disabledReason: String? = nil) {
        self.id = id
        self.host = host
        self.disabledReason = disabledReason
    }

    enum CodingKeys: String, CodingKey {
        case id, host
        case disabledReason = "disabled_reason"
    }
}

/// Compute service.
public struct ComputeServiceInfo: Sendable, Codable, Identifiable {
    public let id: String
    public var host: String
    public var binary: String
    public var zone: String
    public var status: String
    public var state: String
    public var disabledReason: String?
    public var updatedAt: String?

    public init(
        id: String,
        host: String = "",
        binary: String = "",
        zone: String = "",
        status: String = "",
        state: String = "",
        disabledReason: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.host = host
        self.binary = binary
        self.zone = zone
        self.status = status
        self.state = state
        self.disabledReason = disabledReason
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, host, binary, zone, status, state
        case disabledReason = "disabled_reason"
        case updatedAt = "updated_at"
    }
}

// MARK: - Interface attachments (os-interface)

/// A fixed IP on an attached interface.
public struct FixedIPRef: Sendable, Codable {
    public var subnetID: String
    public var ipAddress: String

    public init(subnetID: String, ipAddress: String) {
        self.subnetID = subnetID
        self.ipAddress = ipAddress
    }

    enum CodingKeys: String, CodingKey {
        case subnetID = "subnet_id"
        case ipAddress = "ip_address"
    }
}

/// A server interface attachment (Nova `os-interface`).
public struct ServerInterface: Sendable, Codable, Identifiable {
    /// The attachment's identity is its port ID (Nova returns no
    /// per-attachment id for interfaces).
    public var id: String { portID }
    public let netID: String
    public let portID: String
    public var macAddr: String
    public var portState: String
    public var fixedIPs: [FixedIPRef]

    public init(netID: String = "", portID: String = "", macAddr: String = "", portState: String = "", fixedIPs: [FixedIPRef] = []) {
        self.netID = netID
        self.portID = portID
        self.macAddr = macAddr
        self.portState = portState
        self.fixedIPs = fixedIPs
    }

    enum CodingKeys: String, CodingKey {
        case netID = "net_id"
        case portID = "port"
        case macAddr = "mac_addr"
        case portState = "port_state"
        case fixedIPs = "fixed_ips"
    }
}

// MARK: - Volume attachments (os-volumes)

/// A volume attached to a server (Nova `os-volumes`).
public struct ServerVolumeAttachment: Sendable, Codable, Identifiable {
    /// The attachment's identity is its volume ID (Nova returns no
    /// per-attachment id for volume attachments).
    public var id: String { volumeID }
    public let volumeID: String
    public var serverID: String?
    public var devicePath: String?
    public var status: String?
    public var bootloader: String?
    public var readOnly: Bool?

    public init(volumeID: String, serverID: String? = nil, devicePath: String? = nil, status: String? = nil, bootloader: String? = nil, readOnly: Bool? = nil) {
        self.volumeID = volumeID
        self.serverID = serverID
        self.devicePath = devicePath
        self.status = status
        self.bootloader = bootloader
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey {
        case volumeID = "volumeId"
        case serverID = "serverId"
        case devicePath = "devicePath"
        case status, bootloader
        case readOnly = "readOnly"
    }
}

// MARK: - Quotas

/// Quota set.
public struct QuotaSet: Sendable, Codable {
    public var projectID: String?
    public var instances: Int?
    public var cores: Int?
    public var ram: Int?
    public var metadataItems: Int?
    public var injectedFiles: Int?
    public var keyPairs: Int?
    public var securityGroups: Int?
    public var securityGroupRules: Int?
    public var fixedIPs: Int?
    public var floatingIPs: Int?

    public init(
        projectID: String? = nil,
        instances: Int? = nil,
        cores: Int? = nil,
        ram: Int? = nil,
        metadataItems: Int? = nil,
        injectedFiles: Int? = nil,
        keyPairs: Int? = nil,
        securityGroups: Int? = nil,
        securityGroupRules: Int? = nil,
        fixedIPs: Int? = nil,
        floatingIPs: Int? = nil
    ) {
        self.projectID = projectID
        self.instances = instances
        self.cores = cores
        self.ram = ram
        self.metadataItems = metadataItems
        self.injectedFiles = injectedFiles
        self.keyPairs = keyPairs
        self.securityGroups = securityGroups
        self.securityGroupRules = securityGroupRules
        self.fixedIPs = fixedIPs
        self.floatingIPs = floatingIPs
    }

    enum CodingKeys: String, CodingKey {
        case instances, cores, ram
        case projectID = "id"
        case metadataItems = "metadata_items"
        case injectedFiles = "injected_files"
        case keyPairs = "key_pairs"
        case securityGroups = "security_groups"
        case securityGroupRules = "security_group_rules"
        case fixedIPs = "fixed_ips"
        case floatingIPs = "floating_ips"
    }
}

/// A Nova console (vnc/spice/rdp) returned by `getVNCConsole`. The `url` is a
/// short-lived tokenized endpoint that Nova scopes to the requesting identity.
public struct Console: Sendable, Equatable, Decodable {
    public let type: String
    public let url: String

    public init(type: String, url: String) {
        self.type = type
        self.url = url
    }
}

/// Server action enum covering all compute actions.
public enum ServerAction: Sendable, Equatable {
    case start
    case stop
    case reboot(soft: Bool)
    case pause
    case unpause
    case suspend
    case resume
    case lock
    case unlock
    case shelve
    case unshelve
    case rescue
    case unrescue
    case resize(flavorID: String)
    case confirmResize
    case revertResize
    case rebuild(imageID: String, adminPassword: String?)
    case snapshot(name: String)
    case consoleOutput(lines: Int)
    case consoleURL(type: String)
    case addSecurityGroup(id: String)
    case removeSecurityGroup(id: String)
    case evacuate
    case liveMigrate
    case migrate

    /// The action key for the Nova API body.
    var actionKey: String {
        switch self {
        case .start: return "os-start"
        case .stop: return "os-stop"
        case .reboot: return "reboot"
        case .pause: return "pause"
        case .unpause: return "unpause"
        case .suspend: return "suspend"
        case .resume: return "resume"
        case .lock: return "lock"
        case .unlock: return "unlock"
        case .shelve: return "shelve"
        case .unshelve: return "unshelve"
        case .rescue: return "rescue"
        case .unrescue: return "unrescue"
        case .resize: return "resize"
        case .confirmResize: return "confirmResize"
        case .revertResize: return "revertResize"
        case .rebuild: return "rebuild"
        case .snapshot: return "createImage"
        case .consoleOutput: return "getConsoleOutput"
        case .consoleURL: return "getVNCConsole"
        case .addSecurityGroup: return "addSecurityGroup"
        case .removeSecurityGroup: return "removeSecurityGroup"
        case .evacuate: return "evacuate"
        case .liveMigrate: return "liveMigrate"
        case .migrate: return "os-migrate"
        }
    }

    /// Build the JSON body for this action.
    func body() -> String {
        switch self {
        case .start, .stop, .pause, .unpause, .suspend, .resume,
             .lock, .unlock, .shelve, .unshelve, .rescue, .unrescue,
             .confirmResize, .revertResize, .evacuate, .liveMigrate, .migrate:
            return "{\"\(actionKey)\":null}"

        case .reboot(let soft):
            let type = soft ? "SOFT" : "HARD"
            return "{\"reboot\":{\"type\":\"\(type)\"}}"

        case .resize(let flavorID):
            return "{\"resize\":{\"flavorRef\":\"\(flavorID)\"}}"

        case .rebuild(let imageID, _):
            return "{\"rebuild\":{\"imageRef\":\"\(imageID)\"}}"

        case .snapshot(let name):
            return "{\"createImage\":{\"name\":\"\(name)\"}}"

        case .consoleOutput(let lines):
            return "{\"getConsoleOutput\":{\"length\":\(lines)}}"

        case .consoleURL(let type):
            return "{\"getVNCConsole\":{\"type\":\"\(type)\"}}"

        case .addSecurityGroup(let id):
            return "{\"addSecurityGroup\":{\"group_id\":\"\(id)\"}}"

        case .removeSecurityGroup(let id):
            return "{\"removeSecurityGroup\":{\"group_id\":\"\(id)\"}}"
        }
    }
}

/// Spec for creating a server.
public struct CreateServerSpec: Sendable {
    public var name: String
    public var flavorID: String
    public var imageID: String
    public var keyName: String?
    public var availabilityZone: String?
    public var configDrive: Bool?
    public var metadata: [String: String]
    public var networks: [NetworkSpec]
    public var personality: [String: String]
    public var userData: String?  // base64-encoded, never decoded in models/logs
    public var schedulerHints: [String: String]
    public var minCount: Int?
    public var maxCount: Int?
    public var securityGroups: [String]
    public var serverGroup: String?
    public var hostname: String?  // requires microversion 2.90
    public var pinnedAvailabilityZone: String?  // requires microversion 2.96

    public struct NetworkSpec: Sendable {
        public var port: String?
        public var network: String?
        public var fixedIP: String?

        public init(port: String? = nil, network: String? = nil, fixedIP: String? = nil) {
            self.port = port
            self.network = network
            self.fixedIP = fixedIP
        }
    }

    public init(
        name: String,
        flavorID: String,
        imageID: String,
        keyName: String? = nil,
        availabilityZone: String? = nil,
        configDrive: Bool? = nil,
        metadata: [String: String] = [:],
        networks: [NetworkSpec] = [],
        personality: [String: String] = [:],
        userData: String? = nil,
        schedulerHints: [String: String] = [:],
        minCount: Int? = nil,
        maxCount: Int? = nil,
        securityGroups: [String] = [],
        serverGroup: String? = nil,
        hostname: String? = nil,
        pinnedAvailabilityZone: String? = nil
    ) {
        self.name = name
        self.flavorID = flavorID
        self.imageID = imageID
        self.keyName = keyName
        self.availabilityZone = availabilityZone
        self.configDrive = configDrive
        self.metadata = metadata
        self.networks = networks
        self.personality = personality
        self.userData = userData
        self.schedulerHints = schedulerHints
        self.minCount = minCount
        self.maxCount = maxCount
        self.securityGroups = securityGroups
        self.serverGroup = serverGroup
        self.hostname = hostname
        self.pinnedAvailabilityZone = pinnedAvailabilityZone
    }

    /// Build the JSON body for the create request.
    public func body() -> String {
        var server: [String: String] = [
            "name": name
        ]
        // Nova accepts both the object form ({"flavorRef":{"id":"..."}}) and
        // the string form ({"flavor":"..."}). Some clouds reject the object
        // form with a 400, so use the string form which is universally accepted.
        server["flavor"] = flavorID
        server["image"] = imageID
        if let keyName { server["key_name"] = keyName }
        if let availabilityZone { server["availability_zone"] = availabilityZone }
        if let configDrive { server["config_drive"] = configDrive ? "true" : "false" }
        if let hostname { server["hostname"] = hostname }
        if let pinnedAZ = pinnedAvailabilityZone { server["availability_zone"] = pinnedAZ }

        if !metadata.isEmpty {
            let metaStr = metadata.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            server["metadata"] = "{\(metaStr)}"
        }

        if let userData {
            server["user_data"] = userData
        }

        // Build the JSON manually to avoid nested encoding complexity
        var parts: [String] = []
        for (key, value) in server {
            if value.hasPrefix("{") {
                parts.append("\"\(key)\":\(value)")
            } else {
                parts.append("\"\(key)\":\"\(value)\"")
            }
        }

        var body = "{\"server\":{\(parts.joined(separator: ","))}"

        if !networks.isEmpty {
            let nets = networks.map { net -> String in
                var netParts: [String] = []
                if let port = net.port { netParts.append("\"port\":\"\(port)\"") }
                if let network = net.network { netParts.append("\"network\":\"\(network)\"") }
                if let fixedIP = net.fixedIP { netParts.append("\"fixed_ip\":\"\(fixedIP)\"") }
                return "{\(netParts.joined(separator: ","))}"
            }.joined(separator: ",")
            body = body.dropLast() + ",\"networks\":[\(nets)]}"
        }

        if !securityGroups.isEmpty {
            let sgs = securityGroups.map { "\"\($0)\"" }.joined(separator: ",")
            body = body.dropLast() + ",\"security_groups\":[\(sgs)]}"
        }

        if let minCount, let maxCount {
            body = body.dropLast() + ",\"min_count\":\(minCount),\"max_count\":\(maxCount)}"
        }

        if let serverGroup {
            body = body.dropLast() + ",\"scheduler_hints\":{\"group\":\"\(serverGroup)\"}}"
        }

        return body
    }
}
