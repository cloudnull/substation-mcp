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

        let result = try await transport.request(
            method: "GET",
            service: "key-manager",
            path: "\(basePath)/secrets",
            query: query,
            tokenOverride: vt.token.id
        )
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
        _ = try resolveRegion(vt)
        let result = try await transport.request(
            method: "GET",
            service: "key-manager",
            path: "\(basePath)/secrets/\(id)",
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(Secret.self, from: result.body)
    }

    public func createSecret(_ vt: ValidatedToken, _ spec: CreateSecretSpec) async throws -> Secret {
        let region = try resolveRegion(vt)
        let result = try await transport.request(
            method: "POST",
            service: "key-manager",
            path: "\(basePath)/secrets",
            body: Data(spec.body().utf8),
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "secret", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Secret.self, from: result.body)
    }

    public func deleteSecret(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(
            method: "DELETE",
            service: "key-manager",
            path: "\(basePath)/secrets/\(id)",
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "secret", tokenID: vt.token.id, region: region)
    }

    /// Fetch a secret's payload (the actual secret value). Only readable when
    /// the token's roles permit; Barbican returns the payload + content type.
    public func getSecretPayload(_ vt: ValidatedToken, id: String) async throws -> SecretPayload {
        _ = try resolveRegion(vt)
        let result = try await transport.request(
            method: "GET",
            service: "key-manager",
            path: "\(basePath)/secrets/\(id)",
            tokenOverride: vt.token.id
        )
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

        let result = try await transport.request(
            method: "GET",
            service: "key-manager",
            path: "\(basePath)/containers",
            query: query,
            tokenOverride: vt.token.id
        )
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
        _ = try resolveRegion(vt)
        let result = try await transport.request(
            method: "GET",
            service: "key-manager",
            path: "\(basePath)/containers/\(id)",
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "key-manager", requestID: result.requestID, hasAccessRules: false)
        }
        return try JSONDecoder().decode(SecretContainer.self, from: result.body)
    }

    public func deleteContainer(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await transport.request(
            method: "DELETE",
            service: "key-manager",
            path: "\(basePath)/containers/\(id)",
            tokenOverride: vt.token.id
        )
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
