import Foundation

// MARK: - Network

/// A Neutron network.
public struct Network: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var adminStateUp: Bool
    public var status: String
    public var shared: Bool
    public var provider: Provider?
    public var projectID: String
    public var routerExternal: Bool
    public var portSecurityEnabled: Bool
    public var subnets: [String]

    public struct Provider: Sendable, Codable {
        public var networkType: String
        public var physicalNetwork: String?
        public var segmentationID: Int?

        public init(networkType: String = "", physicalNetwork: String? = nil, segmentationID: Int? = nil) {
            self.networkType = networkType
            self.physicalNetwork = physicalNetwork
            self.segmentationID = segmentationID
        }
    }

    public init(
        id: String,
        name: String = "",
        adminStateUp: Bool = true,
        status: String = "ACTIVE",
        shared: Bool = false,
        provider: Provider? = nil,
        projectID: String = "",
        routerExternal: Bool = false,
        portSecurityEnabled: Bool = true,
        subnets: [String] = []
    ) {
        self.id = id
        self.name = name
        self.adminStateUp = adminStateUp
        self.status = status
        self.shared = shared
        self.provider = provider
        self.projectID = projectID
        self.routerExternal = routerExternal
        self.portSecurityEnabled = portSecurityEnabled
        self.subnets = subnets
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, shared, provider, subnets
        case adminStateUp = "admin_state_up"
        case projectID = "project_id"
        case routerExternal = "router:external"
        case portSecurityEnabled = "port_security_enabled"
    }
}

public struct CreateNetworkSpec: Sendable {
    public var name: String
    public var shared: Bool
    public var adminStateUp: Bool
    public var provider: Network.Provider?  // requires extension `provider`

    public init(name: String, shared: Bool = false, adminStateUp: Bool = true, provider: Network.Provider? = nil) {
        self.name = name
        self.shared = shared
        self.adminStateUp = adminStateUp
        self.provider = provider
    }

    func body() -> String {
        var parts: [String] = [
            "\"name\":\"\(name)\"",
            "\"shared\":\(shared ? "true" : "false")",
            "\"admin_state_up\":\(adminStateUp ? "true" : "false")"
        ]
        if let provider {
            let physical = provider.physicalNetwork.map { "\"\($0)\"" } ?? "null"
            let seg = provider.segmentationID.map { "\($0)" } ?? "null"
            parts.append("\"provider\":{\"network_type\":\"\(provider.networkType)\",\"physical_network\":\(physical),\"segmentation_id\":\(seg)}")
        }
        return "{\"network\":{\(parts.joined(separator: ","))}}"
    }
}

public struct UpdateNetworkSpec: Sendable {
    public var name: String?
    public var shared: Bool?
    public var adminStateUp: Bool?

    public init(name: String? = nil, shared: Bool? = nil, adminStateUp: Bool? = nil) {
        self.name = name
        self.shared = shared
        self.adminStateUp = adminStateUp
    }

    func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let shared { parts.append("\"shared\":\(shared ? "true" : "false")") }
        if let adminStateUp { parts.append("\"admin_state_up\":\(adminStateUp ? "true" : "false")") }
        return "{\"network\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Subnet

/// A Neutron subnet.
public struct Subnet: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var networkID: String
    public var cidr: String
    public var ipVersion: Int
    public var gatewayIP: String?
    public var enableDHCP: Bool
    public var allocationPools: [AllocationPool]
    public var projectID: String

    public init(
        id: String,
        name: String = "",
        networkID: String = "",
        cidr: String = "",
        ipVersion: Int = 4,
        gatewayIP: String? = nil,
        enableDHCP: Bool = true,
        allocationPools: [AllocationPool] = [],
        projectID: String = ""
    ) {
        self.id = id
        self.name = name
        self.networkID = networkID
        self.cidr = cidr
        self.ipVersion = ipVersion
        self.gatewayIP = gatewayIP
        self.enableDHCP = enableDHCP
        self.allocationPools = allocationPools
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cidr
        case networkID = "network_id"
        case ipVersion = "ip_version"
        case gatewayIP = "gateway_ip"
        case enableDHCP = "enable_dhcp"
        case allocationPools = "allocation_pools"
        case projectID = "project_id"
    }
}

