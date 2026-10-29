import Foundation
import Logging

/// Region-bound Glance v2 client.
public struct ImageRegion: Sendable {
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
    private let serviceRoot: String = "v2"
    /// The Keystone catalog service type (may differ from the transport label,
    /// e.g. magnum is catalog type `container-infra` but labeled `container`).
    private let catalogType: String = "image"

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

    init(cloud: CloudEntry, transport: Transport, cache: Cache, logger: Logger, basePath: String, serviceType: String = "image", defaultRegion: String? = nil) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.logger = logger
        self.basePath = basePath
        self.serviceType = serviceType
        self.defaultRegion = defaultRegion
    }

    // MARK: - Images

    public func listImages(
        _ vt: ValidatedToken,
        filters: [String: String] = [:],
        limit: Int? = nil,
        marker: String? = nil
    ) async throws -> [Image] {
        let region = try resolveRegion(vt)
        let suffix = "f:\(filters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")):l:\(limit ?? 0):m:\(marker ?? "")"
        let key = CacheKey(tokenID: vt.token.id, region: region, resource: "image", suffix: suffix)

        if let cached = await cache.get(key, ttl: .seconds(300), as: [Image].self) {
            return cached
        }

        var query: [URLQueryItem] = []
        for (k, v) in filters { query.append(URLQueryItem(name: k, value: v)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }

        let result = try await req(vt, region, method: "GET", path: "\(basePath)/images", query: query)
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }

        struct ImageList: Decodable { let images: [Image] }
        let decoded = try JSONDecoder().decode(ImageList.self, from: result.body)
        await cache.put(key, ttl: .seconds(300), value: decoded.images)
        return decoded.images
    }

    public func getImage(_ vt: ValidatedToken, id: String) async throws -> Image {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "GET", path: "\(basePath)/images/\(id)")
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        // Glance v2 GET /images/{id} returns the image object directly
        // (not wrapped in {"image": ...}).
        return try JSONDecoder().decode(Image.self, from: result.body)
    }

    public func createImage(_ vt: ValidatedToken, _ spec: CreateImageSpec) async throws -> Image {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/images", body: spec.body().data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        // Glance v2 replies with the image object UNWRAPPED, exactly like
        // GET /images/{id}. Decoding `{image: Image}` here throws keyNotFound
        // *after* the image was created, so the caller sees a decode failure
        // for work that actually succeeded.
        return try JSONDecoder().decode(Image.self, from: result.body)
    }

    /// The media type Glance requires on `PATCH /v2/images/{id}`. Any other
    /// media type is refused with 415, and a flat attribute map is refused with
    /// 400 even when the media type is right — the body must be an RFC 6902
    /// operation array. Live-verified on Genestack 2024.1, and the Glance v2 API
    /// reference states the same rule, so there is no Glance to negotiate away
    /// from.
    static let patchMediaType = "application/openstack-images-v2.1-json-patch"

    /// Update an image through Glance's JSON-Patch surface.
    ///
    /// Only the attributes actually supplied become operations: an op for a nil
    /// argument would clear a value the caller never mentioned. `properties`
    /// carries Glance's CUSTOM properties, which are individual top-level keys
    /// on the image representation — Glance's image schema has no `properties`
    /// attribute — so each one is its own `add` op, and a nil value is a `remove`
    /// (Glance has no other way to clear a custom property).
    ///
    /// `min_disk` is patchable; Glance's `_readonly_properties` list does not
    /// include it, and it is the attribute that actually gates scheduling onto a
    /// store with enough room (`min_ram` alone is not enough for a large image).
    ///
    /// `status` is deliberately not patchable: Glance refuses it with
    /// `403 Attribute 'status' is read-only`, and the route that does change it
    /// is admin-only (see the `deactivate`/`reactivate` action notes).
    public func updateImage(
        _ vt: ValidatedToken,
        id: String,
        name: String? = nil,
        visibility: String? = nil,
        protected: Bool? = nil,
        properties: [String: String?]? = nil,
        minRAM: Int? = nil,
        minDisk: Int? = nil,
        tags: [String]? = nil
    ) async throws -> Image {
        let region = try resolveRegion(vt)
        var ops: [String] = []
        if let name { ops.append(Self.patchOp("replace", "/name", "\"\(jsonEscape(name))\"")) }
        if let visibility { ops.append(Self.patchOp("replace", "/visibility", "\"\(jsonEscape(visibility))\"")) }
        if let protected { ops.append(Self.patchOp("replace", "/protected", protected ? "true" : "false")) }
        if let minRAM { ops.append(Self.patchOp("replace", "/min_ram", "\(minRAM)")) }
        if let minDisk { ops.append(Self.patchOp("replace", "/min_disk", "\(minDisk)")) }
        if let tags {
            let list = tags.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
            ops.append(Self.patchOp("replace", "/tags", "[\(list)]"))
        }
        for (key, value) in (properties ?? [:]).sorted(by: { $0.key < $1.key }) {
            let path = Self.patchPath(key)
            if let value {
                ops.append(Self.patchOp("add", "/\(path)", "\"\(jsonEscape(value))\""))
            } else {
                ops.append(Self.patchRemoveOp("/\(path)"))
            }
        }
        let body = "[\(ops.joined(separator: ","))]"
        let result = try await req(
            vt, region, method: "PATCH", path: "\(basePath)/images/\(id)",
            body: body.data(using: .utf8),
            extraHeaders: [("Content-Type", Self.patchMediaType)]
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
        return try JSONDecoder().decode(Image.self, from: result.body)
    }

    /// One RFC 6902 operation. `value` is raw JSON, so integers, booleans and
    /// arrays are carried unquoted instead of being stringified.
    static func patchOp(_ op: String, _ path: String, _ value: String) -> String {
        "{\"op\":\"\(op)\",\"path\":\"\(path)\",\"value\":\(value)}"
    }

    /// A `remove` operation, which carries no `value` member. RFC 6902 says so,
    /// and Glance's deserializer reads `value` for `add`/`replace` only.
    private static func patchRemoveOp(_ path: String) -> String {
        "{\"op\":\"remove\",\"path\":\"\(path)\"}"
    }

    /// An RFC 6901 path segment for a custom property name: `~` and `/` are the
    /// pointer's own metacharacters, and the name is caller data.
    private static func patchPath(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    public func deleteImage(_ vt: ValidatedToken, id: String) async throws {
        let region = try resolveRegion(vt)
        let result = try await req(vt, region, method: "DELETE", path: "\(basePath)/images/\(id)")
        if ![200, 202, 204].contains(result.status) {
            if !(200...299).contains(result.status) {
                throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
            }
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    // MARK: - Tags

    /// Adds tags without dropping the ones already on the image.
    ///
    /// Glance has no append operation for tags: `/tags` is patchable only as a
    /// whole-list `replace` (live-verified on Genestack 2024.1 — `add` with the
    /// RFC 6902 array-append pointer `/tags/-` is a 400 `Invalid JSON pointer
    /// for this resource`, and `add /tags` with an array is accepted but just
    /// sets the list). So a merge-then-replace is the only way to add: read the
    /// image, union, write the whole set.
    ///
    /// The read is the point. A bare `replace` of just the new tags silently
    /// deleted every tag the image already carried — live-verified on
    /// Genestack 2024.1, where `add_tag y` on an image tagged `x` by another
    /// writer left `["y"]`. The read is uncached: `getImage` hits Glance every
    /// time, so the merge sees writes this server never made.
    ///
    /// The dedicated member route `PUT /v2/images/{id}/tags/{tag_value}` is NOT
    /// used: it is a single-tag add with no whole-collection counterpart (a
    /// `PUT` to the collection is a 404, and Glance's source registers only the
    /// member route), so driving a multi-tag create through it would be one
    /// request per tag.
    public func addTags(_ vt: ValidatedToken, id: String, tags: [String]) async throws {
        let current = try await getImage(vt, id: id)
        var merged = current.tags
        for tag in tags where !merged.contains(tag) { merged.append(tag) }
        try await replaceTags(vt, id: id, tags: merged)
    }

    /// The whole-set write behind `addTags` and `removeTag`.
    private func replaceTags(_ vt: ValidatedToken, id: String, tags: [String]) async throws {
        let region = try resolveRegion(vt)
        let list = tags.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
        let ops = [Self.patchOp("replace", "/tags", "[\(list)]")]
        let result = try await req(
            vt, region, method: "PATCH", path: "\(basePath)/images/\(id)",
            body: "[\(ops.joined(separator: ","))]".data(using: .utf8),
            extraHeaders: [("Content-Type", Self.patchMediaType)]
        )
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    /// Removes one tag through the same whole-set write as `addTags`, so the
    /// tags the image carries stay intact. Glance's `DELETE
    /// /v2/images/{id}/tags/{tag_value}` would also work and 404s when the tag
    /// is absent, but it is a second mutation dialect for the same attribute;
    /// one path keeps the read-modify-write story single.
    public func removeTag(_ vt: ValidatedToken, id: String, tag: String) async throws {
        let current = try await getImage(vt, id: id)
        guard current.tags.contains(tag) else {
            throw OpenStackError(
                service: "image", status: 404, code: "itemNotFound",
                message: "Image \(id) carries no tag '\(tag)'.",
                hint: "Current tags: \(current.tags.isEmpty ? "(none)" : current.tags.joined(separator: ", "))."
            )
        }
        try await replaceTags(vt, id: id, tags: current.tags.filter { $0 != tag })
    }

    // MARK: - Visibility / Protect

    public func setVisibility(_ vt: ValidatedToken, id: String, visibility: String) async throws -> Image {
        try await updateImage(vt, id: id, visibility: visibility)
    }

    public func protect(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, protected: true)
    }

    public func unprotect(_ vt: ValidatedToken, id: String) async throws -> Image {
        try await updateImage(vt, id: id, protected: false)
    }

    // MARK: - Upload

    /// Import an image via the web-download mechanism. The fake fetches from
    /// the given URI (which can point at its own static file route).
    ///
    /// Glance's body is `{"method": {"name": …, "uri": …}}` — the method is an
    /// OBJECT and `uri` lives INSIDE it. Live-verified on Genestack 2024.1: the
    /// flat `{"method": "web-download", "uri": …}` form crashes Glance's
    /// `_validate_import_body` (`method['name']` on a String) with a **500**,
    /// and `{"method": {"name": …}}` with the uri omitted 400s "URI for
    /// web-download does not pass filtering: None". The fake accepted the flat
    /// form, which is how this shipped broken: the create path advertised
    /// `import`, the whole suite was green, and every real import died with an
    /// opaque HTTP 500.
    public func importImage(_ vt: ValidatedToken, id: String, mechanism: String, uri: String) async throws {
        let region = try resolveRegion(vt)
        let body = "{\"method\":{\"name\":\"\(jsonEscape(mechanism))\",\"uri\":\"\(jsonEscape(uri))\"}}"
        let result = try await req(vt, region, method: "POST", path: "\(basePath)/images/\(id)/import", body: body.data(using: .utf8))
        if !(200...299).contains(result.status) {
            throw OpenStackError.normalize(body: result.body, status: result.status, service: "image", requestID: result.requestID, hasAccessRules: false)
        }
        await cache.invalidate(resource: "image", tokenID: vt.token.id, region: region)
    }

    /// Upload a small base64-encoded payload directly via PUT with X-Image-Meta headers.
    public func uploadImage(_ vt: ValidatedToken, id: String, data: String, diskFormat: String) async throws {
        let region = try resolveRegion(vt)
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

    private func resolveRegion(_ vt: ValidatedToken) throws -> String {
        let region = defaultRegion ?? cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
        try guardEndpoint(serviceType: catalogType, region: region, vt: vt)
        return region
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
        ImageRegion(cloud: cloud, transport: transport, cache: cache, logger: logger, basePath: "glance/v2", defaultRegion: region ?? cloud.regionName)
    }
}
