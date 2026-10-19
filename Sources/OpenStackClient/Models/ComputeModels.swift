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

/// One entry of `os-extended-volumes:volumes_attached` on a server detail
/// response — the volume-attachment view available even on a Nova 2.1 proxy
/// (the `server_volume_attachment` list needs the same data; this is the
/// per-server inline form). `delete_on_termination` is reported by Nova as
/// either a bool or a "True"/"False" string (live on IAD3: bool).
public struct ServerVolumeAttachmentRef: Sendable, Codable, Equatable {
    public var id: String
    public var deleteOnTermination: Bool?

    public init(id: String, deleteOnTermination: Bool? = nil) {
        self.id = id
        self.deleteOnTermination = deleteOnTermination
    }

    enum CodingKeys: String, CodingKey {
        case id
        case deleteOnTermination = "delete_on_termination"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let b = try? c.decode(Bool.self, forKey: .deleteOnTermination) {
            deleteOnTermination = b
        } else if let s = try? c.decode(String.self, forKey: .deleteOnTermination) {
            deleteOnTermination = (s.lowercased() == "true")
        } else {
            deleteOnTermination = nil
        }
    }
}

/// Nova instance model, exposed under a unique name so call sites that also
/// import the MCP SDK (whose `Server` actor collides with bare `Server`) can
/// spell it without ambiguity. Same type as `Server`.
public typealias NovaServer = Server

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
    /// `OS-EXT-STS:task_state` — non-null while an async operation (migration,
    /// resize, rebuild…) is in flight; null when idle. Available at Nova mv 2.1
    /// (unlike `OS-EXT-SRV-ATTR:*`, which Rackspace's 2.1-pinned proxy never
    /// emits). The evacuation/migration wait polls this back to null.
    public var taskState: String?
    /// `OS-EXT-STS:power_state` (1 = running, 0 = shutdown, 3 = suspended…).
    public var powerState: Int?
    /// `OS-EXT-STS:vm_state` (active/stopped/suspended/shelved/rescued/error).
    public var vmState: String?
    /// `os-extended-volumes:volumes_attached` — non-empty ⇒ boot-from-volume
    /// (root on a volume). The only volume-attachment view available on a
    /// 2.1-pinned proxy.
    public var volumesAttached: [ServerVolumeAttachmentRef]?
    /// `OS-EXT-SRV-ATTR:host` — the compute host. Only present on clouds that
    /// negotiate ≥2.53; nil on 2.1-pinned proxies.
    public var srvAttrHost: String?
    /// `OS-EXT-SRV-ATTR:hypervisor_hostname` — same availability caveat.
    public var srvAttrHypervisor: String?
    /// `OS-EXT-SRV-ATTR:root_device_name` — e.g. `/dev/vda1` (local) vs
    /// `/dev/vda` on volume-backed; same availability caveat.
    public var srvAttrRootDevice: String?
    /// `OS-EXT-SRV-ATTR:availability_zone` — same availability caveat.
    public var srvAttrAvailabilityZone: String?

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
        progress: Int? = nil,
        taskState: String? = nil,
        powerState: Int? = nil,
        vmState: String? = nil,
        volumesAttached: [ServerVolumeAttachmentRef]? = nil,
        srvAttrHost: String? = nil,
        srvAttrHypervisor: String? = nil,
        srvAttrRootDevice: String? = nil,
        srvAttrAvailabilityZone: String? = nil
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
        self.taskState = taskState
        self.powerState = powerState
        self.vmState = vmState
        self.volumesAttached = volumesAttached
        self.srvAttrHost = srvAttrHost
        self.srvAttrHypervisor = srvAttrHypervisor
        self.srvAttrRootDevice = srvAttrRootDevice
        self.srvAttrAvailabilityZone = srvAttrAvailabilityZone
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
        case taskState = "OS-EXT-STS:task_state"
        case powerState = "OS-EXT-STS:power_state"
        case vmState = "OS-EXT-STS:vm_state"
        case volumesAttached = "os-extended-volumes:volumes_attached"
        case srvAttrHost = "OS-EXT-SRV-ATTR:host"
        case srvAttrHypervisor = "OS-EXT-SRV-ATTR:hypervisor_hostname"
        case srvAttrRootDevice = "OS-EXT-SRV-ATTR:root_device_name"
        case srvAttrAvailabilityZone = "OS-EXT-SRV-ATTR:availability_zone"
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
        taskState = try c.decodeIfPresent(String.self, forKey: .taskState)
        powerState = try c.decodeIfPresent(Int.self, forKey: .powerState)
        vmState = try c.decodeIfPresent(String.self, forKey: .vmState)
        volumesAttached = try c.decodeIfPresent([ServerVolumeAttachmentRef].self, forKey: .volumesAttached)
        srvAttrHost = try c.decodeIfPresent(String.self, forKey: .srvAttrHost)
        srvAttrHypervisor = try c.decodeIfPresent(String.self, forKey: .srvAttrHypervisor)
        srvAttrRootDevice = try c.decodeIfPresent(String.self, forKey: .srvAttrRootDevice)
        srvAttrAvailabilityZone = try c.decodeIfPresent(String.self, forKey: .srvAttrAvailabilityZone)
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
        if let taskState { try c.encode(taskState, forKey: .taskState) }
        if let powerState { try c.encode(powerState, forKey: .powerState) }
        if let vmState { try c.encode(vmState, forKey: .vmState) }
        if let volumesAttached { try c.encode(volumesAttached, forKey: .volumesAttached) }
        if let srvAttrHost { try c.encode(srvAttrHost, forKey: .srvAttrHost) }
        if let srvAttrHypervisor { try c.encode(srvAttrHypervisor, forKey: .srvAttrHypervisor) }
        if let srvAttrRootDevice { try c.encode(srvAttrRootDevice, forKey: .srvAttrRootDevice) }
        if let srvAttrAvailabilityZone { try c.encode(srvAttrAvailabilityZone, forKey: .srvAttrAvailabilityZone) }
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

    /// Polymorphic decoder: Nova returns the server image field either as a
    /// bare string id (`"image": "<uuid>"`, observed on Rackspace) or as an
    /// object (`{"id": "<uuid>", "links": [...]}`, standard Nova, where `id`
    /// may be `null` for imageless servers). Each shape is decoded on a FRESH
    /// sub-decoder via a `try?` closure so we never mix singleValueContainer
    /// and keyedContainer on the same decoder instance — mixing corrupts the
    /// decoder's internal state (same bug class as FlavorRef, commit 3fb7621).
    public init(from decoder: Decoder) throws {
        if let s = try? {
            let c = try decoder.singleValueContainer()
            return try c.decode(String.self)
        }() {
            id = s
            links = []
            return
        }
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
    /// Present only when the client auto-generated the key because the caller omitted `public_key`;
    /// surfaces the private seed exactly once. Never sent to or returned from Nova.
    public var privateKey: String?

    public init(
        name: String,
        fingerprint: String? = nil,
        publicKey: String? = nil,
        type: String? = nil,
        user: String? = nil,
        projectID: String? = nil,
        privateKey: String? = nil
    ) {
        self.name = name
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.type = type
        self.projectID = projectID
        self.privateKey = privateKey
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, type, user
        case publicKey = "public_key"
        case projectID = "project_id"
        case privateKey = "private_key"
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
    public var cpuInfo: HypervisorCPUInfo?
    /// Instances hosted on this hypervisor. Present when the list was fetched
    /// with `with_servers=true`, or from the `/servers` sub-resource.
    public var servers: [HypervisorServerRef]?

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
        cpuInfo: HypervisorCPUInfo? = nil,
        servers: [HypervisorServerRef]? = nil
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
        self.servers = servers
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
        cpuInfo = try c.decodeIfPresent(HypervisorCPUInfo.self, forKey: .cpuInfo)
        servers = try c.decodeIfPresent([HypervisorServerRef].self, forKey: .servers)
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
        case servers
    }
}

