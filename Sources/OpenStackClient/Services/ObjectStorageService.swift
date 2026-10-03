import Foundation
import Logging

/// Region-bound Swift (object storage) client.
///
/// Keystone service type: `object-store`. API base path: `swift/v1`. Swift is
/// a header/account-oriented REST API: the "account" is the tenant (the token's
/// project). Containers live at `/v1/<account>/<container>` and objects at
/// `/v1/<account>/<container>/<object>`.
public struct ObjectStorageRegion: Sendable {
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
    private let catalogType: String = "object-store"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "object-store", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // The Swift account is the tenant; use the token's project name (falling
    // back to the id). Real Swift resolves the account from the token the same
    // way; the fake seeds its account to match.
    private func account(_ vt: ValidatedToken) -> String {
        vt.token.project.name ?? vt.token.project.id
    }

    // Swift paths embed the account / container / object names as raw segments.
    // Those can contain characters (spaces, etc.) that must be percent-encoded,
    // otherwise the request line is malformed and the HTTP router crashes.
    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Containers

    public func listContainers(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Container] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "container", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(120), as: [Container].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(enc(account(vt)))", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }

        // Swift container listings are a bare JSON array of [name, count, bytes]
        // triples where name is a string and count/bytes are integers:
        //   [["bucket", 3, 1234], ...]
        struct Triple: Decodable {
            let name: String
            let count: Int?
            let bytes: Int?
            enum CodingKeys: String, CodingKey { case name, count, bytes }
            // The wire shape is a JSON *array*, not an object; map positionally.
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                name = try c.decode(String.self)
                count = try c.decodeIfPresent(Int.self)
                bytes = try c.decodeIfPresent(Int.self)
            }
        }
        let triples = try JSONDecoder().decode([Triple].self, from: result.body)
        let containers = triples.map { t in
            Container(id: t.name, name: t.name, count: t.count, bytes: t.bytes)
        }
        await cache.put(key, ttl: .seconds(120), value: containers)
        return containers
    }

    public func getContainer(_ vt: ValidatedToken, name: String) async throws -> Container {
        let region = try resolveRegion(vt)
        // Real Swift exposes container metadata via HEAD (headers, no body).
        // Some HTTP stacks handle a container-scoped GET (object listing) and a
        // HEAD differently, so we resolve a container by listing the account's
        // containers and matching by name; a missing container 404s.
        let ctns = try await listContainers(vt)
        if let match = ctns.first(where: { $0.name == name }) {
            return match
        }
        // Confirm the 404 with a direct probe so the error shape is precise.
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(enc(account(vt)))/\(enc(name))")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }
        return Container(id: name, name: name)
    }

    public func createContainer(_ vt: ValidatedToken, _ spec: CreateContainerSpec) async throws -> Container {
        let region = try resolveRegion(vt)
        var extra = spec.headers()
        extra.append(("X-Trans-Id", "osmcp-\(spec.name)"))
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/\(enc(account(vt)))/\(enc(spec.name))", body: Data("{}".utf8), extraHeaders: extra)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "container", tokenID: vt.token.id, region: region)
        return Container(id: spec.name, name: spec.name, quotaBytes: spec.quotaBytes)
    }

    public func deleteContainer(_ vt: ValidatedToken, name: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(enc(account(vt)))/\(enc(name))")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "container", tokenID: vt.token.id, region: region)
    }

    // MARK: - Objects

    public func listObjects(
        _ vt: ValidatedToken,
        container: String,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Object] {
        let region = try resolveRegion(vt)
        let suffix = "c:\(container):f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "object", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(60), as: [Object].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(enc(account(vt)))/\(enc(container))", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }

        let objects = try JSONDecoder().decode([Object].self, from: result.body)
        await cache.put(key, ttl: .seconds(60), value: objects)
        return objects
    }

    public func getObject(_ vt: ValidatedToken, container: String, name: String) async throws -> Object {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(enc(account(vt)))/\(enc(container))/\(enc(name))", query: [URLQueryItem(name: "format", value: "json")])
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }
        // format=json returns the object metadata; the fake serves it directly.
        if !result.body.isEmpty, let obj = try? JSONDecoder().decode(Object.self, from: result.body) {
            return obj
        }
        return Object(id: name, name: name)
    }

    public func createObject(_ vt: ValidatedToken, _ spec: CreateObjectSpec) async throws -> Object {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "PUT", path: "\(basePath)/\(enc(account(vt)))/\(enc(spec.container))/\(enc(spec.name))", body: Data(spec.content.utf8), extraHeaders: spec.headers())
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "object", tokenID: vt.token.id, region: region)
        return Object(id: spec.name, name: spec.name, size: spec.content.count, contentType: spec.contentType)
    }

    public func deleteObject(_ vt: ValidatedToken, container: String, name: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/\(enc(account(vt)))/\(enc(container))/\(enc(name))")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "object-store", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "object", tokenID: vt.token.id, region: region)
    }

    // MARK: - Helpers

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: serviceType, region: region, vt: vt)
        return region
    }
}

/// Swift object-storage client.
public struct ObjectStorageService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "swift/v1") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> ObjectStorageRegion {
        ObjectStorageRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "swift/v1", defaultRegion: region ?? cloud.regionName)
    }
}
