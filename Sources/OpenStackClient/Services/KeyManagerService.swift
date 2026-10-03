import Foundation
import Logging

/// Region-bound Barbican (key manager) client.
///
/// Keystone service type: `key-manager`. API base path: `barbican/v1`.
/// Barbican is a standard OpenStack REST API: collections live at
/// `/v1/secrets` and `/v1/containers`, items at `/v1/secrets/{id}`. Secrets
/// carry a status lifecycle (`inactive` -> `active` -> `expired`/`deleted`),
/// so they are pollable by the waiter.
public struct KeyManagerRegion: Sendable {
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
    private let serviceRoot: String = "v1"
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "key-manager"

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
        timeoutOverride: Duration? = nil
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
            timeoutOverride: timeoutOverride,
            overrideBase: ep.overrideBase
        )
    }

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "key-manager", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Secrets

    public func listSecrets(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Secret] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "secret", suffix: suffix)

        if let cached = try await cache.get(key, ttl: .seconds(120), as: [Secret].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/secrets", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        // Barbican list responses are a keyed envelope: {"secrets":[...], "secrets_links":{}}.
        struct Envelope: Decodable { let secrets: [Secret] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: result.body)
        let secrets = envelope.secrets
        await cache.put(key, ttl: .seconds(120), value: secrets)
        return secrets
    }

    public func getSecret(_ vt: ValidatedToken, id: String) async throws -> Secret {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/secrets/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Secret.self, from: result.body)
    }

    public func createSecret(_ vt: ValidatedToken, _ spec: CreateSecretSpec) async throws -> Secret {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/secrets", body: Data(spec.body().utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "secret", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Secret.self, from: result.body)
    }

    public func deleteSecret(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/secrets/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "secret", tokenID: vt.token.id, region: region)
    }

    /// Fetch a secret's payload (the actual secret value). Only readable when
    /// the token's roles permit; Barbican returns the payload + content type.
    public func getSecretPayload(_ vt: ValidatedToken, id: String) async throws -> SecretPayload {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/secrets/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(SecretPayload.self, from: result.body)
    }

    // MARK: - Containers

    public func listContainers(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [SecretContainer] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "container", suffix: suffix)

        if let cached = try await cache.get(key, ttl: .seconds(120), as: [SecretContainer].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/containers", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        // Barbican list responses are a keyed envelope: {"containers":[...], "containers_links":{}}.
        struct Envelope: Decodable { let containers: [SecretContainer] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: result.body)
        let containers = envelope.containers
        await cache.put(key, ttl: .seconds(120), value: containers)
        return containers
    }

    public func getContainer(_ vt: ValidatedToken, id: String) async throws -> SecretContainer {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/containers/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(SecretContainer.self, from: result.body)
    }

    public func deleteContainer(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/containers/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "container", tokenID: vt.token.id, region: region)
    }

    // MARK: - Helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Barbican key-manager client.
public struct KeyManagerService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "barbican/v1") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> KeyManagerRegion {
        KeyManagerRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "barbican/v1", defaultRegion: region ?? cloud.regionName)
    }
}
