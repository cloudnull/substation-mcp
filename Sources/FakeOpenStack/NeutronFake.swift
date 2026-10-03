import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Neutron v2.0 implementation.
///
/// Routes live under `/neutron/v2.0/*`. Every list endpoint supports
/// `limit`/`marker` pagination and emits `_links.next` when more items
/// remain. Errors use the Neutron shape: `{"NeutronError": {"message": ..., "type": ...}}`.
public struct NeutronFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/neutron/v2.0"

        // MARK: - Extension discovery

        router.get("\(base)/extensions") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let aliases = await state.extensions
            let items = aliases.sorted().map {
                "{\"alias\":\"\($0)\",\"name\":\"\($0)\",\"updated\":\"2024-01-01T00:00:00Z\"}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"extensions":[\(items)]}
            """)
        }

        // MARK: - Networks

        router.get("\(base)/networks") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }

            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)

            let networks = await state.listNetworks(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let nextMarker = networks.count == limit ? networks.last?.id : nil
            let items = networks.map { Self.networkJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/networks")
            return Self.jsonResponse(status: .ok, body: """
            {"networks":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/networks/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let net = await state.getNetwork(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Network \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"network":\(Self.networkJSON(net))}
            """)
        }

        router.post("\(base)/networks") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let name = Self.extractString("name", from: body) ?? "net"
            let net = await state.createNetwork(projectID: token.projectID, name: name)
            return Self.jsonResponse(status: .created, body: """
            {"network":\(Self.networkJSON(net))}
            """)
        }

        router.put("\(base)/networks/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let name = Self.extractString("name", from: body)
            guard let net = await state.updateNetwork(id: id, projectID: token.projectID, name: name, shared: nil, adminStateUp: nil) else {
                return Self.notFound(message: "Network \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"network":\(Self.networkJSON(net))}
            """)
        }

        router.delete("\(base)/networks/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteNetwork(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Network \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Subnets

        router.get("\(base)/subnets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let networkID = Self.queryParam("network_id", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)

            let subnets = await state.listSubnets(projectID: token.projectID, networkID: networkID, limit: limit, marker: marker)
            let nextMarker = subnets.count == limit ? subnets.last?.id : nil
            let items = subnets.map { Self.subnetJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/subnets")
            return Self.jsonResponse(status: .ok, body: """
            {"subnets":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/subnets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let subnet = await state.getSubnet(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Subnet \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"subnet":\(Self.subnetJSON(subnet))}
            """)
        }

        router.post("\(base)/subnets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let networkID = Self.extractString("network_id", from: body) ?? ""
            let cidr = Self.extractString("cidr", from: body) ?? ""
            let name = Self.extractString("name", from: body)
            let gateway = Self.extractString("gateway_ip", from: body)
            let enableDHCP = Self.extractBool("enable_dhcp", from: body)

            var pools: [FakeState.FakeAllocationPool] = []
            if let arr = Self.arrayForValue("allocation_pools", in: body) {
                for element in arr {
                    if let s = Self.extractString("start", from: element), let e = Self.extractString("end", from: element) {
                        pools.append(FakeState.FakeAllocationPool(start: s, end: e))
                    }
                }
            }

            let subnet = await state.createSubnet(
                projectID: token.projectID,
                networkID: networkID,
                cidr: cidr,
                ipVersion: 4,
                gateway: gateway,
                name: name,
                enableDHCP: enableDHCP,
                allocationPools: pools
            )
            guard let subnet else {
                return Self.neutronError(status: .badRequest, type: "InvalidInput", message: "Network \(networkID) could not be found.")
            }
            return Self.jsonResponse(status: .created, body: """
            {"subnet":\(Self.subnetJSON(subnet))}
            """)
        }

        router.delete("\(base)/subnets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSubnet(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Subnet \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Ports

        router.get("\(base)/ports") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let networkID = Self.queryParam("network_id", from: req)
            let deviceID = Self.queryParam("device_id", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)

            let ports = await state.listPorts(projectID: token.projectID, networkID: networkID, deviceID: deviceID, limit: limit, marker: marker)
            let nextMarker = ports.count == limit ? ports.last?.id : nil
            let items = ports.map { Self.portJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/ports")
            return Self.jsonResponse(status: .ok, body: """
            {"ports":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/ports/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let port = await state.getPort(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Port \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"port":\(Self.portJSON(port))}
            """)
        }

        router.post("\(base)/ports") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let portBody = Self.objectForKey("port", in: body) ?? body
            let networkID = Self.extractString("network_id", from: portBody) ?? ""
            let name = Self.extractString("name", from: portBody) ?? ""
            let deviceID = Self.extractString("device_id", from: portBody)
            let deviceOwner = Self.extractString("device_owner", from: portBody)
            let adminStateUp = Self.extractBool("admin_state_up", from: portBody) ?? true
            let portSecurityEnabled = Self.extractBool("port_security_enabled", from: portBody) ?? true

            // fixed_ips: [ { "ip_address": "..." , "subnet_id": "..." } | { } ]
            var fixedIPs: [[String: String?]] = []
            if let arr = Self.arrayForValue("fixed_ips", in: portBody) {
                for element in arr {
                    var entry: [String: String?] = ["ip": nil, "subnet": nil]
                    if let ip = Self.extractString("ip_address", from: element) {
                        entry["ip"] = ip
                    }
                    if let subnet = Self.extractString("subnet_id", from: element) {
                        entry["subnet"] = subnet
                    }
                    fixedIPs.append(entry)
                }
            }

            var securityGroups: [String] = []
            if let arr = Self.arrayForValue("security_groups", in: portBody) {
                for element in arr {
                    let s = element.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                    if !s.isEmpty {
                        securityGroups.append(s)
                    }
                }
            }

            var extraDHCPOpts: [FakeState.FakeExtraDHCPOpt] = []
            if let arr = Self.arrayForValue("extra_dhcp_opts", in: portBody) {
                for element in arr {
                    let n = Self.extractString("opt_name", from: element) ?? ""
                    let v = Self.extractString("opt_value", from: element) ?? ""
                    extraDHCPOpts.append(FakeState.FakeExtraDHCPOpt(optName: n, optValue: v))
                }
            }

            let result = await state.createPort(
                projectID: token.projectID,
                networkID: networkID,
                cidrs: [],
                fixedIPs: fixedIPs,
                name: name,
                securityGroups: securityGroups,
                deviceID: deviceID,
                deviceOwner: deviceOwner,
                extraDHCPOpts: extraDHCPOpts,
                adminStateUp: adminStateUp,
                portSecurityEnabled: portSecurityEnabled
            )
            guard let port = result.port else {
                if let inUse = result.inUseIP {
                    return Self.neutronError(status: .conflict, type: "IpAddressInUse", message: "IP address \(inUse) is already in use.")
                }
                return Self.neutronError(status: .badRequest, type: "InvalidInput", message: "Network \(networkID) could not be found.")
            }
            return Self.jsonResponse(status: .created, body: """
            {"port":\(Self.portJSON(port))}
            """)
        }

        router.put("\(base)/ports/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let portBody = Self.objectForKey("port", in: body) ?? body
            let name = Self.extractString("name", from: portBody)
            let adminStateUp = Self.extractBool("admin_state_up", from: portBody)
            var securityGroups: [String]? = nil
            if let arr = Self.arrayForValue("security_groups", in: portBody) {
                // Neutron accepts string arrays and/or id-object arrays; the
                // compactMap below keeps whichever form each element uses.
                securityGroups = arr.compactMap { part -> String? in
                    if part.hasPrefix("\"") {
                        let inner = String(part.dropFirst()).dropLast()
                        return String(inner)
                    }
                    if let obj = Self.objectForKey("id", in: part) {
                        return Self.extractString("id", from: obj)
                    }
                    return Self.extractString("id", from: part)
                }
            }
            guard var port = await state.updatePort(id: id, projectID: token.projectID, name: name, adminStateUp: adminStateUp) else {
                return Self.notFound(message: "Port \(id) could not be found.")
            }
            if let groups = securityGroups {
                port.securityGroups = groups
                _ = await state.setPortSecurityGroups(portID: id, groups: groups, projectID: token.projectID)
            }
            return Self.jsonResponse(status: .ok, body: """
            {"port":\(Self.portJSON(port))}
            """)
        }

        router.delete("\(base)/ports/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deletePort(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Port \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Routers

        router.get("\(base)/routers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let routers = await state.listRouters(projectID: token.projectID, limit: limit, marker: marker)
            let nextMarker = routers.count == limit ? routers.last?.id : nil
            let items = routers.map { Self.routerJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/routers")
            return Self.jsonResponse(status: .ok, body: """
            {"routers":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/routers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let router = await state.getRouter(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Router \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"router":\(Self.routerJSON(router))}
            """)
        }

        router.post("\(base)/routers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let name = Self.extractString("name", from: Self.objectForKey("router", in: body) ?? body) ?? "router"
            let router = await state.createRouter(projectID: token.projectID, name: name)
            return Self.jsonResponse(status: .created, body: """
            {"router":\(Self.routerJSON(router))}
            """)
        }

        router.put("\(base)/routers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let routerBody = Self.objectForKey("router", in: body) ?? body
            let name = Self.extractString("name", from: routerBody)
            let gwObj = Self.objectForKey("external_gateway_info", in: routerBody)
            let externalNetworkID = gwObj.flatMap { Self.extractString("network_id", from: $0) }
            guard let router = await state.updateRouter(id: id, projectID: token.projectID, name: name, externalNetworkID: externalNetworkID) else {
                return Self.notFound(message: "Router \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"router":\(Self.routerJSON(router))}
            """)
        }

        router.put("\(base)/routers/:id/add_router_interface") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let subnetID = Self.extractString("subnet_id", from: body) ?? ""
            guard let router = await state.getRouter(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Router \(id) could not be found.")
            }
            _ = router
            guard await state.getSubnet(id: subnetID, projectID: token.projectID) != nil else {
                return Self.neutronError(status: .notFound, type: "SubnetNotFound", message: "Subnet \(subnetID) could not be found.")
            }
            await state.addRouterInterface(routerID: id, subnetID: subnetID)
            return Response(status: .noContent)
        }

        router.delete("\(base)/routers/:id/remove_router_interface") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let router = await state.getRouter(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Router \(id) could not be found.")
            }
            _ = router
            let subnets = await state.routerInterfaceSubnets(routerID: id)
            for subnetID in subnets {
                await state.removeRouterInterface(routerID: id, subnetID: subnetID)
            }
            return Response(status: .noContent)
        }

        router.delete("\(base)/routers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteRouter(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Router \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Floating IPs

        router.get("\(base)/floatingips") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let fips = await state.listFloatingIPs(projectID: token.projectID, limit: limit, marker: marker)
            let nextMarker = fips.count == limit ? fips.last?.id : nil
            let items = fips.map { Self.floatingIPJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/floatingips")
            return Self.jsonResponse(status: .ok, body: """
            {"floatingips":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/floatingips/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let fip = await state.getFloatingIP(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "FloatingIP \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"floatingip":\(Self.floatingIPJSON(fip))}
            """)
        }

        router.post("\(base)/floatingips") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let floatingNetworkID = Self.extractString("floating_network_id", from: Self.objectForKey("floatingip", in: body) ?? body) ?? "net-ext"
            let fip = await state.createFloatingIP(projectID: token.projectID, floatingNetworkID: floatingNetworkID)
            return Self.jsonResponse(status: .created, body: """
            {"floatingip":\(Self.floatingIPJSON(fip))}
            """)
        }

        router.put("\(base)/floatingips/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let fipBody = Self.objectForKey("floatingip", in: body) ?? body
            let portID = Self.extractString("port_id", from: fipBody)
            let fixedIPAddress = Self.extractString("fixed_ip_address", from: fipBody)
            guard let fip = await state.updateFloatingIP(id: id, projectID: token.projectID, portID: portID, fixedIPAddress: fixedIPAddress) else {
                return Self.notFound(message: "FloatingIP \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"floatingip":\(Self.floatingIPJSON(fip))}
            """)
        }

        router.delete("\(base)/floatingips/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteFloatingIP(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "FloatingIP \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Security groups

        router.get("\(base)/security-groups") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let groups = await state.listSecurityGroups(projectID: token.projectID, limit: limit, marker: marker)
            let nextMarker = groups.count == limit ? groups.last?.id : nil
            let items = groups.map { Self.securityGroupJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/security-groups")
            return Self.jsonResponse(status: .ok, body: """
            {"security_groups":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/security-groups/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let group = await state.getSecurityGroup(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Security group \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"security_group":\(Self.securityGroupJSON(group))}
            """)
        }

        router.post("\(base)/security-groups") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let sgBody = Self.objectForKey("security_group", in: body) ?? body
            let name = Self.extractString("name", from: sgBody) ?? "sg"
            let description = Self.extractString("description", from: sgBody) ?? ""
            let group = await state.createSecurityGroup(projectID: token.projectID, name: name, description: description)
            return Self.jsonResponse(status: .created, body: """
            {"security_group":\(Self.securityGroupJSON(group))}
            """)
        }

        router.delete("\(base)/security-groups/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSecurityGroup(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Security group \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Security group rules

        router.get("\(base)/security-group-rules") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let securityGroupID = Self.queryParam("security_group_id", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let rules = await state.listSecurityGroupRules(projectID: token.projectID, securityGroupID: securityGroupID, limit: limit, marker: marker)
            let nextMarker = rules.count == limit ? rules.last?.id : nil
            let items = rules.map { Self.securityGroupRuleJSON($0) }
            let links = Self.linksJSON(nextMarker: nextMarker, path: "\(base)/security-group-rules")
            return Self.jsonResponse(status: .ok, body: """
            {"security_group_rules":[\(items.joined(separator: ","))],"_links":\(links)}
            """)
        }

        router.get("\(base)/security-group-rules/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let rule = await state.getSecurityGroupRule(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Security group rule \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"security_group_rule":\(Self.securityGroupRuleJSON(rule))}
            """)
        }

        router.post("\(base)/security-group-rules") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let body = try await Self.readBody(req)
            let ruleBody = Self.objectForKey("security_group_rule", in: body) ?? body
            let securityGroupID = Self.extractString("security_group_id", from: ruleBody) ?? ""
            guard await state.getSecurityGroup(id: securityGroupID, projectID: token.projectID) != nil else {
                return Self.neutronError(status: .badRequest, type: "InvalidInput", message: "Security group \(securityGroupID) could not be found.")
            }
            let direction = Self.extractString("direction", from: ruleBody) ?? "ingress"
            let ethertype = Self.extractString("ethertype", from: ruleBody) ?? "IPv4"
            let protocol_ = Self.extractString("protocol", from: ruleBody)
            let portRangeMin = Self.extractInt("port_range_min", from: ruleBody)
            let portRangeMax = Self.extractInt("port_range_max", from: ruleBody)
            let remoteIPPrefix = Self.extractString("remote_ip_prefix", from: ruleBody)
            let rule = await state.createSecurityGroupRule(
                projectID: token.projectID,
                securityGroupID: securityGroupID,
                direction: direction,
                ethertype: ethertype,
                ipProtocol: protocol_,
                portRangeMin: portRangeMin,
                portRangeMax: portRangeMax,
                remoteIPPrefix: remoteIPPrefix
            )
            return Self.jsonResponse(status: .created, body: """
            {"security_group_rule":\(Self.securityGroupRuleJSON(rule))}
            """)
        }

        router.delete("\(base)/security-group-rules/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSecurityGroupRule(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Security group rule \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Address groups (extension-gated)

        router.get("\(base)/address-groups") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            guard (await state.extensions).contains("address-group") else {
                return Self.neutronError(status: .notFound, type: "ResourceNotFound", message: "The resource could not be found.")
            }
            let groups = await state.listAddressGroups(projectID: token.projectID)
            let items = groups.map { Self.addressGroupJSON($0) }
            return Self.jsonResponse(status: .ok, body: """
            {"address_groups":[\(items.joined(separator: ","))]}
            """)
        }

        router.get("\(base)/address-groups/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            guard (await state.extensions).contains("address-group") else {
                return Self.neutronError(status: .notFound, type: "ResourceNotFound", message: "The resource could not be found.")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let group = await state.getAddressGroup(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Address group \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"address_group":\(Self.addressGroupJSON(group))}
            """)
        }

        router.post("\(base)/address-groups") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            guard (await state.extensions).contains("address-group") else {
                return Self.neutronError(status: .notFound, type: "ResourceNotFound", message: "The resource could not be found.")
            }
            let body = try await Self.readBody(req)
            let agBody = Self.objectForKey("address_group", in: body) ?? body
            let name = Self.extractString("name", from: agBody) ?? "group"
            let description = Self.extractString("description", from: agBody) ?? ""
            let group = await state.createAddressGroup(projectID: token.projectID, name: name, description: description)
            return Self.jsonResponse(status: .created, body: """
            {"address_group":\(Self.addressGroupJSON(group))}
            """)
        }

        router.delete("\(base)/address-groups/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            guard (await state.extensions).contains("address-group") else {
                return Self.neutronError(status: .notFound, type: "ResourceNotFound", message: "The resource could not be found.")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteAddressGroup(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Address group \(id) could not be found.")
            }
            return Response(status: .noContent)
        }

        // MARK: - Quota

        router.get("\(base)/quota/:projectId") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            let pid = ctx.parameters.get("projectId") ?? ""
            return Self.jsonResponse(status: .ok, body: """
            {"quota":{"project_id":"\(pid)","network":10,"subnet":10,"port":50,"security_group":10,"security_group_rule":100,"floatingip":10,"router":10}}
            """)
        }

        router.put("\(base)/quota/:projectId") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.neutronError(status: .unauthorized, type: "Unauthorized", message: "Unauthorized")
            }
            _ = req
            let pid = ctx.parameters.get("projectId") ?? ""
            return Self.jsonResponse(status: .ok, body: """
            {"quota":{"project_id":"\(pid)","network":10,"subnet":10,"port":50,"security_group":10,"security_group_rule":100,"floatingip":10,"router":10}}
            """)
        }
    }

    // MARK: - Request helpers

    static func queryParam(_ key: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(key)].map { String($0) }
    }

    static func readBody(_ req: Request) async throws -> String {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Minimal JSON object helpers (avoid Foundation JSON parsing in handlers)

    /// Returns the raw text of the object `{...}` stored under `key`, if present.
    static func objectForKey(_ key: String, in json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard afterColon.hasPrefix("{") else { return nil }
        return matchBraces(afterColon[afterColon.startIndex...])
    }

    /// Returns the raw text of the array `[...]` stored under `key`, if present.
    static func arrayForValue(_ key: String, in json: String) -> [String]? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard afterColon.hasPrefix("[") else { return nil }
        // Find the matching closing bracket by tracking depth
        var depth = 0
        var foundEnd: String.Index? = nil
        for (idx, ch) in afterColon.enumerated() {
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    foundEnd = afterColon.index(afterColon.startIndex, offsetBy: idx)
                    break
                }
            }
        }
        guard let end = foundEnd else { return nil }
        let innerStart = afterColon.index(afterColon.startIndex, offsetBy: 1)
        return Self.splitTopLevel(String(afterColon[innerStart..<end]))
    }

    /// Splits a raw array interior (without the outer brackets) into
    /// top-level elements, respecting nested `{...}` / `[...]` depth.
    static func splitTopLevel(_ inner: String) -> [String] {
        var elements: [String] = []
        var depth = 0
        var current = ""
        for ch in inner {
            if ch == "{" || ch == "[" { depth += 1 }
            if ch == "}" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 {
                elements.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            elements.append(current)
        }
        return elements
    }

    /// Extract a string value for `key` from a raw JSON object string.
    static func extractString(_ key: String, from json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("\"") {
            let rest = afterColon.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[rest.startIndex..<close])
        }
        // number/bool/null
        let stop = afterColon.firstIndex(where: { $0 == "," || $0 == "}" || $0 == "]" || $0 == " " || $0 == "\n" }) ?? afterColon.endIndex
        let value = String(afterColon[afterColon.startIndex..<stop])
        if value == "null" { return nil }
        return value
    }

    static func extractInt(_ key: String, from json: String) -> Int? {
        extractString(key, from: json).flatMap { Int($0) }
    }

    static func extractBool(_ key: String, from json: String) -> Bool? {
        guard let v = extractString(key, from: json) else { return nil }
        if v == "true" { return true }
        if v == "false" { return false }
        return nil
    }

    /// Given a string starting with `{`, returns the balanced object text.
    private static func matchBraces(_ s: Substring) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        for (i, ch) in s.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(s[s.startIndex..<s.index(s.startIndex, offsetBy: i + 1)])
                }
            }
        }
        return nil
    }

    // MARK: - JSON builders

    static func networkJSON(_ net: FakeState.FakeNetwork) -> String {
        let subnetsJSON = net.subnets.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(net.id)","name":"\(net.name)","admin_state_up":true,"status":"\(net.status)","shared":false,"provider":null,"project_id":"\(net.projectID)","router:external":\(net.routerExternal),"port_security_enabled":true,"subnets":[\(subnetsJSON)]}
        """
    }

    static func subnetJSON(_ subnet: FakeState.FakeSubnet) -> String {
        let gateway = subnet.gatewayIP.map { "\"\($0)\"" } ?? "null"
        let pools = subnet.allocationPools.map { p in
            "{\"start\":\"\(p.start)\",\"end\":\"\(p.end)\"}"
        }.joined(separator: ",")
        return """
        {"id":"\(subnet.id)","name":"\(subnet.name)","network_id":"\(subnet.networkID)","cidr":"\(subnet.cidr)","ip_version":4,"gateway_ip":\(gateway),"enable_dhcp":\(subnet.enableDHCP ? "true" : "false"),"allocation_pools":[\(pools)],"project_id":"\(subnet.projectID)"}
        """
    }

    static func portJSON(_ port: FakeState.FakePort) -> String {
        let fixedIPs = port.fixedIPs.map { ip in
            "{\"subnet_id\":\"\(ip.subnetID)\",\"ip_address\":\"\(ip.ip)\"}"
        }.joined(separator: ",")
        let secGroups = port.securityGroups.map { "\"\($0)\"" }.joined(separator: ",")
        let deviceID = port.deviceID.map { "\"\($0)\"" } ?? "null"
        let deviceOwner = port.deviceOwner.map { "\"\($0)\"" } ?? "null"
        let dhcpOpts = port.extraDHCPOpts.map { opt in
            "{\"opt_name\":\"\(opt.optName)\",\"opt_value\":\"\(opt.optValue)\"}"
        }.joined(separator: ",")
        var parts: [String] = []
        parts.append("\"id\":\"\(port.id)\"")
        parts.append("\"name\":\"\(port.name)\"")
        parts.append("\"status\":\"\(port.status)\"")
        parts.append("\"admin_state_up\":\(port.adminStateUp)")
        parts.append("\"network_id\":\"\(port.networkID)\"")
        parts.append("\"fixed_ips\":[\(fixedIPs)]")
        parts.append("\"security_groups\":[\(secGroups)]")
        parts.append("\"device_id\":\(deviceID)")
        parts.append("\"device_owner\":\(deviceOwner)")
        parts.append("\"extra_dhcp_opts\":[\(dhcpOpts)]")
        parts.append("\"port_security_enabled\":\(port.portSecurityEnabled)")
        parts.append("\"project_id\":\"\(port.projectID)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func routerJSON(_ router: FakeState.FakeRouter) -> String {
        let gw: String
        if let external = router.externalNetworkID {
            gw = "{\"network_id\":\"\(external)\"}"
        } else {
            gw = "null"
        }
        return """
        {"id":"\(router.id)","name":"\(router.name)","status":"\(router.status)","external_gateway_info":\(gw),"project_id":"\(router.projectID)"}
        """
    }

    static func floatingIPJSON(_ fip: FakeState.FakeFloatingIP) -> String {
        let portID = fip.portID.map { "\"\($0)\"" } ?? "null"
        let fixedIP = fip.fixedIPAddress.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(fip.id)","floating_ip_address":"\(fip.floatingIP)","floating_network_id":"\(fip.floatingNetworkID)","port_id":\(portID),"fixed_ip_address":\(fixedIP),"status":"\(fip.status)","project_id":"\(fip.projectID)"}
        """
    }

    static func securityGroupJSON(_ group: FakeState.FakeSecurityGroup) -> String {
        return """
        {"id":"\(group.id)","name":"\(group.name)","description":"\(group.description)","project_id":"\(group.projectID)"}
        """
    }

    static func securityGroupRuleJSON(_ rule: FakeState.FakeSecurityGroupRule) -> String {
        let protocol_ = rule.ipProtocol.map { "\"\($0)\"" } ?? "null"
        let portMin = rule.portRangeMin.map { "\($0)" } ?? "null"
        let portMax = rule.portRangeMax.map { "\($0)" } ?? "null"
        let remote = rule.remoteIPPrefix.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(rule.id)","security_group_id":"\(rule.securityGroupID)","direction":"\(rule.direction)","ethertype":"\(rule.ethertype)","protocol":\(protocol_),"port_range_min":\(portMin),"port_range_max":\(portMax),"remote_ip_prefix":\(remote),"project_id":"\(rule.projectID)"}
        """
    }

    static func addressGroupJSON(_ group: FakeState.FakeAddressGroup) -> String {
        let id = group.id.map { "\"\($0)\"" } ?? "null"
        let addresses = group.addresses.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":\(id),"name":"\(group.name)","description":"\(group.description)","addresses":[\(addresses)],"project_id":"\(group.projectID)"}
        """
    }

    static func linksJSON(nextMarker: String?, path: String) -> String {
        if let nextMarker {
            return "{\"next\":{\"rel\":\"next\",\"href\":\"\(path)?marker=\(nextMarker)\"}}"
        }
        return "{}"
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func notFound(message: String) -> Response {
        neutronError(status: .notFound, type: "ItemNotFound", message: message)
    }

    static func neutronError(status: HTTPResponse.Status, type: String, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: """
            {"NeutronError":{"message":"\(message)","type":"\(type)"}}
            """))
        )
    }
}
