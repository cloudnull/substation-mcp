import Foundation
import Logging

/// Region-bound Trove (database) client.
///
/// Keystone service type: `database`. IAD3 advertises the catalog endpoint
/// already project-scoped (`.../v1.0/<project>`), so the catalog URL is the
/// authoritative base and the client's own basePath is dropped (Heat pattern).
/// List responses are keyed envelopes (`{"instances":[...]}`), single items
/// return the bare object.
public struct DatabaseRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// Empty: the catalog URL (e.g. `.../v1.0/<project>`) is the authoritative
    /// base on IAD3 and the client's basePath is dropped.
    private let serviceRoot: String = ""
    private let catalogType: String = "database"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "database", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Instances

    public func listInstances(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [DatabaseInstance] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "database_instance", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [DatabaseInstance].self) { return cached }
        struct Envelope: Decodable { let instances: [DatabaseInstance] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/instances", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).instances
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getInstance(_ vt: ValidatedToken, id: String) async throws -> DatabaseInstance {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/instances/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(DatabaseInstance.self, from: result.body)
    }

    public func createInstance(_ vt: ValidatedToken, _ spec: CreateDatabaseInstanceSpec) async throws -> DatabaseInstance {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/instances", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "database_instance", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(DatabaseInstance.self, from: result.body)
    }

    public func deleteInstance(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/instances/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "database_instance", tokenID: vt.token.id, region: region)
    }

    // MARK: - Flavors / datastores

    public func listFlavors(_ vt: ValidatedToken, limit: Int? = nil) async throws -> [DatabaseFlavor] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/flavors", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let flavors: [DatabaseFlavor] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).flavors
    }

    public func listDatastores(_ vt: ValidatedToken, limit: Int? = nil) async throws -> [DatabaseDatastore] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/datastores", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let datastores: [DatabaseDatastore] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).datastores
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, region: String, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: path, query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "database", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Trove database client.
public struct DatabaseService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "database/v1.0") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> DatabaseRegion {
        DatabaseRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "database/v1.0", defaultRegion: region ?? cloud.regionName)
    }
}