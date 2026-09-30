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
                let spec = CreateServerSpec(name: name, flavorID: flavorID, imageID: imageID)
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
                default: throw OpenStackError(service: "image", status: 400, message: "Unknown image action: \(action)")
                }
            default:
                throw OpenStackError(service: "image", status: 400, message: "Unknown image action resource: \(descriptor.name)")
            }
        case .identity:
            throw OpenStackError(service: "keystone", status: 501, message: "Identity actions not supported in phase 1")
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
