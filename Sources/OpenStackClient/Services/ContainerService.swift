import Foundation
import Logging

/// Region-bound Magnum (container infrastructure) client.
///
/// Keystone service type: `container`. API base path: `container`.
/// Resources: cluster (pollable — status CREATING -> ACTIVE / ERROR),
/// cluster_template. List responses are keyed envelopes
/// (`{"containers":[...]}`), single items return the bare object.
public struct ContainerRegion: Sendable {
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
    private let catalogType: String = "container-infra"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "container", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Containers

    public func listContainers(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [MagnumCluster] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "container", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [MagnumCluster].self) { return cached }
        struct Envelope: Decodable { let containers: [MagnumCluster] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/containers", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).containers
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getContainer(_ vt: ValidatedToken, id: String) async throws -> MagnumCluster {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/containers/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(MagnumCluster.self, from: result.body)
    }

    public func createContainer(_ vt: ValidatedToken, _ spec: CreateMagnumClusterSpec) async throws -> MagnumCluster {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/containers", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "container", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(MagnumCluster.self, from: result.body)
    }

    public func deleteContainer(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/containers/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "container", tokenID: vt.token.id, region: region)
    }

    // MARK: - Cluster templates

    public func listClusterTemplates(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [MagnumClusterTemplate] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let cluster_templates: [MagnumClusterTemplate] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/cluster_templates", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).cluster_templates
    }

    public func getClusterTemplate(_ vt: ValidatedToken, id: String) async throws -> MagnumClusterTemplate {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/cluster_templates/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(MagnumClusterTemplate.self, from: result.body)
    }

    public func createClusterTemplate(_ vt: ValidatedToken, _ spec: CreateMagnumClusterTemplateSpec) async throws -> MagnumClusterTemplate {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/cluster_templates", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(MagnumClusterTemplate.self, from: result.body)
    }

    public func deleteClusterTemplate(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/cluster_templates/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, region: String, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: path, query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "container", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Magnum container-infrastructure client.
public struct ContainerService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "container") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> ContainerRegion {
        ContainerRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "container", defaultRegion: region ?? cloud.regionName)
    }
}
