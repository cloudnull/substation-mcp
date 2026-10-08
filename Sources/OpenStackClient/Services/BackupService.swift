import Foundation
import Logging

/// Region-bound Freezer (backup) client.
///
/// Keystone service type: `backup`. IAD3 advertises the catalog endpoint at
/// the host root (no version); the API lives under `/v1.0/...`, so the client
/// sets `serviceRoot = "v1.0"` (the Gnocchi/Neutron pattern). Freezer addresses
/// items by `backup_id`; list responses are keyed envelopes (`{"backups":[...]}`).
public struct BackupRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    /// The catalog URL omits the version root (host root), so prepend `v1.0`.
    private let serviceRoot: String = "v1.0"
    private let catalogType: String = "backup"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "backup", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    public func listBackups(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [FreezerBackup] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "backup", suffix: suffix)
        if let cached = await cache.get(key, ttl: .seconds(120), as: [FreezerBackup].self) { return cached }
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/backup", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "backup", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let backups: [FreezerBackup] }
        let items = try JSONDecoder().decode(Envelope.self, from: result.body).backups
        await cache.put(key, ttl: .seconds(120), value: items)
        return items
    }

    public func getBackup(_ vt: ValidatedToken, id: String) async throws -> FreezerBackup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/backup/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "backup", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(FreezerBackup.self, from: result.body)
    }

    public func listSchedules(_ vt: ValidatedToken, filters: [String: String] = [:], limit: Int? = nil) async throws -> [FreezerSchedule] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/schedule", query: query)
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "backup", requestID: result.requestID, hasAccessRules: false)
        }
        struct Envelope: Decodable { let schedules: [FreezerSchedule] }
        return try JSONDecoder().decode(Envelope.self, from: result.body).schedules
    }

    public func getSchedule(_ vt: ValidatedToken, id: String) async throws -> FreezerSchedule {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/schedule/\(id)")
        guard (200...299).contains(result.status) else {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "backup", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(FreezerSchedule.self, from: result.body)
    }

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
    }
}

/// Freezer backup client.
public struct BackupService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "backup") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> BackupRegion {
        BackupRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "backup", defaultRegion: region ?? cloud.regionName)
    }
}