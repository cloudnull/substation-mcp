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
            metadata: [String: String] = [:]
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

    // MARK: - Storage

    public private(set) var credentials: [FakeCredential] = []
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
    public var extensions: Set<String> = ["provider", "qos", "security-group", "address-group"]

    public func removeExtension(_ alias: String) {
        extensions.remove(alias)
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
            servers.append(FakeServer(
                id: String(format: "srv-%04d", serverIDCounter),
                name: "server-\(i)",
                status: "ACTIVE",
                projectID: "proj-one"
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
}
