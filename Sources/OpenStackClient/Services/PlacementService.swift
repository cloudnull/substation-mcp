import Foundation
import Logging

/// Region-bound Placement client.
///
/// Keystone service type: `placement`. The Placement API is served with no
/// version path root (the endpoint URL is the service root), so requests are
/// paths like `/resource_providers` directly under the resolved endpoint.
///
/// The Placement API is the authoritative per-host inventory source:
/// resource providers carry VCPU / MEMORY_MB / DISK_GB (and, on GPU clouds,
/// PCI/GPU resource classes) with their allocated usages. Correlating a
/// provider name with a server's hostId is how an agent learns a host's real
/// GPU/RAM/vCPU without trusting flavor naming.
public struct PlacementRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// The version root the catalog URL should carry (empty = the catalog URL
    /// is always the authoritative base; non-empty = verify the catalog path
    /// ends with it, else use the catalog host + this root). Placement has no
    /// version path, so empty.
    private let serviceRoot: String = ""
    /// The Keystone catalog service type.
    private let catalogType: String = "placement"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "placement", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Resource providers

    /// List the resource providers visible to the token, optionally filtered
    /// by `name` (exact match, as the Placement API implements it).
    public func listResourceProviders(
        _ vt: ValidatedToken,
        name: String? = nil,
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [PlacementResourceProvider] {
        let region = try resolveRegion(vt)
        let suffix = "f:name=\(name ?? ""):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "placement", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [PlacementResourceProvider].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/resource_providers", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "placement", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let resource_providers: [PlacementResourceProvider] }
        let items = try JSONDecoder().decode(Envelope.self, from: result.body).resource_providers
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    /// Fetch a single resource provider by uuid.
    public func getResourceProvider(_ vt: ValidatedToken, uuid: String) async throws -> PlacementResourceProvider {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/resource_providers/\(uuid)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "placement", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let resource_provider: PlacementResourceProvider }
        return try JSONDecoder().decode(Envelope.self, from: result.body).resource_provider
    }

    /// Fetch a provider's resource inventories (totals per resource class).
    public func getInventories(_ vt: ValidatedToken, uuid: String) async throws -> PlacementInventories {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/resource_providers/\(uuid)/inventories")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "placement", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let inventories: PlacementInventories }
        return try JSONDecoder().decode(Envelope.self, from: result.body).inventories
    }

    /// Fetch a provider's usages (allocated amount per resource class).
    public func getUsages(_ vt: ValidatedToken, uuid: String) async throws -> PlacementUsages {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/resource_providers/\(uuid)/usages")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "placement", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let usages: PlacementUsages }
        return try JSONDecoder().decode(Envelope.self, from: result.body).usages
    }

    // MARK: - Helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Placement client.
public struct PlacementService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    let basePath: String

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "placement") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
    }

    public func region(_ region: String? = nil) -> PlacementRegion {
        PlacementRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: basePath, defaultRegion: region ?? cloud.regionName)
    }
}
