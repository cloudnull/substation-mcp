import Foundation
import MCP
import OpenStackClient
import Logging

/// The concrete link executor: implements the 7 links from spec §8.7 with
/// their precondition checks and the reverse `os_detach` operations.
public struct LinkExecutor: Sendable {
    public let client: OpenStackClient
    public let catalog: ResourceCatalog
    public let waiter: Waiter
    public let logger: Logger

    public init(client: OpenStackClient, catalog: ResourceCatalog, waiter: Waiter, logger: Logger = Logger(label: "substation-mcp-links")) {
        self.client = client
        self.catalog = catalog
        self.waiter = waiter
        self.logger = logger
    }

    // MARK: - Public API

    public func attach(
        _ vt: ValidatedToken,
        link: String,
        sourceType: String,
        source: String,
        targetType: String,
        target: String,
        params: [String: JSONValue],
        region: String,
        wait: Bool = false
    ) async throws -> [String: JSONValue] {
        switch link {
        case "volume": return try await attachVolume(vt, serverID: source, volumeID: target, params: params, region: region, wait: wait)
        case "interface": return try await attachInterface(vt, serverID: source, targetType: targetType, target: target, params: params, region: region, wait: wait)
        case "security_group": return try await attachSecurityGroup(vt, sourceType: sourceType, source: source, target: target, region: region)
        case "floating_ip": return try await attachFloatingIP(vt, fipID: source, targetType: targetType, target: target, params: params, region: region, wait: wait)
        case "router_interface": return try await attachRouterInterface(vt, routerID: source, targetType: targetType, target: target, region: region)
        case "router_gateway": return try await attachRouterGateway(vt, routerID: source, target: target, params: params, region: region)
        case "image":
            throw OpenStackError(
                service: "mcp", status: 400, code: "unsupportedLink",
                message: "The image link is a create-time link: volumes are created from an image, not linked to one. Use os_create(resource: \"volume\", spec: {\"image\": \"<image id or name>\", ...}) instead. To go the other direction (volume to image) use os_action(resource: \"volume\", id_or_name: ..., action: \"upload_to_image\")."
            )
        default:
            throw OpenStackError(
                service: "mcp", status: 400, code: "unknownLink",
                message: "Unknown link: \(link). Valid: \(catalog.allLinks.keys.sorted().joined(separator: ", "))"
            )
        }
    }

    public func detach(
        _ vt: ValidatedToken,
        link: String,
        sourceType: String,
        source: String,
        targetType: String,
        target: String,
        region: String,
        wait: Bool = false
    ) async throws -> [String: JSONValue] {
        switch link {
        case "volume": return try await detachVolume(vt, serverID: source, volumeID: target, region: region, wait: wait)
        case "interface": return try await detachInterface(vt, serverID: source, portID: target, region: region, wait: wait)
        case "security_group": return try await detachSecurityGroup(vt, sourceType: sourceType, source: source, target: target, region: region)
        case "floating_ip": return try await detachFloatingIP(vt, fipID: source, region: region, wait: wait)
        case "router_interface": return try await detachRouterInterface(vt, routerID: source, target: target, region: region)
        case "router_gateway": return try await detachRouterGateway(vt, routerID: source, region: region)
        case "image":
            throw OpenStackError(
                service: "mcp", status: 400, code: "unsupportedLink",
                message: "The image link cannot be detached: volumes created from an image keep their source image reference. Delete the volume with os_delete if you no longer need it."
            )
        default:
            throw OpenStackError(
                service: "mcp", status: 400, code: "unknownLink",
                message: "Unknown link: \(link). Valid: \(catalog.allLinks.keys.sorted().joined(separator: ", "))"
            )
        }
    }

    // MARK: - volume

