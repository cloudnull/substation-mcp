import Foundation
import Logging

/// Region-bound Designate (DNS) client.
///
/// Keystone service type: `dns`. API base path: `designate/v3`. Resources:
/// zone (pollable — status pending -> active) and recordset. List responses
/// are keyed envelopes (`{"zones":[...]}`), single items return the bare
/// object.
public struct DNSRegion: Sendable {
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
    private let catalogType: String = "dns"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "dns", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Zones

    public func listZones(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Zone] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "zone", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [Zone].self) { return cached }
        struct Envelope: Decodable { let zones: [Zone] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/zones", filters: filters, limit: limit, marker: marker)
        let items = try JSONDecoder().decode(Envelope.self, from: body).zones
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getZone(_ vt: ValidatedToken, id: String) async throws -> Zone {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/zones/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Zone.self, from: result.body)
    }

    public func createZone(_ vt: ValidatedToken, _ spec: CreateZoneSpec) async throws -> Zone {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/zones", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "zone", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Zone.self, from: result.body)
    }

    public func deleteZone(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/zones/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "zone", tokenID: vt.token.id, region: region)
    }

    // MARK: - Record sets

    public func listRecordSets(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [RecordSet] {
        let region = try resolveRegion(vt)
        struct Envelope: Decodable { let recordsets: [RecordSet] }
        let body = try await fetchBody(vt, region: region, path: "\(basePath)/recordsets", filters: filters, limit: limit, marker: marker)
        return try JSONDecoder().decode(Envelope.self, from: body).recordsets
    }

    public func getRecordSet(_ vt: ValidatedToken, id: String) async throws -> RecordSet {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/recordsets/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(RecordSet.self, from: result.body)
    }

    public func createRecordSet(_ vt: ValidatedToken, _ spec: CreateRecordSetSpec) async throws -> RecordSet {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/recordsets", body: Data(spec.body().utf8))
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(RecordSet.self, from: result.body)
    }

    public func deleteRecordSet(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/recordsets/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
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
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "dns", requestID: result.requestID, hasAccessRules: false)
        }
        return result.body
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Designate DNS client.
public struct DNSService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "designate/v3") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> DNSRegion {
        DNSRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "designate/v3", defaultRegion: region ?? cloud.regionName)
    }
}
