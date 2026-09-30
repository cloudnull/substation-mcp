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
