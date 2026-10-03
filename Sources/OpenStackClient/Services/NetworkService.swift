import Foundation
import Logging

/// Neutron network service. Stateless w.r.t. identity — every operation
/// takes the request's `vt: ValidatedToken` as its first argument.
///
/// No microversion header is sent for Neutron; capability detection is
/// extension-based via `GET /neutron/v2.0/extensions`.
public struct NetworkService: Sendable {
    private let cloud: CloudEntry
    private let transport: Transport
    private let cache: Cache
    private let logger: Logger
    private let basePath: String

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "neutron/v2.0") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
    }

    /// Create a region-bound network client.
    public func region(_ region: String? = nil) -> NetworkRegion {
        NetworkRegion(
            cloud: cloud,
            transport: transport,
            cache: cache,
            logger: logger,
            defaultRegion: region ?? cloud.regionName,
            basePath: basePath
        )
    }
}

/// Region-bound Neutron client. Resolves extensions lazily and caches them.
public struct NetworkRegion: Sendable {
    private let cloud: CloudEntry
    private let transport: Transport
    private let cache: Cache
    private let logger: Logger
    private let defaultRegion: String?
    private let basePath: String
    private let serviceType: String

    private static let extensionsResource = "__extensions__"

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, defaultRegion: String?, basePath: String, serviceType: String = "network") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.defaultRegion = defaultRegion
        self.basePath = basePath
        self.serviceType = serviceType

    }

    /// The version root the catalog URL should carry (empty = the catalog URL is
    /// always the authoritative base; non-empty = verify the catalog path ends
    /// with it, else use the catalog host + this root).
    private let serviceRoot: String = "v2.0"
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "network"

    /// Route a request to the service's real endpoint from the token catalog
    /// (multi-endpoint clouds) or the cloud authURL (single-endpoint fallback).
    /// `path` is the full service path relative to the authURL (starts with
    /// `basePath`); the leading `basePath` is replaced by the resolved prefix.
    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        timeoutOverride: Duration? = nil
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let ep = resolveServiceEndpoint(
            vt: vt, region: region, cloud: cloud,
            basePath: basePath, serviceRoot: serviceRoot,
            serviceType: catalogType, fullPath: path
        )
        return try await transport.request(
            method: method,
            service: serviceType,
            path: ep.path,
            query: query ?? [],
            body: body,
            tokenOverride: vt.token.id,
            timeoutOverride: timeoutOverride,
            overrideBase: ep.overrideBase
        )
    }

    // MARK: - Extension discovery

    /// Discover seeded Neutron extension aliases (cached 1800s).
    public func discoverExtensions(_ vt: ValidatedToken, region: String) async throws -> NeutronExtensions {
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: NetworkRegion.extensionsResource, suffix: "network")
        if let cached = await cache.get(key, ttl: .seconds(1800), as: NeutronExtensions.self) {
            return cached
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/extensions")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct ExtensionsDoc: Decodable {
            struct Extension: Decodable { let alias: String }
            let extensions: [Extension]
        }
        let decoded = try JSONDecoder().decode(ExtensionsDoc.self, from: result.body)
        let ext = NeutronExtensions(aliases: Set(decoded.extensions.map { $0.alias }))
        await cache.put(key, ttl: .seconds(1800), value: ext)
        return ext
    }

    /// Throw a feature error naming the missing alias.
    private func requireExtension(_ alias: String, _ ext: NeutronExtensions) throws {
        guard ext.has(alias) else {
            throw OpenStackError(
                service: "network",
                status: 400,
                code: "feature_unavailable",
                message: "neutron extension '\(alias)' is not available"
            )
        }
    }

    // MARK: - Networks

    public func listNetworks(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Network] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "network", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(300), as: [Network].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/networks", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct NetworkList: Decodable {
            let networks: [Network]
        }
        let decoded = try JSONDecoder().decode(NetworkList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.networks)
        return decoded.networks
    }

    public func getNetwork(_ vt: ValidatedToken, id: String) async throws -> Network {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/networks/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct NetworkResp: Decodable { let network: Network }
        let decoded = try JSONDecoder().decode(NetworkResp.self, from: result.body)
        return decoded.network
    }

    public func createNetwork(_ vt: ValidatedToken, _ spec: CreateNetworkSpec) async throws -> Network {
        let region = try resolveRegion(vt)
        if spec.provider != nil {
            let ext = try await discoverExtensions(vt, region: region)
            try requireExtension("provider", ext)
        }

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/networks", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "network", tokenID: vt.token.id, region: region)

        struct NetworkResp: Decodable { let network: Network }
        let decoded = try JSONDecoder().decode(NetworkResp.self, from: result.body)
        return decoded.network
    }

    public func updateNetwork(_ vt: ValidatedToken, id: String, _ spec: UpdateNetworkSpec) async throws -> Network {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/networks/\(id)", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "network", tokenID: vt.token.id, region: region)

        struct NetworkResp: Decodable { let network: Network }
        let decoded = try JSONDecoder().decode(NetworkResp.self, from: result.body)
        return decoded.network
    }

    public func deleteNetwork(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/networks/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "network", tokenID: vt.token.id, region: region)
        await cache.invalidate(resource: "subnet", tokenID: vt.token.id, region: region)
    }

    // MARK: - Subnets

    public func listSubnets(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Subnet] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "subnet", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(300), as: [Subnet].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/subnets", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct SubnetList: Decodable { let subnets: [Subnet] }
        let decoded = try JSONDecoder().decode(SubnetList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.subnets)
        return decoded.subnets
    }

    public func getSubnet(_ vt: ValidatedToken, id: String) async throws -> Subnet {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/subnets/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct SubnetResp: Decodable { let subnet: Subnet }
        let decoded = try JSONDecoder().decode(SubnetResp.self, from: result.body)
        return decoded.subnet
    }

    public func createSubnet(_ vt: ValidatedToken, _ spec: CreateSubnetSpec) async throws -> Subnet {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/subnets", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "subnet", tokenID: vt.token.id, region: region)
        await cache.invalidate(resource: "network", tokenID: vt.token.id, region: region)

        struct SubnetResp: Decodable { let subnet: Subnet }
        let decoded = try JSONDecoder().decode(SubnetResp.self, from: result.body)
        return decoded.subnet
    }

    public func updateSubnet(_ vt: ValidatedToken, id: String, name: String? = nil, enableDHCP: Bool? = nil) async throws -> Subnet {
        let region = try resolveRegion(vt)
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let enableDHCP { parts.append("\"enable_dhcp\":\(enableDHCP ? "true" : "false")") }
        let body = "{\"subnet\":{\(parts.joined(separator: ","))}}"

        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/subnets/\(id)", body: body.data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "subnet", tokenID: vt.token.id, region: region)

        struct SubnetResp: Decodable { let subnet: Subnet }
        let decoded = try JSONDecoder().decode(SubnetResp.self, from: result.body)
        return decoded.subnet
    }

    public func deleteSubnet(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/subnets/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "subnet", tokenID: vt.token.id, region: region)
    }

    // MARK: - Ports

    public func listPorts(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [OSPort] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "port", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(60), as: [OSPort].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/ports", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct PortList: Decodable { let ports: [OSPort] }
        let decoded = try JSONDecoder().decode(PortList.self, from: result.body)
        await cache.put(key, ttl: .seconds(60), value: decoded.ports)
        return decoded.ports
    }

    public func getPort(_ vt: ValidatedToken, id: String) async throws -> OSPort {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/ports/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct PortResp: Decodable { let port: OSPort }
        let decoded = try JSONDecoder().decode(PortResp.self, from: result.body)
        return decoded.port
    }

    /// Create a port. An empty `fixedIPs` list asks Neutron to auto-assign.
    public func createPort(_ vt: ValidatedToken, _ spec: CreatePortSpec) async throws -> OSPort {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/ports", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "port", tokenID: vt.token.id, region: region)

        struct PortResp: Decodable { let port: OSPort }
        let decoded = try JSONDecoder().decode(PortResp.self, from: result.body)
        return decoded.port
    }

    public func updatePort(_ vt: ValidatedToken, id: String, name: String? = nil, adminStateUp: Bool? = nil, description: String? = nil, securityGroups: [String]? = nil) async throws -> OSPort {
        let region = try resolveRegion(vt)
        let spec = UpdatePortSpec(name: name, adminStateUp: adminStateUp, description: description, securityGroups: securityGroups)
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/ports/\(id)", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "port", tokenID: vt.token.id, region: region)

        struct PortResp: Decodable { let port: OSPort }
        let decoded = try JSONDecoder().decode(PortResp.self, from: result.body)
        return decoded.port
    }

    public func deletePort(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/ports/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "port", tokenID: vt.token.id, region: region)
    }

    // MARK: - Routers

    public func listRouters(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Router] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "router", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(300), as: [Router].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/routers", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct RouterList: Decodable { let routers: [Router] }
        let decoded = try JSONDecoder().decode(RouterList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.routers)
        return decoded.routers
    }

    public func getRouter(_ vt: ValidatedToken, id: String) async throws -> Router {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/routers/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct RouterResp: Decodable { let router: Router }
        let decoded = try JSONDecoder().decode(RouterResp.self, from: result.body)
        return decoded.router
    }

    public func createRouter(_ vt: ValidatedToken, _ spec: CreateRouterSpec) async throws -> Router {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/routers", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "router", tokenID: vt.token.id, region: region)

        struct RouterResp: Decodable { let router: Router }
        let decoded = try JSONDecoder().decode(RouterResp.self, from: result.body)
        return decoded.router
    }

    /// Update a router, optionally setting or removing its external gateway.
    public func updateRouter(_ vt: ValidatedToken, id: String, name: String? = nil, externalGatewayInfo: Router.ExternalGatewayInfo? = nil) async throws -> Router {
        let region = try resolveRegion(vt)
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let externalGatewayInfo {
            parts.append("\"external_gateway_info\":{\"network_id\":\"\(externalGatewayInfo.networkID)\"}")
        }
        let body = "{\"router\":{\(parts.joined(separator: ","))}}"

        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/routers/\(id)", body: body.data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "router", tokenID: vt.token.id, region: region)

        struct RouterResp: Decodable { let router: Router }
        let decoded = try JSONDecoder().decode(RouterResp.self, from: result.body)
        return decoded.router
    }

    public func deleteRouter(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/routers/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "router", tokenID: vt.token.id, region: region)
    }

    // MARK: - Floating IPs

    public func listFloatingIPs(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [FloatingIP] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "floatingip", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(60), as: [FloatingIP].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/floatingips", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct FloatingIPList: Decodable { let floatingips: [FloatingIP] }
        let decoded = try JSONDecoder().decode(FloatingIPList.self, from: result.body)
        await cache.put(key, ttl: .seconds(60), value: decoded.floatingips)
        return decoded.floatingips
    }

    public func getFloatingIP(_ vt: ValidatedToken, id: String) async throws -> FloatingIP {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/floatingips/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct FloatingIPResp: Decodable { let floatingip: FloatingIP }
        let decoded = try JSONDecoder().decode(FloatingIPResp.self, from: result.body)
        return decoded.floatingip
    }

    public func createFloatingIP(_ vt: ValidatedToken, _ spec: CreateFloatingIPSpec) async throws -> FloatingIP {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/floatingips", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "floatingip", tokenID: vt.token.id, region: region)

        struct FloatingIPResp: Decodable { let floatingip: FloatingIP }
        let decoded = try JSONDecoder().decode(FloatingIPResp.self, from: result.body)
        return decoded.floatingip
    }

    /// Associate (portID set) or disassociate (portID nil) a floating IP.
    public func updateFloatingIP(_ vt: ValidatedToken, id: String, portID: String? = nil, fixedIPAddress: String? = nil) async throws -> FloatingIP {
        let region = try resolveRegion(vt)
        var parts: [String] = []
        if let portID { parts.append("\"port_id\":\"\(portID)\"") } else { parts.append("\"port_id\":null") }
        if let fixedIPAddress { parts.append("\"fixed_ip_address\":\"\(fixedIPAddress)\"") } else { parts.append("\"fixed_ip_address\":null") }
        let body = "{\"floatingip\":{\(parts.joined(separator: ","))}}"

        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/floatingips/\(id)", body: body.data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "floatingip", tokenID: vt.token.id, region: region)

        struct FloatingIPResp: Decodable { let floatingip: FloatingIP }
        let decoded = try JSONDecoder().decode(FloatingIPResp.self, from: result.body)
        return decoded.floatingip
    }

    public func deleteFloatingIP(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/floatingips/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "floatingip", tokenID: vt.token.id, region: region)
    }

    // MARK: - Security groups

    public func listSecurityGroups(
        _ vt: ValidatedToken,
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [SecurityGroup] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "securitygroup", suffix: "")

        if let cached = await cache.get(key, ttl: .seconds(300), as: [SecurityGroup].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/security-groups", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct SGList: Decodable { let security_groups: [SecurityGroup] }
        let decoded = try JSONDecoder().decode(SGList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.security_groups)
        return decoded.security_groups
    }

    public func getSecurityGroup(_ vt: ValidatedToken, id: String) async throws -> SecurityGroup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/security-groups/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct SGResp: Decodable { let security_group: SecurityGroup }
        let decoded = try JSONDecoder().decode(SGResp.self, from: result.body)
        return decoded.security_group
    }

    public func createSecurityGroup(_ vt: ValidatedToken, _ spec: CreateSecurityGroupSpec) async throws -> SecurityGroup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/security-groups", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "securitygroup", tokenID: vt.token.id, region: region)

        struct SGResp: Decodable { let security_group: SecurityGroup }
        let decoded = try JSONDecoder().decode(SGResp.self, from: result.body)
        return decoded.security_group
    }

    public func deleteSecurityGroup(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/security-groups/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "securitygroup", tokenID: vt.token.id, region: region)
    }

    // MARK: - Security group rules

    public func listSecurityGroupRules(
        _ vt: ValidatedToken,
        securityGroupID: String? = nil,
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [SecurityGroupRule] {
        let region = try resolveRegion(vt)
        let suffix = securityGroupID.map { "sg:\($0)" } ?? ""
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "securitygrouprule", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(300), as: [SecurityGroupRule].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        if let securityGroupID {
            query.append(URLQueryItem(name: "security_group_id", value: securityGroupID))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let marker {
            query.append(URLQueryItem(name: "marker", value: marker))
        }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/security-group-rules", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct RuleList: Decodable { let security_group_rules: [SecurityGroupRule] }
        let decoded = try JSONDecoder().decode(RuleList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.security_group_rules)
        return decoded.security_group_rules
    }

    public func getSecurityGroupRule(_ vt: ValidatedToken, id: String) async throws -> SecurityGroupRule {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/security-group-rules/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct RuleResp: Decodable { let security_group_rule: SecurityGroupRule }
        let decoded = try JSONDecoder().decode(RuleResp.self, from: result.body)
        return decoded.security_group_rule
    }

    /// Create a rule. Rules are immutable — update is not offered.
    public func createSecurityGroupRule(
        _ vt: ValidatedToken,
        securityGroupID: String,
        direction: String = "ingress",
        ethertype: String = "IPv4",
        ipProtocol: String? = nil,
        portRangeMin: Int? = nil,
        portRangeMax: Int? = nil,
        remoteIPPrefix: String? = nil
    ) async throws -> SecurityGroupRule {
        let region = try resolveRegion(vt)
        let spec = CreateSecurityGroupRuleSpec(
            securityGroupID: securityGroupID,
            direction: direction,
            ethertype: ethertype,
            ipProtocol: ipProtocol,
            portRangeMin: portRangeMin,
            portRangeMax: portRangeMax,
            remoteIPPrefix: remoteIPPrefix
        )
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/security-group-rules", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        await cache.invalidate(resource: "securitygrouprule", tokenID: vt.token.id, region: region)

        struct RuleResp: Decodable { let security_group_rule: SecurityGroupRule }
        let decoded = try JSONDecoder().decode(RuleResp.self, from: result.body)
        return decoded.security_group_rule
    }

    public func deleteSecurityGroupRule(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/security-group-rules/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
        await cache.invalidate(resource: "securitygrouprule", tokenID: vt.token.id, region: region)
    }

    // MARK: - Address groups (extension-gated)

    public func listAddressGroups(_ vt: ValidatedToken) async throws -> [AddressGroup] {
        let region = try resolveRegion(vt)
        let ext = try await discoverExtensions(vt, region: region)
        try requireExtension("address-group", ext)

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/address-groups")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct AGList: Decodable { let address_groups: [AddressGroup] }
        let decoded = try JSONDecoder().decode(AGList.self, from: result.body)
        return decoded.address_groups
    }

    public func getAddressGroup(_ vt: ValidatedToken, id: String) async throws -> AddressGroup {
        let region = try resolveRegion(vt)
        let ext = try await discoverExtensions(vt, region: region)
        try requireExtension("address-group", ext)

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/address-groups/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct AGResp: Decodable { let address_group: AddressGroup }
        let decoded = try JSONDecoder().decode(AGResp.self, from: result.body)
        return decoded.address_group
    }

    public func createAddressGroup(_ vt: ValidatedToken, _ spec: CreateAddressGroupSpec) async throws -> AddressGroup {
        let region = try resolveRegion(vt)
        let ext = try await discoverExtensions(vt, region: region)
        try requireExtension("address-group", ext)

        let result = try await req(vt, region, method: "POST", path: "\(basePath)/address-groups", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct AGResp: Decodable { let address_group: AddressGroup }
        let decoded = try JSONDecoder().decode(AGResp.self, from: result.body)
        return decoded.address_group
    }

    public func deleteAddressGroup(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let ext = try await discoverExtensions(vt, region: region)
        try requireExtension("address-group", ext)

        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/address-groups/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(
                    body: result.body,
                    status: result.status,
                    service: "network",
                    requestID: result.requestID,
                    hasAccessRules: false
                )
            }
        }
    }

    // MARK: - Quotas

    public func getQuota(_ vt: ValidatedToken) async throws -> NetworkQuota {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/quota/\(projectID)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }

        struct QuotaResp: Decodable { let quota: NetworkQuota }
        let decoded = try JSONDecoder().decode(QuotaResp.self, from: result.body)
        return decoded.quota
    }

    public func updateQuota(_ vt: ValidatedToken, _ quota: NetworkQuota) async throws -> NetworkQuota {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/quota/\(projectID)", body: quota.updateBody().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(
                body: result.body,
                status: result.status,
                service: "network",
                requestID: result.requestID,
                hasAccessRules: false
            )
        }
        _ = region

        struct QuotaResp: Decodable { let quota: NetworkQuota }
        let decoded = try JSONDecoder().decode(QuotaResp.self, from: result.body)
        return decoded.quota
    }

    // MARK: - Private helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}
