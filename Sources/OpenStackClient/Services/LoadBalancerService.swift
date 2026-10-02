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
        let body = try await fetchListBody(vt, path: "\(basePath)/loadbalancers", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).loadbalancers
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getLoadBalancer(_ vt: ValidatedToken, id: String) async throws -> LoadBalancer {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: "\(basePath)/loadbalancers/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(LoadBalancer.self, from: result.body)
    }

    public func createLoadBalancer(_ vt: ValidatedToken, _ spec: CreateLoadBalancerSpec) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "loadbalancer", path: "\(basePath)/loadbalancers", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(LoadBalancer.self, from: result.body)
    }

    public func deleteLoadBalancer(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "loadbalancer", path: "\(basePath)/loadbalancers/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
    }

    // MARK: - Listeners

    public func listListeners(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Listener] {
        _ = try resolveRegion(vt)
        struct Envelope: Decodable { let listeners: [Listener] }
        let body = try await fetchListBody(vt, path: "\(basePath)/listeners", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).listeners
    }

    public func getListener(_ vt: ValidatedToken, id: String) async throws -> Listener {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: "\(basePath)/listeners/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Listener.self, from: result.body)
    }

    public func createListener(_ vt: ValidatedToken, _ spec: CreateListenerSpec) async throws -> Listener {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "loadbalancer", path: "\(basePath)/listeners", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Listener.self, from: result.body)
    }

    public func deleteListener(_ vt: ValidatedToken, id: String) async throws {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "loadbalancer", path: "\(basePath)/listeners/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Pools

    public func listPools(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Pool] {
        _ = try resolveRegion(vt)
        struct Envelope: Decodable { let pools: [Pool] }
        let body = try await fetchListBody(vt, path: "\(basePath)/pools", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).pools
    }

    public func getPool(_ vt: ValidatedToken, id: String) async throws -> Pool {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: "\(basePath)/pools/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Pool.self, from: result.body)
    }

    public func createPool(_ vt: ValidatedToken, _ spec: CreatePoolSpec) async throws -> Pool {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "loadbalancer", path: "\(basePath)/pools", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Pool.self, from: result.body)
    }

    public func deletePool(_ vt: ValidatedToken, id: String) async throws {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "loadbalancer", path: "\(basePath)/pools/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Members

    public func listMembers(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Member] {
        _ = try resolveRegion(vt)
        struct Envelope: Decodable { let members: [Member] }
        let body = try await fetchListBody(vt, path: "\(basePath)/members", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).members
    }

    public func getMember(_ vt: ValidatedToken, id: String) async throws -> Member {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: "\(basePath)/members/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Member.self, from: result.body)
    }

    public func createMember(_ vt: ValidatedToken, _ spec: CreateMemberSpec) async throws -> Member {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "loadbalancer", path: "\(basePath)/members", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Member.self, from: result.body)
    }

    public func deleteMember(_ vt: ValidatedToken, id: String) async throws {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "loadbalancer", path: "\(basePath)/members/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Health monitors

    public func listHealthMonitors(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [HealthMonitor] {
        _ = try resolveRegion(vt)
        struct Envelope: Decodable { let healthmonitors: [HealthMonitor] }
        let body = try await fetchListBody(vt, path: "\(basePath)/healthmonitors", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).healthmonitors
    }

    public func getHealthMonitor(_ vt: ValidatedToken, id: String) async throws -> HealthMonitor {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: "\(basePath)/healthmonitors/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(HealthMonitor.self, from: result.body)
    }

    public func createHealthMonitor(_ vt: ValidatedToken, _ spec: CreateHealthMonitorSpec) async throws -> HealthMonitor {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "loadbalancer", path: "\(basePath)/healthmonitors", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(HealthMonitor.self, from: result.body)
    }

    public func deleteHealthMonitor(_ vt: ValidatedToken, id: String) async throws {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "loadbalancer", path: "\(basePath)/healthmonitors/\(id)", tokenOverride: vt.token.id)
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
        _ vt: ValidatedToken, path: String,
        filters: [String: String], limit: Int?, marker: String?
    ) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await transport.request(method: "GET", service: "loadbalancer", path: path, query: query, tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
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
