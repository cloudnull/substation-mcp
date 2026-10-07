import Foundation
import OpenStackClient

/// Thrown when an `id_or_name` value matches multiple resources.
/// The error description lists each candidate with its ID and name
/// (spec §8.2).
public struct AmbiguousNameError: Error, Sendable, CustomStringConvertible {
    public let candidates: [(id: String, name: String)]

    public init(candidates: [(id: String, name: String)]) {
        self.candidates = candidates
    }

    public var description: String {
        let list = candidates
            .map { c in "id=\(c.id) name=\(c.name)" }
            .joined(separator: ", ")
        return "Ambiguous name: \(candidates.count) matches found: \(list)"
    }
}

/// Resolves `id_or_name` values to concrete resource IDs.
///
/// Resolution order (spec §8.2):
/// 1. Exact ID match — `get` by ID; if 404, it's not an ID.
/// 2. Exact name filter — `list` with `filters[nameField] = name`.
/// 3. Case-insensitive scan of listed names.
///
/// ≥2 matches → `AmbiguousNameError`. 0 matches → `OpenStackError` (404).
public actor NameResolver {
    private let catalog: ResourceCatalog
    private let client: OpenStackClient

    public init(catalog: ResourceCatalog, client: OpenStackClient) {
        self.catalog = catalog
        self.client = client
    }

    /// Resolve an `id_or_name` value to a concrete (id, raw JSON) pair.
    public func resolve(
        _ vt: ValidatedToken,
        descriptor: ResourceDescriptor,
        idOrName: String,
        region: String
    ) async throws -> (id: String, raw: [String: JSONValue]) {
        // 1. Exact ID match
        do {
            let raw = try await get(vt: vt, descriptor: descriptor, id: idOrName, region: region)
            return (idOrName, raw)
        } catch {
            // Not found by ID — fall through to name resolution
        }

        // 2 & 3. Name-based resolution
        guard let nameField = descriptor.nameField else {
            throw OpenStackError(
                service: descriptor.service.rawValue,
                status: 404,
                code: "itemNotFound",
                message: "No \(descriptor.name) found matching '\(idOrName)'"
            )
        }

        // 2. Exact name filter
        do {
            let result = try await list(vt: vt, descriptor: descriptor, filters: [nameField: idOrName], limit: 2, region: region)
            if let items = result["items"]?.arrayValue, items.count == 1,
               let item = items[0].objectValue,
               let id = item[descriptor.idField]?.stringValue {
                return (id, item)
            }
            // If ≥2 matches, fall through to step 3 which will detect ambiguity
        } catch {
            // Name filter failed — fall through to case-insensitive scan
        }

        // 3. Case-insensitive scan
        let result = try await list(vt: vt, descriptor: descriptor, filters: [:], limit: 500, region: region)
        guard let items = result["items"]?.arrayValue else {
            throw OpenStackError(
                service: descriptor.service.rawValue,
                status: 404,
                code: "itemNotFound",
                message: "No \(descriptor.name) found matching '\(idOrName)'"
            )
        }

        let nameLower = idOrName.lowercased()
        let matches: [(id: String, name: String)] = items.compactMap { item in
            guard let obj = item.objectValue else { return nil }
            guard let name = obj[nameField]?.stringValue, name.lowercased() == nameLower else { return nil }
            guard let id = obj[descriptor.idField]?.stringValue else { return nil }
            return (id: id, name: name)
        }

        switch matches.count {
        case 0:
            throw OpenStackError(
                service: descriptor.service.rawValue,
                status: 404,
                code: "itemNotFound",
                message: "No \(descriptor.name) found matching '\(idOrName)'"
            )
        case 1:
            let match = matches[0]
            do {
                let raw = try await get(vt: vt, descriptor: descriptor, id: match.id, region: region)
                return (match.id, raw)
            } catch {
                return (match.id, [descriptor.idField: .string(match.id), nameField: .string(match.name)])
            }
        default:
            throw AmbiguousNameError(candidates: matches)
        }
    }

    /// Public list method for the ToolRegistry to call directly.
    public func listPublic(
        _ vt: ValidatedToken,
        descriptor: ResourceDescriptor,
        filters: [String: String],
        limit: Int?,
        marker: String?,
        region: String
    ) async throws -> [String: JSONValue] {
        try await list(vt: vt, descriptor: descriptor, filters: filters, limit: limit ?? 200, region: region)
    }

    // MARK: - Dispatch helpers

    private func get(vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async throws -> [String: JSONValue] {
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                let s = try await r.getServer(vt, id: id)
                return try Self.encodeObject(s)
            case "flavor":
                let f = try await r.getFlavor(vt, id: id)
                return try Self.encodeObject(f)
            case "keypair":
                // No get-by-id for keypairs; use the name as the ID
                let kps = try await r.listKeypairs(vt)
                guard let k = kps.first(where: { $0.name == id }) else {
                    throw OpenStackError(service: "compute", status: 404, code: "itemNotFound", message: "Keypair '\(id)' not found")
                }
                return try Self.encodeObject(k)
            case "compute_quota":
                // Project-scoped; the quota set's id is the project id, so
                // the requested id is honored only as a project sanity check.
                let q = try await r.getQuotaSet(vt)
                var result = try Self.encodeObject(q)
                result["id"] = .string(id)
                return result
            case "server_interface":
                // Server-scoped. The id is a port id; optionally narrow to a
                // single server by passing the server id as the id.
                let matches: [ServerInterface]
                if let ifaces = try? await r.listServerInterfaces(vt, serverID: id) {
                    matches = ifaces
                } else {
                    // Not a server id: scan every server for the port id.
                    let servers = try await r.listServers(vt)
                    var found: [ServerInterface] = []
                    for s in servers {
                        if let ifaces = try? await r.listServerInterfaces(vt, serverID: s.id),
                           let match = ifaces.first(where: { $0.portID == id }) {
                            found.append(match)
                        }
                    }
                    matches = found
                }
                guard let match = matches.first else {
                    throw OpenStackError(service: "compute", status: 404, code: "itemNotFound", message: "Interface '\(id)' not found")
                }
                if matches.count > 1 {
                    throw AmbiguousNameError(candidates: matches.map { (id: $0.portID, name: $0.portID) })
                }
                return try Self.encodeObject(match)
            case "server_volume_attachment":
                // Server-scoped. The id is a volume id; optionally narrow to a
                // single server by passing the server id as the id.
                let matches: [ServerVolumeAttachment]
                if let vols = try? await r.listServerVolumeAttachments(vt, serverID: id) {
                    matches = vols
                } else {
                    // Not a server id: scan every server for the volume id.
                    let servers = try await r.listServers(vt)
                    var found: [ServerVolumeAttachment] = []
                    for s in servers {
                        if let vols = try? await r.listServerVolumeAttachments(vt, serverID: s.id),
                           let match = vols.first(where: { $0.volumeID == id }) {
                            found.append(match)
                        }
                    }
                    matches = found
                }
                guard let match = matches.first else {
                    throw OpenStackError(service: "compute", status: 404, code: "itemNotFound", message: "Volume attachment for '\(id)' not found")
                }
                if matches.count > 1 {
                    throw AmbiguousNameError(candidates: matches.map { (id: $0.volumeID, name: $0.volumeID) })
                }
                return try Self.encodeObject(match)
            default:
                throw OpenStackError(service: "compute", status: 404, message: "Unknown compute resource: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "network":
                let n = try await r.getNetwork(vt, id: id)
                return try Self.encodeObject(n)
            case "subnet":
                let s = try await r.getSubnet(vt, id: id)
                return try Self.encodeObject(s)
            case "port":
                let p = try await r.getPort(vt, id: id)
                return try Self.encodeObject(p)
            case "router":
                let rt = try await r.getRouter(vt, id: id)
                return try Self.encodeObject(rt)
            case "floating_ip":
                let f = try await r.getFloatingIP(vt, id: id)
                return try Self.encodeObject(f)
            case "security_group":
                let sg = try await r.getSecurityGroup(vt, id: id)
                return try Self.encodeObject(sg)
            case "address_group":
                let ag = try await r.getAddressGroup(vt, id: id)
                return try Self.encodeObject(ag)
            default:
                throw OpenStackError(service: "network", status: 404, message: "Unknown network resource: \(descriptor.name)")
            }
        case .blockStorage:
            let r = await client.blockStorage(region: region)
            switch descriptor.name {
            case "volume":
                let v = try await r.getVolume(vt, id: id)
                return try Self.encodeObject(v)
            case "volume_type":
                let vt = try await r.getVolumeType(vt, id: id)
                return try Self.encodeObject(vt)
            case "volume_snapshot":
                let s = try await r.getSnapshot(vt, id: id)
                return try Self.encodeObject(s)
            case "volume_backup":
                let b = try await r.getBackup(vt, id: id)
                return try Self.encodeObject(b)
            case "volume_quota":
                // Project-scoped; the quota has no per-item id, so echo the
                // requested id back for consistency with the resolve() contract.
                let q = try await r.getQuota(vt)
                var result = try Self.encodeObject(q)
                result["id"] = .string(id)
                return result
            default:
                throw OpenStackError(service: "volumev3", status: 404, message: "Unknown volume resource: \(descriptor.name)")
            }
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image":
                let i = try await r.getImage(vt, id: id)
                return try Self.encodeObject(i)
            default:
                throw OpenStackError(service: "image", status: 404, message: "Unknown image resource: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity resources not resolvable in phase 1")
        case .objectStorage:
            let r = await client.objectStorage(region: region)
            switch descriptor.name {
            case "container":
                let c = try await r.getContainer(vt, name: id)
                return try Self.encodeObject(c)
            case "object":
                // Objects are container-scoped; `id` is the object name. Resolve
                // by scanning the project's containers for a uniquely-named object.
                let ctns = try await r.listContainers(vt)
                var found: [Object] = []
                for ctn in ctns {
                    if let obj = try? await r.getObject(vt, container: ctn.name, name: id) {
                        found.append(obj)
                    }
                }
                switch found.count {
                case 0:
                    throw OpenStackError(service: "object-store", status: 404, code: "itemNotFound", message: "No object named '\(id)' found")
                case 1:
                    return try Self.encodeObject(found[0])
                default:
                    throw AmbiguousNameError(candidates: found.map { (id: $0.name, name: $0.name) })
                }
            default:
                throw OpenStackError(service: "object-store", status: 404, message: "Unknown object-storage resource: \(descriptor.name)")
            }
        case .keyManager:
            let r = await client.keyManager(region: region)
            switch descriptor.name {
            case "secret":
                let s = try await r.getSecret(vt, id: id)
                return try Self.encodeObject(s)
            case "secret_container":
                let c = try await r.getContainer(vt, id: id)
                return try Self.encodeObject(c)
            default:
                throw OpenStackError(service: "key-manager", status: 404, message: "Unknown key-manager resource: \(descriptor.name)")
            }
        case .loadBalancer:
            let r = await client.loadBalancer(region: region)
            switch descriptor.name {
            case "load_balancer":
                let lb = try await r.getLoadBalancer(vt, id: id)
                return try Self.encodeObject(lb)
            case "listener":
                let l = try await r.getListener(vt, id: id)
                return try Self.encodeObject(l)
            case "pool":
                let p = try await r.getPool(vt, id: id)
                return try Self.encodeObject(p)
            case "member":
                let m = try await r.getMember(vt, id: id)
                return try Self.encodeObject(m)
            case "health_monitor":
                let h = try await r.getHealthMonitor(vt, id: id)
                return try Self.encodeObject(h)
            default:
                throw OpenStackError(service: "loadbalancer", status: 404, message: "Unknown load-balancer resource: \(descriptor.name)")
            }
        case .dns:
            let r = await client.dns(region: region)
            switch descriptor.name {
            case "zone":
                let z = try await r.getZone(vt, id: id)
                return try Self.encodeObject(z)
            case "recordset":
                let rs = try await r.getRecordSet(vt, id: id)
                return try Self.encodeObject(rs)
            default:
                throw OpenStackError(service: "dns", status: 404, message: "Unknown dns resource: \(descriptor.name)")
            }
        case .containerInfra:
            let r = await client.containerInfra(region: region)
            switch descriptor.name {
            case "cluster":
                let c = try await r.getContainer(vt, id: id)
                return try Self.encodeObject(c)
            case "cluster_template":
                let t = try await r.getClusterTemplate(vt, id: id)
                return try Self.encodeObject(t)
            default:
                throw OpenStackError(service: "container", status: 404, message: "Unknown container resource: \(descriptor.name)")
            }
        case .orchestration:
            let r = await client.orchestration(region: region)
            switch descriptor.name {
            case "stack":
                let s = try await r.getStack(vt, id: id)
                return try Self.encodeObject(s)
            default:
                throw OpenStackError(service: "orchestration", status: 404, message: "Unknown orchestration resource: \(descriptor.name)")
            }
        case .sharev2:
            let r = await client.share(region: region)
            switch descriptor.name {
            case "share":
                let s = try await r.getShare(vt, id: id)
                return try Self.encodeObject(s)
            case "share_access":
                // Share access is share-scoped; the `id` here is the access id.
                // Resolve by scanning the project's shares for one carrying it.
                let shares = try await r.listShares(vt)
                var found: ShareAccess? = nil
                for sh in shares {
                    if let a = try? await r.getShareAccess(vt, shareID: sh.id, id: id) {
                        found = a
                        break
                    }
                }
                guard let a = found else {
                    throw OpenStackError(service: "sharev2", status: 404, code: "itemNotFound", message: "Share access '\(id)' not found")
                }
                return try Self.encodeObject(a)
            default:
                throw OpenStackError(service: "sharev2", status: 404, message: "Unknown share resource: \(descriptor.name)")
            }
        case .placement:
            let r = await client.placement(region: region)
            switch descriptor.name {
            case "placement":
                // The id is the resource provider's uuid. Merge the provider
                // with its inventories (totals) and usages (allocated) so a
                // single os_get call returns the host's full inventory.
                let rp = try await r.getResourceProvider(vt, uuid: id)
                var obj = try Self.encodeObject(rp)
                if let inv = try? await r.getInventories(vt, uuid: id) {
                    let invObj = try Self.encodeObject(inv)
                    obj["inventory"] = invObj["resources"] ?? .object(invObj)
                }
                if let usg = try? await r.getUsages(vt, uuid: id) {
                    let usgObj = try Self.encodeObject(usg)
                    obj["usages"] = usgObj["resources"] ?? .object(usgObj)
                }
                return obj
            default:
                throw OpenStackError(service: "placement", status: 404, message: "Unknown placement resource: \(descriptor.name)")
            }
        }
    }

    private func list(vt: ValidatedToken, descriptor: ResourceDescriptor, filters: [String: String], limit: Int, region: String) async throws -> [String: JSONValue] {
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                let servers = try await r.listServers(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(servers)
                result["resource"] = .string("server")
                result["region"] = .string(region)
                return result
            case "flavor":
                let flavors = try await r.listFlavors(vt)
                var result: [String: JSONValue] = try Self.encodeList(flavors)
                result["resource"] = .string("flavor")
                result["region"] = .string(region)
                return result
            case "keypair":
                let kps = try await r.listKeypairs(vt)
                var result: [String: JSONValue] = try Self.encodeList(kps)
                result["resource"] = .string("keypair")
                result["region"] = .string(region)
                return result
            case "server_group":
                let sgs = try await r.listServerGroups(vt)
                var result: [String: JSONValue] = try Self.encodeList(sgs)
                result["resource"] = .string("server_group")
                result["region"] = .string(region)
                return result
            case "availability_zone":
                let azs = try await r.listAvailabilityZones(vt)
                var result: [String: JSONValue] = try Self.encodeList(azs)
                result["resource"] = .string("availability_zone")
                result["region"] = .string(region)
                return result
            case "hypervisor":
                let hvs = try await r.listHypervisors(vt)
                var result: [String: JSONValue] = try Self.encodeList(hvs)
                result["resource"] = .string("hypervisor")
                result["region"] = .string(region)
                return result
            case "compute_service":
                let cs = try await r.listComputeServices(vt)
                var result: [String: JSONValue] = try Self.encodeList(cs)
                result["resource"] = .string("compute_service")
                result["region"] = .string(region)
                return result
            case "server_interface":
                // Per-server resource: flatten interfaces across all
                // servers (optionally narrowed by a server_id filter).
                let servers = try await r.listServers(vt, filters: filters, limit: limit)
                var all: [ServerInterface] = []
                for s in servers {
                    if let ifaces = try? await r.listServerInterfaces(vt, serverID: s.id) {
                        all.append(contentsOf: ifaces)
                    }
                }
                var result: [String: JSONValue] = try Self.encodeList(all)
                result["resource"] = .string("server_interface")
                result["region"] = .string(region)
                return result
            case "server_volume_attachment":
                // Per-server resource: flatten volume attachments across all
                // servers (optionally narrowed by a server_id filter).
                let servers = try await r.listServers(vt, filters: filters, limit: limit)
                var all: [ServerVolumeAttachment] = []
                for s in servers {
                    if let vols = try? await r.listServerVolumeAttachments(vt, serverID: s.id) {
                        all.append(contentsOf: vols)
                    }
                }
                var result: [String: JSONValue] = try Self.encodeList(all)
                result["resource"] = .string("server_volume_attachment")
                result["region"] = .string(region)
                return result
            case "compute_quota":
                let q = try await r.getQuotaSet(vt)
                var result: [String: JSONValue] = try Self.encodeList([q])
                result["resource"] = .string("compute_quota")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "compute", status: 404, message: "Unknown compute resource: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "network":
                let nets = try await r.listNetworks(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(nets)
                result["resource"] = .string("network")
                result["region"] = .string(region)
                return result
            case "port":
                let ports = try await r.listPorts(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(ports)
                result["resource"] = .string("port")
                result["region"] = .string(region)
                return result
            case "subnet":
                let subnets = try await r.listSubnets(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(subnets)
                result["resource"] = .string("subnet")
                result["region"] = .string(region)
                return result
            case "router":
                let rts = try await r.listRouters(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(rts)
                result["resource"] = .string("router")
                result["region"] = .string(region)
                return result
            case "floating_ip":
                let fips = try await r.listFloatingIPs(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(fips)
                result["resource"] = .string("floating_ip")
                result["region"] = .string(region)
                return result
            case "security_group":
                let sgs = try await r.listSecurityGroups(vt, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(sgs)
                result["resource"] = .string("security_group")
                result["region"] = .string(region)
                return result
            case "security_group_rule":
                let sgrs = try await r.listSecurityGroupRules(vt, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(sgrs)
                result["resource"] = .string("security_group_rule")
                result["region"] = .string(region)
                return result
            case "address_group":
                let ags = try await r.listAddressGroups(vt)
                var result: [String: JSONValue] = try Self.encodeList(ags)
                result["resource"] = .string("address_group")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "network", status: 404, message: "Unknown network resource: \(descriptor.name)")
            }
        case .blockStorage:
            let r = await client.blockStorage(region: region)
            switch descriptor.name {
            case "volume":
                let vols = try await r.listVolumes(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(vols)
                result["resource"] = .string("volume")
                result["region"] = .string(region)
                return result
            case "volume_type":
                let vts = try await r.listVolumeTypes(vt)
                var result: [String: JSONValue] = try Self.encodeList(vts)
                result["resource"] = .string("volume_type")
                result["region"] = .string(region)
                return result
            case "volume_snapshot":
                let snaps = try await r.listSnapshots(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(snaps)
                result["resource"] = .string("volume_snapshot")
                result["region"] = .string(region)
                return result
            case "volume_backup":
                let bks = try await r.listBackups(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(bks)
                result["resource"] = .string("volume_backup")
                result["region"] = .string(region)
                return result
            case "volume_quota":
                let q = try await r.getQuota(vt)
                var result: [String: JSONValue] = try Self.encodeList([q])
                result["resource"] = .string("volume_quota")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "volumev3", status: 404, message: "Unknown volume resource: \(descriptor.name)")
            }
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image":
                let images = try await r.listImages(vt, filters: filters, limit: limit)
                var result: [String: JSONValue] = try Self.encodeList(images)
                result["resource"] = .string("image")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "image", status: 404, message: "Unknown image resource: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity resources not resolvable in phase 1")
        case .objectStorage:
            let r = await client.objectStorage(region: region)
            switch descriptor.name {
            case "container":
                let ctns = try await r.listContainers(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(ctns)
                result["resource"] = .string("container")
                result["region"] = .string(region)
                return result
            case "object":
                // Object listing is container-scoped. With a `container` filter,
                // list objects in that container; without one, flatten objects
                // across all containers (each tagged with its container name).
                if let ctn = filters["container"] {
                    let objs = try await r.listObjects(vt, container: ctn, filters: filters, limit: limit, marker: filters["marker"])
                    var result: [String: JSONValue] = try Self.encodeList(objs)
                    result["resource"] = .string("object")
                    result["region"] = .string(region)
                    return result
                }
                let ctns = try await r.listContainers(vt, limit: limit)
                var all: [Object] = []
                for c in ctns {
                    all.append(contentsOf: (try? await r.listObjects(vt, container: c.name, limit: limit)) ?? [])
                }
                var result: [String: JSONValue] = try Self.encodeList(all)
                result["resource"] = .string("object")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "object-store", status: 404, message: "Unknown object-storage resource: \(descriptor.name)")
            }
        case .keyManager:
            let r = await client.keyManager(region: region)
            switch descriptor.name {
            case "secret":
                let secs = try await r.listSecrets(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(secs)
                result["resource"] = .string("secret")
                result["region"] = .string(region)
                return result
            case "secret_container":
                let ctns = try await r.listContainers(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(ctns)
                result["resource"] = .string("secret_container")
                result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "key-manager", status: 404, message: "Unknown key-manager resource: \(descriptor.name)")
            }
        case .loadBalancer:
            let r = await client.loadBalancer(region: region)
            switch descriptor.name {
            case "load_balancer":
                let items = try await r.listLoadBalancers(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("load_balancer"); result["region"] = .string(region)
                return result
            case "listener":
                let items = try await r.listListeners(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("listener"); result["region"] = .string(region)
                return result
            case "pool":
                let items = try await r.listPools(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("pool"); result["region"] = .string(region)
                return result
            case "member":
                let items = try await r.listMembers(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("member"); result["region"] = .string(region)
                return result
            case "health_monitor":
                let items = try await r.listHealthMonitors(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("health_monitor"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "loadbalancer", status: 404, message: "Unknown load-balancer resource: \(descriptor.name)")
            }
        case .dns:
            let r = await client.dns(region: region)
            switch descriptor.name {
            case "zone":
                let items = try await r.listZones(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("zone"); result["region"] = .string(region)
                return result
            case "recordset":
                let items = try await r.listRecordSets(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("recordset"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "dns", status: 404, message: "Unknown dns resource: \(descriptor.name)")
            }
        case .containerInfra:
            let r = await client.containerInfra(region: region)
            switch descriptor.name {
            case "cluster":
                let items = try await r.listContainers(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("cluster"); result["region"] = .string(region)
                return result
            case "cluster_template":
                let items = try await r.listClusterTemplates(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("cluster_template"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "container", status: 404, message: "Unknown container resource: \(descriptor.name)")
            }
        case .orchestration:
            let r = await client.orchestration(region: region)
            switch descriptor.name {
            case "stack":
                let items = try await r.listStacks(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("stack"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "orchestration", status: 404, message: "Unknown orchestration resource: \(descriptor.name)")
            }
        case .sharev2:
            let r = await client.share(region: region)
            switch descriptor.name {
            case "share":
                let items = try await r.listShares(vt, filters: filters, limit: limit, marker: filters["marker"])
                var result: [String: JSONValue] = try Self.encodeList(items)
                result["resource"] = .string("share"); result["region"] = .string(region)
                return result
            case "share_access":
                // Access rows are share-scoped. With a share_id filter, list
                // that share's access; otherwise flatten access across all
                // shares in the project (each tagged with its share id).
                if let shareID = filters["share_id"] {
                    let items = try await r.listShareAccess(vt, shareID: shareID, filters: filters, limit: limit, marker: filters["marker"])
                    var result: [String: JSONValue] = try Self.encodeList(items)
                    result["resource"] = .string("share_access"); result["region"] = .string(region)
                    return result
                }
                let shares = try await r.listShares(vt, limit: limit)
                var all: [ShareAccess] = []
                for sh in shares {
                    all.append(contentsOf: (try? await r.listShareAccess(vt, shareID: sh.id, limit: limit)) ?? [])
                }
                var result: [String: JSONValue] = try Self.encodeList(all)
                result["resource"] = .string("share_access"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "sharev2", status: 404, message: "Unknown share resource: \(descriptor.name)")
            }
        case .placement:
            let r = await client.placement(region: region)
            switch descriptor.name {
            case "placement":
                let nameFilter = filters["name"]
                // Placement API does not accept a `limit` query param —
                // it only supports `name`, `marker`, and `type`.
                let rps = try await r.listResourceProviders(vt, name: nameFilter)
                var result: [String: JSONValue] = try Self.encodeList(rps)
                result["resource"] = .string("placement"); result["region"] = .string(region)
                return result
            default:
                throw OpenStackError(service: "placement", status: 404, message: "Unknown placement resource: \(descriptor.name)")
            }
        }
    }

    // MARK: - Public mutation methods (for ToolRegistry)

    public func createPublic(_ vt: ValidatedToken, descriptor: ResourceDescriptor, body: JSONValue, region: String) async throws -> [String: JSONValue] {
        guard let obj = body.objectValue else {
            throw OpenStackError(service: "mcp", status: 400, message: "Create body must be an object")
        }
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                let name = obj["name"]?.stringValue
                let flavorID = obj["flavor"]?.stringValue ?? obj["flavorID"]?.stringValue
                let imageID = obj["image"]?.stringValue ?? obj["imageID"]?.stringValue
                guard let name, let flavorID, let imageID else {
                    throw OpenStackError(service: "compute", status: 400, message: "Server create requires name, flavor, image")
                }
                // Optional fields from the create schema
                let keyName = obj["key_name"]?.stringValue ?? obj["keyName"]?.stringValue
                let availabilityZone = obj["availability_zone"]?.stringValue ?? obj["availabilityZone"]?.stringValue
                let configDrive = obj["config_drive"]?.boolValue
                let metadata = obj["metadata"]?.objectValue?.reduce(into: [String: String]()) { $0[$1.key] = $1.value.stringValue ?? "" } ?? [:]
                let networks = obj["networks"]?.arrayValue?.compactMap { entry -> CreateServerSpec.NetworkSpec? in
                    guard let netObj = entry.objectValue else { return nil }
                    return CreateServerSpec.NetworkSpec(
                        port: netObj["port"]?.stringValue,
                        network: netObj["network"]?.stringValue ?? netObj["uuid"]?.stringValue,
                        fixedIP: netObj["fixed_ip"]?.stringValue ?? netObj["fixedIP"]?.stringValue
                    )
                } ?? []
                let userData = obj["user_data"]?.stringValue ?? obj["userData"]?.stringValue
                let serverGroup = obj["server_group"]?.stringValue ?? obj["serverGroup"]?.stringValue
                let hostname = obj["hostname"]?.stringValue

                let spec = CreateServerSpec(
                    name: name, flavorID: flavorID, imageID: imageID,
                    keyName: keyName, availabilityZone: availabilityZone,
                    configDrive: configDrive, metadata: metadata,
                    networks: networks, userData: userData,
                    serverGroup: serverGroup, hostname: hostname
                )
                let s = try await r.createServer(vt, spec)
                return try Self.encodeObject(s)
            case "keypair":
                let name = obj["name"]?.stringValue
                let publicKey = obj["public_key"]?.stringValue
                guard let name else { throw OpenStackError(service: "compute", status: 400, message: "Keypair create requires name") }
                let kp = try await r.createKeyPair(vt, name: name, publicKey: publicKey)
                return try Self.encodeObject(kp)
            default:
                throw OpenStackError(service: "compute", status: 400, message: "Unknown compute create: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "network":
                let name = obj["name"]?.stringValue ?? "mcp-net"
                let spec = CreateNetworkSpec(name: name)
                let n = try await r.createNetwork(vt, spec)
                return try Self.encodeObject(n)
            case "subnet":
                let networkID = obj["network_id"]?.stringValue
                let cidr = obj["cidr"]?.stringValue
                guard let networkID, let cidr else {
                    throw OpenStackError(service: "network", status: 400, message: "Subnet create requires network_id and cidr")
                }
                let spec = CreateSubnetSpec(networkID: networkID, cidr: cidr, name: obj["name"]?.stringValue)
                let s = try await r.createSubnet(vt, spec)
                return try Self.encodeObject(s)
            case "port":
                let networkID = obj["network_id"]?.stringValue
                guard let networkID else { throw OpenStackError(service: "network", status: 400, message: "Port create requires network_id") }
                let name = obj["name"]?.stringValue ?? ""
                let spec = CreatePortSpec(networkID: networkID, name: name)
                let p = try await r.createPort(vt, spec)
                return try Self.encodeObject(p)
            case "router":
                let name = obj["name"]?.stringValue ?? "mcp-router"
                let spec = CreateRouterSpec(name: name)
                let rt = try await r.createRouter(vt, spec)
                return try Self.encodeObject(rt)
            case "floating_ip":
                let networkID = obj["floating_network_id"]?.stringValue
                guard let networkID else { throw OpenStackError(service: "network", status: 400, message: "Floating IP create requires floating_network_id") }
                let spec = CreateFloatingIPSpec(floatingNetworkID: networkID)
                let f = try await r.createFloatingIP(vt, spec)
                return try Self.encodeObject(f)
            case "security_group":
                let name = obj["name"]?.stringValue ?? "mcp-sg"
                let spec = CreateSecurityGroupSpec(name: name, description: obj["description"]?.stringValue ?? "")
                let sg = try await r.createSecurityGroup(vt, spec)
                return try Self.encodeObject(sg)
            case "security_group_rule":
                let securityGroupID = obj["security_group_id"]?.stringValue
                guard let securityGroupID else {
                    throw OpenStackError(service: "network", status: 400, message: "Security group rule create requires security_group_id")
                }
                let rule = try await r.createSecurityGroupRule(
                    vt,
                    securityGroupID: securityGroupID,
                    direction: obj["direction"]?.stringValue ?? "ingress",
                    ethertype: obj["ethertype"]?.stringValue ?? "IPv4",
                    ipProtocol: obj["protocol"]?.stringValue ?? obj["ip_protocol"]?.stringValue,
                    portRangeMin: obj["port_range_min"]?.intValue,
                    portRangeMax: obj["port_range_max"]?.intValue,
                    remoteIPPrefix: obj["remote_ip_prefix"]?.stringValue
                )
                return try Self.encodeObject(rule)
            case "address_group":
                let name = obj["name"]?.stringValue
                guard let name else {
                    throw OpenStackError(service: "network", status: 400, message: "Address group create requires name")
                }
                let spec = CreateAddressGroupSpec(
                    name: name,
                    description: obj["description"]?.stringValue ?? "",
                    addresses: obj["ip_addresses"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                )
                let ag = try await r.createAddressGroup(vt, spec)
                return try Self.encodeObject(ag)
            default:
                throw OpenStackError(service: "network", status: 400, message: "Unknown network create: \(descriptor.name)")
            }
        case .blockStorage:
            let r = await client.blockStorage(region: region)
            switch descriptor.name {
            case "volume":
                let size = obj["size"]?.intValue ?? 1
                let name = obj["name"]?.stringValue ?? "mcp-vol"
                let volType = obj["volume_type"]?.stringValue ?? ""
                let spec = CreateVolumeSpec(name: name, size: size, volumeType: volType)
                let v = try await r.createVolume(vt, spec)
                return try Self.encodeObject(v)
            default:
                throw OpenStackError(service: "volumev3", status: 400, message: "Unknown volume create: \(descriptor.name)")
            }
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image":
                let name = obj["name"]?.stringValue ?? "mcp-image"
                let spec = CreateImageSpec(name: name)
                let img = try await r.createImage(vt, spec)
                return try Self.encodeObject(img)
            default:
                throw OpenStackError(service: "image", status: 400, message: "Unknown image create: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity resources not creatable in phase 1")
        case .objectStorage:
            let r = await client.objectStorage(region: region)
            switch descriptor.name {
            case "container":
                let name = obj["name"]?.stringValue ?? "mcp-container"
                let spec = CreateContainerSpec(name: name, quotaBytes: obj["quota_bytes"]?.intValue)
                let c = try await r.createContainer(vt, spec)
                return try Self.encodeObject(c)
            case "object":
                let container = obj["container"]?.stringValue
                let name = obj["name"]?.stringValue ?? "mcp-object"
                guard let container else {
                    throw OpenStackError(service: "object-store", status: 400, message: "object create requires a 'container'")
                }
                let content = obj["content"]?.stringValue ?? ""
                let spec = CreateObjectSpec(container: container, name: name, content: content, contentType: obj["content_type"]?.stringValue ?? "application/octet-stream")
                let o = try await r.createObject(vt, spec)
                return try Self.encodeObject(o)
            default:
                throw OpenStackError(service: "object-store", status: 400, message: "Unknown object-storage create: \(descriptor.name)")
            }
        case .keyManager:
            let r = await client.keyManager(region: region)
            switch descriptor.name {
            case "secret":
                let spec = CreateSecretSpec(
                    name: obj["name"]?.stringValue,
                    type: obj["type"]?.stringValue ?? "opaque",
                    algorithm: obj["algorithm"]?.stringValue,
                    bit_size: obj["bit_size"]?.intValue,
                    mode: obj["mode"]?.stringValue,
                    secret: obj["secret"]?.stringValue,
                    visibility: obj["visibility"]?.stringValue
                )
                let s = try await r.createSecret(vt, spec)
                return try Self.encodeObject(s)
            default:
                throw OpenStackError(service: "key-manager", status: 400, message: "Unknown key-manager create: \(descriptor.name)")
            }
        case .loadBalancer:
            let r = await client.loadBalancer(region: region)
            switch descriptor.name {
            case "load_balancer":
                let spec = CreateLoadBalancerSpec(
                    name: obj["name"]?.stringValue,
                    vip_subnet_id: obj["vip_subnet_id"]?.stringValue,
                    vip_address: obj["vip_address"]?.stringValue,
                    description: obj["description"]?.stringValue,
                    flavor_id: obj["flavor_id"]?.stringValue
                )
                return try Self.encodeObject(try await r.createLoadBalancer(vt, spec))
            case "listener":
                let spec = CreateListenerSpec(
                    name: obj["name"]?.stringValue,
                    protocolName: obj["protocol"]?.stringValue ?? "HTTP",
                    protocol_port: obj["protocol_port"]?.intValue ?? 80,
                    load_balancer_id: obj["load_balancer_id"]?.stringValue,
                    connection_limit: obj["connection_limit"]?.intValue
                )
                return try Self.encodeObject(try await r.createListener(vt, spec))
            case "pool":
                let spec = CreatePoolSpec(
                    name: obj["name"]?.stringValue,
                    protocolName: obj["protocol"]?.stringValue ?? "HTTP",
                    lb_algorithm: obj["lb_algorithm"]?.stringValue ?? "ROUND_ROBIN",
                    load_balancer_id: obj["load_balancer_id"]?.stringValue,
                    health_monitor_id: obj["health_monitor_id"]?.stringValue
                )
                return try Self.encodeObject(try await r.createPool(vt, spec))
            case "member":
                guard let addr = obj["protocol_address"]?.stringValue, let port = obj["protocol_port"]?.intValue else {
                    throw OpenStackError(service: "loadbalancer", status: 400, message: "member create requires protocol_address and protocol_port")
                }
                let spec = CreateMemberSpec(
                    name: obj["name"]?.stringValue,
                    protocol_address: addr,
                    protocol_port: port,
                    weight: obj["weight"]?.intValue,
                    admin_state_up: obj["admin_state_up"]?.boolValue,
                    pool_id: obj["pool_id"]?.stringValue
                )
                return try Self.encodeObject(try await r.createMember(vt, spec))
            case "health_monitor":
                let spec = CreateHealthMonitorSpec(
                    name: obj["name"]?.stringValue,
                    type: obj["type"]?.stringValue ?? "PING",
                    delay: obj["delay"]?.intValue,
                    timeout: obj["timeout"]?.intValue,
                    max_retries: obj["max_retries"]?.intValue,
                    pool_id: obj["pool_id"]?.stringValue
                )
                return try Self.encodeObject(try await r.createHealthMonitor(vt, spec))
            default:
                throw OpenStackError(service: "loadbalancer", status: 400, message: "Unknown load-balancer create: \(descriptor.name)")
            }
        case .dns:
            let r = await client.dns(region: region)
            switch descriptor.name {
            case "zone":
                guard let name = obj["name"]?.stringValue else {
                    throw OpenStackError(service: "dns", status: 400, message: "zone create requires a 'name'")
                }
                let spec = CreateZoneSpec(name: name, email: obj["email"]?.stringValue, ttl: obj["ttl"]?.intValue)
                return try Self.encodeObject(try await r.createZone(vt, spec))
            case "recordset":
                guard let name = obj["name"]?.stringValue, let type = obj["type"]?.stringValue else {
                    throw OpenStackError(service: "dns", status: 400, message: "recordset create requires 'name' and 'type'")
                }
                let records = obj["records"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let spec = CreateRecordSetSpec(zone_id: obj["zone_id"]?.stringValue, name: name, type: type, ttl: obj["ttl"]?.intValue, records: records)
                return try Self.encodeObject(try await r.createRecordSet(vt, spec))
            default:
                throw OpenStackError(service: "dns", status: 400, message: "Unknown dns create: \(descriptor.name)")
            }
        case .containerInfra:
            let r = await client.containerInfra(region: region)
            switch descriptor.name {
            case "cluster":
                guard let name = obj["name"]?.stringValue else {
                    throw OpenStackError(service: "container", status: 400, message: "cluster create requires a 'name'")
                }
                let spec = CreateMagnumClusterSpec(
                    name: name,
                    cluster_template_id: obj["cluster_template_id"]?.stringValue,
                    master_count: obj["master_count"]?.intValue,
                    node_count: obj["node_count"]?.intValue,
                    server_group: obj["server_group"]?.stringValue
                )
                return try Self.encodeObject(try await r.createContainer(vt, spec))
            case "cluster_template":
                guard let name = obj["name"]?.stringValue else {
                    throw OpenStackError(service: "container", status: 400, message: "cluster_template create requires a 'name'")
                }
                let spec = CreateMagnumClusterTemplateSpec(
                    name: name,
                    master_count: obj["master_count"]?.intValue ?? 1,
                    node_count: obj["node_count"]?.intValue ?? 0
                )
                return try Self.encodeObject(try await r.createClusterTemplate(vt, spec))
            default:
                throw OpenStackError(service: "container", status: 400, message: "Unknown container create: \(descriptor.name)")
            }
        case .orchestration:
            let r = await client.orchestration(region: region)
            switch descriptor.name {
            case "stack":
                guard let name = obj["name"]?.stringValue, let template = obj["template"]?.stringValue else {
                    throw OpenStackError(service: "orchestration", status: 400, message: "stack create requires 'name' and 'template'")
                }
                let parameters = obj["parameters"]?.objectValue?.reduce(into: [String: String]()) { acc, kv in
                    acc[kv.key] = kv.value.stringValue ?? ""
                } ?? [:]
                let spec = CreateStackSpec(name: name, template: template, parameters: parameters, description: obj["description"]?.stringValue)
                return try Self.encodeObject(try await r.createStack(vt, spec))
            default:
                throw OpenStackError(service: "orchestration", status: 400, message: "Unknown orchestration create: \(descriptor.name)")
            }
        case .sharev2:
            let r = await client.share(region: region)
            switch descriptor.name {
            case "share":
                guard let name = obj["name"]?.stringValue else {
                    throw OpenStackError(service: "sharev2", status: 400, message: "share create requires a 'name'")
                }
                let spec = CreateShareSpec(
                    name: name,
                    share_size: obj["share_size"]?.intValue ?? 1,
                    share_type: obj["share_type"]?.stringValue ?? "generic",
                    description: obj["description"]?.stringValue,
                    is_public: obj["is_public"]?.boolValue
                )
                return try Self.encodeObject(try await r.createShare(vt, spec))
            case "share_access":
                guard let shareID = obj["share_id"]?.stringValue, let accessTo = obj["access_to"]?.stringValue else {
                    throw OpenStackError(service: "sharev2", status: 400, message: "share_access create requires 'share_id' and 'access_to'")
                }
                let spec = CreateShareAccessSpec(
                    share_id: shareID,
                    access_to: accessTo,
                    access_type: obj["access_type"]?.stringValue ?? "ip",
                    access_protocol: obj["access_protocol"]?.stringValue ?? "nfs"
                )
                return try Self.encodeObject(try await r.createShareAccess(vt, spec))
            default:
                throw OpenStackError(service: "sharev2", status: 400, message: "Unknown share create: \(descriptor.name)")
            }
        case .placement:
            // Resource providers are host-scoped and not creatable via this
            // MCP surface (the Placement API only allows it as an admin with
            // generation control).
            throw OpenStackError(service: "placement", status: 400, message: "Placement resource providers are not creatable (host-scoped, admin-only)")
        }
    }

    public func updatePublic(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, body: JSONValue, region: String) async throws -> [String: JSONValue] {
        guard let obj = body.objectValue else {
            throw OpenStackError(service: "mcp", status: 400, message: "Update body must be an object")
        }
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                let name = obj["name"]?.stringValue
                let s = try await r.updateServer(vt, id: id, name: name)
                return try Self.encodeObject(s)
            default:
                throw OpenStackError(service: "compute", status: 400, message: "Unknown compute update: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "network":
                let n = try await r.updateNetwork(vt, id: id, .init(name: obj["name"]?.stringValue))
                return try Self.encodeObject(n)
            case "port":
                let p = try await r.updatePort(vt, id: id, name: obj["name"]?.stringValue)
                return try Self.encodeObject(p)
            case "router":
                let rt = try await r.updateRouter(vt, id: id, name: obj["name"]?.stringValue)
                return try Self.encodeObject(rt)
            case "floating_ip":
                let f = try await r.updateFloatingIP(vt, id: id, portID: obj["port_id"]?.stringValue)
                return try Self.encodeObject(f)
            default:
                throw OpenStackError(service: "network", status: 400, message: "Unknown network update: \(descriptor.name)")
            }
        case .blockStorage:
            throw OpenStackError(service: "volumev3", status: 400, message: "Volume update not supported (use os_action for extend/retype)")
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image":
                let img = try await r.updateImage(vt, id: id, name: obj["name"]?.stringValue)
                return try Self.encodeObject(img)
            default:
                throw OpenStackError(service: "image", status: 400, message: "Unknown image update: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity resources not updatable in phase 1")
        case .objectStorage:
            // Swift containers/objects have no partial-update path in phase 2.
            throw OpenStackError(service: "object-store", status: 501, message: "Object-storage resources are not updatable (re-create instead)")
        case .keyManager:
            // Barbican secrets/containers are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "key-manager", status: 501, message: "Key-manager resources are not updatable (re-create instead)")
        case .loadBalancer:
            // Octavia resources are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "loadbalancer", status: 501, message: "Load-balancer resources are not updatable (re-create instead)")
        case .dns:
            // Designate zones/recordsets are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "dns", status: 501, message: "DNS resources are not updatable (re-create instead)")
        case .containerInfra:
            // Magnum clusters/templates are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "container", status: 501, message: "Container resources are not updatable (re-create instead)")
        case .orchestration:
            // Heat stacks are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "orchestration", status: 501, message: "Orchestration resources are not updatable (re-create instead)")
        case .sharev2:
            // Manila shares/access are immutable in phase 2 (re-create instead).
            throw OpenStackError(service: "sharev2", status: 501, message: "Share resources are not updatable (re-create instead)")
        case .placement:
            // Resource provider inventory is reported by the hypervisor agent
            // and cannot be updated through this MCP surface.
            throw OpenStackError(service: "placement", status: 501, message: "Placement resource providers are not updatable (inventory is agent-reported)")
        }
    }

    public func deletePublic(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, region: String) async throws -> [String: JSONValue] {
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                try await r.deleteServer(vt, id: id)
            case "keypair":
                try await r.deleteKeyPair(vt, name: id)
            default:
                throw OpenStackError(service: "compute", status: 400, message: "Unknown compute delete: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "network": try await r.deleteNetwork(vt, id: id)
            case "subnet": try await r.deleteSubnet(vt, id: id)
            case "port": try await r.deletePort(vt, id: id)
            case "router": try await r.deleteRouter(vt, id: id)
            case "floating_ip": try await r.deleteFloatingIP(vt, id: id)
            case "security_group": try await r.deleteSecurityGroup(vt, id: id)
            default: throw OpenStackError(service: "network", status: 400, message: "Unknown network delete: \(descriptor.name)")
            }
        case .blockStorage:
            let r = await client.blockStorage(region: region)
            switch descriptor.name {
            case "volume": try await r.deleteVolume(vt, id: id)
            case "volume_type": try await r.deleteVolumeType(vt, id: id)
            case "volume_snapshot": try await r.deleteSnapshot(vt, id: id)
            case "volume_backup": try await r.deleteBackup(vt, id: id)
            default: throw OpenStackError(service: "volumev3", status: 400, message: "Unknown volume delete: \(descriptor.name)")
            }
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image": try await r.deleteImage(vt, id: id)
            default: throw OpenStackError(service: "image", status: 400, message: "Unknown image delete: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity resources not deletable in phase 1")
        case .objectStorage:
            let r = await client.objectStorage(region: region)
            switch descriptor.name {
            case "container":
                try await r.deleteContainer(vt, name: id)
            case "object":
                // Object delete is container-scoped; `id` is the object name.
                // Resolve the (unique) container holding it, then delete.
                let ctns = try await r.listContainers(vt)
                var target: String? = nil
                for ctn in ctns {
                    if (try? await r.getObject(vt, container: ctn.name, name: id)) != nil {
                        if target != nil {
                            throw AmbiguousNameError(candidates: [(id: id, name: id), (id: id, name: id)])
                        }
                        target = ctn.name
                    }
                }
                guard let ctn = target else {
                    throw OpenStackError(service: "object-store", status: 404, code: "itemNotFound", message: "No object named '\(id)' found")
                }
                try await r.deleteObject(vt, container: ctn, name: id)
            default:
                throw OpenStackError(service: "object-store", status: 400, message: "Unknown object-storage delete: \(descriptor.name)")
            }
        case .keyManager:
            let r = await client.keyManager(region: region)
            switch descriptor.name {
            case "secret":
                try await r.deleteSecret(vt, id: id)
            case "secret_container":
                try await r.deleteContainer(vt, id: id)
            default:
                throw OpenStackError(service: "key-manager", status: 400, message: "Unknown key-manager delete: \(descriptor.name)")
            }
        case .loadBalancer:
            let r = await client.loadBalancer(region: region)
            switch descriptor.name {
            case "load_balancer":
                try await r.deleteLoadBalancer(vt, id: id)
            case "listener":
                try await r.deleteListener(vt, id: id)
            case "pool":
                try await r.deletePool(vt, id: id)
            case "member":
                try await r.deleteMember(vt, id: id)
            case "health_monitor":
                try await r.deleteHealthMonitor(vt, id: id)
            default:
                throw OpenStackError(service: "loadbalancer", status: 400, message: "Unknown load-balancer delete: \(descriptor.name)")
            }
        case .dns:
            let r = await client.dns(region: region)
            switch descriptor.name {
            case "zone":
                try await r.deleteZone(vt, id: id)
            case "recordset":
                try await r.deleteRecordSet(vt, id: id)
            default:
                throw OpenStackError(service: "dns", status: 400, message: "Unknown dns delete: \(descriptor.name)")
            }
        case .containerInfra:
            let r = await client.containerInfra(region: region)
            switch descriptor.name {
            case "cluster":
                try await r.deleteContainer(vt, id: id)
            case "cluster_template":
                try await r.deleteClusterTemplate(vt, id: id)
            default:
                throw OpenStackError(service: "container", status: 400, message: "Unknown container delete: \(descriptor.name)")
            }
        case .orchestration:
            let r = await client.orchestration(region: region)
            switch descriptor.name {
            case "stack":
                try await r.deleteStack(vt, id: id)
            default:
                throw OpenStackError(service: "orchestration", status: 400, message: "Unknown orchestration delete: \(descriptor.name)")
            }
        case .sharev2:
            let r = await client.share(region: region)
            switch descriptor.name {
            case "share":
                try await r.deleteShare(vt, id: id)
            case "share_access":
                // Access rows are share-scoped; resolve the owning share by scanning.
                let shares = try await r.listShares(vt)
                var ownedShareID: String? = nil
                for sh in shares {
                    if let a = try? await r.getShareAccess(vt, shareID: sh.id, id: id), a.id == id {
                        ownedShareID = sh.id
                        break
                    }
                }
                guard let sid = ownedShareID else {
                    throw OpenStackError(service: "sharev2", status: 404, code: "itemNotFound", message: "Share access '\(id)' not found")
                }
                try await r.deleteShareAccess(vt, shareID: sid, id: id)
            default:
                throw OpenStackError(service: "sharev2", status: 400, message: "Unknown share delete: \(descriptor.name)")
            }
        case .placement:
            // Deleting a resource provider is an admin operation that detaches
            // live hosts from the scheduler; not exposed through this surface.
            throw OpenStackError(service: "placement", status: 400, message: "Placement resource providers are not deletable through this surface")
        }
        return ["deleted": .bool(true), "id": .string(id)]
    }

    public func actionPublic(_ vt: ValidatedToken, descriptor: ResourceDescriptor, id: String, action: String, params: [String: JSONValue], region: String) async throws -> [String: JSONValue] {
        switch descriptor.service {
        case .compute:
            let r = await client.compute(region: region)
            switch descriptor.name {
            case "server":
                let serverAction: ServerAction
                switch action {
                case "start": serverAction = .start
                case "stop": serverAction = .stop
                case "reboot": serverAction = .reboot(soft: !(params["hard"]?.boolValue ?? false))
                case "pause": serverAction = .pause
                case "unpause": serverAction = .unpause
                case "suspend": serverAction = .suspend
                case "resume": serverAction = .resume
                case "lock": serverAction = .lock
                case "unlock": serverAction = .unlock
                case "shelve": serverAction = .shelve
                case "unshelve": serverAction = .unshelve
                case "rescue": serverAction = .rescue
                case "unrescue": serverAction = .unrescue
                case "resize":
                    let flavorID = params["flavor_id"]?.stringValue ?? params["flavorRef"]?.stringValue
                    guard let flavorID else { throw OpenStackError(service: "compute", status: 400, message: "Resize requires flavor_id") }
                    serverAction = .resize(flavorID: flavorID)
                case "confirm_resize": serverAction = .confirmResize
                case "revert_resize": serverAction = .revertResize
                case "rebuild":
                    let imageID = params["imageRef"]?.stringValue
                    guard let imageID else { throw OpenStackError(service: "compute", status: 400, message: "Rebuild requires imageRef") }
                    serverAction = .rebuild(imageID: imageID, adminPassword: params["adminPass"]?.stringValue)
                case "snapshot":
                    let name = params["name"]?.stringValue ?? "\(id)-snap"
                    serverAction = .snapshot(name: name)
                case "console_output": serverAction = .consoleOutput(lines: params["lines"]?.intValue ?? 20)
                case "console_url": serverAction = .consoleURL(type: params["type"]?.stringValue ?? "serial")
                case "add_security_group":
                    let sgID = params["security_group_id"]?.stringValue
                    guard let sgID else { throw OpenStackError(service: "compute", status: 400, message: "add_security_group requires security_group_id") }
                    serverAction = .addSecurityGroup(id: sgID)
                case "remove_security_group":
                    let sgID = params["security_group_id"]?.stringValue
                    guard let sgID else { throw OpenStackError(service: "compute", status: 400, message: "remove_security_group requires security_group_id") }
                    serverAction = .removeSecurityGroup(id: sgID)
                case "evacuate": serverAction = .evacuate
                case "live_migrate": serverAction = .liveMigrate
                case "migrate": serverAction = .migrate
                default:
                    throw OpenStackError(service: "compute", status: 400, message: "Unknown server action: \(action)")
                }
                // Console actions return a payload (console object / output
                // string) rather than 202-no-body, so they take a dedicated
                // client path that decodes the response (spec §12: console
                // urls are returned only to the requesting session).
                if action == "console_url" {
                    let type = params["type"]?.stringValue ?? "novnc"
                    let console = try await r.getConsole(vt, id, type: type)
                    return [
                        "action": .string("console_url"),
                        "id": .string(id),
                        "console": .object([
                            "type": .string(console.type),
                            "url": .string(console.url),
                        ]),
                    ]
                }
                if action == "console_output" {
                    let lines = params["lines"]?.intValue ?? 20
                    let output = try await r.getConsoleOutput(vt, id, lines: lines)
                    return ["action": .string("console_output"), "id": .string(id), "output": .string(output)]
                }
                let result = try await r.action(vt, id, serverAction)
                if let s = result {
                    return try Self.encodeObject(s)
                }
                return ["action": .string(action), "id": .string(id), "status": .string("accepted")]
            default:
                throw OpenStackError(service: "compute", status: 400, message: "Unknown compute action resource: \(descriptor.name)")
            }
        case .blockStorage:
            let r = await client.blockStorage(region: region)
            switch descriptor.name {
            case "volume":
                switch action {
                case "extend":
                    let newSize = params["new_size"]?.intValue ?? params["size"]?.intValue
                    guard let newSize else { throw OpenStackError(service: "volumev3", status: 400, message: "Extend requires new_size") }
                    let vol = try await r.extendVolume(vt, id: id, size: newSize)
                    return try Self.encodeObject(vol)
                case "retype":
                    let newType = params["new_volume_type"]?.stringValue
                    guard let newType else { throw OpenStackError(service: "volumev3", status: 400, message: "Retype requires new_volume_type") }
                    let vol = try await r.retypeVolume(vt, id: id, volumeType: newType)
                    return try Self.encodeObject(vol)
                case "set_bootable":
                    let vol = try await r.setBootable(vt, id: id, bootable: params["bootable"]?.boolValue ?? true)
                    return try Self.encodeObject(vol)
                case "upload_to_image":
                    let imageRef = try await r.uploadToImage(vt, id: id)
                    return ["action": .string("upload_to_image"), "id": .string(id), "image_ref": .string(imageRef)]
                case "reset_status":
                    throw OpenStackError(service: "volumev3", status: 501, message: "reset_status not yet implemented in client")
                default:
                    throw OpenStackError(service: "volumev3", status: 400, message: "Unknown volume action: \(action)")
                }
            default:
                throw OpenStackError(service: "volumev3", status: 400, message: "Unknown blockStorage action resource: \(descriptor.name)")
            }
        case .network:
            let r = await client.network(region: region)
            switch descriptor.name {
            case "router":
                switch action {
                case "add_router_interface":
                    throw OpenStackError(service: "network", status: 501, message: "add_router_interface not yet in client — use os_update on the router or the Neutron API directly")
                case "remove_router_interface":
                    throw OpenStackError(service: "network", status: 501, message: "remove_router_interface not yet in client — use os_update on the router or the Neutron API directly")
                case "set_gateway":
                    let networkID = params["network_id"]?.stringValue
                    guard let networkID else { throw OpenStackError(service: "network", status: 400, message: "set_gateway requires network_id") }
                    let gw = Router.ExternalGatewayInfo(networkID: networkID)
                    let rt = try await r.updateRouter(vt, id: id, externalGatewayInfo: gw)
                    return try Self.encodeObject(rt)
                case "clear_gateway":
                    let rt = try await r.updateRouter(vt, id: id, externalGatewayInfo: nil)
                    return try Self.encodeObject(rt)
                default:
                    throw OpenStackError(service: "network", status: 400, message: "Unknown router action: \(action)")
                }
            default:
                throw OpenStackError(service: "network", status: 400, message: "Unknown network action resource: \(descriptor.name)")
            }
        case .image:
            let r = await client.image(region: region)
            switch descriptor.name {
            case "image":
                switch action {
                case "protect": let img = try await r.protect(vt, id: id); return try Self.encodeObject(img)
                case "unprotect": let img = try await r.unprotect(vt, id: id); return try Self.encodeObject(img)
                case "deactivate": let img = try await r.deactivate(vt, id: id); return try Self.encodeObject(img)
                case "reactivate": let img = try await r.reactivate(vt, id: id); return try Self.encodeObject(img)
                case "set_visibility":
                    let visibility = params["visibility"]?.stringValue
                    guard let visibility else { throw OpenStackError(service: "image", status: 400, message: "set_visibility requires visibility") }
                    let img = try await r.setVisibility(vt, id: id, visibility: visibility)
                    return try Self.encodeObject(img)
                case "add_tag":
                    let tag = params["tag"]?.stringValue
                    guard let tag else { throw OpenStackError(service: "image", status: 400, message: "add_tag requires tag") }
                    try await r.addTags(vt, id: id, tags: [tag])
                    return ["action": .string("add_tag"), "id": .string(id), "tag": .string(tag)]
                case "remove_tag":
                    let tag = params["tag"]?.stringValue
                    guard let tag else { throw OpenStackError(service: "image", status: 400, message: "remove_tag requires tag") }
                    try await r.removeTag(vt, id: id, tag: tag)
                    return ["action": .string("remove_tag"), "id": .string(id), "tag": .string(tag)]
                default: throw OpenStackError(service: "image", status: 400, message: "Unknown image action: \(action)")
                }
            default:
                throw OpenStackError(service: "image", status: 400, message: "Unknown image action resource: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity actions not supported in phase 1")
        case .objectStorage:
            // Phase 2 Swift has no custom actions (protect/delete are verbs).
            throw OpenStackError(service: "object-store", status: 501, message: "Object-storage actions not supported (use delete for removal)")
        case .keyManager:
            let r = await client.keyManager(region: region)
            switch descriptor.name {
            case "secret":
                switch action {
                case "get_payload":
                    let payload = try await r.getSecretPayload(vt, id: id)
                    return try Self.encodeObject(payload)
                default:
                    throw OpenStackError(service: "key-manager", status: 400, message: "Unknown secret action: \(action)")
                }
            default:
                throw OpenStackError(service: "key-manager", status: 400, message: "Unknown key-manager action resource: \(descriptor.name)")
            }
        case .loadBalancer:
            // Octavia has no custom actions in phase 2.
            throw OpenStackError(service: "loadbalancer", status: 501, message: "Load-balancer actions not supported")
        case .dns:
            // Designate has no custom actions in phase 2.
            throw OpenStackError(service: "dns", status: 501, message: "DNS actions not supported")
        case .containerInfra:
            // Magnum has no custom actions in phase 2.
            throw OpenStackError(service: "container", status: 501, message: "Container actions not supported")
        case .orchestration:
            let r = await client.orchestration(region: region)
            switch descriptor.name {
            case "stack":
                switch action {
                case "get_outputs":
                    let outputs = try await r.getStackOutputs(vt, id: id)
                    let encoded = try Self.encodeList(outputs)
                    var result: [String: JSONValue] = ["resource": .string("stack")]
                    result["outputs"] = encoded["items"] ?? .array([])
                    result["count"] = encoded["count"] ?? .integer(0)
                    return result
                default:
                    throw OpenStackError(service: "orchestration", status: 400, message: "Unknown stack action: \(action)")
                }
            default:
                throw OpenStackError(service: "orchestration", status: 400, message: "Unknown orchestration action resource: \(descriptor.name)")
            }
        case .sharev2:
            // Manila has no custom actions in phase 2.
            throw OpenStackError(service: "sharev2", status: 501, message: "Share actions not supported")
        case .placement:
            // Placement has no custom actions in phase 2.
            throw OpenStackError(service: "placement", status: 501, message: "Placement actions not supported")
        }
    }

    // MARK: - Encoding

    static func encodeObject<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenStackError(service: "internal", status: 500, message: "Failed to encode resource to JSON object")
        }
        return convertDict(dict)
    }

    static func encodeList<T: Encodable>(_ values: [T]) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(values)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw OpenStackError(service: "internal", status: 500, message: "Failed to encode resource list to JSON array")
        }
        var items: [JSONValue] = []
        for v in arr {
            if let dict = v as? [String: Any] {
                items.append(.object(convertDict(dict)))
            }
        }
        return ["items": .array(items), "count": .integer(items.count)]
    }

    static func convertDict(_ dict: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            result[key] = convertValue(value)
        }
        return result
    }

    static func convertValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .integer(i)
        case let d as Double: return .float(d)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map(convertValue))
        case let dict as [String: Any]: return .object(convertDict(dict))
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }
}
