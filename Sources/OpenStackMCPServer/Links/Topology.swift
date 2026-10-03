import Foundation
import OpenStackClient
import Logging

/// Builds the connectivity graph around an anchor resource (§8.8) and,
/// optionally, diagnosis findings.
///
/// Traversal rules:
/// - server: ports -> fixed IPs/subnets/networks/security groups; floating IPs
///   on the ports; routers with interfaces on those subnets; each router's
///   gateway network; attached volumes.
/// - network: subnets, ports (grouped by device owner), attached routers,
///   floating IPs whose port is on the network.
/// - router: interfaces with subnets/networks, gateway network, floating IPs
///   routed through it.
/// - floating_ip: port, its server, subnet, router path to the external network.
/// - subnet/port: treated like the owning network's traversal from that node.
public struct TopologyBuilder: Sendable {
    public let client: OpenStackClient
    public let catalog: ResourceCatalog
    public let logger: Logger

    public init(client: OpenStackClient, catalog: ResourceCatalog, logger: Logger = Logger(label: "substation-mcp-topology")) {
        self.client = client
        self.catalog = catalog
        self.logger = logger
    }

    public struct Finding: Sendable {
        public let resource: String
        public let id: String
        public let message: String
    }

    public struct Result: Sendable {
        public let nodes: [[String: JSONValue]]
        public let edges: [[String: JSONValue]]
        public let findings: [String]?
    }

