import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Glance v2 implementation.
///
/// Routes live under `/glance/v2/*`. Errors use the Glance shape: plain-text
/// body with the status line (e.g. `404 Not Found`). Pagination is via the
/// `Link: <...>; rel="next"` response header.
public struct GlanceFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/glance/v2"

        // MARK: - Static file route (for web-download imports)

        // Serves a small fake qcow2 payload. The URI in the import request
        // points here; the fake fetches it (its own route) and sets the image
        // active. A missing path yields 404, which the fake maps to `killed`.
        router.get("/static/image.qcow2") { _, _ in
            let payload = Data("FAKEQCOW2PAYLOAD-0123456789".utf8)
            return Response(
                status: .ok,
                headers: [.contentType: "application/octet-stream"],
                body: .init(byteBuffer: .init(bytes: payload))
            )
        }

        // MARK: - Images

        router.get("\(base)/images") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let imgs = await state.listImages(projectID: token.projectID, limit: limit, marker: marker)
            let items = imgs.map { Self.imageJSON($0) }.joined(separator: ",")

            // Build a Link: rel=next header if more pages remain.
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let all = await state.listImages(projectID: token.projectID)
            var nextIndex = -1
            // The marker is the LAST id of the previous page, so it is not in
            // the current page — look it up in the full list. (Matching it
            // against `imgs` left nextIndex at -1 and the subscript below
            // trapped on Index out of range.)
            if let marker, let idx = all.firstIndex(where: { $0.id == marker }) {
                nextIndex = idx
            }
            if marker == nil { nextIndex = imgs.count - 1 }
            if imgs.count == limit && nextIndex >= 0 && nextIndex + 1 < all.count {
                let nextMarker = imgs[nextIndex].id
                headers[HTTPField.Name("Link")!] = ";\(base)/images?marker=\(nextMarker)&limit=\(limit); rel=\"next\""
            }
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: .init(string: """
                {"images":[\(items)]}
                """))
            )
        }

        router.get("\(base)/images/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let img = await state.getImage(id: id, projectID: token.projectID) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            // Glance v2 GET /images/{id} returns the image directly (no wrapper)
            return Self.jsonResponse(status: .ok, body: Self.imageJSON(img))
        }

        // Glance v2 accepts the image attributes at the TOP LEVEL. A `{"image":
        // {...}}` body is not merely tolerated — it is a hard 400, because the
        // schema's `additionalProperties` is `{"type": "string"}` (custom
        // properties) and an object-valued `image` key fails it. The fake holds
        // that line so a wrapped request cannot pass tests, and replies flat.
        router.post("\(base)/images") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let body = try await Self.readBody(req)
            if let err = Self.schemaError(for: body) { return err }
            let name = Self.stringField("name", in: body) ?? ""
            let visibility = Self.stringField("visibility", in: body) ?? "private"
            let diskFormat = Self.stringField("disk_format", in: body) ?? "raw"
            let containerFormat = Self.stringField("container_format", in: body) ?? "bare"
            let minRAM = Self.intField("min_ram", in: body) ?? 0
            let protected = Self.boolField("protected", in: body) ?? false
            let img = await state.createImage(
                projectID: token.projectID,
                name: name,
                visibility: visibility,
                diskFormat: diskFormat,
                containerFormat: containerFormat,
                minRAM: minRAM,
                protected: protected,
                properties: Self.customProperties(in: body)
            )
            return Self.jsonResponse(status: .created, body: Self.imageJSON(img))
        }

        // Glance's PATCH contract, held to the letter: the media type must be
        // application/openstack-images-v2.{0,1}-json-patch (anything else is a
        // 415), the body must be an RFC 6902 operation ARRAY (a flat attribute
        // map is a 400 even with the right media type), and `status` is a
        // read-only attribute (403). Live-verified on Genestack 2024.1.
        router.patch("\(base)/images/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let mediaType = (req.headers[.contentType] ?? "")
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard Self.patchMediaTypes.contains(mediaType) else {
                return Self.glanceError(
                    status: .unsupportedMediaType,
                    message: "415 Unsupported Media Type: The request media type \(mediaType.isEmpty ? "<unset>" : mediaType) is not supported by this server."
                )
            }
            let body = try await Self.readBody(req)
            guard let ops = Self.parsePatchOps(body) else {
                return Self.glanceError(
                    status: .badRequest,
                    message: "400 Bad Request: Request body must be a JSON array of operation objects."
                )
            }
            if let err = Self.patchOpsError(for: ops) { return err }
            let edits = Self.imagePatchEdits(from: ops)
            guard let img = await state.updateImage(
                id: id, projectID: token.projectID,
                name: edits.name, visibility: edits.visibility,
                protected: edits.protected, minRAM: edits.minRAM, tags: edits.tags,
                setProperties: edits.setProperties, removedProperties: edits.removedProperties
            ) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            return Self.jsonResponse(status: .ok, body: Self.imageJSON(img))
        }

        router.delete("\(base)/images/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteImage(id: id, projectID: token.projectID) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            return Response(status: .accepted)
        }

        // MARK: - Tags

        router.put("\(base)/images/:id/tags") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            guard let tags = Self.stringArrayField("tags", in: body) else {
                return Self.glanceError(status: .badRequest,
                                        message: "400 Bad Request: Provided object does not match schema 'tags'")
            }
            guard let img = await state.addTags(id: id, projectID: token.projectID, tags: tags) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            // Glance returns the updated image, unwrapped.
            return Self.jsonResponse(status: .ok, body: Self.imageJSON(img))
        }

        router.delete("\(base)/images/:id/tags/:tag") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let tag = ctx.parameters.get("tag") ?? ""
            guard await state.removeTag(id: id, projectID: token.projectID, tag: tag) != nil else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            return Response(status: .noContent)
        }

        // MARK: - Import (web-download)

        router.post("\(base)/images/:id/import") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            // POST /images/{id}/import takes a FLAT {"method","uri"} body; the
            // `{"import": {...}}` wrapper is not in the Glance schema.
            guard let importBody = Self.parseObject(body),
                  Self.stringField("import", in: body) == nil,
                  importBody["import"] == nil else {
                return Self.textError(status: .badRequest, message: "400 Bad Request")
            }
            let method = importBody["method"] as? String ?? ""
            let uri = importBody["uri"] as? String ?? ""
            guard method == "web-download" else {
                return Self.textError(status: .badRequest, message: "400 Bad Request")
            }

            // Fetch the URI. The fake's own base host is registered in state.
            let baseHost = await state.baseHost
            _ = baseHost
            guard !uri.isEmpty else {
                _ = await state.setImportResult(id: id, projectID: token.projectID, active: false, size: 0, statusReason: "import URI is empty")
                return Self.textError(status: .badRequest, message: "400 Bad Request")
            }

            // Determine if the URI is reachable: it must be one of the fake's
            // static routes. We test by checking the path against known routes.
            let path = URL(string: uri)?.path ?? ""
            if path == "/static/image.qcow2" {
                let size = "FAKEQCOW2PAYLOAD-0123456789".utf8.count
                _ = await state.setImportResult(id: id, projectID: token.projectID, active: true, size: size, statusReason: nil)
                return Response(status: .accepted)
            } else {
                _ = await state.setImportResult(id: id, projectID: token.projectID, active: false, size: 0, statusReason: "import source not found: \(path)")
                return Response(status: .accepted)
            }
        }

        // MARK: - Direct upload (base64/small payload)

        // PUT /images/:id with X-Image-Meta-Format header uploads data directly.
        // We register this AFTER the GET/POST/PATCH/DELETE so the method
        // discriminates (Hummingbird matches on method + path).
        router.put("\(base)/images/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            var data = ""
            for try await buffer in req.body {
                data += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            }
            let payload: Data
            if let decoded = Data(base64Encoded: data) {
                payload = decoded
            } else {
                payload = Data(data.utf8)
            }
            guard let img = await state.setImageData(id: id, projectID: token.projectID, data: payload) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            _ = img
            return Response(status: .accepted)
        }
    }

    // MARK: - JSON builders

    static func imageJSON(_ img: FakeState.FakeImage) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(jsonString(img.id))\"")
        parts.append("\"name\":\"\(jsonString(img.name))\"")
        parts.append("\"status\":\"\(jsonString(img.status))\"")
        if let reason = img.statusReason {
            parts.append("\"status_reason\":\"\(jsonString(reason))\"")
        }
        parts.append("\"visibility\":\"\(jsonString(img.visibility))\"")
        parts.append("\"disk_format\":\"\(jsonString(img.diskFormat))\"")
        parts.append("\"container_format\":\"\(jsonString(img.containerFormat))\"")
        parts.append("\"size\":\(img.size)")
        parts.append("\"min_ram\":\(img.minRAM)")
        parts.append("\"protected\":\(img.protected)")
        let tags = img.tags.map { "\"\(jsonString($0))\"" }.joined(separator: ",")
        parts.append("\"tags\":[\(tags)]")
        let props = img.properties.sorted { $0.key < $1.key }
            .map { "\"\(jsonString($0.key))\":\"\(jsonString($0.value))\"" }
            .joined(separator: ",")
        parts.append("\"properties\":{\(props)}")
        parts.append("\"created_at\":\"\(jsonString(img.created))\"")
        parts.append("\"updated_at\":\"\(jsonString(img.updated))\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Escapes a value for a JSON string literal in a hand-built reply. Names and
    /// custom properties are caller data: an unescaped quote or newline in one
    /// would make the fake's own reply unparseable, which reads as a client bug.
    static func jsonString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    // MARK: - Request body parsing

    /// Glance v2's image schema takes attributes at the TOP LEVEL and declares
    /// `additionalProperties: {"type": "string"}` — that is how custom properties
    /// travel. Two consequences the fake must reproduce, because they are the only
    /// thing that catches a wrapped request body:
    ///   * `{"image": {...}}` is a hard 400, not a tolerated alias: `image` is
    ///     read as a custom property and an object is not a string.
    ///   * a read-only attribute in a create/PATCH body is a 400.
    ///
    /// Parsed with `JSONSerialization`, not substring scanning: the value of a
    /// custom property is caller data and may itself contain `":"`, `","` or a
    /// brace, which the substring helpers would mis-scan into a wrong verdict.
    static func parseObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Glance's own image attributes as they appear on the wire. Any other
    /// top-level key is a custom property and must carry a string value.
    static let glanceImageAttributes: Set<String> = [
        "id", "name", "status", "status_reason", "visibility", "disk_format",
        "container_format", "size", "min_ram", "min_disk", "protected", "tags",
        "properties", "created_at", "updated_at", "owner", "schema", "direct_url",
        "self", "file", "virtual_size", "checksum", "os_hash_algo", "os_hash_value",
        "imports", "os_hidden"
    ]

    /// Attributes a client may never send on create. `status` is deliberately
    /// absent: Glance accepts it on create (register an image directly as
    /// `active`). On PATCH it is read-only — see `patchReadOnlyAttributes`.
    static let glanceReadOnlyAttributes: Set<String> = [
        "id", "status_reason", "created_at", "updated_at", "owner",
        "schema", "self", "file", "direct_url", "size", "checksum",
        "virtual_size", "os_hash_algo", "os_hash_value", "imports"
    ]

    /// Media types Glance accepts on `PATCH /v2/images/{id}`. Anything else is a
    /// 415, including plain `application/json` and `application/json-patch+json`.
    static let patchMediaTypes: Set<String> = [
        "application/openstack-images-v2.1-json-patch",
        "application/openstack-images-v2.0-json-patch"
    ]

    /// Attributes Glance refuses to change over PATCH. `status` is the one that
    /// matters here: it is set through Glance's admin-only v1-compatibility
    /// route, not through PATCH.
    static let patchReadOnlyAttributes: Set<String> = ["status"]

    /// Parses a PATCH body into its RFC 6902 operation objects. Nil when the
    /// body is not an array of objects — Glance's own 400 for that shape.
    static func parsePatchOps(_ body: String) -> [[String: Any]]? {
        guard let data = body.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var ops: [[String: Any]] = []
        for element in array {
            guard let op = element as? [String: Any], op["op"] is String, op["path"] is String else { return nil }
            ops.append(op)
        }
        return ops
    }

    /// Glance's per-operation refusals. Returns the first one that applies.
    static func patchOpsError(for ops: [[String: Any]]) -> Response? {
        for op in ops {
            let path = (op["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let attribute = path.components(separatedBy: "/").first ?? path
            if patchReadOnlyAttributes.contains(attribute) {
                return glanceError(
                    status: .forbidden,
                    message: "403 Forbidden: Attribute '\(attribute)' is read-only."
                )
            }
            // Custom properties are string-valued; a non-string value on an
            // attribute Glance does not type-check still has to be a string.
            if !glanceImageAttributes.contains(attribute), let value = op["value"], !(value is String) {
                return glanceError(
                    status: .badRequest,
                    message: "400 Bad Request: Provided object does not match schema 'image': "
                        + "{\"\(attribute)\": \(jsonScalar(value))} is not of type 'string'"
                )
            }
        }
        return nil
    }

    /// The fake's own edit set for a patch document: which base attributes are
    /// replaced, which custom properties are set or removed, and the whole-list
    /// replacement for `tags`.
    struct ImagePatchEdits: Sendable {
        var name: String?
        var visibility: String?
        var protected: Bool?
        var minRAM: Int?
        var tags: [String]?
        var setProperties: [String: String] = [:]
        var removedProperties: [String] = []
    }

    /// Turns RFC 6902 operations into `ImagePatchEdits`. `add` and `replace` are
    /// treated alike (Glance does, for these attributes); `remove` on a custom
    /// property clears it.
    static func imagePatchEdits(from ops: [[String: Any]]) -> ImagePatchEdits {
        var edits = ImagePatchEdits()
        for op in ops {
            let name = op["op"] as? String ?? ""
            let path = op["path"] as? String ?? ""
            let attribute = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .components(separatedBy: "/").first ?? path
            let value = op["value"]
            switch attribute {
            case "name": edits.name = value as? String
            case "visibility": edits.visibility = value as? String
            case "protected": edits.protected = value as? Bool
            case "min_ram":
                if let i = value as? Int { edits.minRAM = i }
                else if let d = value as? Double { edits.minRAM = Int(d) }
            case "tags": edits.tags = (value as? [Any])?.compactMap { $0 as? String }
            default:
                if name == "remove" {
                    edits.removedProperties.append(unescapePointerSegment(attribute))
                } else if let s = value as? String {
                    edits.setProperties[unescapePointerSegment(attribute)] = s
                }
            }
        }
        return edits
    }

    /// RFC 6901 percent/tilde unescaping for a path segment.
    static func unescapePointerSegment(_ segment: String) -> String {
        segment.replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }

    /// Validates a create body against Glance's flat schema. Returns a
    /// Glance-shaped 400 when unacceptable, nil when acceptable.
    static func schemaError(for body: String) -> Response? {
        guard let dict = parseObject(body) else {
            return glanceError(status: .badRequest, message: "400 Bad Request: malformed JSON body")
        }
        if dict["image"] != nil {
            return glanceError(
                status: .badRequest,
                message: "400 Bad Request: Provided object does not match schema 'image': "
                    + "{\"image\": ...} is not of type 'string'"
            )
        }
        if dict["properties"] != nil {
            return glanceError(
                status: .badRequest,
                message: "400 Bad Request: Provided object does not match schema 'image': "
                    + "{\"properties\": ...} is not of type 'string'"
            )
        }
        for key in dict.keys.sorted() where glanceReadOnlyAttributes.contains(key) {
            return glanceError(
                status: .badRequest,
                message: "400 Bad Request: Property \(key) is read-only and cannot be set."
            )
        }
        // Every non-attribute top-level key is a custom property: string-typed.
        for (key, value) in dict.sorted(by: { $0.key < $1.key })
        where !glanceImageAttributes.contains(key) {
            if value is String { continue }
            return glanceError(
                status: .badRequest,
                message: "400 Bad Request: Provided object does not match schema 'image': "
                    + "{\"\(key)\": \(jsonScalar(value))} is not of type 'string'"
            )
        }
        return nil
    }

    /// Custom properties carried as top-level string keys on a create body.
    static func customProperties(in body: String) -> [String: String] {
        guard let dict = parseObject(body) else { return [:] }
        var props: [String: String] = [:]
        for (key, value) in dict where !glanceImageAttributes.contains(key) {
            if let s = value as? String { props[key] = s }
        }
        return props
    }

    /// A JSON rendering of a scalar, for error text.
    private static func jsonScalar(_ value: Any) -> String {
        if let s = value as? String { return "\"\(s)\"" }
        if value is [Any] { return "[...]" }
        if value is [String: Any] { return "{...}" }
        return "\(value)"
    }

    /// A top-level string attribute of a parsed body.
    static func stringField(_ key: String, in body: String) -> String? {
        parseObject(body)?[key] as? String
    }

    /// A top-level integer attribute of a parsed body.
    static func intField(_ key: String, in body: String) -> Int? {
        guard let value = parseObject(body)?[key] else { return nil }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// A top-level boolean attribute of a parsed body.
    static func boolField(_ key: String, in body: String) -> Bool? {
        parseObject(body)?[key] as? Bool
    }

    /// A top-level string array of a parsed body.
    static func stringArrayField(_ key: String, in body: String) -> [String]? {
        parseObject(body)?[key] as? [String]
    }


    // MARK: - Helpers

    static func readBody(_ req: Request) async throws -> String {
        var data = ""
        for try await buffer in req.body {
            data += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        }
        return data
    }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func textError(status: HTTPResponse.Status, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: .init(string: message))
        )
    }

    /// Glance-shaped error (plain-text body carrying the status line). Used for
    /// the PATCH media-type guard so a wrong Content-Type surfaces as a real 415.
    static func glanceError(status: HTTPResponse.Status, message: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: .init(string: message))
        )
    }
}
