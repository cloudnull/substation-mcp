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
        if let cached = try await cache.get(key, ttl: .seconds(120), as: [Share].self) { return cached }
        struct Envelope: Decodable { let shares: [Share] }
        let body = try await fetchBody(vt, path: "\(basePath)/shares", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).shares
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getShare(_ vt: ValidatedToken, id: String) async throws -> Share {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "sharev2", path: "\(basePath)/shares/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Share.self, from: result.body)
    }

    public func createShare(_ vt: ValidatedToken, _ spec: CreateShareSpec) async throws -> Share {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "sharev2", path: "\(basePath)/shares", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Share.self, from: result.body)
    }

    public func deleteShare(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "sharev2", path: "\(basePath)/shares/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share", tokenID: vt.token.id, region: region)
    }

    // MARK: - Share access

    public func listShareAccess(_ vt: ValidatedToken, shareID: String, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [ShareAccess] {
        _ = try resolveRegion(vt)
        struct Envelope: Decodable { let share_access_list: [ShareAccess] }
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await transport.request(method: "GET", service: "sharev2", path: "\(basePath)/shares/\(shareID)/access", query: query, tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Envelope.self, from: result.body).share_access_list
    }

    public func getShareAccess(_ vt: ValidatedToken, shareID: String, id: String) async throws -> ShareAccess {
        _ = try resolveRegion(vt)
        let result = try await transport.request(method: "GET", service: "sharev2", path: "\(basePath)/shares/\(shareID)/access/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(ShareAccess.self, from: result.body)
    }

    public func createShareAccess(_ vt: ValidatedToken, _ spec: CreateShareAccessSpec) async throws -> ShareAccess {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "POST", service: "sharev2", path: "\(basePath)/shares/\(spec.share_id)/access", body: Data(spec.body().utf8), tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share_access", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(ShareAccess.self, from: result.body)
    }

    public func deleteShareAccess(_ vt: ValidatedToken, shareID: String, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(method: "DELETE", service: "sharev2", path: "\(basePath)/shares/\(shareID)/access/\(id)", tokenOverride: vt.token.id)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "sharev2", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "share_access", tokenID: vt.token.id, region: region)
    }

    // MARK: - Helpers

    private func fetchBody(_ vt: ValidatedToken, path: String, filters: [String: String], limit: Int?, marker: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await transport.request(method: "GET", service: "sharev2", path: path, query: query, tokenOverride: vt.token.id)
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
