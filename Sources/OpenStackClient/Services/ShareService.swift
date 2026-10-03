import Foundation
import Logging

/// Region-bound Manila (shared file systems) client.
///
/// Keystone service type: `sharev2`. API base path: `share/v2`.
/// Resources: share (pollable — status creating -> available) and
/// share_access. List responses are keyed envelopes (`{"shares":[...]}`),
/// single items return the bare object.
public struct ShareRegion: Sendable {
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
    private let catalogType: String = "sharev2"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "sharev2", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Shares

    public func listShares(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Share] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "share", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [Share].self) { return cached }
        struct Envelope: Decodable { let shares: [Share] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/shares", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).shares
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getShare(_ vt: ValidatedToken, id: String) async throws -> Share {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/shares/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Share.self, from: result.body)
    }

    public func createShare(_ vt: ValidatedToken, _ spec: CreateShareSpec) async throws -> Share {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/shares", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Share.self, from: result.body)
    }

    public func deleteShare(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/shares/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share", tokenID: vt.token.id, region: region)
    }

    // MARK: - Share access

    public func listShareAccess(_ vt: ValidatedToken, shareID: String, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [ShareAccess] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let share_access_list: [ShareAccess] }
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/shares/\(shareID)/access", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Envelope.self, from: result.body).share_access_list
    }

    public func getShareAccess(_ vt: ValidatedToken, shareID: String, id: String) async throws -> ShareAccess {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/shares/\(shareID)/access/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(ShareAccess.self, from: result.body)
    }

    public func createShareAccess(_ vt: ValidatedToken, _ spec: CreateShareAccessSpec) async throws -> ShareAccess {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/shares/\(spec.share_id)/access", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share_access", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(ShareAccess.self, from: result.body)
    }

    public func deleteShareAccess(_ vt: ValidatedToken, shareID: String, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/shares/\(shareID)/access/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share_access", tokenID: vt.token.id, region: region)
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, region: String, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: path, query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Manila shared-file-systems client.
public struct ShareService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "share/v2") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> ShareRegion {
        ShareRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "share/v2", defaultRegion: region ?? cloud.regionName)
    }
}
