import Foundation
import Logging

/// Region-bound Cinder v3 client. Resolves endpoint and sends the
/// `OpenStack-API-Version: volume 3.x` header on every request.
public struct BlockStorageRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    static let floor = "3.44"
    static let clientMax = "3.70"

    /// The version root the catalog URL should carry (empty = the catalog URL is
    /// always the authoritative base; non-empty = verify the catalog path ends
    /// with it, else use the catalog host + this root).
    private let serviceRoot: String = "v3"
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "volumev3"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "volumev3", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    /// Every request carries the API-version header. The fake rejects requests
    /// that omit it, which pins the header contract.
    private var versionHeader: [(String, String)] {
        [("OpenStack-API-Version", "volume \(Self.clientMax)")]
    }

    // MARK: - Volumes

    public func listVolumes(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Volume] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "volume", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(60), as: [Volume].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters {
            query.append(URLQueryItem(name: k, value: v))
        }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/volumes/detail", query: query, extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }

        struct VolumeList: Decodable { let volumes: [Volume] }
        let decoded = try JSONDecoder().decode(VolumeList.self, from: result.body)
        await cache.put(key, ttl: .seconds(60), value: decoded.volumes)
        return decoded.volumes
    }

    public func getVolume(_ vt: ValidatedToken, id: String) async throws -> Volume {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/volumes/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    public func createVolume(_ vt: ValidatedToken, _ spec: CreateVolumeSpec) async throws -> Volume {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    public func deleteVolume(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/volumes/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
    }

    public func extendVolume(_ vt: ValidatedToken, id: String, size: Int) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-extend\":{\"new_size\":\(size)}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    public func retypeVolume(_ vt: ValidatedToken, id: String, volumeType: String) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-retype\":{\"new_type\":\"\(volumeType)\"}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    public func setBootable(_ vt: ValidatedToken, id: String, bootable: Bool) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-set_bootable\":{\"bootable\":\(bootable ? "true" : "false")}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    public func uploadToImage(_ vt: ValidatedToken, id: String) async throws -> String {
        let region = try resolveRegion(vt)
        let body = "{\"os-volume_upload_to_image\":{}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)

        struct ImageResp: Decodable { let imageId: String }
        let decoded = try JSONDecoder().decode(ImageResp.self, from: result.body)
        return decoded.imageId
    }

    public func resetStatus(_ vt: ValidatedToken, id: String, status: String) async throws {
        let region = try resolveRegion(vt)
        let body = "{\"reset-status\":{\"status\":\"\(status)\"}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
    }

    // MARK: - Volume Types

    public func listVolumeTypes(_ vt: ValidatedToken) async throws -> [VolumeType] {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/volume-types", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let volumeTypes: [VolumeType] }
        return try JSONDecoder().decode(List.self, from: result.body).volumeTypes
    }

    public func getVolumeType(_ vt: ValidatedToken, id: String) async throws -> VolumeType {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/volume-types/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let volumeType: VolumeType }
        return try JSONDecoder().decode(Resp.self, from: result.body).volumeType
    }

    public func createVolumeType(_ vt: ValidatedToken, _ spec: CreateVolumeTypeSpec) async throws -> VolumeType {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/\(projectID)/volume-types", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let volumeType: VolumeType }
        return try JSONDecoder().decode(Resp.self, from: result.body).volumeType
    }

    public func deleteVolumeType(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(projectID)/volume-types/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
    }

    // MARK: - Snapshots

    public func listSnapshots(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Snapshot] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/snapshots", query: query, extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let snapshots: [Snapshot] }
        return try JSONDecoder().decode(List.self, from: result.body).snapshots
    }

    public func getSnapshot(_ vt: ValidatedToken, id: String) async throws -> Snapshot {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/snapshots/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let snapshot: Snapshot }
        return try JSONDecoder().decode(Resp.self, from: result.body).snapshot
    }

    public func createSnapshot(_ vt: ValidatedToken, _ spec: CreateSnapshotSpec) async throws -> Snapshot {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/snapshots", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let snapshot: Snapshot }
        return try JSONDecoder().decode(Resp.self, from: result.body).snapshot
    }

    public func deleteSnapshot(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/snapshots/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
    }

    // MARK: - Backups

    public func listBackups(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Backup] {
        let region = try resolveRegion(vt)
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/backups", query: query, extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let backups: [Backup] }
        return try JSONDecoder().decode(List.self, from: result.body).backups
    }

    public func getBackup(_ vt: ValidatedToken, id: String) async throws -> Backup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/backups/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let backup: Backup }
        return try JSONDecoder().decode(Resp.self, from: result.body).backup
    }

    public func createBackup(_ vt: ValidatedToken, _ spec: CreateBackupSpec) async throws -> Backup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/backups", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let backup: Backup }
        return try JSONDecoder().decode(Resp.self, from: result.body).backup
    }

    public func deleteBackup(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/backups/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
    }

    /// Restore a backup into a new volume. Returns the restored volume.
    public func restoreBackup(_ vt: ValidatedToken, id: String) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"restore\":{}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/backups/\(id)/restore", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        struct VolumeResp: Decodable { let volume: Volume }
        return try JSONDecoder().decode(VolumeResp.self, from: result.body).volume
    }

    // MARK: - Quotas

    public func getQuota(_ vt: ValidatedToken) async throws -> VolumeQuota {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/os-quota-sets/\(vt.token.project.id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        // Cinder v3 quota response: {"quota_set": {...}}
        struct QuotaResp: Decodable { let quota_set: VolumeQuota }
        return try JSONDecoder().decode(QuotaResp.self, from: result.body).quota_set
    }

    // MARK: - Helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Cinder v3 block storage client.
public struct BlockStorageService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "cinder/v3") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> BlockStorageRegion {
        BlockStorageRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "cinder/v3", defaultRegion: region ?? cloud.regionName)
    }
}