/// An IP allocation pool within a subnet.
public struct AllocationPool: Sendable, Codable, Equatable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct CreateSubnetSpec: Sendable {
    public var networkID: String
    public var cidr: String
    public var ipVersion: Int
    public var gateway: String?
    public var name: String?
    public var enableDHCP: Bool?
    public var allocationPools: [AllocationPool]

    public init(
        networkID: String,
        cidr: String,
        ipVersion: Int = 4,
        gateway: String? = nil,
        name: String? = nil,
        enableDHCP: Bool? = nil,
        allocationPools: [AllocationPool] = []
    ) {
        self.networkID = networkID
        self.cidr = cidr
        self.ipVersion = ipVersion
        self.gateway = gateway
        self.name = name
        self.enableDHCP = enableDHCP
        self.allocationPools = allocationPools
    }

    func body() -> String {
        var parts: [String] = [
            "\"network_id\":\"\(networkID)\"",
            "\"cidr\":\"\(cidr)\"",
            "\"ip_version\":\(ipVersion)"
        ]
        if let gateway { parts.append("\"gateway_ip\":\"\(gateway)\"") }
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let enableDHCP { parts.append("\"enable_dhcp\":\(enableDHCP ? "true" : "false")") }
        if !allocationPools.isEmpty {
            let pools = allocationPools.map { "\"\($0.start)\",\"\($0.end)\"" }.joined(separator: ",")
            // Neutron accepts both object and shorthand forms; use objects
            let poolObjects = allocationPools.map { "{\"start\":\"\($0.start)\",\"end\":\"\($0.end)\"}" }.joined(separator: ",")
            _ = pools
            parts.append("\"allocation_pools\":[\(poolObjects)]")
        }
        return "{\"subnet\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Port

/// A Neutron port.
/// A Neutron port.
///
/// Named `OSPort` (not `Port`) because `NIOPosix.VsockAddress.Port` leaks into
/// every file that transitively imports NIO (via Hummingbird's `public import`
/// of NIOCore), making an unqualified `Port` ambiguous throughout the package.
public struct OSPort: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var adminStateUp: Bool
    public var networkID: String
    public var fixedIPs: [PortFixedIP]
    public var securityGroups: [String]
    public var deviceID: String?
    public var deviceOwner: String?
    public var extraDHCPOpts: [ExtraDHCPOpt]
    public var portSecurityEnabled: Bool
    public var projectID: String

    public init(
        id: String,
        name: String = "",
        status: String = "ACTIVE",
        adminStateUp: Bool = true,
        networkID: String = "",
        fixedIPs: [PortFixedIP] = [],
        securityGroups: [String] = [],
        deviceID: String? = nil,
        deviceOwner: String? = nil,
        extraDHCPOpts: [ExtraDHCPOpt] = [],
        portSecurityEnabled: Bool = true,
        projectID: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.adminStateUp = adminStateUp
        self.networkID = networkID
        self.fixedIPs = fixedIPs
        self.securityGroups = securityGroups
        self.deviceID = deviceID
        self.deviceOwner = deviceOwner
        self.extraDHCPOpts = extraDHCPOpts
        self.portSecurityEnabled = portSecurityEnabled
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, fixedIPs = "fixed_ips", securityGroups = "security_groups", extraDHCPOpts = "extra_dhcp_opts", portSecurityEnabled = "port_security_enabled"
        case adminStateUp = "admin_state_up"
        case networkID = "network_id"
        case deviceID = "device_id"
        case deviceOwner = "device_owner"
        case projectID = "project_id"
    }
}

/// A fixed IP on a port.
public struct PortFixedIP: Sendable, Codable, Equatable {
    public var ipAddress: String
    public var subnetID: String

    public init(ipAddress: String = "", subnetID: String = "") {
        self.ipAddress = ipAddress
        self.subnetID = subnetID
    }

    enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case subnetID = "subnet_id"
    }
}

/// An extra DHCP option on a port.
public struct ExtraDHCPOpt: Sendable, Codable, Equatable {
    public var optName: String
    public var optValue: String

    public init(optName: String, optValue: String) {
        self.optName = optName
        self.optValue = optValue
    }

    enum CodingKeys: String, CodingKey {
        case optName = "opt_name"
        case optValue = "opt_value"
    }
}

public struct CreatePortSpec: Sendable {
    public var networkID: String
    public var fixedIPs: [PortFixedIP]  // empty list = auto-assign one IP
    public var name: String
    public var securityGroups: [String]
    public var deviceID: String?
    public var deviceOwner: String?
    public var extraDHCPOpts: [ExtraDHCPOpt]
    public var adminStateUp: Bool
    public var portSecurityEnabled: Bool

    public init(
        networkID: String,
        fixedIPs: [PortFixedIP] = [],
        name: String = "",
        securityGroups: [String] = [],
        deviceID: String? = nil,
        deviceOwner: String? = nil,
        extraDHCPOpts: [ExtraDHCPOpt] = [],
        adminStateUp: Bool = true,
        portSecurityEnabled: Bool = true
    ) {
        self.networkID = networkID
        self.fixedIPs = fixedIPs
        self.name = name
        self.securityGroups = securityGroups
        self.deviceID = deviceID
        self.deviceOwner = deviceOwner
        self.extraDHCPOpts = extraDHCPOpts
        self.adminStateUp = adminStateUp
        self.portSecurityEnabled = portSecurityEnabled
    }

    func body() -> String {
        var parts: [String] = [
            "\"network_id\":\"\(networkID)\"",
            "\"admin_state_up\":\(adminStateUp ? "true" : "false")",
            "\"port_security_enabled\":\(portSecurityEnabled ? "true" : "false")"
        ]
        if !name.isEmpty { parts.append("\"name\":\"\(name)\"") }

        let ips = fixedIPs.map { ip -> String in
            var ipParts: [String] = []
            if !ip.ipAddress.isEmpty { ipParts.append("\"ip_address\":\"\(ip.ipAddress)\"") }
            if !ip.subnetID.isEmpty { ipParts.append("\"subnet_id\":\"\(ip.subnetID)\"") }
            return "{\(ipParts.joined(separator: ","))}"
        }.joined(separator: ",")
        parts.append("\"fixed_ips\":[\(ips)]")

        if !securityGroups.isEmpty {
            parts.append("\"security_groups\":[\(securityGroups.map { "\"\($0)\"" }.joined(separator: ","))]")
        }
        if let deviceID { parts.append("\"device_id\":\"\(deviceID)\"") }
        if let deviceOwner { parts.append("\"device_owner\":\"\(deviceOwner)\"") }
        if !extraDHCPOpts.isEmpty {
            let opts = extraDHCPOpts.map { "{\"opt_name\":\"\($0.optName)\",\"opt_value\":\"\($0.optValue)\"}" }.joined(separator: ",")
            parts.append("\"extra_dhcp_opts\":[\(opts)]")
        }

        return "{\"port\":{\(parts.joined(separator: ","))}}"
    }
}

public struct UpdatePortSpec: Sendable {
    public var name: String?
    public var adminStateUp: Bool?
    public var description: String?
    public var securityGroups: [String]?

    public init(name: String? = nil, adminStateUp: Bool? = nil, description: String? = nil, securityGroups: [String]? = nil) {
        self.name = name
        self.adminStateUp = adminStateUp
        self.description = description
        self.securityGroups = securityGroups
    }

