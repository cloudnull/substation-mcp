import Foundation

/// A Nova server (instance).
public struct Server: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var flavor: FlavorRef
    public var addresses: [String: [String: String]]
    public var created: Date?
    public var metadata: [String: String]
    public var tags: [String]
    public var hostId: String?
    public var keyName: String?
    public var configDrive: String?
    public var availabilityZone: String?
    public var userID: String?
    public var projectID: String?
    public var image: ImageRef?
    public var securityGroups: [String]
    public var updated: Date?
    public var progress: Int?

    public init(
        id: String,
        name: String = "",
        status: String = "",
        flavor: FlavorRef = FlavorRef(id: "", links: []),
        addresses: [String: [String: String]] = [:],
        created: Date? = nil,
        metadata: [String: String] = [:],
        tags: [String] = [],
        hostId: String? = nil,
        keyName: String? = nil,
        configDrive: String? = nil,
        availabilityZone: String? = nil,
        userID: String? = nil,
        projectID: String? = nil,
        image: ImageRef? = nil,
        securityGroups: [String] = [],
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
        case hostId = "hostid"
        case keyName = "key_name"
        case configDrive = "config_drive"
        case availabilityZone = "availability_zone"
        case userID = "user_id"
        case projectID = "project_id"
        case image, securityGroups
        case created, updated, progress
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            // Bare-string flavor: Nova uses the string as the flavor identifier.
            self.id = string
            self.links = []
            return
        }
        if container.decodeNil() {
            self.id = ""
            self.links = []
            return
        }
        let object = try container.decode(FlavorObject.self)
        self.id = object.id
        self.links = object.links
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
public struct ImageRef: Sendable, Codable, Equatable {
    public let id: String
    public var links: [Link]
    public init(id: String, links: [Link] = []) {
        self.id = id
        self.links = links
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
        metadata: [String: String]? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, name, vcpus, ram, disk, ephemeral, swap
        case rxtxFactor = "rxtx_factor"
        case isPublic = "is_public"
        case links, metadata
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

/// Hypervisor.
public struct Hypervisor: Sendable, Codable {
    public let host: String
    public var hypervisorHostname: String
    public var hypervisorVersion: String
    public var state: String
    public var status: String
    public var maxMemoryRAM: Int
    public var currentMemoryRAM: Int
    public var diskTotal: Int
    public var diskUsed: Int
    public var CPUCount: Int
    public var vCPUs: Int
    public var runningVCPUs: Int

    public init(
        host: String,
        hypervisorHostname: String = "",
        hypervisorVersion: String = "0",
        state: String = "",
        status: String = "",
        maxMemoryRAM: Int = 0,
        currentMemoryRAM: Int = 0,
        diskTotal: Int = 0,
        diskUsed: Int = 0,
        CPUCount: Int = 0,
        vCPUs: Int = 0,
        runningVCPUs: Int = 0
    ) {
        self.host = host
        self.hypervisorHostname = hypervisorHostname
        self.hypervisorVersion = hypervisorVersion
        self.state = state
        self.status = status
        self.maxMemoryRAM = maxMemoryRAM
        self.currentMemoryRAM = currentMemoryRAM
        self.diskTotal = diskTotal
        self.diskUsed = diskUsed
        self.CPUCount = CPUCount
        self.vCPUs = vCPUs
        self.runningVCPUs = runningVCPUs
    }

    enum CodingKeys: String, CodingKey {
        case host, state, status
        case hypervisorHostname = "hypervisor_hostname"
        case hypervisorVersion = "hypervisor_version"
        case maxMemoryRAM = "maxmemory"
        case currentMemoryRAM = "current_workload"
        case diskTotal = "disk_total"
        case diskUsed = "disk_used"
        case CPUCount = "cpu"
        case vCPUs = "cpus"
        case runningVCPUs = "running_vcpus"
    }
}

/// Compute service.
public struct ComputeServiceInfo: Sendable, Codable, Identifiable {
    public let id: Int
    public var host: String
    public var binary: String
    public var zone: String
    public var status: String
    public var state: String
    public var disabledReason: String?
    public var updated: String?

    public init(
        id: Int,
        host: String = "",
        binary: String = "",
        zone: String = "",
        status: String = "",
        state: String = "",
        disabledReason: String? = nil,
        updated: String? = nil
    ) {
        self.id = id
        self.host = host
        self.binary = binary
        self.zone = zone
        self.status = status
        self.state = state
        self.disabledReason = disabledReason
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, host, binary, zone, status, state, updated
        case disabledReason = "disabled_reason"
    }
}

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
        self.serverGroup = serverGroup
        self.hostname = hostname
        self.pinnedAvailabilityZone = pinnedAvailabilityZone
    }

    /// Build the JSON body for the create request.
    func body() -> String {
        var server: [String: String] = [
            "name": name
        ]
        // flavorRef and imageRef are objects in Nova API, not strings
        let flavorJSON = "{\"id\":\"\(flavorID)\"}"
        let imageJSON = "{\"id\":\"\(imageID)\"}"
        server["flavorRef"] = flavorJSON
        server["imageRef"] = imageJSON
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

        if let minCount, let maxCount {
            body = body.dropLast() + ",\"min_count\":\(minCount),\"max_count\":\(maxCount)}"
        }

        if let serverGroup {
            body = body.dropLast() + ",\"scheduler_hints\":{\"group\":\"\(serverGroup)\"}}"
        }

        return body
    }
}
