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
    /// Async Cinder volume actions (extend/retype/set_bootable) often return 202 Accepted with an
    /// EMPTY body, not a `{volume}` envelope. Decoding an empty body as a Volume throws a spurious
    /// 500 even though the action succeeded. Best-effort decode; on empty/failed body, read the
    /// volume back so callers get authoritative post-action state.
    private func volumeAfterAction(_ vt: ValidatedToken, id: String, region: String, resultBody: Data) async throws -> Volume {
        if !resultBody.isEmpty, let decoded = try? JSONDecoder().decode(VolumeEnvelope.self, from: resultBody).volume {
            return decoded
        }
        return try await getVolume(vt, id: id)
    }
    private struct VolumeEnvelope: Decodable { let volume: Volume }


    public func extendVolume(_ vt: ValidatedToken, id: String, size: Int) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-extend\":{\"new_size\":\(size)}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        return try await volumeAfterAction(vt, id: id, region: region, resultBody: result.body)
    }

    public func retypeVolume(_ vt: ValidatedToken, id: String, volumeType: String) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-retype\":{\"new_type\":\"\(volumeType)\"}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        return try await volumeAfterAction(vt, id: id, region: region, resultBody: result.body)
    }

    public func setBootable(_ vt: ValidatedToken, id: String, bootable: Bool) async throws -> Volume {
        let region = try resolveRegion(vt)
        let body = "{\"os-set_bootable\":{\"bootable\":\(bootable ? "true" : "false")}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/volumes/\(id)/action", body: body.data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "volume", tokenID: vt.token.id, region: region)
        return try await volumeAfterAction(vt, id: id, region: region, resultBody: result.body)
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

    /// Cinder v3 serves volume types under the project-scoped collection
    /// `types` — **not** `volume-types`. Verified against the Cinder api-ref
    /// (`api-ref/source/v3/volumes-v3-types.inc`, mirrored at
    /// https://docs.openstack.org/api-ref/block-storage/v3/):
    ///   GET    /v3/{project_id}/types
    ///   GET    /v3/{project_id}/types/{volume_type_id}
    ///   POST   /v3/{project_id}/types
    ///   DELETE /v3/{project_id}/types/{volume_type_id}
    /// The old `volume-types` segment matched no route in Cinder's v3 mapper
    /// (`cinder/api/v3/router.py` registers `mapper.resource("type", "types")`),
    /// so every call 404'd with `itemNotFound` — including `os_list volume_type`
    /// for a plain project member.
    ///
    /// The `{project_id}` prefix is kept deliberately. Cinder ≥ Xena (microversion
    /// 3.67, `cinder/api/openstack/rest_api_version_history.rst`) also accepts the
    /// unscoped form `/v3/types`, but that form exists for *system- and
    /// domain-scoped* tokens; a project-scoped token — which is what a password
    /// login to a project yields — must send the project id. Listing is policy
    /// `volume_extension:type_get_all` = `rule:system_reader_or_project_reader`
    /// (`cinder/policies/volume_type.py`), i.e. any project member can read it;
    /// this is a path bug, never a permissions one.
    ///
    /// `is_public` is deliberately NOT sent: Cinder ignores it for non-admin
    /// callers (`cinder/api/v3/types.py` forces `filters['is_public'] = True`).
    public func listVolumeTypes(_ vt: ValidatedToken) async throws -> [VolumeType] {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/types", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let volume_types: [VolumeType] }
        return try JSONDecoder().decode(List.self, from: result.body).volume_types
    }

    public func getVolumeType(_ vt: ValidatedToken, id: String) async throws -> VolumeType {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/types/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let volume_type: VolumeType }
        return try JSONDecoder().decode(Resp.self, from: result.body).volume_type
    }

    public func createVolumeType(_ vt: ValidatedToken, _ spec: CreateVolumeTypeSpec) async throws -> VolumeType {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/\(projectID)/types", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let volume_type: VolumeType }
        return try JSONDecoder().decode(Resp.self, from: result.body).volume_type
    }

    public func deleteVolumeType(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(projectID)/types/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
    }

    // MARK: - Snapshots

    /// Cinder v3 registers snapshots project-scoped — `GET /v3/{project_id}/snapshots`,
    /// `POST …/snapshots`, `GET|DELETE …/snapshots/{id}`
    /// (`cinder/api/v3/router.py` `mapper.resource("snapshot", "snapshots", …)`;
    /// api-ref `volumes-v3-snapshots.inc`). Same class of bug as the volume-type
    /// path above: without the `{project_id}` segment the request matches no
    /// Cinder route and 404s. Detail listing is a separate collection route
    /// (`…/snapshots/detail`) whose rows carry `status`, `volume_id`, `size` and
    /// `created_at` (`cinder/api/views/snapshots.py`), which is what the models
    /// here decode, so listings go to `/detail`.

    public func listSnapshots(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Snapshot] {
        let region = try resolveRegion(vt)
        let projectID = vt.token.project.id
        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/snapshots/detail", query: query, extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let snapshots: [Snapshot] }
        return try JSONDecoder().decode(List.self, from: result.body).snapshots
    }

    public func getSnapshot(_ vt: ValidatedToken, id: String) async throws -> Snapshot {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(vt.token.project.id)/snapshots/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let snapshot: Snapshot }
        return try JSONDecoder().decode(Resp.self, from: result.body).snapshot
    }

    public func createSnapshot(_ vt: ValidatedToken, _ spec: CreateSnapshotSpec) async throws -> Snapshot {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/\(vt.token.project.id)/snapshots", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let snapshot: Snapshot }
        return try JSONDecoder().decode(Resp.self, from: result.body).snapshot
    }

    public func deleteSnapshot(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(vt.token.project.id)/snapshots/\(id)", extraHeaders: versionHeader)
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
            }
        }
    }

    // MARK: - Backups

    /// Backups are project-scoped in Cinder too
    /// (`GET /v3/{project_id}/backups/detail`, `POST …/backups`,
    /// `GET|DELETE …/backups/{id}`, `POST …/backups/{id}/restore`;
    /// cinder/api/v3/router.py + api-ref ext-backups.inc). The plain
    /// `…/backups` index is a *summary* view — `id`/`name`/`links` only
    /// (`cinder/api/views/backups.py` `summary`), which cannot satisfy the
    /// `Backup` model — so listings use `/detail`.

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

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(vt.token.project.id)/backups/detail", query: query, extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct List: Decodable { let backups: [Backup] }
        return try JSONDecoder().decode(List.self, from: result.body).backups
    }

    public func getBackup(_ vt: ValidatedToken, id: String) async throws -> Backup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(vt.token.project.id)/backups/\(id)", extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let backup: Backup }
        return try JSONDecoder().decode(Resp.self, from: result.body).backup
    }

    public func createBackup(_ vt: ValidatedToken, _ spec: CreateBackupSpec) async throws -> Backup {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/\(vt.token.project.id)/backups", body: spec.body().data(using: .utf8), extraHeaders: versionHeader)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "volume", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let backup: Backup }
        return try JSONDecoder().decode(Resp.self, from: result.body).backup
    }

    public func deleteBackup(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(vt.token.project.id)/backups/\(id)", extraHeaders: versionHeader)
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
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/\(vt.token.project.id)/backups/\(id)/restore", body: body.data(using: .utf8), extraHeaders: versionHeader)
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