    func body() -> String {
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let adminStateUp { parts.append("\"admin_state_up\":\(adminStateUp ? "true" : "false")") }
        if let description { parts.append("\"description\":\"\(description)\"") }
        if let securityGroups {
            let groups = securityGroups.map { "\"\($0)\"" }.joined(separator: ",")
            parts.append("\"security_groups\":[\(groups)]")
        }
        return "{\"port\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Router

/// A Neutron router.
public struct Router: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var status: String
    public var externalGatewayInfo: ExternalGatewayInfo?
    public var projectID: String

    public struct ExternalGatewayInfo: Sendable, Codable, Equatable {
        public var networkID: String

        public init(networkID: String) {
            self.networkID = networkID
        }

        enum CodingKeys: String, CodingKey {
            case networkID = "network_id"
        }
    }

    public init(
        id: String,
        name: String = "",
        status: String = "DOWN",
        externalGatewayInfo: ExternalGatewayInfo? = nil,
        projectID: String = ""
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.externalGatewayInfo = externalGatewayInfo
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case externalGatewayInfo = "external_gateway_info"
        case projectID = "project_id"
    }
}

public struct CreateRouterSpec: Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    func body() -> String {
        "{\"router\":{\"name\":\"\(name)\"}}"
    }
}

// MARK: - Floating IP

/// A Neutron floating IP.
public struct FloatingIP: Sendable, Codable, Identifiable {
    public let id: String
    public var floatingIP: String
    public var floatingNetworkID: String
    public var portID: String?
    public var fixedIPAddress: String?
    public var status: String
    public var projectID: String

    public init(
        id: String,
        floatingIP: String = "",
        floatingNetworkID: String = "",
        portID: String? = nil,
        fixedIPAddress: String? = nil,
        status: String = "DOWN",
        projectID: String = ""
    ) {
        self.id = id
        self.floatingIP = floatingIP
        self.floatingNetworkID = floatingNetworkID
        self.portID = portID
        self.fixedIPAddress = fixedIPAddress
        self.status = status
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case floatingIP = "floating_ip_address"
        case floatingNetworkID = "floating_network_id"
        case portID = "port_id"
        case fixedIPAddress = "fixed_ip_address"
        case projectID = "project_id"
    }
}

public struct CreateFloatingIPSpec: Sendable {
    public var floatingNetworkID: String

    public init(floatingNetworkID: String) {
        self.floatingNetworkID = floatingNetworkID
    }

    func body() -> String {
        "{\"floatingip\":{\"floating_network_id\":\"\(floatingNetworkID)\"}}"
    }
}

// MARK: - Security group

/// A Neutron security group.
public struct SecurityGroup: Sendable, Codable, Identifiable {
    public let id: String
    public var name: String
    public var description: String
    public var projectID: String

    public init(id: String, name: String = "", description: String = "", projectID: String = "") {
        self.id = id
        self.name = name
        self.description = description
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case projectID = "project_id"
    }
}

public struct CreateSecurityGroupSpec: Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }

    func body() -> String {
        "{\"security_group\":{\"name\":\"\(name)\",\"description\":\"\(description)\"}}"
    }
}

/// A Neutron security group rule (immutable once created).
public struct SecurityGroupRule: Sendable, Codable, Identifiable {
    public let id: String
    public var securityGroupID: String
    public var direction: String
    public var ethertype: String
    public var ipProtocol: String?
    public var portRangeMin: Int?
    public var portRangeMax: Int?
    public var remoteIPPrefix: String?
    public var projectID: String

    public init(
        id: String,
        securityGroupID: String = "",
        direction: String = "ingress",
        ethertype: String = "IPv4",
        ipProtocol: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteIPPrefix: String? = nil,
        projectID: String = ""
    ) {
        self.id = id
        self.securityGroupID = securityGroupID
        self.direction = direction
        self.ethertype = ethertype
        self.ipProtocol = ipProtocol
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteIPPrefix = remoteIPPrefix
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, direction, ethertype
        case ipProtocol = "protocol"
        case securityGroupID = "security_group_id"
        case portRangeMin = "port_range_min"
        case portRangeMax = "port_range_max"
        case remoteIPPrefix = "remote_ip_prefix"
        case projectID = "project_id"
    }
}

