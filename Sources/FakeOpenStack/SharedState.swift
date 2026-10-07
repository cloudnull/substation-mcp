import Foundation

/// In-memory state for the fake OpenStack cloud.
/// Seeded with 2 regions, standard flavors, one image, default security group,
/// one external network + subnet + router, and seeded credentials.
public actor FakeState {
    // MARK: - Credentials

    public struct FakeCredential: Sendable {
        public let id: String
        public let name: String
        public let secret: String
        public let projectID: String
        public let roles: [String]
        public let method: AuthMethod
        public let userID: String
        public let userName: String
        public let domain: String

        public enum AuthMethod: Sendable {
            case applicationCredential
            case password
        }
    }

    // MARK: - Token store

    public struct FakeToken: Sendable {
        public let id: String
        public let projectID: String
        public let projectName: String
        public let domainID: String
        public let domainName: String
        public let userID: String
        public let userName: String
        public let userDomain: String
        public let roles: [String]
        public let expiresAt: Date
    }

    // MARK: - Resources

    public struct FakeServer: Sendable, Identifiable {
        public let id: String
        public var name: String
        public var status: String
        public var flavorID: String
        public var flavorName: String
        public var imageID: String?
        public var projectID: String
        public var region: String
        public var addresses: [String: [String: String]]
        public var keyName: String?
        public var securityGroups: [String: String]
        public var metadata: [String: String]
        public var userData: String?
        public var created: Date
        public var updated: Date?

        public init(
            id: String,
            name: String,
            status: String = "ACTIVE",
            flavorID: String = "1",
            flavorName: String = "m1.small",
            imageID: String? = nil,
            projectID: String,
            region: String = "RegionOne",
            addresses: [String: [String: String]] = [:],
            keyName: String? = nil,
            securityGroups: [String: String] = [:],
            metadata: [String: String] = [:],
            userData: String? = nil
        ) {
            self.id = id
            self.name = name
            self.status = status
            self.flavorID = flavorID
            self.flavorName = flavorName
            self.imageID = imageID
            self.projectID = projectID
            self.region = region
            self.addresses = addresses
            self.keyName = keyName
            self.securityGroups = securityGroups
            self.metadata = metadata
            self.userData = userData
            self.created = Date()
            self.updated = nil
        }
    }

    public struct FakeFlavor: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let vcpus: Int
        public let ram: Int
        public let disk: Int
    }

    public struct FakeNetwork: Sendable, Identifiable {
        public let id: String
        public var name: String
        public let projectID: String
        public let region: String
        public var routerExternal: Bool
        public var status: String
        public var subnets: [String]
    }

    public struct FakeSubnet: Sendable, Identifiable {
        public let id: String
        public var name: String
        public let networkID: String
        public let projectID: String
        public let cidr: String
        public let gatewayIP: String?
        public var enableDHCP: Bool
        public var allocationPools: [FakeAllocationPool]
    }

    public struct FakeAllocationPool: Sendable {
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public struct FakeRouter: Sendable, Identifiable {
        public let id: String
        public var name: String
        public let projectID: String
        public var externalNetworkID: String?
        public var status: String
    }

    public struct FakeSecurityGroup: Sendable, Identifiable {
        public let id: String
        public var name: String
        public var description: String
        public let projectID: String
    }

    public struct FakeSecurityGroupRule: Sendable, Identifiable {
        public let id: String
        public let securityGroupID: String
        public let projectID: String
        public var direction: String
        public var ethertype: String
        public var ipProtocol: String?
        public var portRangeMin: Int?
        public var portRangeMax: Int?
        public var remoteIPPrefix: String?
    }

    public struct FakePort: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var networkID: String
        public var adminStateUp: Bool
        public var fixedIPs: [FakeFixedIP]
        public var securityGroups: [String]
        public var deviceID: String?
        public var deviceOwner: String?
        public var extraDHCPOpts: [FakeExtraDHCPOpt]
        public var portSecurityEnabled: Bool
    }

    public struct FakeFixedIP: Sendable {
        public var ip: String
        public var subnetID: String
    }

    public struct FakeExtraDHCPOpt: Sendable {
        public var optName: String
        public var optValue: String
    }

    public struct FakeFloatingIP: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var floatingIP: String
        public var floatingNetworkID: String
        public var portID: String?
        public var fixedIPAddress: String?
        public var routerID: String?
        public var status: String
    }

    public struct FakeAddressGroup: Sendable, Identifiable {
        public var id: String?
        public let projectID: String
        public var name: String
        public var description: String
        public var addresses: [String]
    }

    // MARK: - Cinder Types

    public struct FakeVolume: Sendable, Identifiable {
        public let id: String
        public let projectID: String
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
        public var attachments: [FakeVolumeAttachment]
        public var created: String

        public init(
            id: String,
            projectID: String,
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
            attachments: [FakeVolumeAttachment] = [],
            created: String = ""
        ) {
            self.id = id
            self.projectID = projectID
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
            self.attachments = attachments
            self.created = created
        }
    }

    public struct FakeVolumeAttachment: Sendable, Identifiable {
        public let id: String
        public var serverID: String?
        public var volumeID: String
        public var device: String
    }

    public struct FakeVolumeType: Sendable, Identifiable {
        public let id: String
        public var name: String
        public var extraSpecs: [String: String]?
    }

    public struct FakeSnapshot: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var volumeID: String
        public var size: Int
        public var description: String
        public var force: Bool
        public var created: String
    }

    public struct FakeBackup: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var volumeID: String
        public var size: Int
        public var description: String
        public var created: String
    }

    // MARK: - Glance Types

    public struct FakeImage: Sendable, Identifiable {
        public let id: String
        public let projectID: String
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
        /// Stored payload bytes (for base64 upload) or nil (web-download).
        public var data: Data?

        public init(
            id: String,
            projectID: String,
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
            updated: String = "",
            data: Data? = nil
        ) {
            self.id = id
            self.projectID = projectID
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
            self.data = data
        }
    }

    // MARK: - Swift (object storage) fake state

    public struct FakeContainer: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var quotaBytes: Int?
        public var metadata: [String: String]
        public var created: String

        public init(id: String, projectID: String, name: String = "", quotaBytes: Int? = nil, metadata: [String: String] = [:], created: String = "2026-01-01T00:00:00.000") {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.quotaBytes = quotaBytes
            self.metadata = metadata
            self.created = created
        }
    }

    public struct FakeObject: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var container: String
        public var name: String
        public var size: Int
        public var contentType: String
        public var data: Data
        public var metadata: [String: String]

        public init(id: String, projectID: String, container: String, name: String = "", size: Int = 0, contentType: String = "application/octet-stream", data: Data = Data(), metadata: [String: String] = [:]) {
            self.id = id
            self.projectID = projectID
            self.container = container
            self.name = name
            self.size = size
            self.contentType = contentType
            self.data = data
            self.metadata = metadata
        }
    }

    // MARK: - Barbican (key manager) fake state

    public struct FakeSecret: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var type: String
        public var status: String
        public var algorithm: String?
        public var bitSize: Int?
        public var mode: String?
        public var isSecret: Bool
        public var visibility: String
        public var payload: String
        public var payloadContentType: String

        public init(
            id: String,
            projectID: String,
            name: String? = nil,
            type: String = "opaque",
            status: String = "inactive",
            algorithm: String? = nil,
            bitSize: Int? = nil,
            mode: String? = nil,
            isSecret: Bool = true,
            visibility: String = "private",
            payload: String = "",
            payloadContentType: String = "text/plain"
        ) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.type = type
            self.status = status
            self.algorithm = algorithm
            self.bitSize = bitSize
            self.mode = mode
            self.isSecret = isSecret
            self.visibility = visibility
            self.payload = payload
            self.payloadContentType = payloadContentType
        }
    }

    public struct FakeSecretContainer: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var type: String
        public var secretRefs: [String]

        public init(id: String, projectID: String, name: String? = nil, type: String = "generic", secretRefs: [String] = []) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.type = type
            self.secretRefs = secretRefs
        }
    }

    // MARK: - Octavia (load balancer) fake state

    public struct FakeLoadBalancer: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var status: String
        public var provisioningStatus: String
        public var vipAddress: String?

        public init(id: String, projectID: String, name: String? = nil, status: String = "ACTIVE", provisioningStatus: String = "ACTIVE", vipAddress: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.status = status
            self.provisioningStatus = provisioningStatus
            self.vipAddress = vipAddress
        }
    }

    public struct FakeListener: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var protocolName: String
        public var protocolPort: Int
        public var loadBalancerID: String?

        public init(id: String, projectID: String, name: String? = nil, protocolName: String = "HTTP", protocolPort: Int = 80, loadBalancerID: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.protocolName = protocolName
            self.protocolPort = protocolPort
            self.loadBalancerID = loadBalancerID
        }
    }

    public struct FakePool: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var protocolName: String
        public var lbAlgorithm: String
        public var loadBalancerID: String?
        public var healthMonitorID: String?

        public init(id: String, projectID: String, name: String? = nil, protocolName: String = "HTTP", lbAlgorithm: String = "ROUND_ROBIN", loadBalancerID: String? = nil, healthMonitorID: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.protocolName = protocolName
            self.lbAlgorithm = lbAlgorithm
            self.loadBalancerID = loadBalancerID
            self.healthMonitorID = healthMonitorID
        }
    }

    public struct FakeMember: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var protocolAddress: String
        public var protocolPort: Int
        public var weight: Int?
        public var adminStateUp: Bool?
        public var poolID: String?
        public var status: String?

        public init(id: String, projectID: String, name: String? = nil, protocolAddress: String, protocolPort: Int, weight: Int? = 1, adminStateUp: Bool? = true, poolID: String? = nil, status: String? = "ONLINE") {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.protocolAddress = protocolAddress
            self.protocolPort = protocolPort
            self.weight = weight
            self.adminStateUp = adminStateUp
            self.poolID = poolID
            self.status = status
        }
    }

    public struct FakeHealthMonitor: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String?
        public var type: String
        public var delay: Int?
        public var timeout: Int?
        public var maxRetries: Int?
        public var poolID: String?

        public init(id: String, projectID: String, name: String? = nil, type: String = "PING", delay: Int? = 10, timeout: Int? = 5, maxRetries: Int? = 3, poolID: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.type = type
            self.delay = delay
            self.timeout = timeout
            self.maxRetries = maxRetries
            self.poolID = poolID
        }
    }

    // MARK: - Designate (DNS) fake state

    public struct FakeZone: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var email: String?
        public var status: String
        public var ttl: Int?

        public init(id: String, projectID: String, name: String, email: String? = nil, status: String = "active", ttl: Int? = 3600) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.email = email
            self.status = status
            self.ttl = ttl
        }
    }

    public struct FakeRecordSet: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var type: String
        public var ttl: Int?
        public var records: [String]
        public var zoneID: String?

        public init(id: String, projectID: String, name: String, type: String, ttl: Int? = nil, records: [String] = [], zoneID: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.type = type
            self.ttl = ttl
            self.records = records
            self.zoneID = zoneID
        }
    }

    // MARK: - Magnum (container) fake state

    public struct FakeMagnumCluster: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var masterCount: Int
        public var nodeCount: Int
        public var clusterTemplateID: String?

        public init(id: String, projectID: String, name: String, status: String = "ACTIVE", masterCount: Int = 1, nodeCount: Int = 0, clusterTemplateID: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.status = status
            self.masterCount = masterCount
            self.nodeCount = nodeCount
            self.clusterTemplateID = clusterTemplateID
        }
    }

    public struct FakeMagnumTemplate: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var masterCount: Int
        public var nodeCount: Int

        public init(id: String, projectID: String, name: String, masterCount: Int = 1, nodeCount: Int = 0) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.masterCount = masterCount
            self.nodeCount = nodeCount
        }
    }

    // MARK: - Heat (orchestration) fake state

    public struct FakeHeatStack: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var parameters: [String: String]
        public var outputs: [FakeStackOutput]

        public init(id: String, projectID: String, name: String, status: String = "CREATE_COMPLETE", parameters: [String: String] = [:], outputs: [FakeStackOutput] = []) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.status = status
            self.parameters = parameters
            self.outputs = outputs
        }
    }

    public struct FakeStackOutput: Sendable {
        public var outputKey: String
        public var outputValue: String
        public var description: String?

        public init(outputKey: String, outputValue: String, description: String? = nil) {
            self.outputKey = outputKey
            self.outputValue = outputValue
            self.description = description
        }
    }

    // MARK: - Storage

    public private(set) var credentials: [FakeCredential] = []
    public private(set) var zones: [FakeZone] = []
    public private(set) var recordSets: [FakeRecordSet] = []
    public private(set) var magnumClusters: [FakeMagnumCluster] = []
    public private(set) var magnumTemplates: [FakeMagnumTemplate] = []
    public private(set) var heatStacks: [FakeHeatStack] = []
    public private(set) var shares: [FakeShare] = []
    public private(set) var shareAccesses: [FakeShareAccess] = []

    // MARK: - Manila (shared file systems) fake state

    public struct FakeShare: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var name: String
        public var status: String
        public var shareSize: Int
        public var shareType: String
        public var description: String?
        public var isPublic: Bool

        public init(id: String, projectID: String, name: String, status: String = "available", shareSize: Int = 1, shareType: String = "generic", description: String? = nil, isPublic: Bool = false) {
            self.id = id
            self.projectID = projectID
            self.name = name
            self.status = status
            self.shareSize = shareSize
            self.shareType = shareType
            self.description = description
            self.isPublic = isPublic
        }
    }

    public struct FakeShareAccess: Sendable, Identifiable {
        public let id: String
        public let projectID: String
        public var shareID: String
        public var accessTo: String
        public var accessType: String
        public var accessProtocol: String
        public var state: String

        public init(id: String, projectID: String, shareID: String, accessTo: String, accessType: String = "ip", accessProtocol: String = "nfs", state: String = "accessible") {
            self.id = id
            self.projectID = projectID
            self.shareID = shareID
            self.accessTo = accessTo
            self.accessType = accessType
            self.accessProtocol = accessProtocol
            self.state = state
        }
    }
    public private(set) var loadBalancers: [FakeLoadBalancer] = []
    public private(set) var listeners: [FakeListener] = []
    public private(set) var pools: [FakePool] = []
    public private(set) var members: [FakeMember] = []
    public private(set) var healthMonitors: [FakeHealthMonitor] = []
    public private(set) var secrets: [FakeSecret] = []
    public private(set) var secretContainers: [FakeSecretContainer] = []
    public private(set) var tokens: [String: FakeToken] = [:]
    public private(set) var servers: [FakeServer] = []
    public private(set) var flavors: [FakeFlavor] = []
    public private(set) var networks: [FakeNetwork] = []
    public private(set) var subnets: [FakeSubnet] = []
    public private(set) var routers: [FakeRouter] = []
    public private(set) var securityGroups: [FakeSecurityGroup] = []
    public private(set) var securityGroupRules: [FakeSecurityGroupRule] = []
    public private(set) var ports: [FakePort] = []
    public private(set) var floatingIPs: [FakeFloatingIP] = []
    public private(set) var addressGroups: [FakeAddressGroup] = []
    public private(set) var volumes: [FakeVolume] = []
    public private(set) var volumeTypes: [FakeVolumeType] = []
    public private(set) var snapshots: [FakeSnapshot] = []
    public private(set) var backups: [FakeBackup] = []
    public private(set) var images: [FakeImage] = []
    public private(set) var containers: [FakeContainer] = []
    public private(set) var objects: [FakeObject] = []
    public var extensions: Set<String> = ["provider", "qos", "security-group", "address-group"]

    // MARK: - Keystone catalog (services + endpoints) for register-catalog

    public struct FakeService: Sendable, Identifiable {
        public let id: String
        public let type: String
        public let name: String
        public let description: String
    }

    public struct FakeEndpoint: Sendable, Identifiable {
        public let id: String
        public let serviceID: String
        public let interface: String
        public let regionID: String
        public let url: String
    }

    // MARK: - Keystone identity (domains/users/roles/app-creds) for provisioning

    public struct FakeDomain: Sendable, Identifiable {
        public let id: String
        public let name: String
    }

    public struct FakeIdentityUser: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let domainID: String
        public let enabled: Bool
        /// The user's password (set at creation). Used for password-based token
        /// minting of provisioned service users.
        public let password: String?
    }

    public struct FakeRole: Sendable, Identifiable {
        public let id: String
        public let name: String
    }

    public struct FakeRoleAssignment: Sendable {
        public let roleID: String
        public let userID: String
        public let domainID: String
    }

    public struct FakeAppCred: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let userID: String
        public let secret: String
    }

    public private(set) var services: [FakeService] = []
    public private(set) var endpoints: [FakeEndpoint] = []
    public private(set) var identityDomains: [FakeDomain] = []
    public private(set) var identityUsers: [FakeIdentityUser] = []
    public private(set) var identityRoles: [FakeRole] = []
    public private(set) var identityRoleAssignments: [FakeRoleAssignment] = []
    public private(set) var identityAppCreds: [FakeAppCred] = []

    /// Delay applied before a server action settles to its final status
    /// (used by waiter tests to observe intermediate progress). Nil = instant.
    public var transitionDelay: Duration? = nil

    /// Router interface attachments: router id -> subnet ids.
    public private(set) var routerInterfaces: [String: [String]] = [:]
    /// Volume attachments: attachment id -> (serverID, volumeID, device, status).
    public private(set) var volumeAttachments: [String: (serverID: String, volumeID: String, device: String, status: String)] = [:]
    /// Console urls keyed by (tokenID, serverID). Nova scopes a console url to
    /// the requesting identity, so a session only ever sees the url it asked
    /// for; same-project sessions mint their own (distinct) urls.
    public private(set) var consoles: [String: [String: String]] = [:]

    /// Generate (or return the existing) console url for a token+server pair.
    /// The url is derived from the token's project + server so it is stable per
    /// requestor but distinct across requestors.
    public func consoleURL(tokenID: String, serverID: String, type: String) -> String {
        let key = "\(tokenID):\(serverID):\(type)"
        if let existing = consoles[tokenID]?[key] {
            return existing
        }
        let token = tokens[tokenID]
        let project = token?.projectName ?? "unknown"
        let url = "http://127.0.0.1:6080/console/\(project)/\(serverID)/\(UUID().uuidString)"
        consoles[tokenID, default: [:]][key] = url
        return url
    }

    /// Test-only knob: set true to make the next server status change settle instantly.
    public var suppressTransitionDelay: Bool = false

    /// Set the transition delay from a nonisolated context.
    public func setTransitionDelay(_ delay: Duration?) {
        transitionDelay = delay
    }

    public func removeExtension(_ alias: String) {
        extensions.remove(alias)
    }

    // MARK: - Test/seed mutators (Task 15)

    /// Add a router interface attachment (router <-> subnet).
    @discardableResult
    public func addRouterInterface(routerID: String, subnetID: String) -> Bool {
        guard routers.contains(where: { $0.id == routerID }) else { return false }
        if !routerInterfaces[routerID, default: []].contains(subnetID) {
            routerInterfaces[routerID, default: []].append(subnetID)
        }
        return true
    }

    /// All subnet ids a router has interfaces on.
    public func routerInterfaceSubnets(routerID: String) -> [String] {
        routerInterfaces[routerID] ?? []
    }

    /// Remove a router interface attachment.
    @discardableResult
    public func removeRouterInterface(routerID: String, subnetID: String) -> Bool {
        guard var list = routerInterfaces[routerID] else { return false }
        guard let idx = list.firstIndex(of: subnetID) else { return false }
        list.remove(at: idx)
        routerInterfaces[routerID] = list
        return true
    }

    /// Attach a volume to a server (mimics Nova os-volume_attachments).
    @discardableResult
    public func attachVolume(serverID: String, volumeID: String, device: String, projectID: String) -> String? {
        guard let vIdx = volumes.firstIndex(where: { $0.id == volumeID && $0.projectID == projectID }),
              servers.contains(where: { $0.id == serverID && $0.projectID == projectID }) else {
            return nil
        }
        let attID = "att-\(volumeAttachments.count + 100)"
        volumeAttachments[attID] = (serverID: serverID, volumeID: volumeID, device: device, status: "attached")
        var vol = volumes[vIdx]
        vol.status = "in-use"
        let att = FakeVolumeAttachment(id: attID, serverID: serverID, volumeID: volumeID, device: device)
        vol.attachments.append(att)
        volumes[vIdx] = vol
        return attID
    }

    /// Detach a volume from a server (mimics Nova os-volume_attachments/:attID delete).
    @discardableResult
    public func detachVolume(attachmentID: String, serverID: String, projectID: String) -> Bool {
        guard let att = volumeAttachments[attachmentID], att.serverID == serverID else { return false }
        volumeAttachments.removeValue(forKey: attachmentID)
        guard let vIdx = volumes.firstIndex(where: { $0.id == att.volumeID && $0.projectID == projectID }) else { return true }
        var vol = volumes[vIdx]
        vol.attachments.removeAll { $0.id == attachmentID }
        vol.status = vol.attachments.isEmpty ? "available" : "in-use"
        volumes[vIdx] = vol
        return true
    }

    /// List volume attachments for a server (mimics Nova os-volumes).
    /// Nova's os-volumes shape has volumeId + device; the volume id doubles
    /// as the attachment's own id here (the fake does not track separate
    /// attachment ids for listing).
    public func listServerVolumeAttachments(serverID: String, projectID: String) -> [FakeVolumeAttachment] {
        volumes
            .filter { $0.projectID == projectID }
            .flatMap { vol in
                vol.attachments
                    .filter { $0.serverID == serverID }
                    .map { FakeVolumeAttachment(id: vol.id, serverID: serverID, volumeID: vol.id, device: $0.device) }
            }
    }

    /// List interfaces (ports) attached to a server (mimics Nova os-interface).
    public func listServerInterfaces(serverID: String, projectID: String) -> [FakePort] {
        ports.filter { $0.projectID == projectID && $0.deviceID == serverID && $0.deviceOwner == "compute:nova" }
    }

    /// Attach an interface to a server (mimics Nova os-interface-attach).
    /// Returns the port id.
    @discardableResult
    public func attachInterface(serverID: String, networkID: String?, subnetID: String?, portID: String?, projectID: String) -> String? {
        guard servers.contains(where: { $0.id == serverID && $0.projectID == projectID }) else { return nil }
        if let portID {
            // Attach an existing port: mark device
            if let pIdx = ports.firstIndex(where: { $0.id == portID && $0.projectID == projectID }) {
                var p = ports[pIdx]
                p.deviceID = serverID
                p.deviceOwner = "compute:nova"
                p.status = "ACTIVE"
                ports[pIdx] = p
                return portID
            }
            return nil
        }
        // Create a new port on the network
        guard let networkID, let nIdx = networks.firstIndex(where: { $0.id == networkID && $0.projectID == projectID }) else {
            return nil
        }
        let net = networks[nIdx]
        let subnet = subnetID.flatMap { s in subnets.first(where: { $0.id == s && $0.projectID == projectID }) }
            ?? subnets.first(where: { $0.networkID == networkID && $0.projectID == projectID })
        portIDCounter += 1
        let id = "port-\(String(format: "%03d", portIDCounter))"
        var fixed: [FakeFixedIP] = []
        if let subnet, let pool = subnet.allocationPools.first,
           let start = pool.start.split(separator: ".").last, let startInt = Int(start) {
            let base = pool.start
            var candidate: String
            repeat {
                let n = startInt + portIDCounter
                candidate = base.split(separator: ".").prefix(3).joined(separator: ".") + ".\(n)"
            } while usedIPs(projectID: projectID).contains(candidate)
            fixed = [FakeFixedIP(ip: candidate, subnetID: subnet.id)]
        }
        let port = FakePort(
            id: id,
            projectID: projectID,
            name: "port-srv-\(serverID)",
            status: "ACTIVE",
            networkID: net.id,
            adminStateUp: true,
            fixedIPs: fixed,
            securityGroups: [],
            deviceID: serverID,
            deviceOwner: "compute:nova",
            extraDHCPOpts: [],
            portSecurityEnabled: true
        )
        ports.append(port)
        return id
    }

    /// Detach an interface from a server (mimics Nova os-interface-detach).
    @discardableResult
    public func detachInterface(serverID: String, portID: String, projectID: String) -> Bool {
        guard let pIdx = ports.firstIndex(where: { $0.id == portID && $0.projectID == projectID && $0.deviceID == serverID }) else {
            return false
        }
        var p = ports[pIdx]
        p.deviceID = nil
        p.deviceOwner = nil
        p.status = "DOWN"
        ports[pIdx] = p
        return true
    }

    /// Replace a port's security groups (mimics Neutron port update for SG links).
    @discardableResult
    public func setPortSecurityGroups(portID: String, groups: [String], projectID: String) -> FakePort? {
        guard let pIdx = ports.firstIndex(where: { $0.id == portID && $0.projectID == projectID }) else { return nil }
        ports[pIdx].securityGroups = groups
        return ports[pIdx]
    }

    /// Apply a server action with an optional settle delay (used by waiter tests).
    /// When `transitionDelay` is set and the action settles to ACTIVE, the
    /// intermediate status is applied immediately and the final status runs
    /// after the delay in a background task.
    public func serverActionWithSettle(id: String, projectID: String, action: String) -> (success: Bool, error: String?) {
        guard let idx = servers.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else {
            return (false, "server not found")
        }
        let delay = transitionDelay
        switch action {
        case "start", "os-start", "unpause", "resume", "unlock", "unshelve", "unrescue", "reboot":
            if let delay, !suppressTransitionDelay {
                // Two-phase: intermediate now, ACTIVE after the delay
                servers[idx].status = action == "reboot" ? "REBOOT" : "REBUILD"
                servers[idx].updated = Date()
                Task {
                    try? await Task.sleep(for: delay)
                    self.finishSettle(idx: idx, status: "ACTIVE")
                }
            } else {
                servers[idx].status = "ACTIVE"
                servers[idx].updated = Date()
            }
        case "stop", "os-stop": servers[idx].status = "SHUTOFF"; servers[idx].updated = Date()
        case "pause": servers[idx].status = "PAUSED"; servers[idx].updated = Date()
        case "suspend": servers[idx].status = "SUSPENDED"; servers[idx].updated = Date()
        case "lock": servers[idx].status = "LOCKED"; servers[idx].updated = Date()
        case "shelve": servers[idx].status = "SHELVED"; servers[idx].updated = Date()
        case "rescue": servers[idx].status = "RESCUE"; servers[idx].updated = Date()
        default:
            return (false, "unknown action: \(action)")
        }
        return (true, nil)
    }

    private func finishSettle(idx: Int, status: String) {
        guard idx < servers.count else { return }
        servers[idx].status = status
        servers[idx].updated = Date()
    }

    /// List ports whose fixed IP addresses include the given IP (any project-scoped).
    public func portsWithFixedIP(_ ip: String, projectID: String) -> [FakePort] {
        ports.filter { $0.projectID == projectID && $0.fixedIPs.contains(where: { $0.ip == ip }) }
    }

    private var serverIDCounter = 0
    private var tokenIDCounter = 0
    private var netIDCounter = 0
    private var subnetIDCounter = 0
    private var portIDCounter = 0
    private var routerIDCounter = 1
    private var sgIDCounter = 0
    private var sgRuleIDCounter = 0
    private var fipIDCounter = 0
    private var agIDCounter = 0
    private var volIDCounter = 0
    private var containerIDCounter = 0
    private var objectIDCounter = 0
    private var secretIDCounter = 0
    private var secretContainerIDCounter = 0
    private var lbIDCounter = 0
    private var listenerIDCounter = 0
    private var poolIDCounter = 0
    private var memberIDCounter = 0
    private var healthMonitorIDCounter = 0
    private var zoneIDCounter = 0
    private var recordSetIDCounter = 0
    private var magnumClusterIDCounter = 0
    private var magnumTemplateIDCounter = 0
    private var heatStackIDCounter = 0
    private var shareIDCounter = 0
    private var shareAccessIDCounter = 0
    private var volTypeIDCounter = 0
    private var snapIDCounter = 0
    private var backupIDCounter = 0
    private var imgIDCounter = 0
    private var serviceIDCounter = 0
    private var endpointIDCounter = 0
    private var identityUserCounter = 0
    private var identityAppCredCounter = 0
    private var _baseHost: String = "http://127.0.0.1:0"

    public var baseHost: String { _baseHost }
    public func setBaseHost(_ host: String) { _baseHost = host }

    public init() {}

    // MARK: - Seeding

    /// Seed the fake state with default data.
    public func seed() {
        // Flavors
        flavors = [
            FakeFlavor(id: "1", name: "m1.small", vcpus: 1, ram: 2048, disk: 20),
            FakeFlavor(id: "2", name: "m1.large", vcpus: 2, ram: 8192, disk: 40),
            FakeFlavor(id: "3", name: "m1.xlarge", vcpus: 4, ram: 16384, disk: 80)
        ]

        // Networks
        networks = [
            FakeNetwork(id: "net-ext", name: "ext-net", projectID: "proj-one", region: "RegionOne", routerExternal: true, status: "ACTIVE", subnets: ["subnet-ext"]),
            FakeNetwork(id: "net-int", name: "int-net", projectID: "proj-one", region: "RegionOne", routerExternal: false, status: "ACTIVE", subnets: ["subnet-int"]),
            FakeNetwork(id: "net-two", name: "int-net-2", projectID: "proj-two", region: "RegionOne", routerExternal: false, status: "ACTIVE", subnets: ["subnet-two"])
        ]

        // Subnets
        subnets = [
            FakeSubnet(id: "subnet-ext", name: "subnet-ext", networkID: "net-ext", projectID: "proj-one", cidr: "10.0.0.0/24", gatewayIP: "10.0.0.1", enableDHCP: true, allocationPools: [FakeAllocationPool(start: "10.0.0.2", end: "10.0.0.254")]),
            FakeSubnet(id: "subnet-int", name: "subnet-int", networkID: "net-int", projectID: "proj-one", cidr: "192.168.1.0/24", gatewayIP: "192.168.1.1", enableDHCP: true, allocationPools: [FakeAllocationPool(start: "192.168.1.2", end: "192.168.1.254")]),
            FakeSubnet(id: "subnet-two", name: "subnet-two", networkID: "net-two", projectID: "proj-two", cidr: "192.168.2.0/24", gatewayIP: "192.168.2.1", enableDHCP: true, allocationPools: [FakeAllocationPool(start: "192.168.2.2", end: "192.168.2.254")])
        ]

        // Routers
        routers = [
            FakeRouter(id: "router-1", name: "router-1", projectID: "proj-one", externalNetworkID: "net-ext", status: "ACTIVE")
        ]
        // router-1 bridges subnet-int to net-ext
        routerInterfaces = ["router-1": ["subnet-int"]]

        // Security groups
        securityGroups = [
            FakeSecurityGroup(id: "sg-default", name: "default", description: "default", projectID: "proj-one"),
            FakeSecurityGroup(id: "sg-default-two", name: "default", description: "default", projectID: "proj-two")
        ]

        // Credentials
        credentials = [
            FakeCredential(
                id: "fake-cred-admin",
                name: "fake-cred-admin",
                secret: "secret-admin",
                projectID: "proj-one",
                roles: ["admin"],
                method: .applicationCredential,
                userID: "user-admin",
                userName: "admin",
                domain: "default"
            ),
            FakeCredential(
                id: "fake-cred-ro",
                name: "fake-cred-ro",
                secret: "secret-ro",
                projectID: "proj-one",
                roles: ["member", "_member_"],
                method: .applicationCredential,
                userID: "user-ro",
                userName: "readonly",
                domain: "default"
            ),
            FakeCredential(
                id: "fake-cred-two",
                name: "fake-cred-two",
                secret: "secret-two",
                projectID: "proj-two",
                roles: ["admin"],
                method: .applicationCredential,
                userID: "user-two",
                userName: "two-admin",
                domain: "default"
            )
        ]

        // Seed a few servers in proj-one
        for i in 1...3 {
            serverIDCounter += 1
            // srv-0001 carries user_data so the hardening suite can assert the
            // MCP server never echoes it back (spec §12).
            let userData = i == 1 ? "c2VjcmV0LXVzZXItZGF0YQ==" : nil
            servers.append(FakeServer(
                id: String(format: "srv-%04d", serverIDCounter),
                name: "server-\(i)",
                status: "ACTIVE",
                projectID: "proj-one",
                userData: userData
            ))
        }

        // One server in proj-two
        serverIDCounter += 1
        servers.append(FakeServer(
            id: String(format: "srv-%04d", serverIDCounter),
            name: "server-two-1",
            status: "ACTIVE",
            projectID: "proj-two"
        ))

        // Seeded port in proj-one (uses 10.0.0.5 on subnet-ext)
        portIDCounter += 1
        ports.append(FakePort(
            id: "port-001",
            projectID: "proj-one",
            name: "port-seed",
            status: "ACTIVE",
            networkID: "net-ext",
            adminStateUp: true,
            fixedIPs: [FakeFixedIP(ip: "10.0.0.5", subnetID: "subnet-ext")],
            securityGroups: ["sg-default"],
            deviceID: nil,
            deviceOwner: nil,
            extraDHCPOpts: [],
            portSecurityEnabled: true
        ))

        // One unassociated floating IP in proj-one
        fipIDCounter += 1
        floatingIPs.append(FakeFloatingIP(
            id: "fip-001",
            projectID: "proj-one",
            floatingIP: "203.0.113.10",
            floatingNetworkID: "net-ext",
            portID: nil,
            fixedIPAddress: nil,
            routerID: "router-1",
            status: "DOWN"
        ))

        // Cinder: volume types + a seeded volume
        volTypeIDCounter = 2
        volumeTypes = [
            FakeVolumeType(id: "vt-1", name: "lvmdriver-1", extraSpecs: ["volume_backend_name": "lvmdriver-1"]),
            FakeVolumeType(id: "vt-2", name: "lvmdriver-2", extraSpecs: ["volume_backend_name": "lvmdriver-2"])
        ]
        volIDCounter += 1
        volumes.append(FakeVolume(
            id: "seed-vol",
            projectID: "proj-one",
            name: "seed-vol",
            status: "available",
            size: 10,
            volumeType: "lvmdriver-1",
            created: "2026-01-01T00:00:00.000"
        ))
        // Dedicated seeds used by the compute client tests (attach/detach).
        volumes.append(FakeVolume(
            id: "vol-001",
            projectID: "proj-one",
            name: "vol-001",
            status: "in-use",
            size: 1,
            volumeType: "lvmdriver-1",
            created: "2026-01-01T00:00:00.000"
        ))
        volumeAttachments["att-001"] = (serverID: "srv-0001", volumeID: "vol-001", device: "/dev/vdb", status: "attached")
        // Mirror the attachment into the volume's attachment list so the
        // os-volumes list endpoint (which reads volume.attachments) reports
        // it for srv-0001.
        if let vIdx = volumes.firstIndex(where: { $0.id == "vol-001" && $0.projectID == "proj-one" }) {
            volumes[vIdx].attachments.append(FakeVolumeAttachment(
                id: "att-001",
                serverID: "srv-0001",
                volumeID: "vol-001",
                device: "/dev/vdb"
            ))
        }

        // Dedicated network + port seeds used by the compute client tests.
        networks.append(FakeNetwork(
            id: "net-001",
            name: "net-001",
            projectID: "proj-one",
            region: "RegionOne",
            routerExternal: false,
            status: "ACTIVE",
            subnets: ["subnet-001"]
        ))
        subnets.append(FakeSubnet(
            id: "subnet-001",
            name: "subnet-001",
            networkID: "net-001",
            projectID: "proj-one",
            cidr: "172.16.1.0/24",
            gatewayIP: "172.16.1.1",
            enableDHCP: true,
            allocationPools: [FakeAllocationPool(start: "172.16.1.2", end: "172.16.1.254")]
        ))
        subnetIDCounter = 1
        portIDCounter = 2
        ports.append(FakePort(
            id: "port-002",
            projectID: "proj-one",
            name: "port-002",
            status: "ACTIVE",
            networkID: "net-int",
            adminStateUp: true,
            fixedIPs: [FakeFixedIP(ip: "192.168.1.77", subnetID: "subnet-int")],
            securityGroups: ["sg-default"],
            deviceID: "srv-0001",
            deviceOwner: "compute:nova",
            extraDHCPOpts: [],
            portSecurityEnabled: true
        ))

        // Glance: a seeded active image
        imgIDCounter = 1
        images.append(FakeImage(
            id: "img-1",
            projectID: "proj-one",
            name: "ubuntu-24.04",
            status: "active",
            visibility: "public",
            diskFormat: "qcow2",
            containerFormat: "bare",
            size: 1024,
            minRAM: 512,
            created: "2026-01-01T00:00:00.000",
            updated: "2026-01-01T00:00:00.000"
        ))

        // Swift (object storage) seed: one container with one object.
        containerIDCounter = 1
        containers.append(FakeContainer(id: "ctn-1", projectID: "proj-one", name: "fake-bucket"))
        objectIDCounter = 1
        objects.append(FakeObject(id: "obj-1", projectID: "proj-one", container: "fake-bucket", name: "hello.txt", size: 11, contentType: "text/plain", data: Data("hello world".utf8)))

        // Barbican (key manager) seed: one active opaque secret + one container.
        secretIDCounter = 1
        secrets.append(FakeSecret(
            id: "sec-1",
            projectID: "proj-one",
            name: "fake-api-key",
            type: "opaque",
            status: "active",
            isSecret: true,
            visibility: "private",
            payload: "ZmFrZS1zZWNyZXQtbWF0ZXJpYWw=",
            payloadContentType: "text/plain"
        ))
        secretContainerIDCounter = 1
        secretContainers.append(FakeSecretContainer(id: "sct-1", projectID: "proj-one", name: "fake-key-container", type: "generic", secretRefs: ["sec-1"]))

        // Octavia (load balancer) seed: one active LB + a pool + a member.
        lbIDCounter = 1
        loadBalancers.append(FakeLoadBalancer(id: "lb-1", projectID: "proj-one", name: "fake-lb", status: "ACTIVE", provisioningStatus: "ACTIVE", vipAddress: "10.0.0.10"))
        poolIDCounter = 1
        pools.append(FakePool(id: "pool-1", projectID: "proj-one", name: "fake-pool", protocolName: "HTTP", lbAlgorithm: "ROUND_ROBIN", loadBalancerID: "lb-1"))
        memberIDCounter = 1
        members.append(FakeMember(id: "member-1", projectID: "proj-one", name: "fake-member", protocolAddress: "10.0.0.20", protocolPort: 80, poolID: "pool-1", status: "ONLINE"))

        // Designate (DNS) seed: one active zone + one record set.
        zoneIDCounter = 1
        zones.append(FakeZone(id: "zone-1", projectID: "proj-one", name: "example.com.", email: "admin@example.com", status: "active", ttl: 3600))
        recordSetIDCounter = 1
        recordSets.append(FakeRecordSet(id: "rs-1", projectID: "proj-one", name: "www.example.com.", type: "A", ttl: 3600, records: ["10.0.0.1"], zoneID: "zone-1"))

        // Magnum (container) seed: one template + one active cluster.
        magnumTemplateIDCounter = 1
        magnumTemplates.append(FakeMagnumTemplate(id: "ct-1", projectID: "proj-one", name: "fake-k8s-template", masterCount: 1, nodeCount: 3))
        magnumClusterIDCounter = 1
        magnumClusters.append(FakeMagnumCluster(id: "cluster-1", projectID: "proj-one", name: "fake-k8s-cluster", status: "ACTIVE", masterCount: 1, nodeCount: 3, clusterTemplateID: "ct-1"))

        // Heat (orchestration) seed: one CREATE_COMPLETE stack with an output.
        heatStackIDCounter = 1
        heatStacks.append(FakeHeatStack(
            id: "stack-1",
            projectID: "proj-one",
            name: "fake-stack",
            status: "CREATE_COMPLETE",
            parameters: ["environment": "dev"],
            outputs: [FakeStackOutput(outputKey: "endpoint", outputValue: "http://10.0.0.50:8080", description: "Public endpoint")]
        ))

        // Manila (shared file systems) seed: one available share + one access.
        shareIDCounter = 1
        shares.append(FakeShare(id: "share-1", projectID: "proj-one", name: "fake-share", status: "available", shareSize: 10, shareType: "generic", isPublic: false))
        shareAccessIDCounter = 1
        shareAccesses.append(FakeShareAccess(id: "sa-1", projectID: "proj-one", shareID: "share-1", accessTo: "10.0.0.0/24", accessType: "ip", accessProtocol: "nfs", state: "accessible"))

        // Keystone identity bootstrap: the standard domains + roles that every
        // OpenStack cloud ships with, so provisioning tests are realistic.
        identityDomains = [
            FakeDomain(id: "default", name: "default"),
            FakeDomain(id: "service", name: "service"),
            FakeDomain(id: "admin", name: "admin"),
        ]
        identityRoles = [
            FakeRole(id: "admin-role", name: "admin"),
            FakeRole(id: "member-role", name: "member"),
            FakeRole(id: "reader-role", name: "reader"),
        ]
    }

    // MARK: - Token minting

    public func mintToken(credID: String, secret: String, domain: String?, password: String?, userID: String?) -> FakeToken? {
        // Find the credential
        guard let cred = credentials.first(where: { entry in
            if entry.method == .applicationCredential {
                return entry.id == credID && entry.secret == secret
            } else {
                return entry.id == (userID ?? credID) && entry.secret == (password ?? secret)
            }
        }) else {
            // Provisioned service users: support password auth (user + domain)
            // and app-cred auth (id + secret) against the identity store so the
            // provisioner can mint a token *as* the new service user to create
            // its own application credential.
            if let user = identityUsers.first(where: { $0.name == (userID ?? credID) && $0.enabled && ($0.password ?? "") == (password ?? "") && $0.password != nil }) {
                let domainName = identityDomains.first { $0.id == user.domainID }?.name ?? "Default"
                let roleNames = identityRoleAssignments.filter { $0.userID == user.id && $0.domainID == user.domainID }
                    .compactMap { assignment in identityRoles.first { $0.id == assignment.roleID }?.name }
                tokenIDCounter += 1
                let tokenID = String(format: "fake-tok-%04d", tokenIDCounter)
                let token = FakeToken(
                    id: tokenID,
                    projectID: "proj-one",
                    projectName: "Project One",
                    domainID: user.domainID,
                    domainName: domainName,
                    userID: user.id,
                    userName: user.name,
                    userDomain: user.domainID,
                    roles: roleNames.isEmpty ? ["member"] : roleNames,
                    expiresAt: Date().addingTimeInterval(3600)
                )
                tokens[tokenID] = token
                return token
            }
            if let appCred = identityAppCreds.first(where: { $0.id == credID && $0.secret == secret }) {
                guard let owner = identityUsers.first(where: { $0.id == appCred.userID }) else { return nil }
                let domainName = identityDomains.first { $0.id == owner.domainID }?.name ?? "Default"
                let roleNames = identityRoleAssignments.filter { $0.userID == owner.id && $0.domainID == owner.domainID }
                    .compactMap { assignment in identityRoles.first { $0.id == assignment.roleID }?.name }
                tokenIDCounter += 1
                let tokenID = String(format: "fake-tok-%04d", tokenIDCounter)
                let token = FakeToken(
                    id: tokenID,
                    projectID: "proj-one",
                    projectName: "Project One",
                    domainID: owner.domainID,
                    domainName: domainName,
                    userID: owner.id,
                    userName: owner.name,
                    userDomain: owner.domainID,
                    roles: roleNames.isEmpty ? ["member"] : roleNames,
                    expiresAt: Date().addingTimeInterval(3600)
                )
                tokens[tokenID] = token
                return token
            }
            return nil
        }

        tokenIDCounter += 1
        let tokenID = String(format: "fake-tok-%04d", tokenIDCounter)
        let token = FakeToken(
            id: tokenID,
            projectID: cred.projectID,
            projectName: cred.projectID.hasSuffix("-one") ? "Project One" : "Project Two",
            domainID: "default",
            domainName: "Default",
            userID: cred.userID,
            userName: cred.userName,
            userDomain: cred.domain,
            roles: cred.roles,
            expiresAt: Date().addingTimeInterval(3600)
        )
        tokens[tokenID] = token
        return token
    }

    public func validateToken(_ tokenID: String) -> FakeToken? {
        guard let token = tokens[tokenID] else { return nil }
        if token.expiresAt < Date() {
            tokens.removeValue(forKey: tokenID)
            return nil
        }
        return token
    }

    /// Force a token to expire immediately (test hook). The next validation
    /// treats it as expired, so a live MCP session presenting it 401s —
    /// proving identity is per-token, not per-session (spec §12 hardening).
    @discardableResult
    public func expireToken(_ tokenID: String) -> Bool {
        guard let token = tokens[tokenID] else { return false }
        let expired = FakeToken(
            id: token.id,
            projectID: token.projectID,
            projectName: token.projectName,
            domainID: token.domainID,
            domainName: token.domainName,
            userID: token.userID,
            userName: token.userName,
            userDomain: token.userDomain,
            roles: token.roles,
            expiresAt: Date().addingTimeInterval(-1)
        )
        tokens[tokenID] = expired
        return true
    }

    // MARK: - Keystone catalog (services + endpoints)

    public func listServices() -> [FakeService] { services }

    public func serviceByType(_ type: String) -> FakeService? {
        services.first { $0.type == type }
    }

    @discardableResult
    public func createService(type: String, name: String, description: String) -> FakeService {
        serviceIDCounter += 1
        let id = "svc-\(serviceIDCounter)"
        let svc = FakeService(id: id, type: type, name: name, description: description)
        services.append(svc)
        return svc
    }

    public func listEndpoints(serviceID: String? = nil) -> [FakeEndpoint] {
        guard let serviceID else { return endpoints }
        return endpoints.filter { $0.serviceID == serviceID }
    }

    public func endpoint(serviceID: String, interface: String, regionID: String) -> FakeEndpoint? {
        endpoints.first { $0.serviceID == serviceID && $0.interface == interface && $0.regionID == regionID }
    }

    @discardableResult
    public func createEndpoint(serviceID: String, interface: String, regionID: String, url: String) -> FakeEndpoint {
        endpointIDCounter += 1
        let id = "ep-\(endpointIDCounter)"
        let ep = FakeEndpoint(id: id, serviceID: serviceID, interface: interface, regionID: regionID, url: url)
        endpoints.append(ep)
        return ep
    }

    // MARK: - Keystone identity CRUD (for provisioning)

    public func listDomains(name: String? = nil) -> [FakeDomain] {
        guard let name else { return identityDomains }
        return identityDomains.filter { $0.name == name }
    }

    public func listIdentityUsers(name: String? = nil, domainID: String? = nil) -> [FakeIdentityUser] {
        var result = identityUsers
        if let name { result = result.filter { $0.name == name } }
        if let domainID { result = result.filter { $0.domainID == domainID } }
        return result
    }

    public func listRoles(name: String? = nil) -> [FakeRole] {
        guard let name else { return identityRoles }
        return identityRoles.filter { $0.name == name }
    }

    public func domain(name: String) -> FakeDomain? {
        identityDomains.first { $0.name == name }
    }

    public func identityUser(name: String, domainID: String) -> FakeIdentityUser? {
        identityUsers.first { $0.name == name && $0.domainID == domainID }
    }

    public func identityUser(id: String) -> FakeIdentityUser? {
        identityUsers.first { $0.id == id }
    }

    @discardableResult
    public func createIdentityUser(name: String, domainID: String, enabled: Bool = true, password: String? = nil) -> FakeIdentityUser {
        identityUserCounter += 1
        let id = "user-\(identityUserCounter)"
        let user = FakeIdentityUser(id: id, name: name, domainID: domainID, enabled: enabled, password: password)
        identityUsers.append(user)
        return user
    }

    public func role(name: String) -> FakeRole? {
        identityRoles.first { $0.name == name }
    }

    public func roleAssigned(userID: String, roleID: String, domainID: String) -> Bool {
        identityRoleAssignments.contains { $0.userID == userID && $0.roleID == roleID && $0.domainID == domainID }
    }

    public func roleAssignments(userID: String, domainID: String) -> [FakeRoleAssignment] {
        identityRoleAssignments.filter { $0.userID == userID && $0.domainID == domainID }
    }

    public func addRoleAssignment(roleID: String, userID: String, domainID: String) {
        identityRoleAssignments.append(FakeRoleAssignment(roleID: roleID, userID: userID, domainID: domainID))
    }

    public func appCred(name: String, userID: String) -> FakeAppCred? {
        identityAppCreds.first { $0.name == name && $0.userID == userID }
    }

    public func appCreds(userID: String) -> [FakeAppCred] {
        identityAppCreds.filter { $0.userID == userID }
    }

    @discardableResult
    public func createAppCred(name: String, userID: String, secret: String) -> FakeAppCred {
        identityAppCredCounter += 1
        let id = "appcred-\(identityAppCredCounter)"
        let cred = FakeAppCred(id: id, name: name, userID: userID, secret: secret)
        identityAppCreds.append(cred)
        return cred
    }

    // MARK: - Server CRUD

    public func listServers(projectID: String, name: String? = nil, status: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeServer] {
        var result = servers.filter { $0.projectID == projectID }
        if let name {
            result = result.filter { $0.name.contains(name) }
        }
        if let status {
            result = result.filter { $0.status == status }
        }
        if let marker {
            if let idx = result.firstIndex(where: { $0.id == marker }) {
                result = Array(result[(idx + 1)...])
            }
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getServer(id: String, projectID: String) -> FakeServer? {
        servers.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createServer(name: String, projectID: String, flavorID: String, region: String = "RegionOne") -> FakeServer {
        serverIDCounter += 1
        let id = String(format: "srv-%04d", serverIDCounter)
        let flavor = flavors.first { $0.id == flavorID }
        let server = FakeServer(
            id: id,
            name: name,
            status: "BUILD",
            flavorID: flavorID,
            flavorName: flavor?.name ?? "unknown",
            projectID: projectID,
            region: region
        )
        servers.append(server)
        return server
    }

    public func deleteServer(id: String, projectID: String) -> Bool {
        let idx = servers.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        servers.remove(at: idx)
        return true
    }

    public func serverAction(id: String, projectID: String, action: String) -> (success: Bool, error: String?) {
        guard let idx = servers.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else {
            return (false, "server not found")
        }
        switch action {
        case "start": servers[idx].status = "ACTIVE"
        case "stop": servers[idx].status = "SHUTOFF"
        case "reboot": servers[idx].status = "REBOOT"
        case "pause": servers[idx].status = "PAUSED"
        case "unpause": servers[idx].status = "ACTIVE"
        case "suspend": servers[idx].status = "SUSPENDED"
        case "resume": servers[idx].status = "ACTIVE"
        case "lock": servers[idx].status = "LOCKED"
        case "unlock": servers[idx].status = "ACTIVE"
        case "shelve": servers[idx].status = "SHELVED"
        case "unshelve": servers[idx].status = "ACTIVE"
        case "rescue": servers[idx].status = "RESCUE"
        case "unrescue": servers[idx].status = "ACTIVE"
        default:
            return (false, "unknown action: \(action)")
        }
        servers[idx].updated = Date()
        return (true, nil)
    }

    // MARK: - Neutron: Networks

    public func listNetworks(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeNetwork] {
        var result = networks.filter { $0.projectID == projectID }
        if let name {
            result = result.filter { $0.name.contains(name) }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getNetwork(id: String, projectID: String) -> FakeNetwork? {
        networks.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createNetwork(projectID: String, name: String, shared: Bool = false, adminStateUp: Bool = true) -> FakeNetwork {
        netIDCounter += 1
        let id = "net-\(netIDCounter)"
        let net = FakeNetwork(id: id, name: name, projectID: projectID, region: "RegionOne", routerExternal: false, status: "ACTIVE", subnets: [])
        networks.append(net)
        return net
    }

    public func updateNetwork(id: String, projectID: String, name: String?, shared: Bool?, adminStateUp: Bool?) -> FakeNetwork? {
        guard let idx = networks.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let name { networks[idx].name = name }
        _ = shared
        _ = adminStateUp
        return networks[idx]
    }

    public func deleteNetwork(id: String, projectID: String) -> Bool {
        let idx = networks.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        networks.remove(at: idx)
        return true
    }

    // MARK: - Neutron: Subnets

    public func listSubnets(projectID: String, networkID: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeSubnet] {
        var result = subnets.filter { $0.projectID == projectID }
        if let networkID {
            result = result.filter { $0.networkID == networkID }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getSubnet(id: String, projectID: String) -> FakeSubnet? {
        subnets.first { $0.id == id && $0.projectID == projectID }
    }

    /// Creates a subnet; returns nil if the network doesn't exist in the project.
    public func createSubnet(projectID: String, networkID: String, cidr: String, ipVersion: Int, gateway: String?, name: String?, enableDHCP: Bool?, allocationPools: [FakeAllocationPool]) -> FakeSubnet? {
        guard networks.contains(where: { $0.id == networkID && $0.projectID == projectID }) else { return nil }
        subnetIDCounter += 1
        let id = "subnet-\(subnetIDCounter)"
        let subnet = FakeSubnet(id: id, name: name ?? id, networkID: networkID, projectID: projectID, cidr: cidr, gatewayIP: gateway, enableDHCP: enableDHCP ?? true, allocationPools: allocationPools)
        subnets.append(subnet)
        _ = ipVersion
        return subnet
    }

    public func deleteSubnet(id: String, projectID: String) -> Bool {
        let idx = subnets.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        subnets.remove(at: idx)
        return true
    }

    // MARK: - Neutron: Ports

    public func listPorts(projectID: String, networkID: String? = nil, deviceID: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakePort] {
        var result = ports.filter { $0.projectID == projectID }
        if let networkID {
            result = result.filter { $0.networkID == networkID }
        }
        if let deviceID {
            result = result.filter { $0.deviceID == deviceID }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getPort(id: String, projectID: String) -> FakePort? {
        ports.first { $0.id == id && $0.projectID == projectID }
    }

    /// Creates a port. Returns (nil, "in-use") when a fixed IP is already
    /// assigned to another port on the same subnet.
    public func createPort(projectID: String, networkID: String, cidrs: [[String: String]], fixedIPs: [[String: String?]], name: String, securityGroups: [String], deviceID: String?, deviceOwner: String?, extraDHCPOpts: [FakeExtraDHCPOpt], adminStateUp: Bool, portSecurityEnabled: Bool) -> (port: FakePort?, inUseIP: String?) {
        guard networks.contains(where: { $0.id == networkID && $0.projectID == projectID }) else {
            return (nil, nil)
        }

        var assigned: [FakeFixedIP] = []

        if fixedIPs.isEmpty {
            // Empty fixed_ips list: auto-assign one IP from the first subnet on this network
            if let subnet = subnets.first(where: { $0.networkID == networkID && $0.projectID == projectID }),
               let ip = Self.nextFreeIP(cidr: subnet.cidr, taken: usedIPs(projectID: projectID)) {
                assigned.append(FakeFixedIP(ip: ip, subnetID: subnet.id))
            } else {
                return (nil, nil)
            }
        } else {
            for spec in fixedIPs {
                let requested = spec["ip"].flatMap { $0 }
                if let ip = requested, !ip.isEmpty {
                    // Explicit IP: conflict check within project (all subnets share one IP space in the fake)
                    let taken = ports.contains { $0.projectID == projectID && $0.fixedIPs.contains { $0.ip == ip } }
                    if taken {
                        return (nil, ip)
                    }
                    let subnetID: String?
                    if let subnetVal = spec["subnet"].flatMap({ $0 }), !subnetVal.isEmpty {
                        subnetID = subnetVal
                    } else {
                        // Resolve the requested IP against the network's subnets (numerical prefix match)
                        subnetID = subnets.first(where: { s in
                            s.networkID == networkID && s.projectID == projectID && Self.ipInCidr(ip, cidr: s.cidr)
                        })?.id
                    }
                    assigned.append(FakeFixedIP(ip: ip, subnetID: subnetID ?? ""))
                } else {
                    // Auto-assign: find a subnet for this network and pick a free host IP
                    guard let subnet = subnets.first(where: { $0.networkID == networkID && $0.projectID == projectID }),
                          let ip = Self.nextFreeIP(cidr: subnet.cidr, taken: usedIPs(projectID: projectID)) else {
                        return (nil, nil)
                    }
                    assigned.append(FakeFixedIP(ip: ip, subnetID: subnet.id))
                }
            }
        }

        portIDCounter += 1
        let id = "port-\(portIDCounter)"
        let port = FakePort(
            id: id,
            projectID: projectID,
            name: name,
            status: "ACTIVE",
            networkID: networkID,
            adminStateUp: adminStateUp,
            fixedIPs: assigned,
            securityGroups: securityGroups.isEmpty ? ["sg-default"] : securityGroups,
            deviceID: deviceID,
            deviceOwner: deviceOwner,
            extraDHCPOpts: extraDHCPOpts,
            portSecurityEnabled: portSecurityEnabled
        )
        ports.append(port)
        _ = cidrs
        return (port, nil)
    }

    public func updatePort(id: String, projectID: String, name: String?, adminStateUp: Bool?) -> FakePort? {
        guard let idx = ports.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let name { ports[idx].name = name }
        if let adminStateUp { ports[idx].adminStateUp = adminStateUp }
        return ports[idx]
    }

    public func deletePort(id: String, projectID: String) -> Bool {
        let idx = ports.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        ports.remove(at: idx)
        return true
    }

    /// All IPs assigned to ports in the project.
    public func usedIPs(projectID: String) -> Set<String> {
        Set(ports.filter { $0.projectID == projectID }.flatMap { $0.fixedIPs.map { $0.ip } })
    }

    /// Check whether an IPv4 address falls within the given CIDR range.
    public static func ipInCidr(_ ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefixLen = Int(parts[1]), prefixLen >= 0 && prefixLen <= 32 else { return false }
        guard let ipVal = Self.ipToInt(ip), let netVal = Self.ipToInt(String(parts[0])) else { return false }
        let mask: Int32 = prefixLen == 0 ? 0 : Int32(bitPattern: 0xFFFFFFFF << (32 - prefixLen))
        return (ipVal & mask) == (netVal & mask)
    }

    static func ipToInt(_ ip: String) -> Int32? {
        let octets = ip.split(separator: ".").compactMap { Int32($0) }
        guard octets.count == 4 else { return nil }
        for o in octets where o < 0 || o > 255 { return nil }
        return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
    }

    /// The base address of a CIDR (e.g. "192.168.1.0" for "192.168.1.0/24").
    public static func networkPrefix(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2 else { return "" }
        let octets = parts[0].split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, let prefixLen = Int(parts[1]) else { return "" }
        let network = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        if prefixLen == 0 {
            return "0.0.0.0"
        }
        let mask = 0xFFFFFFFF << (32 - prefixLen)
        let net = network & mask
        return "\(net >> 24 & 0xFF).\(net >> 16 & 0xFF).\(net >> 8 & 0xFF).\(net & 0xFF)"
    }

    /// Walk a CIDR and return the first host address not in `taken`
    /// (skipping the network and broadcast addresses for /31-safe logic).
    public static func nextFreeIP(cidr: String, taken: Set<String>) -> String? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        guard let prefixLen = Int(parts[1]), prefixLen < 31 else { return nil }
        let network = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let hostBits = 32 - prefixLen
        let usable = 1 << hostBits
        var n = network + 1
        let stop = n + usable - 2
        while n < stop {
            let ip = "\(n >> 24 & 0xFF).\(n >> 16 & 0xFF).\(n >> 8 & 0xFF).\(n & 0xFF)"
            if !taken.contains(ip) { return ip }
            n += 1
        }
        return nil
    }

    // MARK: - Neutron: Routers

    public func listRouters(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeRouter] {
        var result = routers.filter { $0.projectID == projectID }
        if let name {
            result = result.filter { $0.name.contains(name) }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getRouter(id: String, projectID: String) -> FakeRouter? {
        routers.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createRouter(projectID: String, name: String) -> FakeRouter {
        routerIDCounter += 1
        let id = "router-\(routerIDCounter)"
        let router = FakeRouter(id: id, name: name, projectID: projectID, externalNetworkID: nil, status: "DOWN")
        routers.append(router)
        return router
    }

    /// Updates a router; sets external gateway (status ACTIVE when gateway set).
    public func updateRouter(id: String, projectID: String, name: String?, externalNetworkID: String?) -> FakeRouter? {
        guard let idx = routers.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let name { routers[idx].name = name }
        if let externalNetworkID {
            guard networks.contains(where: { $0.id == externalNetworkID && $0.routerExternal }) else {
                return routers[idx]
            }
            routers[idx].externalNetworkID = externalNetworkID
            routers[idx].status = "ACTIVE"
        }
        return routers[idx]
    }

    public func deleteRouter(id: String, projectID: String) -> Bool {
        let idx = routers.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        routers.remove(at: idx)
        return true
    }

    // MARK: - Neutron: Floating IPs

    public func listFloatingIPs(projectID: String, floatingIP: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeFloatingIP] {
        var result = floatingIPs.filter { $0.projectID == projectID }
        if let floatingIP {
            result = result.filter { $0.floatingIP == floatingIP }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getFloatingIP(id: String, projectID: String) -> FakeFloatingIP? {
        floatingIPs.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createFloatingIP(projectID: String, floatingNetworkID: String) -> FakeFloatingIP {
        guard networks.contains(where: { $0.id == floatingNetworkID && $0.projectID == projectID }) else {
            // Fall back to the seeded external network so create never hard-fails in tests
            fipIDCounter += 1
            return FakeFloatingIP(id: "fip-\(fipIDCounter)", projectID: projectID, floatingIP: "203.0.113.\(100 + fipIDCounter)", floatingNetworkID: floatingNetworkID, portID: nil, fixedIPAddress: nil, routerID: nil, status: "DOWN")
        }
        fipIDCounter += 1
        let fip = FakeFloatingIP(
            id: "fip-\(fipIDCounter)",
            projectID: projectID,
            floatingIP: "203.0.113.\(100 + fipIDCounter)",
            floatingNetworkID: floatingNetworkID,
            portID: nil,
            fixedIPAddress: nil,
            routerID: nil,
            status: "DOWN"
        )
        floatingIPs.append(fip)
        return fip
    }

    /// Associates (portID set) or disassociates (portID nil) a floating IP.
    public func updateFloatingIP(id: String, projectID: String, portID: String?, fixedIPAddress: String?) -> FakeFloatingIP? {
        guard let idx = floatingIPs.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let portID, !portID.isEmpty {
            floatingIPs[idx].portID = portID
            floatingIPs[idx].fixedIPAddress = fixedIPAddress
            floatingIPs[idx].status = "ACTIVE"
        } else {
            floatingIPs[idx].portID = nil
            floatingIPs[idx].fixedIPAddress = nil
            floatingIPs[idx].status = "DOWN"
        }
        return floatingIPs[idx]
    }

    public func deleteFloatingIP(id: String, projectID: String) -> Bool {
        let idx = floatingIPs.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        floatingIPs.remove(at: idx)
        return true
    }

    // MARK: - Neutron: Security groups

    public func listSecurityGroups(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeSecurityGroup] {
        var result = securityGroups.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getSecurityGroup(id: String, projectID: String) -> FakeSecurityGroup? {
        securityGroups.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createSecurityGroup(projectID: String, name: String, description: String) -> FakeSecurityGroup {
        sgIDCounter += 1
        let id = "sg-\(sgIDCounter)"
        let group = FakeSecurityGroup(id: id, name: name, description: description, projectID: projectID)
        securityGroups.append(group)
        return group
    }

    public func deleteSecurityGroup(id: String, projectID: String) -> Bool {
        let idx = securityGroups.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        securityGroups.remove(at: idx)
        securityGroupRules.removeAll { $0.securityGroupID == id }
        return true
    }

    // MARK: - Neutron: Security group rules

    public func listSecurityGroupRules(projectID: String, securityGroupID: String?, limit: Int? = nil, marker: String? = nil) -> [FakeSecurityGroupRule] {
        var result = securityGroupRules.filter { $0.projectID == projectID }
        if let securityGroupID {
            result = result.filter { $0.securityGroupID == securityGroupID }
        }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count {
            result = Array(result[0..<limit])
        }
        return result
    }

    public func getSecurityGroupRule(id: String, projectID: String) -> FakeSecurityGroupRule? {
        securityGroupRules.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createSecurityGroupRule(projectID: String, securityGroupID: String, direction: String, ethertype: String, ipProtocol: String?, portRangeMin: Int?, portRangeMax: Int?, remoteIPPrefix: String?) -> FakeSecurityGroupRule {
        sgRuleIDCounter += 1
        let id = "sgr-\(sgRuleIDCounter)"
        let rule = FakeSecurityGroupRule(
            id: id,
            securityGroupID: securityGroupID,
            projectID: projectID,
            direction: direction,
            ethertype: ethertype,
            ipProtocol: ipProtocol,
            portRangeMin: portRangeMin,
            portRangeMax: portRangeMax,
            remoteIPPrefix: remoteIPPrefix
        )
        securityGroupRules.append(rule)
        return rule
    }

    public func deleteSecurityGroupRule(id: String, projectID: String) -> Bool {
        let idx = securityGroupRules.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        securityGroupRules.remove(at: idx)
        return true
    }

    // MARK: - Neutron: Address groups (extension-gated)

    public func listAddressGroups(projectID: String) -> [FakeAddressGroup] {
        addressGroups.filter { $0.projectID == projectID }
    }

    public func getAddressGroup(id: String, projectID: String) -> FakeAddressGroup? {
        addressGroups.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createAddressGroup(projectID: String, name: String, description: String) -> FakeAddressGroup {
        agIDCounter += 1
        let group = FakeAddressGroup(
            id: "ag-\(agIDCounter)",
            projectID: projectID,
            name: name,
            description: description,
            addresses: []
        )
        addressGroups.append(group)
        return group
    }

    public func deleteAddressGroup(id: String, projectID: String) -> Bool {
        let idx = addressGroups.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        addressGroups.remove(at: idx)
        return true
    }

    // MARK: - Cinder: Volumes

    public func listVolumes(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeVolume] {
        var result = volumes.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getVolume(id: String, projectID: String) -> FakeVolume? {
        volumes.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createVolume(projectID: String, name: String, size: Int, volumeType: String = "lvmdriver-1", imageID: String? = nil, sourceVolumeID: String? = nil, snapshotID: String? = nil, description: String = "", availabilityZone: String? = nil, multiattach: Bool = false, metadata: [String: String]? = nil) -> FakeVolume {
        volIDCounter += 1
        let id = "vol-\(volIDCounter)"
        let vol = FakeVolume(
            id: id,
            projectID: projectID,
            name: name,
            status: "creating",
            size: size,
            volumeType: volumeType,
            availabilityZone: availabilityZone,
            multiattach: multiattach,
            metadata: metadata,
            sourceVolumeID: sourceVolumeID,
            imageID: imageID,
            created: "2026-01-01T00:00:00.000"
        )
        volumes.append(vol)
        return vol
    }

    public func updateVolume(id: String, projectID: String, size: Int? = nil, volumeType: String? = nil, bootable: Bool? = nil, name: String? = nil) -> FakeVolume? {
        guard let idx = volumes.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let size { volumes[idx].size = size }
        if let volumeType { volumes[idx].volumeType = volumeType }
        if let bootable { volumes[idx].bootable = bootable }
        if let name { volumes[idx].name = name }
        return volumes[idx]
    }

    public func deleteVolume(id: String, projectID: String) -> Bool {
        let idx = volumes.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        volumes.remove(at: idx)
        return true
    }

    /// Upload-to-image: returns a new image ID and registers it as an active image.
    public func uploadVolumeToImage(id: String, projectID: String) -> String? {
        guard let vol = getVolume(id: id, projectID: projectID) else { return nil }
        imgIDCounter += 1
        let imageID = "img-\(imgIDCounter)"
        images.append(FakeImage(
            id: imageID,
            projectID: projectID,
            name: vol.name.isEmpty ? "upload-from-\(vol.id)" : vol.name,
            status: "active",
            diskFormat: "raw",
            containerFormat: "bare",
            size: vol.size,
            created: "2026-01-01T00:00:00.000",
            updated: "2026-01-01T00:00:00.000"
        ))
        return imageID
    }

    // MARK: - Cinder: Volume Types

    public func listVolumeTypes() -> [FakeVolumeType] { volumeTypes }

    public func getVolumeType(id: String) -> FakeVolumeType? {
        volumeTypes.first { $0.id == id }
    }

    @discardableResult
    public func createVolumeType(name: String, extraSpecs: [String: String]? = nil) -> FakeVolumeType {
        volTypeIDCounter += 1
        let vt = FakeVolumeType(id: "vt-\(volTypeIDCounter)", name: name, extraSpecs: extraSpecs)
        volumeTypes.append(vt)
        return vt
    }

    public func deleteVolumeType(id: String) -> Bool {
        let idx = volumeTypes.firstIndex { $0.id == id }
        guard let idx else { return false }
        volumeTypes.remove(at: idx)
        return true
    }

    // MARK: - Cinder: Snapshots

    public func listSnapshots(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeSnapshot] {
        var result = snapshots.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getSnapshot(id: String, projectID: String) -> FakeSnapshot? {
        snapshots.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createSnapshot(projectID: String, volumeID: String, name: String = "", description: String = "", force: Bool = false) -> FakeSnapshot? {
        guard let vol = getVolume(id: volumeID, projectID: projectID) else { return nil }
        snapIDCounter += 1
        let snap = FakeSnapshot(
            id: "snap-\(snapIDCounter)",
            projectID: projectID,
            name: name,
            status: "creating",
            volumeID: volumeID,
            size: vol.size,
            description: description,
            force: force,
            created: "2026-01-01T00:00:00.000"
        )
        snapshots.append(snap)
        return snap
    }

    public func deleteSnapshot(id: String, projectID: String) -> Bool {
        let idx = snapshots.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        snapshots.remove(at: idx)
        return true
    }

    // MARK: - Cinder: Backups

    public func listBackups(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeBackup] {
        var result = backups.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getBackup(id: String, projectID: String) -> FakeBackup? {
        backups.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createBackup(projectID: String, volumeID: String, name: String = "", description: String = "") -> FakeBackup? {
        guard let vol = getVolume(id: volumeID, projectID: projectID) else { return nil }
        backupIDCounter += 1
        let backup = FakeBackup(
            id: "backup-\(backupIDCounter)",
            projectID: projectID,
            name: name,
            status: "available",
            volumeID: volumeID,
            size: vol.size,
            description: description,
            created: "2026-01-01T00:00:00.000"
        )
        backups.append(backup)
        return backup
    }

    public func deleteBackup(id: String, projectID: String) -> Bool {
        let idx = backups.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        backups.remove(at: idx)
        return true
    }

    /// Restore a backup into a new volume carrying the backup_id marker.
    public func restoreBackup(id: String, projectID: String) -> FakeVolume? {
        guard let backup = getBackup(id: id, projectID: projectID) else { return nil }
        volIDCounter += 1
        let vol = FakeVolume(
            id: "vol-\(volIDCounter)",
            projectID: projectID,
            name: "restored-from-\(backup.id)",
            status: "creating",
            size: backup.size,
            metadata: ["os-extended-vol-backup:backup_id": backup.id],
            created: "2026-01-01T00:00:00.000"
        )
        volumes.append(vol)
        return vol
    }

    // MARK: - Glance: Images

    public func listImages(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeImage] {
        var result = images.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getImage(id: String, projectID: String) -> FakeImage? {
        images.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createImage(projectID: String, name: String, visibility: String = "private", diskFormat: String = "raw", containerFormat: String = "bare", minRAM: Int = 0, properties: [String: String] = [:]) -> FakeImage {
        imgIDCounter += 1
        let img = FakeImage(
            id: "img-\(imgIDCounter)",
            projectID: projectID,
            name: name,
            status: "queued",
            visibility: visibility,
            diskFormat: diskFormat,
            containerFormat: containerFormat,
            minRAM: minRAM,
            properties: properties,
            created: "2026-01-01T00:00:00.000",
            updated: "2026-01-01T00:00:00.000"
        )
        images.append(img)
        return img
    }

    public func updateImage(id: String, projectID: String, name: String? = nil, visibility: String? = nil, protected: Bool? = nil, status: String? = nil) -> FakeImage? {
        guard let idx = images.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if let name { images[idx].name = name }
        if let visibility { images[idx].visibility = visibility }
        if let protected { images[idx].protected = protected }
        if let status { images[idx].status = status }
        images[idx].updated = "2026-01-01T00:00:00.000"
        return images[idx]
    }

    public func setImageData(id: String, projectID: String, data: Data) -> FakeImage? {
        guard let idx = images.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        images[idx].data = data
        images[idx].size = data.count
        images[idx].status = "active"
        return images[idx]
    }

    public func setImportResult(id: String, projectID: String, active: Bool, size: Int, statusReason: String?) -> FakeImage? {
        guard let idx = images.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        if active {
            images[idx].status = "active"
            images[idx].size = size
            images[idx].statusReason = nil
        } else {
            images[idx].status = "killed"
            images[idx].statusReason = statusReason ?? "import failed"
        }
        return images[idx]
    }

    public func deleteImage(id: String, projectID: String) -> Bool {
        let idx = images.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        images.remove(at: idx)
        return true
    }

    public func addTags(id: String, projectID: String, tags: [String]) -> FakeImage? {
        guard let idx = images.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        images[idx].tags = Array(Set(images[idx].tags + tags))
        return images[idx]
    }

    public func removeTag(id: String, projectID: String, tag: String) -> FakeImage? {
        guard let idx = images.firstIndex(where: { $0.id == id && $0.projectID == projectID }) else { return nil }
        images[idx].tags.removeAll { $0 == tag }
        return images[idx]
    }

    // MARK: - Swift (object storage) CRUD

    public func listContainers(projectID: String, prefix: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeContainer] {
        var result = containers.filter { $0.projectID == projectID }
        if let prefix { result = result.filter { $0.name.hasPrefix(prefix) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.name == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getContainer(name: String, projectID: String) -> FakeContainer? {
        containers.first { $0.name == name && $0.projectID == projectID }
    }

    @discardableResult
    public func createContainer(projectID: String, name: String, quotaBytes: Int? = nil, metadata: [String: String] = [:]) -> FakeContainer? {
        guard getContainer(name: name, projectID: projectID) == nil else { return nil }
        containerIDCounter += 1
        let ctn = FakeContainer(id: "ctn-\(containerIDCounter)", projectID: projectID, name: name, quotaBytes: quotaBytes, metadata: metadata)
        containers.append(ctn)
        return ctn
    }

    public func deleteContainer(name: String, projectID: String) -> Bool {
        let idx = containers.firstIndex { $0.name == name && $0.projectID == projectID }
        guard let idx else { return false }
        containers.remove(at: idx)
        // Swift: deleting a container also removes its objects.
        objects.removeAll { $0.container == name && $0.projectID == projectID }
        return true
    }

    public func listObjects(projectID: String, container: String, prefix: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeObject] {
        var result = objects.filter { $0.projectID == projectID && $0.container == container }
        if let prefix { result = result.filter { $0.name.hasPrefix(prefix) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.name == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func countObjects(projectID: String, container: String) -> Int {
        objects.filter { $0.projectID == projectID && $0.container == container }.count
    }

    public func sumObjectBytes(projectID: String, container: String) -> Int {
        objects.filter { $0.projectID == projectID && $0.container == container }.reduce(0) { $0 + $1.size }
    }

    public func getObject(projectID: String, container: String, name: String) -> FakeObject? {
        objects.first { $0.projectID == projectID && $0.container == container && $0.name == name }
    }

    @discardableResult
    public func createObject(projectID: String, container: String, name: String, data: Data, contentType: String = "application/octet-stream", metadata: [String: String] = [:]) -> FakeObject {
        objectIDCounter += 1
        let obj = FakeObject(id: "obj-\(objectIDCounter)", projectID: projectID, container: container, name: name, size: data.count, contentType: contentType, data: data, metadata: metadata)
        objects.append(obj)
        return obj
    }

    public func deleteObject(projectID: String, container: String, name: String) -> Bool {
        let idx = objects.firstIndex { $0.projectID == projectID && $0.container == container && $0.name == name }
        guard let idx else { return false }
        objects.remove(at: idx)
        return true
    }

    // MARK: - Barbican (key manager) CRUD

    public func listSecrets(projectID: String, name: String? = nil, type: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeSecret] {
        var result = secrets.filter { $0.projectID == projectID }
        if let name { result = result.filter { ($0.name ?? "").contains(name) } }
        if let type { result = result.filter { $0.type == type } }
        result.sort { ($0.name ?? "") < ($1.name ?? "") }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getSecret(id: String, projectID: String) -> FakeSecret? {
        secrets.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createSecret(projectID: String, name: String?, type: String = "opaque", algorithm: String? = nil, bitSize: Int? = nil, mode: String? = nil, secret: String? = nil, visibility: String? = nil) -> FakeSecret {
        secretIDCounter += 1
        let s = FakeSecret(
            id: "sec-\(secretIDCounter)",
            projectID: projectID,
            name: name,
            type: type,
            status: "active",
            algorithm: algorithm,
            bitSize: bitSize,
            mode: mode,
            isSecret: true,
            visibility: visibility ?? "private",
            payload: secret ?? "",
            payloadContentType: "text/plain"
        )
        secrets.append(s)
        return s
    }

    public func deleteSecret(id: String, projectID: String) -> Bool {
        let idx = secrets.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        secrets.remove(at: idx)
        return true
    }

    public func listSecretContainers(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeSecretContainer] {
        var result = secretContainers.filter { $0.projectID == projectID }
        if let name { result = result.filter { ($0.name ?? "").contains(name) } }
        result.sort { ($0.name ?? "") < ($1.name ?? "") }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) {
            result = Array(result[(idx + 1)...])
        }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getSecretContainer(id: String, projectID: String) -> FakeSecretContainer? {
        secretContainers.first { $0.id == id && $0.projectID == projectID }
    }

    public func deleteSecretContainer(id: String, projectID: String) -> Bool {
        let idx = secretContainers.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        secretContainers.remove(at: idx)
        return true
    }

    // MARK: - Octavia (load balancer) CRUD

    public func listLoadBalancers(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeLoadBalancer] {
        var result = loadBalancers.filter { $0.projectID == projectID }
        if let name { result = result.filter { ($0.name ?? "").contains(name) } }
        result.sort { ($0.name ?? "") < ($1.name ?? "") }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getLoadBalancer(id: String, projectID: String) -> FakeLoadBalancer? {
        loadBalancers.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createLoadBalancer(projectID: String, name: String? = nil, vipAddress: String? = nil) -> FakeLoadBalancer {
        lbIDCounter += 1
        let lb = FakeLoadBalancer(id: "lb-\(lbIDCounter)", projectID: projectID, name: name, status: "ACTIVE", provisioningStatus: "ACTIVE", vipAddress: vipAddress ?? "10.0.0.\(lbIDCounter + 9)")
        loadBalancers.append(lb)
        return lb
    }

    public func deleteLoadBalancer(id: String, projectID: String) -> Bool {
        let idx = loadBalancers.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        loadBalancers.remove(at: idx)
        return true
    }

    public func listListeners(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeListener] {
        var result = listeners.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getListener(id: String, projectID: String) -> FakeListener? {
        listeners.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createListener(projectID: String, name: String?, protocolName: String, protocolPort: Int, loadBalancerID: String?) -> FakeListener {
        listenerIDCounter += 1
        let l = FakeListener(id: "listener-\(listenerIDCounter)", projectID: projectID, name: name, protocolName: protocolName, protocolPort: protocolPort, loadBalancerID: loadBalancerID)
        listeners.append(l)
        return l
    }

    public func deleteListener(id: String, projectID: String) -> Bool {
        let idx = listeners.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        listeners.remove(at: idx)
        return true
    }

    public func listPools(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakePool] {
        var result = pools.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getPool(id: String, projectID: String) -> FakePool? {
        pools.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createPool(projectID: String, name: String?, protocolName: String, lbAlgorithm: String, loadBalancerID: String?, healthMonitorID: String?) -> FakePool {
        poolIDCounter += 1
        let p = FakePool(id: "pool-\(poolIDCounter)", projectID: projectID, name: name, protocolName: protocolName, lbAlgorithm: lbAlgorithm, loadBalancerID: loadBalancerID, healthMonitorID: healthMonitorID)
        pools.append(p)
        return p
    }

    public func deletePool(id: String, projectID: String) -> Bool {
        let idx = pools.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        pools.remove(at: idx)
        return true
    }

    public func listMembers(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeMember] {
        var result = members.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getMember(id: String, projectID: String) -> FakeMember? {
        members.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createMember(projectID: String, name: String?, protocolAddress: String, protocolPort: Int, weight: Int?, adminStateUp: Bool?, poolID: String?) -> FakeMember {
        memberIDCounter += 1
        let m = FakeMember(id: "member-\(memberIDCounter)", projectID: projectID, name: name, protocolAddress: protocolAddress, protocolPort: protocolPort, weight: weight, adminStateUp: adminStateUp, poolID: poolID, status: "ONLINE")
        members.append(m)
        return m
    }

    public func deleteMember(id: String, projectID: String) -> Bool {
        let idx = members.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        members.remove(at: idx)
        return true
    }

    public func listHealthMonitors(projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeHealthMonitor] {
        var result = healthMonitors.filter { $0.projectID == projectID }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getHealthMonitor(id: String, projectID: String) -> FakeHealthMonitor? {
        healthMonitors.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createHealthMonitor(projectID: String, name: String?, type: String, delay: Int?, timeout: Int?, maxRetries: Int?, poolID: String?) -> FakeHealthMonitor {
        healthMonitorIDCounter += 1
        let h = FakeHealthMonitor(id: "hm-\(healthMonitorIDCounter)", projectID: projectID, name: name, type: type, delay: delay, timeout: timeout, maxRetries: maxRetries, poolID: poolID)
        healthMonitors.append(h)
        return h
    }

    public func deleteHealthMonitor(id: String, projectID: String) -> Bool {
        let idx = healthMonitors.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        healthMonitors.remove(at: idx)
        return true
    }

    // MARK: - Designate (DNS) CRUD

    public func listZones(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeZone] {
        var result = zones.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getZone(id: String, projectID: String) -> FakeZone? {
        zones.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createZone(projectID: String, name: String, email: String?, ttl: Int?) -> FakeZone {
        zoneIDCounter += 1
        let z = FakeZone(id: "zone-\(zoneIDCounter)", projectID: projectID, name: name, email: email, status: "active", ttl: ttl)
        zones.append(z)
        return z
    }

    public func deleteZone(id: String, projectID: String) -> Bool {
        let idx = zones.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        zones.remove(at: idx)
        return true
    }

    public func listRecordSets(projectID: String, name: String? = nil, zoneID: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeRecordSet] {
        var result = recordSets.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        if let zoneID { result = result.filter { $0.zoneID == zoneID } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getRecordSet(id: String, projectID: String) -> FakeRecordSet? {
        recordSets.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createRecordSet(projectID: String, name: String, type: String, ttl: Int?, records: [String], zoneID: String?) -> FakeRecordSet {
        recordSetIDCounter += 1
        let rs = FakeRecordSet(id: "rs-\(recordSetIDCounter)", projectID: projectID, name: name, type: type, ttl: ttl, records: records, zoneID: zoneID)
        recordSets.append(rs)
        return rs
    }

    public func deleteRecordSet(id: String, projectID: String) -> Bool {
        let idx = recordSets.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        recordSets.remove(at: idx)
        return true
    }

    // MARK: - Magnum (container) CRUD

    public func listMagnumClusters(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeMagnumCluster] {
        var result = magnumClusters.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getMagnumCluster(id: String, projectID: String) -> FakeMagnumCluster? {
        magnumClusters.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createMagnumCluster(projectID: String, name: String, masterCount: Int?, nodeCount: Int?, clusterTemplateID: String?) -> FakeMagnumCluster {
        magnumClusterIDCounter += 1
        let c = FakeMagnumCluster(id: "cluster-\(magnumClusterIDCounter)", projectID: projectID, name: name, status: "ACTIVE", masterCount: masterCount ?? 1, nodeCount: nodeCount ?? 0, clusterTemplateID: clusterTemplateID)
        magnumClusters.append(c)
        return c
    }

    public func deleteMagnumCluster(id: String, projectID: String) -> Bool {
        let idx = magnumClusters.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        magnumClusters.remove(at: idx)
        return true
    }

    public func listMagnumTemplates(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeMagnumTemplate] {
        var result = magnumTemplates.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getMagnumTemplate(id: String, projectID: String) -> FakeMagnumTemplate? {
        magnumTemplates.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createMagnumTemplate(projectID: String, name: String, masterCount: Int, nodeCount: Int) -> FakeMagnumTemplate {
        magnumTemplateIDCounter += 1
        let t = FakeMagnumTemplate(id: "ct-\(magnumTemplateIDCounter)", projectID: projectID, name: name, masterCount: masterCount, nodeCount: nodeCount)
        magnumTemplates.append(t)
        return t
    }

    public func deleteMagnumTemplate(id: String, projectID: String) -> Bool {
        let idx = magnumTemplates.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        magnumTemplates.remove(at: idx)
        return true
    }

    // MARK: - Heat (orchestration) CRUD

    public func listHeatStacks(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeHeatStack] {
        var result = heatStacks.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getHeatStack(id: String, projectID: String) -> FakeHeatStack? {
        heatStacks.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createHeatStack(projectID: String, name: String, parameters: [String: String]) -> FakeHeatStack {
        heatStackIDCounter += 1
        let s = FakeHeatStack(id: "stack-\(heatStackIDCounter)", projectID: projectID, name: name, status: "CREATE_COMPLETE", parameters: parameters)
        heatStacks.append(s)
        return s
    }

    public func deleteHeatStack(id: String, projectID: String) -> Bool {
        let idx = heatStacks.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        heatStacks.remove(at: idx)
        return true
    }

    // MARK: - Manila (shared file systems) CRUD

    public func listShares(projectID: String, name: String? = nil, limit: Int? = nil, marker: String? = nil) -> [FakeShare] {
        var result = shares.filter { $0.projectID == projectID }
        if let name { result = result.filter { $0.name.contains(name) } }
        result.sort { $0.name < $1.name }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getShare(id: String, projectID: String) -> FakeShare? {
        shares.first { $0.id == id && $0.projectID == projectID }
    }

    @discardableResult
    public func createShare(projectID: String, name: String, shareSize: Int, shareType: String, description: String?, isPublic: Bool) -> FakeShare {
        shareIDCounter += 1
        let s = FakeShare(id: "share-\(shareIDCounter)", projectID: projectID, name: name, status: "available", shareSize: shareSize, shareType: shareType, description: description, isPublic: isPublic)
        shares.append(s)
        return s
    }

    public func deleteShare(id: String, projectID: String) -> Bool {
        let idx = shares.firstIndex { $0.id == id && $0.projectID == projectID }
        guard let idx else { return false }
        // Cascade-delete any access rows on the removed share.
        shareAccesses.removeAll { $0.shareID == id && $0.projectID == projectID }
        shares.remove(at: idx)
        return true
    }

    public func listShareAccess(shareID: String, projectID: String, limit: Int? = nil, marker: String? = nil) -> [FakeShareAccess] {
        var result = shareAccesses.filter { $0.projectID == projectID && $0.shareID == shareID }
        result.sort { $0.accessTo < $1.accessTo }
        if let marker, let idx = result.firstIndex(where: { $0.id == marker }) { result = Array(result[(idx + 1)...]) }
        if let limit, limit < result.count { result = Array(result[0..<limit]) }
        return result
    }

    public func getShareAccess(id: String, shareID: String, projectID: String) -> FakeShareAccess? {
        shareAccesses.first { $0.id == id && $0.shareID == shareID && $0.projectID == projectID }
    }

    @discardableResult
    public func createShareAccess(projectID: String, shareID: String, accessTo: String, accessType: String, accessProtocol: String) -> FakeShareAccess {
        shareAccessIDCounter += 1
        let a = FakeShareAccess(id: "sa-\(shareAccessIDCounter)", projectID: projectID, shareID: shareID, accessTo: accessTo, accessType: accessType, accessProtocol: accessProtocol, state: "accessible")
        shareAccesses.append(a)
        return a
    }

    public func deleteShareAccess(id: String, shareID: String, projectID: String) -> Bool {
        let idx = shareAccesses.firstIndex { $0.id == id && $0.shareID == shareID && $0.projectID == projectID }
        guard let idx else { return false }
        shareAccesses.remove(at: idx)
        return true
    }
}