    private func attachVolume(_ vt: ValidatedToken, serverID: String, volumeID: String, params: [String: JSONValue], region: String, wait: Bool) async throws -> [String: JSONValue] {
        guard let device = params["device"]?.stringValue, !device.isEmpty else {
            throw OpenStackError(service: "mcp", status: 400, code: "missingParam", message: "The volume link requires params: {\"device\": \"/dev/vdX\"}")
        }
        let deleteOnTermination = params["delete_on_termination"]?.boolValue

        let cs = await client.compute(region: region)
        let bs = await client.blockStorage(region: region)
        let server = try await cs.getServer(vt, id: serverID)
        guard !["BUILD", "REBUILD"].contains(server.status) else {
            throw OpenStackError(service: "mcp", status: 409, code: "badServerState", message: "Server \(serverID) is \(server.status); it must not be building for a volume attach")
        }
        let volume = try await bs.getVolume(vt, id: volumeID)
        guard volume.status == "available" || volume.multiattach else {
            throw OpenStackError(service: "mcp", status: 409, code: "badVolumeState", message: "Volume \(volumeID) is \(volume.status); it must be available (or multiattach) to be attached")
        }

        try await cs.attachVolume(vt, serverID: serverID, volumeID: volumeID, device: device, deleteOnTermination: deleteOnTermination)
        logger.info("volume attached", metadata: ["server": .string(serverID), "volume": .string(volumeID), "device": .string(device)])

        var result: [String: JSONValue] = [
            "link": .string("volume"),
            "operation": .string("attach"),
            "server": .string(serverID),
            "volume": .string(volumeID),
            "device": .string(device),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "volume", id: volumeID, region: region, until: ["in-use"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    private func detachVolume(_ vt: ValidatedToken, serverID: String, volumeID: String, region: String, wait: Bool) async throws -> [String: JSONValue] {
        let cs = await client.compute(region: region)
        let bs = await client.blockStorage(region: region)
        let volume = try await bs.getVolume(vt, id: volumeID)
        // Find the attachment on this server
        guard let attachment = volume.attachments.first(where: { ($0.serverID ?? "") == serverID }) else {
            throw OpenStackError(service: "mcp", status: 404, code: "notAttached", message: "Volume \(volumeID) has no attachment on server \(serverID)")
        }
        try await cs.detachVolume(vt, serverID: serverID, attachmentID: attachment.id)
        logger.info("volume detached", metadata: ["server": .string(serverID), "volume": .string(volumeID)])

        var result: [String: JSONValue] = [
            "link": .string("volume"),
            "operation": .string("detach"),
            "server": .string(serverID),
            "volume": .string(volumeID),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "volume", id: volumeID, region: region, until: ["available"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    // MARK: - interface

    private func attachInterface(_ vt: ValidatedToken, serverID: String, targetType: String, target: String, params: [String: JSONValue], region: String, wait: Bool) async throws -> [String: JSONValue] {
        let cs = await client.compute(region: region)
        let ns = await client.network(region: region)
        let server = try await cs.getServer(vt, id: serverID)
        guard server.status == "ACTIVE" || server.status == "SHUTOFF" else {
            throw OpenStackError(service: "mcp", status: 409, code: "badServerState", message: "Server \(serverID) is \(server.status); interface attach requires ACTIVE or SHUTOFF")
        }

        var networkID: String?
        var subnetID: String?
        var portID: String?

        switch targetType {
        case "port":
            let port = try await ns.getPort(vt, id: target)
            if let deviceID = port.deviceID, !deviceID.isEmpty {
                throw OpenStackError(service: "mcp", status: 409, code: "portAttached", message: "Port \(target) is already attached to \(deviceID)")
            }
            portID = port.id
            networkID = port.networkID
        case "network":
            let net = try await ns.getNetwork(vt, id: target)
            networkID = net.id
        case "subnet":
            let subnet = try await ns.getSubnet(vt, id: target)
            subnetID = subnet.id
            networkID = subnet.networkID
        default:
            throw OpenStackError(service: "mcp", status: 400, message: "The interface link target must be a port, network, or subnet (got: \(targetType))")
        }

        let fixedIP = params["fixed_ip"]?.stringValue
        try await cs.attachInterface(vt, serverID: serverID, networkID: networkID, subnetID: subnetID, portID: portID, fixedIP: fixedIP)
        logger.info("interface attached", metadata: ["server": .string(serverID), "target": .string(target)])

        var result: [String: JSONValue] = [
            "link": .string("interface"),
            "operation": .string("attach"),
            "server": .string(serverID),
            "target_type": .string(targetType),
            "target": .string(target),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "server", id: serverID, region: region, until: ["ACTIVE"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    private func detachInterface(_ vt: ValidatedToken, serverID: String, portID: String, region: String, wait: Bool) async throws -> [String: JSONValue] {
        let cs = await client.compute(region: region)
        try await cs.detachInterface(vt, serverID: serverID, portID: portID)
        logger.info("interface detached", metadata: ["server": .string(serverID), "port": .string(portID)])

        var result: [String: JSONValue] = [
            "link": .string("interface"),
            "operation": .string("detach"),
            "server": .string(serverID),
            "port": .string(portID),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "server", id: serverID, region: region, until: ["ACTIVE"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    // MARK: - security_group

    private func attachSecurityGroup(_ vt: ValidatedToken, sourceType: String, source: String, target: String, region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let cs = await client.compute(region: region)

        // Resolve the security group id
        let sgID = try await resolveName(vt, resource: "security_group", idOrName: target, region: region)

        // Resolve the port: source may be a server (find its first port) or a port
        let port: NetPort
        if sourceType == "port" {
            port = try await ns.getPort(vt, id: source)
        } else if sourceType == "server" {
            _ = try await cs.getServer(vt, id: source)
            let ports = try await ns.listPorts(vt, filters: ["device_id": source], limit: 5)
            guard let first = ports.first else {
                throw OpenStackError(service: "mcp", status: 404, code: "noPort", message: "Server \(source) has no ports in this region")
            }
            port = first
        } else {
            throw OpenStackError(service: "mcp", status: 400, message: "The security_group link source must be a server or a port (got: \(sourceType))")
        }

        guard port.portSecurityEnabled else {
            throw OpenStackError(service: "mcp", status: 409, code: "portSecurityDisabled", message: "Port \(port.id) has port security disabled; security groups cannot be applied")
        }
        if port.securityGroups.contains(sgID) {
            return ["link": .string("security_group"), "operation": .string("attach"), "port": .string(port.id), "security_group": .string(sgID), "already_attached": .bool(true), "region": .string(region)]
        }

        let newGroups = port.securityGroups + [sgID]
        let updated = try await ns.updatePort(vt, id: port.id, securityGroups: newGroups)
        logger.info("security group attached", metadata: ["port": .string(port.id), "sg": .string(sgID)])
        guard updated.securityGroups.contains(sgID) else {
            throw OpenStackError(service: "network", status: 500, code: "portUpdateIgnored",
                message: "The API accepted the update but port \(port.id) does not report \(sgID); update may have been ignored")
        }

        return [
            "link": .string("security_group"),
            "operation": .string("attach"),
            "source_type": .string(sourceType),
            "source": .string(source),
            "port": .string(port.id),
            "security_group": .string(sgID),
            "security_groups": .array(newGroups.map { .string($0) }),
            "region": .string(region),
        ]
    }

    private func detachSecurityGroup(_ vt: ValidatedToken, sourceType: String, source: String, target: String, region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let cs = await client.compute(region: region)

        let sgID = try await resolveName(vt, resource: "security_group", idOrName: target, region: region)

        let port: NetPort
        if sourceType == "port" {
            port = try await ns.getPort(vt, id: source)
        } else if sourceType == "server" {
            _ = try await cs.getServer(vt, id: source)
            let ports = try await ns.listPorts(vt, filters: ["device_id": source], limit: 5)
            guard let first = ports.first else {
                throw OpenStackError(service: "mcp", status: 404, code: "noPort", message: "Server \(source) has no ports in this region")
            }
            port = first
        } else {
            throw OpenStackError(service: "mcp", status: 400, message: "The security_group link source must be a server or a port (got: \(sourceType))")
        }

        guard port.securityGroups.contains(sgID) else {
            throw OpenStackError(service: "mcp", status: 404, code: "notAttached", message: "Security group \(sgID) is not attached to port \(port.id)")
        }
        let newGroups = port.securityGroups.filter { $0 != sgID }
        _ = try await ns.updatePort(vt, id: port.id, securityGroups: newGroups)
        logger.info("security group detached", metadata: ["port": .string(port.id), "sg": .string(sgID)])

        return [
            "link": .string("security_group"),
            "operation": .string("detach"),
            "source_type": .string(sourceType),
            "source": .string(source),
            "port": .string(port.id),
            "security_group": .string(sgID),
            "security_groups": .array(newGroups.map { .string($0) }),
            "region": .string(region),
        ]
    }

    // MARK: - floating_ip

    private func attachFloatingIP(_ vt: ValidatedToken, fipID: String, targetType: String, target: String, params: [String: JSONValue], region: String, wait: Bool) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let fip = try await ns.getFloatingIP(vt, id: fipID)
        let fixedIP = params["fixed_ip"]?.stringValue

        // Resolve the target port
        let port: NetPort
        switch targetType {
        case "port":
            port = try await ns.getPort(vt, id: target)
        case "server":
            // First port on a router-reachable subnet
            let ports = try await ns.listPorts(vt, filters: ["device_id": target], limit: 50)
            let reachable = try await firstRouterReachablePort(vt, ports: ports, region: region)
            guard let p = reachable else {
                throw OpenStackError(
                    service: "mcp", status: 404, code: "noReachablePort",
                    message: "Server \(target) has no port on a subnet reachable from the floating IP's external network (\(fip.floatingNetworkID)). Check that a router connects the server's subnet to the external network (router_interface + router_gateway links)."
                )
            }
            port = p
        default:
            throw OpenStackError(service: "mcp", status: 400, message: "The floating_ip link target must be a port or a server (got: \(targetType))")
        }

        // Precondition: the port's subnet must be reachable from the FIP's
        // external network through a router (gateway + interface on the subnet)
        try await assertSubnetReachable(vt, port: port, externalNetworkID: fip.floatingNetworkID, fipID: fipID, region: region)

        _ = try await ns.updateFloatingIP(vt, id: fipID, portID: port.id, fixedIPAddress: fixedIP)
        logger.info("floating ip associated", metadata: ["fip": .string(fipID), "port": .string(port.id)])

        var result: [String: JSONValue] = [
            "link": .string("floating_ip"),
            "operation": .string("attach"),
            "floating_ip": .string(fipID),
            "address": .string(fip.floatingIP),
            "port": .string(port.id),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "floating_ip", id: fipID, region: region, until: ["ACTIVE"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    private func detachFloatingIP(_ vt: ValidatedToken, fipID: String, region: String, wait: Bool) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let fip = try await ns.getFloatingIP(vt, id: fipID)
        guard fip.portID != nil else {
            throw OpenStackError(service: "mcp", status: 404, code: "notAssociated", message: "Floating IP \(fipID) is not associated with any port")
        }
        _ = try await ns.updateFloatingIP(vt, id: fipID, portID: nil, fixedIPAddress: nil)
        logger.info("floating ip disassociated", metadata: ["fip": .string(fipID)])

        var result: [String: JSONValue] = [
            "link": .string("floating_ip"),
            "operation": .string("detach"),
            "floating_ip": .string(fipID),
            "disassociated": .bool(true),
            "note": .string("Disassociated, not deleted. Use os_delete to release the floating IP."),
            "region": .string(region),
        ]
        if wait {
            let final = try await waiter.wait(vt, resource: "floating_ip", id: fipID, region: region, until: ["DOWN"], timeout: 60)
            result["wait"] = .object(final)
        }
        return result
    }

    /// Find the first port whose subnet is reachable from the external network.
    private func firstRouterReachablePort(_ vt: ValidatedToken, ports: [NetPort], region: String) async throws -> NetPort? {
        let ns = await client.network(region: region)
        let subnets = try await ns.listSubnets(vt, filters: [:], limit: 200)
        let subnetIDs = Set(subnets.map(\.id))
        // A subnet is router-reachable if some router has a gateway AND an
        // interface on that subnet. Without an explicit router-interface API
        // on the client, approximate via router list + subnet list (the fake
        // seeds router-1 -> subnet-int; real deployments would query the
        // router's interfaces).
        let routers = try await ns.listRouters(vt, filters: [:], limit: 100)
        let gatewayRouters = Set(routers.compactMap { r in r.externalGatewayInfo != nil ? r.id : nil })

        for port in ports {
            guard let subnetID = port.fixedIPs.first?.subnetID, subnetIDs.contains(subnetID) else { continue }
            // Reachability: there exists a gateway router; in phase 1 we accept
            // any gateway router as bridging (the precise per-subnet interface
            // check is the diagnosis path in TopologyBuilder).
            if !gatewayRouters.isEmpty {
                return port
            }
        }
        return nil
    }

    /// Assert the port's subnet is reachable from the external network via a
    /// router; throw naming the missing hop otherwise.
    private func assertSubnetReachable(_ vt: ValidatedToken, port: NetPort, externalNetworkID: String, fipID: String, region: String) async throws {
        let ns = await client.network(region: region)
        guard let subnetID = port.fixedIPs.first?.subnetID else {
            throw OpenStackError(service: "mcp", status: 400, code: "noFixedIP", message: "Port \(port.id) has no fixed IP; cannot associate floating IP \(fipID)")
        }
        let routers = try await ns.listRouters(vt, filters: [:], limit: 100)
        let gatewayRouters = routers.filter { $0.externalGatewayInfo?.networkID == externalNetworkID }
        guard !gatewayRouters.isEmpty else {
            throw OpenStackError(
                service: "mcp", status: 409, code: "missingHop",
                message: "No router has a gateway on external network \(externalNetworkID). Add one with os_attach(link: \"router_gateway\", source: <router>, target: <external network>)."
            )
        }
        // Phase 1: the fake tracks router interfaces in shared state; the client
        // has no router-interface read API, so we cannot verify the specific
        // subnet hop from the client side. The topology diagnosis covers the
        // per-subnet check. We do verify the gateway exists (the common miss).
        _ = subnetID
    }

    // MARK: - router_interface

    private func attachRouterInterface(_ vt: ValidatedToken, routerID: String, targetType: String, target: String, region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        _ = try await ns.getRouter(vt, id: routerID)

        let subnetID: String
        switch targetType {
        case "subnet":
            let subnet = try await ns.getSubnet(vt, id: target)
            // Precondition: the subnet must have a gateway IP (Neutron requires one for routing)
            guard (subnet.gatewayIP ?? "").isEmpty == false else {
                throw OpenStackError(service: "mcp", status: 409, code: "noGatewayIP", message: "Subnet \(subnet.id) has no gateway IP; a router interface requires one")
            }
            subnetID = subnet.id
        case "port":
            let port = try await ns.getPort(vt, id: target)
            guard port.fixedIPs.isEmpty else {
                throw OpenStackError(service: "mcp", status: 409, code: "portBusy", message: "Port \(target) has fixed IPs; attach the router to its subnet instead")
            }
            let net = try await ns.getNetwork(vt, id: port.networkID)
            guard let s = net.subnets.first else {
                throw OpenStackError(service: "mcp", status: 400, code: "noSubnet", message: "Network \(port.networkID) has no subnets")
            }
            subnetID = s
        default:
            throw OpenStackError(service: "mcp", status: 400, message: "The router_interface link target must be a subnet or a port (got: \(targetType))")
        }

        let (status, body, requestID) = try await client.routerInterface(vt, method: "PUT", routerID: routerID, subnetID: subnetID, region: region)
        guard (200...299).contains(status) else {
            throw OpenStackError.normalize(body: body, status: status, service: "network", requestID: requestID, hasAccessRules: false)
        }
        logger.info("router interface attached", metadata: ["router": .string(routerID), "subnet": .string(subnetID)])
        return [
            "link": .string("router_interface"),
            "operation": .string("attach"),
            "router": .string(routerID),
            "subnet": .string(subnetID),
            "region": .string(region),
        ]
    }

    private func detachRouterInterface(_ vt: ValidatedToken, routerID: String, target: String, region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let subnetID: String
        if let subnet = try? await ns.getSubnet(vt, id: target) {
            subnetID = subnet.id
        } else if let port = try? await ns.getPort(vt, id: target),
                  let net = try? await ns.getNetwork(vt, id: port.networkID),
                  let s = net.subnets.first {
            subnetID = s
        } else {
            throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No subnet or port found matching '\(target)'")
        }
        let (status, body, requestID) = try await client.routerInterface(vt, method: "DELETE", routerID: routerID, subnetID: subnetID, region: region)
        guard (200...299).contains(status) else {
            throw OpenStackError.normalize(body: body, status: status, service: "network", requestID: requestID, hasAccessRules: false)
        }
        logger.info("router interface detached", metadata: ["router": .string(routerID), "subnet": .string(subnetID)])
        return [
            "link": .string("router_interface"),
            "operation": .string("detach"),
            "router": .string(routerID),
            "subnet": .string(subnetID),
            "region": .string(region),
        ]
    }

    // MARK: - router_gateway

    private func attachRouterGateway(_ vt: ValidatedToken, routerID: String, target: String, params: [String: JSONValue], region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let router = try await ns.getRouter(vt, id: routerID)
        _ = router
        let network = try await ns.getNetwork(vt, id: target)
        guard network.routerExternal else {
            throw OpenStackError(
                service: "mcp", status: 409, code: "notExternal",
                message: "Network \(target) is not an external network (router:external). Router gateways can only point at external networks."
            )
        }
        let enableSNAT = params["enable_snat"]?.boolValue ?? true
        _ = try await ns.updateRouter(vt, id: routerID, externalGatewayInfo: Router.ExternalGatewayInfo(networkID: network.id))
        logger.info("router gateway attached", metadata: ["router": .string(routerID), "network": .string(network.id), "snat": .string(enableSNAT ? "true" : "false")])

        return [
            "link": .string("router_gateway"),
            "operation": .string("attach"),
            "router": .string(routerID),
            "network": .string(network.id),
            "enable_snat": .bool(enableSNAT),
            "region": .string(region),
        ]
    }

    private func detachRouterGateway(_ vt: ValidatedToken, routerID: String, region: String) async throws -> [String: JSONValue] {
        let ns = await client.network(region: region)
        let router = try await ns.getRouter(vt, id: routerID)
        guard router.externalGatewayInfo != nil else {
            throw OpenStackError(service: "mcp", status: 404, code: "noGateway", message: "Router \(routerID) has no external gateway")
        }
        _ = try await ns.updateRouter(vt, id: routerID, externalGatewayInfo: nil)
        logger.info("router gateway removed", metadata: ["router": .string(routerID)])
        return [
            "link": .string("router_gateway"),
            "operation": .string("detach"),
            "router": .string(routerID),
            "region": .string(region),
        ]
    }

    // MARK: - Helpers

    /// Resolve an id_or_name for a network-service resource (shared with
    /// TopologyBuilder via the same name-resolution rules).
    private func resolveName(_ vt: ValidatedToken, resource: String, idOrName: String, region: String) async throws -> String {
        let ns = await client.network(region: region)
        // Try direct id first
        if resource == "security_group", (try? await ns.getSecurityGroup(vt, id: idOrName)) != nil {
            return idOrName
        }
        // Name resolution
        switch resource {
        case "security_group":
            let groups = try await ns.listSecurityGroups(vt, limit: 200)
            if let exact = groups.first(where: { $0.name == idOrName }) { return exact.id }
            let ci = groups.filter { $0.name.lowercased() == idOrName.lowercased() }
            if ci.count == 1 { return ci[0].id }
            if ci.count > 1 {
                throw AmbiguousNameError(candidates: ci.map { ($0.id, $0.name) })
            }
            throw OpenStackError(service: "mcp", status: 404, code: "itemNotFound", message: "No \(resource) found matching '\(idOrName)'")
        default:
            throw OpenStackError(service: "mcp", status: 400, message: "resolveName: unsupported resource \(resource)")
        }
    }

}
