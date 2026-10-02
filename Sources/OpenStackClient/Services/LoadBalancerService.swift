import Foundation
import Logging

/// Region-bound Octavia (load balancer) client.
///
/// Keystone service type: `loadbalancer`. API base path: `loadbalancer/v1`.
/// Octavia resources: load_balancer (pollable — provisioning -> active),
/// listener, pool, member, health_monitor. List responses are keyed
/// envelopes (`{"loadbalancers":[...]}`), single items return the bare object.
public struct LoadBalancerRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// The version root the catalog URL should carry (empty = the catalog URL is
    /// always the authoritative base; non-empty = verify the catalog path ends
    /// with it, else use the catalog host + this root).
    private let serviceRoot: String = ""
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "load-balancer"

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
        timeoutOverride: Duration? = nil,
        extraHeaders: [(String, String)] = []
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
            extraHeaders: extraHeaders,
            timeoutOverride: timeoutOverride,
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "loadbalancer", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Load balancers

    public func listLoadBalancers(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [LoadBalancer] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "load_balancer", suffix: suffix)
        if let cached = try await cache.get(key, ttl: .seconds(120), as: [LoadBalancer].self) { return cached }
        struct Envelope: Decodable { let loadbalancers: [LoadBalancer] }
        let body = try await fetchListBody(vt, region: region, path: "\(basePath)/loadbalancers", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).loadbalancers
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getLoadBalancer(_ vt: ValidatedToken, id: String) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/loadbalancers/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(LoadBalancer.self, from: result.body)
    }

    public func createLoadBalancer(_ vt: ValidatedToken, _ spec: CreateLoadBalancerSpec) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/loadbalancers", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(LoadBalancer.self, from: result.body)
    }

    public func deleteLoadBalancer(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/loadbalancers/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
    }

    // MARK: - Listeners

    public func listListeners(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Listener] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let listeners: [Listener] }
        let body = try await fetchListBody(vt, region: region, path: "\(basePath)/listeners", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).listeners
    }

    public func getListener(_ vt: ValidatedToken, id: String) async throws -> Listener {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/listeners/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Listener.self, from: result.body)
    }

    public func createListener(_ vt: ValidatedToken, _ spec: CreateListenerSpec) async throws -> Listener {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/listeners", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Listener.self, from: result.body)
    }

    public func deleteListener(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/listeners/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Pools

    public func listPools(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Pool] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let pools: [Pool] }
        let body = try await fetchListBody(vt, region: region, path: "\(basePath)/pools", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).pools
    }

    public func getPool(_ vt: ValidatedToken, id: String) async throws -> Pool {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/pools/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Pool.self, from: result.body)
    }

    public func createPool(_ vt: ValidatedToken, _ spec: CreatePoolSpec) async throws -> Pool {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/pools", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Pool.self, from: result.body)
    }

    public func deletePool(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/pools/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Members

    public func listMembers(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Member] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let members: [Member] }
        let body = try await fetchListBody(vt, region: region, path: "\(basePath)/members", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).members
    }

    public func getMember(_ vt: ValidatedToken, id: String) async throws -> Member {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/members/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Member.self, from: result.body)
    }

    public func createMember(_ vt: ValidatedToken, _ spec: CreateMemberSpec) async throws -> Member {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/members", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Member.self, from: result.body)
    }

    public func deleteMember(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/members/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Health monitors

    public func listHealthMonitors(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [HealthMonitor] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let healthmonitors: [HealthMonitor] }
        let body = try await fetchListBody(vt, region: region, path: "\(basePath)/healthmonitors", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).healthmonitors
    }

    public func getHealthMonitor(_ vt: ValidatedToken, id: String) async throws -> HealthMonitor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/healthmonitors/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(HealthMonitor.self, from: result.body)
    }

    public func createHealthMonitor(_ vt: ValidatedToken, _ spec: CreateHealthMonitorSpec) async throws -> HealthMonitor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/healthmonitors", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(HealthMonitor.self, from: result.body)
    }

    public func deleteHealthMonitor(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/healthmonitors/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Helpers

    /// Octavia list responses are keyed envelopes (e.g. {"loadbalancers":[...],
    /// "loadbalancers_links":{}}). Decode the bare array under the collection key.
    /// Fetch an Octavia collection list (keyed envelope) and hand the raw body
    /// to a decode closure. Octavia list responses are shaped
    /// {"<collection>":[...], "<collection>_links":{}}.
    private func fetchListBody(
        _ vt: ValidatedToken, region: String, path: String,
        filters: [String: String], limit: Int?, marker: String?
    ) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: path, query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Octavia load-balancer client.
public struct LoadBalancerService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "loadbalancer/v1") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> LoadBalancerRegion {
        LoadBalancerRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "loadbalancer/v1", defaultRegion: region ?? cloud.regionName)
    }
}