/// CPU info as Nova returns it: a JSON *string* below microversion 2.88 and a
/// nested JSON *object* at/above it (also a bare int on some stubs).
public enum HypervisorCPUInfo: Sendable, Codable {
    case int(Int)
    case double(Double)
    case str(String)
    case object([String: HypervisorCPUInfo])
    case array([HypervisorCPUInfo])
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .str(s); return }
        if let a = try? container.decode([HypervisorCPUInfo].self) { self = .array(a); return }
        if let o = try? container.decode([String: HypervisorCPUInfo].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .str(let s): try container.encode(s)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

/// A server reference nested inside a hypervisor's `servers` field.
public struct HypervisorServerRef: Sendable, Codable {
    public var name: String
    public var uuid: String

    public init(name: String, uuid: String) {
        self.name = name
        self.uuid = uuid
    }
}

/// Fleet-wide hypervisor totals (`GET /os-hypervisors/statistics`).
public struct HypervisorStatistics: Sendable, Codable {
    public var count: Int?
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

    public init(count: Int? = nil, vcpus: Int? = nil, memoryMB: Int? = nil, localGB: Int? = nil,
                vcpusUsed: Int? = nil, memoryMBUsed: Int? = nil, localGBUsed: Int? = nil,
                freeRAMMB: Int? = nil, freeDiskGB: Int? = nil, currentWorkload: Int? = nil,
                runningVms: Int? = nil, diskAvailableLeast: Int? = nil) {
        self.count = count
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
    }

    enum CodingKeys: String, CodingKey {
        case count, vcpus
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
    /// `POST …/action {"evacuate":{…}}`. Nova (validated live on IAD3) requires
    /// an OBJECT body with `onSharedStorage` present; `host` is optional;
    /// `force` is NOT an accepted property (400 Additional properties).
    case evacuate(onSharedStorage: Bool?, host: String?)
    /// `POST …/action {"os-migrateLive":{…}}`. NOTE the wire key is
    /// `os-migrateLive` — `liveMigrate`/`live-migrate` are 400 "no such action"
    /// on Nova 2.1 (validated live on IAD3). `host` is a REQUIRED property of
    /// the body (null = let Nova pick); `block_migration`/`disk_over_commit`
    /// are optional booleans (null = omit).
    case liveMigrate(host: String?, blockMigration: Bool?, diskOverCommit: Bool?)
    /// `POST …/action {"migrate":{…}}` — cold migration. Object body; `host`
    /// optional (null = scheduler picks). `block_migration`/`disk_over_commit`
    /// are the 2.25+ block-migration form; a 2.1 proxy accepts and ignores
    /// them (validated live on IAD3).
    case migrate(host: String?, blockMigration: Bool?, diskOverCommit: Bool?)

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
        case .liveMigrate: return "os-migrateLive"
        case .migrate: return "migrate"
        }
    }

    /// Build the JSON body for this action.
    func body() -> String {
        switch self {
        case .start, .stop, .pause, .unpause, .suspend, .resume,
             .lock, .unlock, .shelve, .unshelve, .rescue, .unrescue,
             .confirmResize, .revertResize:
            return "{\"\(actionKey)\":null}"

        // evacuate: `null` body → 400 and `onSharedStorage:null` → 400 (live
        // probe); emit an object, include the bool only when the caller set it.
        case .evacuate(let onSharedStorage, let host):
            var fields: [String] = []
            if let onSharedStorage { fields.append("\"onSharedStorage\":\(onSharedStorage ? "true" : "false")") }
            if let host { fields.append("\"host\":\"\(host)\"") }
            let inner = fields.isEmpty ? "{}" : "{\(fields.joined(separator: ","))}"
            return "{\"evacuate\":\(inner)}"

        // os-migrateLive: `host` is a REQUIRED property (null = scheduler
        // picks). block_migration/disk_over_commit omitted when nil.
        case .liveMigrate(let host, let blockMigration, let diskOverCommit):
            var fields: [String] = ["\"host\":\(host.map { "\"\($0)\"" } ?? "null")"]
            if let blockMigration { fields.append("\"block_migration\":\(blockMigration ? "true" : "false")") }
            if let diskOverCommit { fields.append("\"disk_over_commit\":\(diskOverCommit ? "true" : "false")") }
            return "{\"os-migrateLive\":{\(fields.joined(separator: ","))}}"

        // migrate (cold): object body; host null = scheduler; block-migration
        // pair included only when the caller expressed them.
        case .migrate(let host, let blockMigration, let diskOverCommit):
            var fields: [String] = ["\"host\":\(host.map { "\"\($0)\"" } ?? "null")"]
            if let blockMigration { fields.append("\"block_migration\":\(blockMigration ? "true" : "false")") }
            if let diskOverCommit { fields.append("\"disk_over_commit\":\(diskOverCommit ? "true" : "false")") }
            return "{\"migrate\":{\(fields.joined(separator: ","))}}"

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
            return "{\"os-getConsoleOutput\":{\"length\":\(lines)}}"

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
    public var blockDeviceMapping: [BlockDeviceMapping]

    /// A single block device mapping entry for boot-from-volume or additional disks.
    public struct BlockDeviceMapping: Sendable {
        public var uuid: String          // volume ID
        public var bootIndex: Int?       // 0 = root/boot device
        public var deleteOnTermination: Bool?
        public var sourceType: String?   // "volume", "image", "blank"
        public var destinationType: String?  // "volume", "local"
        public var volumeSize: Int?      // GB (for image→volume)
        public var volumeType: String?   // e.g. "HA-Performance"

        public init(
            uuid: String,
            bootIndex: Int? = nil,
            deleteOnTermination: Bool? = nil,
            sourceType: String? = nil,
            destinationType: String? = nil,
            volumeSize: Int? = nil,
            volumeType: String? = nil
        ) {
            self.uuid = uuid
            self.bootIndex = bootIndex
            self.deleteOnTermination = deleteOnTermination
            self.sourceType = sourceType
            self.destinationType = destinationType
            self.volumeSize = volumeSize
            self.volumeType = volumeType
        }
    }

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
        pinnedAvailabilityZone: String? = nil,
        blockDeviceMapping: [BlockDeviceMapping] = []
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
        self.blockDeviceMapping = blockDeviceMapping
    }


    /// Build the JSON body for the create request.
    public func body() -> String {
        var server: [String: String] = [
            "name": name
        ]
        // regionone's Nova (2026 cloud, strict schema) requires the *string*
        // flavorRef/imageRef form: {"flavorRef":"<uuid>","imageRef":"<uuid>"}.
        // It rejects the bare "flavor"/"image" keys ("'flavorRef' is a required
        // property") and rejects the object form flavorRef:{id:...} ("not of type
        // 'string'"). Live-validated via curl probe (flavorRef str + imageRef str
        // + networks[].uuid -> 202).
        server["flavorRef"] = flavorID
        server["imageRef"] = imageID
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

        var body = "{\"server\":{\(parts.joined(separator: ","))"

        if !networks.isEmpty {
            let nets = networks.map { net -> String in
                var netParts: [String] = []
                if let port = net.port { netParts.append("\"port\":\"\(port)\"") }
                // regionone Nova's create schema rejects the "network" key on a
                // networks[] entry ("Additional properties are not allowed") but
                // accepts "uuid". Live-validated: networks:[{"uuid":"..."}] -> 202.
                if let network = net.network { netParts.append("\"uuid\":\"\(network)\"") }
                if let fixedIP = net.fixedIP { netParts.append("\"fixed_ip\":\"\(fixedIP)\"") }
                return "{\(netParts.joined(separator: ","))}"
            }.joined(separator: ",")
            body = body + ",\"networks\":[\(nets)]"
        }

        if !securityGroups.isEmpty {
            // Rackspace's Nova (and other strict-schema clouds) reject the legacy
            // string-array form of security_groups ("'name' is not of type 'object'").
            // The object form [{"name":"..."}] is accepted by both strict and lenient
            // schemas, so always use it.
            let sgs = securityGroups.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
            body = body + ",\"security_groups\":[\(sgs)]"
        }

        if let minCount, let maxCount {
            body = body + ",\"min_count\":\(minCount),\"max_count\":\(maxCount)"
        }

        if let serverGroup {
            body = body + ",\"scheduler_hints\":{\"group\":\"\(serverGroup)\"}"
        }

        // block_device_mapping_v2: boot-from-volume and additional disks.
        // When a BDM entry has boot_index=0, the server boots from that volume.
        // The imageRef in the request must be set to the boot volume's ID (Nova
        // requirement for boot-from-volume with pre-existing volumes).
        if !blockDeviceMapping.isEmpty {
            let bdms = blockDeviceMapping.map { bdm -> String in
                var parts: [String] = []
                parts.append("\"uuid\":\"\(bdm.uuid)\"")
                if let bi = bdm.bootIndex { parts.append("\"boot_index\":\(bi)") }
                if let dot = bdm.deleteOnTermination { parts.append("\"delete_on_termination\":\(dot ? "true" : "false")") }
                if let st = bdm.sourceType { parts.append("\"source_type\":\"\(st)\"") }
                if let dt = bdm.destinationType { parts.append("\"destination_type\":\"\(dt)\"") }
                if let vs = bdm.volumeSize { parts.append("\"volume_size\":\(vs)") }
                if let vt = bdm.volumeType { parts.append("\"volume_type\":\"\(vt)\"") }
                return "{\(parts.joined(separator: ","))}"
            }.joined(separator: ",")
            body = body + ",\"block_device_mapping_v2\":[\(bdms)]"
        }

        return body + "}}"
    }
}

