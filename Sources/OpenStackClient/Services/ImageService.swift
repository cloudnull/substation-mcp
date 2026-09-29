import Foundation
import Logging

/// Region-bound Glance v2 client.
public struct ImageRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
    }

    // MARK: - Images

    public func listImages(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Image] {
        let region = resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "image", suffix: suffix)

        if let cached = try await cache.get(key, ttl: .seconds(300), as: [Image].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await transport.request(
            method: "GET",
            service: "image",
            path: "\(basePath)/images",
            query: query,
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }

        struct ImageList: Decodable { let images: [Image] }
        let decoded = try JSONDecoder().decode(ImageList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.images)
        return decoded.images
    }

    public func getImage(_ vt: ValidatedToken, id: String) async throws -> Image {
        _ = resolveRegion(vt)
        let result = try await transport.request(
            method: "GET",
            service: "image",
            path: "\(basePath)/images/\(id)",
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        struct Resp: Decodable { let image: Image }
        return try JSONDecoder().decode(Resp.self, from: result.body).image
    }

    public func createImage(_ vt: ValidatedToken, _ spec: CreateImageSpec) async throws -> Image {
        let region = resolveRegion(vt)
        let result = try await transport.request(
            method: "POST",
            service: "image",
            path: "\(basePath)/images",
            body: spec.body().data(using: .utf8),
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
        struct Resp: Decodable { let image: Image }
        return try JSONDecoder().decode(Resp.self, from: result.body).image
    }

    public func updateImage(
        _ vt: ValidatedToken,
        id: String,
        name: String? = nil,
        visibility: String? = nil,
        protected: Bool? = nil,
        properties: [String: String]? = nil,
        status: String? = nil
    ) async throws -> Image {
        let region = resolveRegion(vt)
        var parts: [String] = []
        if let name { parts.append("\"name\":\"\(name)\"") }
        if let visibility { parts.append("\"visibility\":\"\(visibility)\"") }
        if let protected { parts.append("\"protected\":\(protected ? "true" : "false")") }
        if let properties {
            let props = properties.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"properties\":{\(props)}")
        }
        if let status { parts.append("\"status\":\"\(status)\"") }
        let body = "{\"image\":{\(parts.joined(separator: ","))}}"

        let result = try await transport.request(
            method: "PATCH",
            service: "image",
            path: "\(basePath)/images/\(id)",
            body: body.data(using: .utf8),
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
        struct Resp: Decodable { let image: Image }
        return try JSONDecoder().decode(Resp.self, from: result.body).image
    }

    public func deleteImage(_ vt: ValidatedToken, id: String) async throws {
        let region = resolveRegion(vt)
        let result = try await transport.request(
            method: "DELETE",
            service: "image",
            path: "\(basePath)/images/\(id)",
            tokenOverride: vt.token.id
        )
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    // MARK: - Tags

    public func addTags(_ vt: ValidatedToken, id: String, tags: [String]) async throws {
        let region = resolveRegion(vt)
        let joined = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let body = "{\"tags\":[\(joined)]}"
        let result = try await transport.request(
            method: "PUT",
            service: "image",
            path: "\(basePath)/images/\(id)/tags",
            body: body.data(using: .utf8),
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    public func removeTag(_ vt: ValidatedToken, id: String, tag: String) async throws {
        let region = resolveRegion(vt)
        let result = try await transport.request(
            method: "DELETE",
            service: "image",
            path: "\(basePath)/images/\(id)/tags/\(tag)",
            tokenOverride: vt.token.id
        )
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    // MARK: - Visibility / Protect / Deactivate

    public func setVisibility(_ vt: ValidatedToken, id: String, visibility: String) async throws -> Image {
        try await updateImage(vt, id: id, visibility: visibility)
    }

    public func protect(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, protected: true)
    }

    public func unprotect(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, protected: false)
    }

    public func deactivate(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, status: "deactivated")
    }

    public func reactivate(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, status: "active")
    }

    // MARK: - Upload

    /// Import an image via the web-download mechanism. The fake fetches from
    /// the given URI (which can point at its own static file route).
    public func importImage(_ vt: ValidatedToken, id: String, mechanism: String, uri: String) async throws {
        let region = resolveRegion(vt)
        let body = "{\"import\":\(mechanism == "web-download" ? "{\"method\":\"web-download\",\"uri\":\"\(uri)\"}" : "{}}")}"
        let result = try await transport.request(
            method: "POST",
            service: "image",
            path: "\(basePath)/images/\(id)/import",
            body: body.data(using: .utf8),
            tokenOverride: vt.token.id
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    /// Upload a small base64-encoded payload directly via PUT with X-Image-Meta headers.
    public func uploadImage(_ vt: ValidatedToken, id: String, data: String, diskFormat: String) async throws {
        let region = resolveRegion(vt)
        let payload = Data(data.utf8)
        let result = try await transport.request(
            method: "PUT",
            service: "image",
            path: "\(basePath)/images/\(id)",
            body: payload,
            tokenOverride: vt.token.id,
            extraHeaders: [
                ("X-Image-Meta-Format", diskFormat),
                ("Content-Type", "application/octet-stream")
            ]
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    // MARK: - Helpers

    private func resolveRegion(_ vt: ValidatedToken) -> String {
        cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
    }
}

/// Glance v2 image client.
public struct ImageService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String = "glance/v2") {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
    }

    public func region(_ region: String? = nil) -> ImageRegion {
        ImageRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "glance/v2")
    }
}
