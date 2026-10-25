import Foundation
import Logging

/// Region-bound Octavia (load balancer) client.
///
/// Keystone catalog service type: `load-balancer`. Real Octavia serves its v2
/// API under `<endpoint>/v2/lbaas/<collection>` — the `lbaas` segment is the
/// `V2Controller.lbaas` attribute in `octavia/api/v2/controllers/__init__.py`,
/// and every route in the upstream api-ref (`api-ref/source/v2/*.inc`) is
/// written `…/v2/lbaas/…`. `LoadBalancerRegion` therefore rewrites the
/// resource path through `octaviaPath(_:)` before sending it.
///
/// Octavia resources: load_balancer (pollable — provisioning -> ACTIVE),
/// listener, pool, member (a pool SUB-resource), health_monitor. List
/// responses are keyed envelopes (`{"loadbalancers":[…]}`); single-item
/// GET/POST/PUT responses return the bare object.
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
    private let serviceRoot: String = "v2"
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "load-balancer"
    /// Octavia's API namespace segment, between the version root and the
    /// collection: `/v2/lbaas/listeners`.
    static let apiNamespace = "lbaas"

    /// Turn a resource path (`listeners`, `pools/<id>`,
    /// `pools/<pool_id>/members`) into the path the transport should carry,
    /// inserting Octavia's `lbaas` namespace when the resolved endpoint root
    /// does not already end in it.
    ///
    /// Both endpoint shapes exist in the wild and in this repo's own fixtures:
    /// Rackspace advertises `…/os-octavia/v2` (so `lbaas` still has to be
    /// inserted), while the fake advertises `…/loadbalancer/v2` and older
    /// single-endpoint layouts use `loadbalancer/v2`. When the advertised root
    /// already ends in `lbaas` the path is passed through untouched, which keeps
    /// the fake's `/loadbalancer/v2/…` layout working unchanged.
    func octaviaPath(_ resource: String) -> String {
        if basePath.hasSuffix("/\(Self.apiNamespace)") || basePath == Self.apiNamespace {
            return "\(basePath)/\(resource)"
        }
        return "\(basePath)/\(Self.apiNamespace)/\(resource)"
    }

    /// Route a request to the service's real endpoint from the token catalog
    /// (multi-endpoint clouds) or the cloud authURL (single-endpoint fallback).
    /// `resource` is the Octavia resource path relative to the version root
    /// (`listeners`, `pools/p-1/members`); the `lbaas` namespace is inserted
    /// here, so callers never spell it.
    private func req(
        _ vt: ValidatedToken,
        _ region: String,
        method: String,
        resource: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        timeoutOverride: Duration? = nil,
        extraHeaders: [(String, String)] = []
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let path = octaviaPath(resource)
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
        if let cached = await cache.get(key, ttl: .seconds(120), as: [LoadBalancer].self) { return cached }
        struct Envelope: Decodable { let loadbalancers: [LoadBalancer] }
        let body = try await fetchListBody(vt, region: region, resource: "loadbalancers", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).loadbalancers
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getLoadBalancer(_ vt: ValidatedToken, id: String) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", resource: "loadbalancers/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(LoadBalancer.self, from: result.body, envelope: "loadbalancer")
    }

    public func createLoadBalancer(_ vt: ValidatedToken, _ spec: CreateLoadBalancerSpec) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", resource: "loadbalancers", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
        // Some clouds answer a create with a minimal/unusable body, which used to
        // surface as a false 500 ("The data is missing") even though the LB was
        // created (ISSUE 18). Read it back instead of failing the caller.
        return try await octaviaAfterWrite(
            vt, envelope: "loadbalancer", resultBody: result.body,
            readBack: { [self] in
                let items = try await self.listLoadBalancers(vt)
                if let name = spec.name, !name.isEmpty, let match = items.first(where: { $0.name == name }) {
                    return match
                }
                return items.max(by: { ($0.created_at ?? "") < ($1.created_at ?? "") })
            }
        )
    }

    public func updateLoadBalancer(_ vt: ValidatedToken, id: String, _ spec: UpdateLoadBalancerSpec) async throws -> LoadBalancer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", resource: "loadbalancers/\(id)", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
        return try Self.decodeOctaviaObject(LoadBalancer.self, from: result.body, envelope: "loadbalancer")
    }

    /// `DELETE /v2/lbaas/loadbalancers/{id}`. `cascade: true` appends
    /// `?cascade=true`, which tells Octavia to delete the load balancer AND all
    /// its children (listeners, pools, members, health monitors) in one call.
    /// Without it, an LB that still has children is rejected with
    /// `400 … it has children` — Octavia never deletes a parent out from under
    /// its children unless asked to cascade.
    public func deleteLoadBalancer(_ vt: ValidatedToken, id: String, cascade: Bool = false) async throws {
        let region = try resolveRegion(vt)
        let query: [URLQueryItem] = cascade ? [URLQueryItem(name: "cascade", value: "true")] : []
        let result = try await req(vt, region, method: "DELETE", resource: "loadbalancers/\(id)", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "load_balancer", tokenID: vt.token.id, region: region)
    }

    // MARK: - Listeners

    public func listListeners(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Listener] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let listeners: [Listener] }
        let body = try await fetchListBody(vt, region: region, resource: "listeners", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).listeners
    }

    public func getListener(_ vt: ValidatedToken, id: String) async throws -> Listener {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", resource: "listeners/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Listener.self, from: result.body, envelope: "listener")
    }

    public func createListener(_ vt: ValidatedToken, _ spec: CreateListenerSpec) async throws -> Listener {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", resource: "listeners", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        // Defect #5: the listener WAS created; only our read of the response
        // failed, and the caller was told 500 — so it retried and created a
        // duplicate. Decode leniently, and if the body is genuinely unusable,
        // read the listener back by name instead of failing.
        return try await octaviaAfterWrite(
            vt, envelope: "listener", resultBody: result.body,
            readBack: { [self] in
                let items = try await self.listListeners(vt)
                if let name = spec.name, !name.isEmpty { return items.first(where: { $0.name == name }) }
                return items.last
            }
        )
    }

    /// `PUT /v2/lbaas/listeners/{id}`. `UpdateListenerSpec.default_pool_id` is
    /// how a pool becomes an existing listener's default pool.
    public func updateListener(_ vt: ValidatedToken, id: String, _ spec: UpdateListenerSpec) async throws -> Listener {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", resource: "listeners/\(id)", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Listener.self, from: result.body, envelope: "listener")
    }

    public func deleteListener(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", resource: "listeners/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Pools

    public func listPools(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Pool] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let pools: [Pool] }
        let body = try await fetchListBody(vt, region: region, resource: "pools", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).pools
    }

    public func getPool(_ vt: ValidatedToken, id: String) async throws -> Pool {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", resource: "pools/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Pool.self, from: result.body, envelope: "pool")
    }

    public func createPool(_ vt: ValidatedToken, _ spec: CreatePoolSpec) async throws -> Pool {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", resource: "pools", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try await octaviaAfterWrite(
            vt, envelope: "pool", resultBody: result.body,
            readBack: { [self] in
                let items = try await self.listPools(vt)
                if let name = spec.name, !name.isEmpty { return items.first(where: { $0.name == name }) }
                return items.last
            }
        )
    }

    public func updatePool(_ vt: ValidatedToken, id: String, _ spec: UpdatePoolSpec) async throws -> Pool {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", resource: "pools/\(id)", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Pool.self, from: result.body, envelope: "pool")
    }

    public func deletePool(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", resource: "pools/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Members (pool sub-resource)

    /// Members live UNDER a pool: `GET|POST /v2/lbaas/pools/{pool_id}/members`
    /// and `GET|PUT|DELETE /v2/lbaas/pools/{pool_id}/members/{member_id}`
    /// (`MemberController.__init__(pool_id)` plus the `PoolsController._lookup`
    /// that hands `pools/{id}/members` to it — see
    /// `octavia/api/v2/controllers/pool.py:559`). Octavia exposes NO top-level
    /// `/v2/lbaas/members` collection, which is why the old top-level POST
    /// answered `405 Method Not Allowed` (defect #7).
    ///
    /// `poolID` is required for every member verb; `filters["pool_id"]` is
    /// accepted as a fallback so the catalog's `pool_id` list filter keeps
    /// working.
    private static func memberPoolID(_ poolID: String?, _ filters: [String: String]) throws -> String {
        if let poolID, !poolID.isEmpty { return poolID }
        if let fromFilter = filters["pool_id"], !fromFilter.isEmpty { return fromFilter }
        throw OpenStackError(service: "loadbalancer", status: 400, code: "missingPoolID",
            message: "Members are a pool sub-resource: a pool_id is required (spec/filters pool_id).",
            hint: "os_list(member, filters:{pool_id: <pool>}) / os_create(member, spec:{pool_id: <pool>, address, protocol_port}). Find pools with os_list(pool).")
    }

    public func listMembers(_ vt: ValidatedToken, poolID: String? = nil, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Member] {
        let region = try resolveRegion(vt)
        let pool = try Self.memberPoolID(poolID, filters)
        var listFilters = filters
        listFilters.removeValue(forKey: "pool_id")
        struct Envelope: Decodable { let members: [Member] }
        let body = try await fetchListBody(vt, region: region, resource: "pools/\(pool)/members", filters: listFilters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).members
    }

    public func getMember(_ vt: ValidatedToken, poolID: String?, id: String) async throws -> Member {
        let region = try resolveRegion(vt)
        let pool = try Self.memberPoolID(poolID, [:])
        let result = try await req(vt, region, method: "GET", resource: "pools/\(pool)/members/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Member.self, from: result.body, envelope: "member")
    }

    public func createMember(_ vt: ValidatedToken, _ spec: CreateMemberSpec) async throws -> Member {
        let region = try resolveRegion(vt)
        let pool = try Self.memberPoolID(spec.pool_id, [:])
        let result = try await req(vt, region, method: "POST", resource: "pools/\(pool)/members", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try await octaviaAfterWrite(
            vt, envelope: "member", resultBody: result.body,
            readBack: { [self] in
                let items = try await self.listMembers(vt, poolID: pool)
                if let name = spec.name, !name.isEmpty { return items.first(where: { $0.name == name }) }
                return items.first(where: { $0.address == spec.address && $0.protocol_port == spec.protocol_port }) ?? items.last
            }
        )
    }

    public func updateMember(_ vt: ValidatedToken, poolID: String?, id: String, _ spec: UpdateMemberSpec) async throws -> Member {
        let region = try resolveRegion(vt)
        let pool = try Self.memberPoolID(poolID, [:])
        let result = try await req(vt, region, method: "PUT", resource: "pools/\(pool)/members/\(id)", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(Member.self, from: result.body, envelope: "member")
    }

    public func deleteMember(_ vt: ValidatedToken, poolID: String?, id: String) async throws {
        let region = try resolveRegion(vt)
        let pool = try Self.memberPoolID(poolID, [:])
        let result = try await req(vt, region, method: "DELETE", resource: "pools/\(pool)/members/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    /// Find the pool a member belongs to, so the pool-scoped member routes can
    /// be built from a member id alone (the MCP surface addresses resources by
    /// id, and `os_get`/`os_delete(member)` carry no pool). Scans the pools this
    /// project can see; returns nil when the member is in none of them.
    public func findMemberPool(_ vt: ValidatedToken, memberID: String) async throws -> Pool? {
        for pool in try await listPools(vt) {
            let members = (try? await listMembers(vt, poolID: pool.id)) ?? []
            if members.contains(where: { $0.id == memberID }) { return pool }
        }
        return nil
    }

    // MARK: - Health monitors

    public func listHealthMonitors(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [HealthMonitor] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let healthmonitors: [HealthMonitor] }
        let body = try await fetchListBody(vt, region: region, resource: "healthmonitors", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).healthmonitors
    }

    public func getHealthMonitor(_ vt: ValidatedToken, id: String) async throws -> HealthMonitor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", resource: "healthmonitors/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(HealthMonitor.self, from: result.body, envelope: "healthmonitor")
    }

    public func createHealthMonitor(_ vt: ValidatedToken, _ spec: CreateHealthMonitorSpec) async throws -> HealthMonitor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", resource: "healthmonitors", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try await octaviaAfterWrite(
            vt, envelope: "healthmonitor", resultBody: result.body,
            readBack: { [self] in
                let items = try await self.listHealthMonitors(vt)
                if let name = spec.name, !name.isEmpty { return items.first(where: { $0.name == name }) }
                return items.last
            }
        )
    }

    public func updateHealthMonitor(_ vt: ValidatedToken, id: String, _ spec: UpdateHealthMonitorSpec) async throws -> HealthMonitor {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", resource: "healthmonitors/\(id)", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
        return try Self.decodeOctaviaObject(HealthMonitor.self, from: result.body, envelope: "healthmonitor")
    }

    public func deleteHealthMonitor(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", resource: "healthmonitors/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "loadbalancer", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Octavia response decoding

    /// Parse a body into a `[String: Any]` JSON object, or nil when it is not one.
    static func jsonObject(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Decode a single Octavia resource from a response body, accepting both the
    /// bare object and the singular envelope.
    ///
    /// Upstream Octavia returns the **bare** object for POST/PUT/GET on every
    /// lbaas resource — every `api-ref/source/v2/examples/*-create-response.json`
    /// shows the object at the top level, not under its singular key — but some
    /// clouds and proxies wrap it, so accept both shapes. The models tolerate
    /// JSON `null` for fields they declare non-optional (Octavia emits
    /// `"name": null` rather than omitting the key), which is what keeps a
    /// successful create from decoding as a failure (defect #5).
    static func decodeOctaviaObject<T: Decodable>(_ type: T.Type, from body: Data, envelope: String) throws -> T {
        let decoder = JSONDecoder()
        // Envelope first. Octavia wraps the object as `{"<envelope>":{…}}`, and
        // these models decode tolerantly (`decodeOrZero` fills missing keys with
        // ""/0). A bare decode of the wrapper therefore "succeeds" with an all
        // empty object — every field absent at the top level — and the caller
        // gets `id:""`, `protocol:""` for a resource that was created with real
        // values. Extract the envelope whenever the body is an object carrying
        // this key; only fall back to a bare decode for an unwrapped body.
        if let obj = jsonObject(body), let inner = obj[envelope],
           let data = try? JSONSerialization.data(withJSONObject: inner),
           let wrapped = try? decoder.decode(T.self, from: data) {
            return wrapped
        }
        if let bare = try? decoder.decode(T.self, from: body) { return bare }
        throw OpenStackError(service: "loadbalancer", status: 500, code: "decodeFailure",
            message: "The load-balancer service returned a response this server could not read.",
            hint: "The resource may still have been created. Check os_list before retrying — a retry can create a duplicate.")
    }

    /// Decode an Octavia write response, and when the body is unusable (empty,
    /// minimal, or an unknown shape) recover the authoritative object via a
    /// read-back closure instead of reporting a failure for a write that already
    /// happened (defect #5 / ISSUE 18).
    private func octaviaAfterWrite<T: Decodable>(
        _ vt: ValidatedToken, envelope: String, resultBody: Data,
        readBack: @Sendable () async throws -> T?
    ) async throws -> T {
        if !resultBody.isEmpty, let decoded = try? Self.decodeOctaviaObject(T.self, from: resultBody, envelope: envelope) {
            return decoded
        }
        if let recovered = try await readBack() { return recovered }
        throw OpenStackError.normalize(body: resultBody, status: 201, service: "loadbalancer", requestID: nil, hasAccessRules: false)
    }

    // MARK: - Helpers

    /// Fetch an Octavia collection list and hand back the raw body. Octavia list
    /// responses are shaped `{"<collection>":[…], "<collection>_links":{}}`.
    private func fetchListBody(
        _ vt: ValidatedToken, region: String, resource: String,
        filters: [String: String], limit: Int?, marker: String?
    ) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", resource: resource, query: query)
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

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "loadbalancer/v2") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> LoadBalancerRegion {
        LoadBalancerRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "loadbalancer/v2", defaultRegion: region ?? cloud.regionName)
    }
}
