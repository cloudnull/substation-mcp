import Foundation
import Logging

/// Region-bound Gnocchi (metric) client.
///
/// Keystone service type: `metric`. IAD3 advertises the catalog endpoint at
/// the host root (no version), while the API lives under `/v1/...` — so the
/// client sets `serviceRoot = "v1"` and the resolver prepends it to the catalog
/// host (the Neutron pattern). Metric lists are bare JSON arrays; the resource
/// type map (`GET /v1/resource`) is a `{name: href}` object.
public struct MetricRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// The catalog URL omits the version root (host root), so verify/prepend `v1`.
    private let serviceRoot: String = "v1"
    private let catalogType: String = "metric"

    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil
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
            body: nil,
            tokenOverride: vt.token.id,
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "metric", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    /// List metrics, optionally filtered by name (server-side `name=` filter).
    public func listMetrics(_ vt: ValidatedToken, name: String? = nil, limit: Int? = nil, marker: String? = nil) async throws -> [GnocchiMetric] {
        let region = try resolveRegion(vt)
        let suffix = "n:\(name ?? ""):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "metric", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [GnocchiMetric].self) { return cached }
        var query: [URLQueryItem] = []
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/metric", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        let items = try JSONDecoder().decode([GnocchiMetric].self, from: result.body)
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    /// List the resource types this Gnocchi instance tracks (the
    /// `GET /v1/resource` map: `{name: href}`), rendered as objects.
    public func listResourceTypes(_ vt: ValidatedToken) async throws -> [GnocchiResourceType] {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/resource")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        let map = try JSONDecoder().decode([String: String].self, from: result.body)
        return map.keys.sorted().map { GnocchiResourceType(id: $0, name: $0, href: map[$0] ?? "") }
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Gnocchi metric client.
public struct MetricService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "metric") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> MetricRegion {
        MetricRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "metric", defaultRegion: region ?? cloud.regionName)
    }
}