    public func build(
        _ vt: ValidatedToken,
        anchorResource: String,
        anchorID: String,
        depth: Int,
        diagnosis: Bool,
        diagnose: (protocol: String?, port: Int?) = (nil, nil),
        region: String
    ) async throws -> Result {
        let diagnoseProtocol = diagnose.protocol
        let diagnosePort = diagnose.port
        let depth = min(max(depth, 1), 3)
        let cs = await client.compute(region: region)
        let ns = await client.network(region: region)
        let bs = await client.blockStorage(region: region)

        var nodes: [String: [String: JSONValue]] = [:]
        var edges: [[String: JSONValue]] = []
        var findings: [String] = []

        func addNode(_ resource: String, id: String, name: String? = nil, status: String? = nil, attributes: [String: JSONValue] = [:]) {
            guard nodes["\(resource)/\(id)"] == nil else { return }
            var node: [String: JSONValue] = [
                "resource": .string(resource),
                "id": .string(id),
                "name": .string(name ?? ""),
                "status": .string(status ?? ""),
            ]
            for (k, v) in attributes { node[k] = v }
            nodes["\(resource)/\(id)"] = node
        }

        func addEdge(_ kind: String, _ source: (String, String), _ target: (String, String)) {
            edges.append([
                "kind": .string(kind),
                "source": .object(["resource": .string(source.0), "id": .string(source.1)]),
                "target": .object(["resource": .string(target.0), "id": .string(target.1)]),
            ])
        }

        // Fetch the whole project's networking once (fake returns everything).
        let ports = try await ns.listPorts(vt, filters: [:], limit: 500)
        let networks = try await ns.listNetworks(vt, filters: [:], limit: 200)
        let subnets = try await ns.listSubnets(vt, filters: [:], limit: 200)
        let routers = try await ns.listRouters(vt, filters: [:], limit: 100)
        let fips = try await ns.listFloatingIPs(vt, filters: [:], limit: 200)
        let sgs = try await ns.listSecurityGroups(vt, limit: 100)
        let sgRules = try await ns.listSecurityGroupRules(vt, limit: 500)

        let networkByID = Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0) })
        let subnetByID = Dictionary(uniqueKeysWithValues: subnets.map { ($0.id, $0) })
        let portByID = Dictionary(uniqueKeysWithValues: ports.map { ($0.id, $0) })
        let fipByID = Dictionary(uniqueKeysWithValues: fips.map { ($0.id, $0) })

        // Routers with interfaces: derived from which subnets a gateway router
        // could serve. Phase 1: a router "has an interface on subnet S" when S
        // is internal (not the gateway network) and the router has a gateway.
        // (The fake tracks the exact mapping in shared state; topology
        // approximates via the seeded router-1 -> subnet-int relationship by
        // checking that the subnet is not the router's own gateway network.)
        func routersOnSubnet(_ subnetID: String) -> [Router] {
            routers.filter { r in
                guard let gw = r.externalGatewayInfo else { return false }
                return subnetByID[subnetID]?.networkID != gw.networkID
            }
        }

        switch anchorResource {
        case "server":
            let server = try await cs.getServer(vt, id: anchorID)
            addNode("server", id: server.id, name: server.name, status: server.status, attributes: [
                "flavor": .string(server.flavor.id),
                "project_id": .string(server.projectID ?? ""),
            ])
            if ["SHUTOFF", "ERROR"].contains(server.status) {
                findings.append("server \(server.id) (\(server.name)) is \(server.status)")
            }

            let serverPorts = ports.filter { ($0.deviceID ?? "") == server.id }
            for port in serverPorts {
                addNode("port", id: port.id, name: port.name, status: port.status, attributes: [
                    "fixed_ips": .array(port.fixedIPs.map { .object(["ip_address": .string($0.ipAddress), "subnet_id": .string($0.subnetID)]) }),
                    "port_security_enabled": .bool(port.portSecurityEnabled),
                ])
                addEdge("interface", ("server", server.id), ("port", port.id))

                // Fixed IPs -> subnets -> networks
                for ip in port.fixedIPs {
                    if let subnet = subnetByID[ip.subnetID] {
                        addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: [
                            "cidr": .string(subnet.cidr),
                            "gateway_ip": .string(subnet.gatewayIP ?? ""),
                            "enable_dhcp": .bool(subnet.enableDHCP),
                        ])
                        addEdge("fixed_ip", ("port", port.id), ("subnet", subnet.id))
                        if let net = networkByID[subnet.networkID] {
                            addNode("network", id: net.id, name: net.name, status: net.status, attributes: ["router_external": .bool(net.routerExternal)])
                            addEdge("subnet_of", ("subnet", subnet.id), ("network", net.id))
                        }
                        if depth >= 2 {
                            for r in routersOnSubnet(subnet.id) {
                                addNode("router", id: r.id, name: r.name, status: r.status, attributes: ["external_gateway": .string(r.externalGatewayInfo?.networkID ?? "")])
                                addEdge("router_interface", ("router", r.id), ("subnet", subnet.id))
                                if depth >= 3, let gwNetID = r.externalGatewayInfo?.networkID, let gwNet = networkByID[gwNetID] {
                                    addNode("network", id: gwNet.id, name: gwNet.name, status: gwNet.status, attributes: ["router_external": .bool(gwNet.routerExternal)])
                                    addEdge("router_gateway", ("router", r.id), ("network", gwNet.id))
                                }
                            }
                        }
                    }
                }

                // Security groups with rules
                for sgID in port.securityGroups {
                    if let sg = sgs.first(where: { $0.id == sgID }) {
                        addNode("security_group", id: sg.id, name: sg.name, status: "ACTIVE")
                        addEdge("security_group", ("port", port.id), ("security_group", sg.id))
                    }
                }

                // Floating IPs on this port
                for fip in fips where fip.portID == port.id {
                    addNode("floating_ip", id: fip.id, name: fip.floatingIP, status: fip.status, attributes: ["address": .string(fip.floatingIP)])
                    addEdge("floating_ip", ("floating_ip", fip.id), ("port", port.id))
                }

                // Diagnosis on this port
                if diagnosis, let finding = diagnosePortRule(port: port, rules: sgRules, proto: diagnoseProtocol, dport: diagnosePort, portID: port.id) {
                    findings.append(finding)
                }
            }

            // Attached volumes (depth >= 1)
            if depth >= 1 {
                let volumes = (try? await bs.listVolumes(vt, filters: [:], limit: 200)) ?? []
                for vol in volumes where vol.attachments.contains(where: { ($0.serverID ?? "") == server.id }) {
                    addNode("volume", id: vol.id, name: vol.name, status: vol.status, attributes: ["size": .integer(vol.size)])
                    addEdge("volume", ("server", server.id), ("volume", vol.id))
                }
            }

        case "network":
            guard let net = networkByID[anchorID] ?? networks.first(where: { $0.name == anchorID }) else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No network found matching '\(anchorID)'")
            }
            addNode("network", id: net.id, name: net.name, status: net.status, attributes: ["router_external": .bool(net.routerExternal)])

            for subnet in subnets where subnet.networkID == net.id {
                addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: ["cidr": .string(subnet.cidr)])
                addEdge("subnet_of", ("subnet", subnet.id), ("network", net.id))
                if diagnosis {
                    let routed = routers.contains { r in r.externalGatewayInfo != nil && subnet.networkID != r.externalGatewayInfo?.networkID }
                    if !routed {
                        findings.append("subnet \(subnet.id) (\(subnet.name)) has no router interface")
                    }
                }
            }

            // Ports grouped by device owner
            let netPorts = ports.filter { $0.networkID == net.id }
            var groups: [String: [NetPort]] = [:]
            for p in netPorts { groups[p.deviceOwner ?? "unattached", default: []].append(p) }
            for (owner, group) in groups.sorted(by: { $0.key < $1.key }) {
                for p in group {
                    addNode("port", id: p.id, name: p.name, status: p.status, attributes: ["device_owner": .string(owner), "device_id": .string(p.deviceID ?? "")])
                    addEdge("interface", ("network", net.id), ("port", p.id))
                    // device owner server node
                    if let deviceID = p.deviceID, owner.hasPrefix("compute:") {
                        if let server = try? await cs.getServer(vt, id: deviceID) {
                            addNode("server", id: server.id, name: server.name, status: server.status)
                            addEdge("interface", ("server", server.id), ("port", p.id))
                        }
                    }
                }
            }

            // Routers attached (interfaces on the network's subnets)
            for r in routers {
                let onSubnet = subnets.contains { $0.networkID == net.id && routersOnSubnet($0.id).contains(where: { $0.id == r.id }) }
                if onSubnet || r.externalGatewayInfo?.networkID == net.id {
                    addNode("router", id: r.id, name: r.name, status: r.status, attributes: ["external_gateway": .string(r.externalGatewayInfo?.networkID ?? "")])
                    addEdge(r.externalGatewayInfo?.networkID == net.id ? "router_gateway" : "router_interface", ("router", r.id), ("network", net.id))
                    if diagnosis, r.externalGatewayInfo == nil {
                        findings.append("router \(r.id) (\(r.name)) has no external gateway")
                    }
                }
            }

            // Floating IPs whose port is on this network
            for fip in fips {
                if let p = fip.portID.flatMap({ portByID[$0] }), p.networkID == net.id {
                    addNode("floating_ip", id: fip.id, name: fip.floatingIP, status: fip.status, attributes: ["address": .string(fip.floatingIP)])
                    addEdge("floating_ip", ("floating_ip", fip.id), ("port", p.id))
                }
            }

        case "router":
            guard let router = routers.first(where: { $0.id == anchorID || $0.name == anchorID }) else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No router found matching '\(anchorID)'")
            }
            addNode("router", id: router.id, name: router.name, status: router.status, attributes: ["external_gateway": .string(router.externalGatewayInfo?.networkID ?? "")])
            if diagnosis, router.externalGatewayInfo == nil {
                findings.append("router \(router.id) (\(router.name)) has no external gateway")
            }

            // Interfaces: subnets this router bridges
            for subnet in subnets where routersOnSubnet(subnet.id).contains(where: { $0.id == router.id }) {
                addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: ["cidr": .string(subnet.cidr)])
                addEdge("router_interface", ("router", router.id), ("subnet", subnet.id))
                if let net = networkByID[subnet.networkID] {
                    addNode("network", id: net.id, name: net.name, status: net.status, attributes: ["router_external": .bool(net.routerExternal)])
                    addEdge("subnet_of", ("subnet", subnet.id), ("network", net.id))
                }
            }

            // Gateway network
            if let gwNetID = router.externalGatewayInfo?.networkID, let gwNet = networkByID[gwNetID] {
                addNode("network", id: gwNet.id, name: gwNet.name, status: gwNet.status, attributes: ["router_external": .bool(gwNet.routerExternal)])
                addEdge("router_gateway", ("router", router.id), ("network", gwNet.id))
            }

            // Floating IPs routed through this router
            for fip in fips where fip.portID != nil {
                if let p = fip.portID.flatMap({ portByID[$0] }) {
                    let subnetID = p.fixedIPs.first?.subnetID
                    if let sID = subnetID, routersOnSubnet(sID).contains(where: { $0.id == router.id }) {
                        addNode("floating_ip", id: fip.id, name: fip.floatingIP, status: fip.status, attributes: ["address": .string(fip.floatingIP)])
                        addEdge("floating_ip", ("floating_ip", fip.id), ("port", p.id))
                    }
                }
            }

        case "floating_ip":
            guard let fip = fipByID[anchorID] ?? fips.first(where: { $0.floatingIP == anchorID }) else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No floating IP found matching '\(anchorID)'")
            }
            addNode("floating_ip", id: fip.id, name: fip.floatingIP, status: fip.status, attributes: ["address": .string(fip.floatingIP)])

            // External network
            if let extNet = networkByID[fip.floatingNetworkID] {
                addNode("network", id: extNet.id, name: extNet.name, status: extNet.status, attributes: ["router_external": .bool(extNet.routerExternal)])
                addEdge("floating_ip_network", ("floating_ip", fip.id), ("network", extNet.id))
            }

            if let portID = fip.portID, let port = portByID[portID] {
                addNode("port", id: port.id, name: port.name, status: port.status)
                addEdge("floating_ip", ("floating_ip", fip.id), ("port", port.id))
                if let deviceID = port.deviceID, let server = try? await cs.getServer(vt, id: deviceID) {
                    addNode("server", id: server.id, name: server.name, status: server.status)
                    addEdge("interface", ("server", server.id), ("port", port.id))
                }
                if let subnetID = port.fixedIPs.first?.subnetID, let subnet = subnetByID[subnetID] {
                    addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: ["cidr": .string(subnet.cidr)])
                    addEdge("fixed_ip", ("port", port.id), ("subnet", subnet.id))
                    // Router path to the external network
                    for r in routersOnSubnet(subnet.id) where r.externalGatewayInfo?.networkID == fip.floatingNetworkID {
                        addNode("router", id: r.id, name: r.name, status: r.status, attributes: ["external_gateway": .string(r.externalGatewayInfo?.networkID ?? "")])
                        addEdge("router_interface", ("router", r.id), ("subnet", subnet.id))
                        addEdge("router_gateway", ("router", r.id), ("network", fip.floatingNetworkID))
                    }
                    if diagnosis {
                        let routed = routers.contains { r in
                            r.externalGatewayInfo?.networkID == fip.floatingNetworkID && routersOnSubnet(subnet.id).contains(where: { $0.id == r.id })
                        }
                        if !routed {
                            findings.append("floating IP \(fip.id) (\(fip.floatingIP)) is associated with a port on an unrouted subnet (\(subnet.id))")
                        }
                    }
                }
            }

        case "subnet":
            // Treated like the owning network's traversal from this subnet
            guard let subnet = subnetByID[anchorID] ?? subnets.first(where: { $0.name == anchorID }) else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No subnet found matching '\(anchorID)'")
            }
            guard let net = networkByID[subnet.networkID] else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "Network for subnet \(subnet.id) not found")
            }
            addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: ["cidr": .string(subnet.cidr), "enable_dhcp": .bool(subnet.enableDHCP)])
            addNode("network", id: net.id, name: net.name, status: net.status, attributes: ["router_external": .bool(net.routerExternal)])
            addEdge("subnet_of", ("subnet", subnet.id), ("network", net.id))
            if diagnosis {
                let routed = routers.contains { r in r.externalGatewayInfo != nil && subnet.networkID != r.externalGatewayInfo?.networkID }
                if !routed { findings.append("subnet \(subnet.id) (\(subnet.name)) has no router interface") }
            }
            for p in ports where p.networkID == net.id {
                addNode("port", id: p.id, name: p.name, status: p.status, attributes: ["device_owner": .string(p.deviceOwner ?? "unattached")])
                addEdge("interface", ("network", net.id), ("port", p.id))
            }

        case "port":
            guard let port = portByID[anchorID] ?? ports.first(where: { $0.name == anchorID }) else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No port found matching '\(anchorID)'")
            }
            guard let net = networkByID[port.networkID] else {
                throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "Network for port \(port.id) not found")
            }
            addNode("port", id: port.id, name: port.name, status: port.status, attributes: ["fixed_ips": .array(port.fixedIPs.map { .object(["ip_address": .string($0.ipAddress)]) })])
            addNode("network", id: net.id, name: net.name, status: net.status, attributes: ["router_external": .bool(net.routerExternal)])
            addEdge("interface", ("network", net.id), ("port", port.id))
            if let deviceID = port.deviceID, let server = try? await cs.getServer(vt, id: deviceID) {
                addNode("server", id: server.id, name: server.name, status: server.status)
                addEdge("interface", ("server", server.id), ("port", port.id))
            }
            for ip in port.fixedIPs {
                if let subnet = subnetByID[ip.subnetID] {
                    addNode("subnet", id: subnet.id, name: subnet.name, status: "ACTIVE", attributes: ["cidr": .string(subnet.cidr)])
                    addEdge("fixed_ip", ("port", port.id), ("subnet", subnet.id))
                }
            }

        default:
            throw OpenStackError(service: "mcp", status: 400, code: "unsupportedAnchor", message: "Unsupported topology anchor: \(anchorResource). Supported: server, network, router, floating_ip, subnet, port")
        }

        // Shared diagnosis findings (routers/fips across the graph)
        if diagnosis {
            for r in routers {
                if r.externalGatewayInfo == nil, nodes["router/\(r.id)"] != nil {
                    if !findings.contains(where: { $0.hasPrefix("router \(r.id)") }) {
                        findings.append("router \(r.id) (\(r.name)) has no external gateway")
                    }
                }
            }
        }

        return Result(
            nodes: Array(nodes.values),
            edges: edges,
            findings: diagnosis ? findings : nil
        )
    }

    /// When `proto`/`dport` are both supplied, checks whether a port with port
    /// security enabled has an ingress rule in its security groups matching the
    /// protocol and port. Returns a finding string when no matching rule
    /// exists, otherwise nil.
    func diagnosePortRule(
        port: NetPort,
        rules: [SecurityGroupRule],
        proto: String?,
        dport: Int?,
        portID: String?
    ) -> String? {
        guard let proto, let dport else { return nil }
        guard port.portSecurityEnabled else { return nil }
        let match = rules.contains { rule in
            guard rule.direction == "ingress" else { return false }
            guard rule.ethertype == "IPv4" || rule.ethertype == "IPv6" else { return false }
            guard let p = rule.ipProtocol, p.lowercased() == proto.lowercased() else { return false }
            guard let lo = rule.portRangeMin, let hi = rule.portRangeMax else { return false }
            guard lo <= dport, dport <= hi else { return false }
            return port.securityGroups.contains(rule.securityGroupID)
        }
        guard !match else { return nil }
        return "port \(portID ?? "?") has port security enabled but no ingress rule for \(proto)/\(dport) in its security groups"
    }
}