public struct CreateSecurityGroupRuleSpec: Sendable {
    public var securityGroupID: String
    public var direction: String
    public var ethertype: String
    public var ipProtocol: String?
    public var portRangeMin: Int?
    public var portRangeMax: Int?
    public var remoteIPPrefix: String?

    public init(
        securityGroupID: String,
        direction: String = "ingress",
        ethertype: String = "IPv4",
        ipProtocol: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteIPPrefix: String? = nil
    ) {
        self.securityGroupID = securityGroupID
        self.direction = direction
        self.ethertype = ethertype
        self.ipProtocol = ipProtocol
        self.portRangeMin = portRangeMin
        self.portRangeMax = portRangeMax
        self.remoteIPPrefix = remoteIPPrefix
    }

    func body() -> String {
        var parts: [String] = [
            "\"security_group_id\":\"\(securityGroupID)\"",
            "\"direction\":\"\(direction)\"",
            "\"ethertype\":\"\(ethertype)\""
        ]
        if let ipProtocol { parts.append("\"protocol\":\"\(ipProtocol)\"") }
        if let portRangeMin { parts.append("\"port_range_min\":\(portRangeMin)") }
        if let portRangeMax { parts.append("\"port_range_max\":\(portRangeMax)") }
        if let remoteIPPrefix { parts.append("\"remote_ip_prefix\":\"\(remoteIPPrefix)\"") }
        return "{\"security_group_rule\":{\(parts.joined(separator: ","))}}"
    }
}

// MARK: - Address group (extension `address-group`)

/// A Neutron address group.
public struct AddressGroup: Sendable, Codable, Identifiable {
    public var id: String?
    public var name: String
    public var description: String
    public var addresses: [String]
    public var projectID: String

    public init(id: String? = nil, name: String = "", description: String = "", addresses: [String] = [], projectID: String = "") {
        self.id = id
        self.name = name
        self.description = description
        self.addresses = addresses
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, addresses
        case projectID = "project_id"
    }
}

public struct CreateAddressGroupSpec: Sendable {
    public var name: String
    public var description: String
    public var addresses: [String]

    public init(name: String, description: String = "", addresses: [String] = []) {
        self.name = name
        self.description = description
        self.addresses = addresses
    }

    func body() -> String {
        let addrs = addresses.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"address_group\":{\"name\":\"\(name)\",\"description\":\"\(description)\",\"addresses\":[\(addrs)]}}"
    }
}

// MARK: - Quota

/// Neutron quota set for a project.
public struct NetworkQuota: Sendable, Codable {
    public var projectID: String?
    public var network: Int?
    public var subnet: Int?
    public var port: Int?
    public var securityGroup: Int?
    public var securityGroupRule: Int?
    public var floatingip: Int?
    public var router: Int?

    public init(
        projectID: String? = nil,
        network: Int? = nil,
        subnet: Int? = nil,
        port: Int? = nil,
        securityGroup: Int? = nil,
        securityGroupRule: Int? = nil,
        floatingip: Int? = nil,
        router: Int? = nil
    ) {
        self.projectID = projectID
        self.network = network
        self.subnet = subnet
        self.port = port
        self.securityGroup = securityGroup
        self.securityGroupRule = securityGroupRule
        self.floatingip = floatingip
        self.router = router
    }

    enum CodingKeys: String, CodingKey {
        case network, subnet, port, floatingip, router
        case projectID = "project_id"
        case securityGroup = "security_group"
        case securityGroupRule = "security_group_rule"
    }

    func updateBody() -> String {
        var parts: [String] = []
        if let network { parts.append("\"network\":\(network)") }
        if let subnet { parts.append("\"subnet\":\(subnet)") }
        if let port { parts.append("\"port\":\(port)") }
        if let securityGroup { parts.append("\"security_group\":\(securityGroup)") }
        if let securityGroupRule { parts.append("\"security_group_rule\":\(securityGroupRule)") }
        if let floatingip { parts.append("\"floatingip\":\(floatingip)") }
        if let router { parts.append("\"router\":\(router)") }
        return "{\"quota\":{\(parts.joined(separator: ","))}}"
    }
}
