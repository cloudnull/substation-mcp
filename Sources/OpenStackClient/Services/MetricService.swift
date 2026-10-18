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
        query: [URLQueryItem]? = nil,
        body: Data? = nil
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

    /// List metrics, optionally filtered by name, resource id, or archive
    /// policy (server-side query filters).
    public func listMetrics(
        _ vt: ValidatedToken,
        name: String? = nil,
        resourceID: String? = nil,
        archivePolicy: String? = nil,
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [GnocchiMetric] {
        let region = try resolveRegion(vt)
        let suffix = "n:\(name ?? ""):r:\(resourceID ?? ""):a:\(archivePolicy ?? ""):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "metric", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [GnocchiMetric].self) { return cached }
        var query: [URLQueryItem] = []
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let resourceID { query.append(URLQueryItem(name: "resource_id", value: resourceID)) }
        if let archivePolicy { query.append(URLQueryItem(name: "archive_policy.name", value: archivePolicy)) }
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

    /// One metric by id (`GET /v1/metric/{id}`). The list row plus the
    /// `resource` link Gnocchi adds on the item endpoint.
    public func getMetric(_ vt: ValidatedToken, id: String) async throws -> GnocchiMetric {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/metric/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(GnocchiMetric.self, from: result.body)
    }

    /// List metrics for one Gnocchi resource (`GET /v1/metric?resource_id=`).
    /// This is the resource→metrics join: for a server, the Gnocchi `instance`
    /// resource id is the server uuid.
    public func listMetricsForResource(_ vt: ValidatedToken, resourceID: String, limit: Int? = nil) async throws -> [GnocchiMetric] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "metric", suffix: "r:\(resourceID):l:\(limit ?? 0)")
        if let cached = await cache.get(key, ttl: .seconds(120), as: [GnocchiMetric].self) { return cached }
        var query: [URLQueryItem] = [URLQueryItem(name: "resource_id", value: resourceID)]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/metric", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        let items = try JSONDecoder().decode([GnocchiMetric].self, from: result.body)
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    /// Raw stored measures (`GET /v1/metric/{id}/measures`): the bare JSON
    /// array of `[timestamp, granularity_seconds, value]` triples. Passed
    /// through unmodeled (open-ended shape). Live-validated on IAD3 meterng:
    /// 200 for a project-owned metric; 403 for another project's metric.
    public func getMeasures(_ vt: ValidatedToken, metricID: String) async throws -> RawJSONValue {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/metric/\(metricID)/measures")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(RawJSONValue.self, from: result.body)
    }

    /// Aggregated measures (`GET /v1/metric/{id}/measures?aggregation=&granularity=`).
    /// Both params are required together (Gnocchi ignores a lone one). The
    /// aggregation must be one of the metric's archive-policy methods and the
    /// granularity one of its definition steps, else Gnocchi 404s with
    /// "Aggregation method … does not exist". IAD3 meterng REJECTS relative
    /// windows (`start=-P7D` → 400); `start`/`stop` must be absolute ISO-8601.
    public func getAggregatedMeasures(
        _ vt: ValidatedToken,
        metricID: String,
        aggregation: String,
        granularity: String,
        start: String?,
        stop: String?,
        limit: Int? = nil
    ) async throws -> RawJSONValue {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "aggregation", value: aggregation),
            URLQueryItem(name: "granularity", value: granularity),
        ]
        if let start { query.append(URLQueryItem(name: "start", value: start)) }
        if let stop { query.append(URLQueryItem(name: "stop", value: stop)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/metric/\(metricID)/measures", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(RawJSONValue.self, from: result.body)
    }

    /// Archive policies this Gnocchi instance offers (`GET /v1/archive_policy`)
    /// — the vocabulary for creating metrics and for picking valid
    /// aggregation/granularity pairs (IAD3: 8 policies incl. the ceilometer-*
    /// family meterng writes into).
    public func listArchivePolicies(_ vt: ValidatedToken) async throws -> [GnocchiArchivePolicy] {
        let region = try resolveRegion(vt)
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "archive_policy", suffix: "list")
        if let cached = await cache.get(key, ttl: .seconds(600), as: [GnocchiArchivePolicy].self) { return cached }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/archive_policy")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        let items = try JSONDecoder().decode([GnocchiArchivePolicy].self, from: result.body)
        await cache.put(key, ttl: .seconds(600), value: items)
        return items
    }

    /// Create an unbound metric under an archive policy (`POST /v1/metric`).
    /// Live-validated on IAD3 meterng: project members may create and delete
    /// their own metrics (201/204 with the member-role app credential).
    public func createMetric(_ vt: ValidatedToken, archivePolicy: String, name: String? = nil, unit: String? = nil) async throws -> GnocchiMetric {
        let region = try resolveRegion(vt)
        var obj: [String: String] = ["archive_policy_name": archivePolicy]
        if let name { obj["name"] = name }
        if let unit { obj["unit"] = unit }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/metric", body: body)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "metric", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(GnocchiMetric.self, from: result.body)
    }

    /// Delete a metric (`DELETE /v1/metric/{id}`). Gnocchi refuses (409) when
    /// the metric is bound to a resource.
    public func deleteMetric(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/metric/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "metric", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "metric", tokenID: vt.token.id, region: region)
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
