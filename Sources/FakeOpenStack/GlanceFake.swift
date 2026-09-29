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
            let allCount = await state.listImages(projectID: token.projectID).count
            var nextIndex = -1
            if let marker, let idx = imgs.firstIndex(where: { $0.id == marker }) {
                nextIndex = idx
            }
            if marker == nil { nextIndex = imgs.count - 1 }
            if imgs.count == limit && nextIndex + 1 < allCount {
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
            return Self.jsonResponse(status: .ok, body: """
            {"image":\(Self.imageJSON(img))}
            """)
        }

        router.post("\(base)/images") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let body = try await Self.readBody(req)
            let imgBody = Self.objectForKey("image", in: body) ?? body
            let name = Self.extractString("name", from: imgBody) ?? ""
            let visibility = Self.extractString("visibility", from: imgBody) ?? "private"
            let diskFormat = Self.extractString("disk_format", from: imgBody) ?? "raw"
            let containerFormat = Self.extractString("container_format", from: imgBody) ?? "bare"
            let minRAM = Self.extractInt("min_ram", from: imgBody) ?? 0
            let img = await state.createImage(
                projectID: token.projectID,
                name: name,
                visibility: visibility,
                diskFormat: diskFormat,
                containerFormat: containerFormat,
                minRAM: minRAM
            )
            return Self.jsonResponse(status: .created, body: """
            {"image":\(Self.imageJSON(img))}
            """)
        }

        router.patch("\(base)/images/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.textError(status: .unauthorized, message: "401 Unauthorized")
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = try await Self.readBody(req)
            let imgBody = Self.objectForKey("image", in: body) ?? body
            let name = Self.extractString("name", from: imgBody)
            let visibility = Self.extractString("visibility", from: imgBody)
            let protected = Self.extractBool("protected", from: imgBody)
            let status = Self.extractString("status", from: imgBody)
            guard let img = await state.updateImage(
                id: id, projectID: token.projectID,
                name: name, visibility: visibility,
                protected: protected, status: status
            ) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"image":\(Self.imageJSON(img))}
            """)
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
            var tags: [String] = []
            if let arr = Self.arrayForValue("tags", in: body) {
                for element in arr {
                    var s = element.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                        s = String(s.dropFirst().dropLast())
                    }
                    if !s.isEmpty { tags.append(s) }
                }
            }
            guard let img = await state.addTags(id: id, projectID: token.projectID, tags: tags) else {
                return Self.textError(status: .notFound, message: "404 Not Found")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"image":\(Self.imageJSON(img))}
            """)
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
            let importObj = Self.objectForKey("import", in: body) ?? body
            let uri = Self.extractString("uri", from: importObj) ?? ""

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
        parts.append("\"id\":\"\(img.id)\"")
        parts.append("\"name\":\"\(img.name)\"")
        parts.append("\"status\":\"\(img.status)\"")
        if let reason = img.statusReason {
            parts.append("\"status_reason\":\"\(reason)\"")
        }
        parts.append("\"visibility\":\"\(img.visibility)\"")
        parts.append("\"disk_format\":\"\(img.diskFormat)\"")
        parts.append("\"container_format\":\"\(img.containerFormat)\"")
        parts.append("\"size\":\(img.size)")
        parts.append("\"min_ram\":\(img.minRAM)")
        parts.append("\"protected\":\(img.protected)")
        let tags = img.tags.map { "\"\($0)\"" }.joined(separator: ",")
        parts.append("\"tags\":[\(tags)]")
        let props = img.properties.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        parts.append("\"properties\":{\(props)}")
        parts.append("\"created_at\":\"\(img.created)\"")
        parts.append("\"updated_at\":\"\(img.updated)\"")
        return "{" + parts.joined(separator: ",") + "}"
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

    static func objectForKey(_ key: String, in json: String) -> String? {
        let pattern = "\"\(key)\":"
        guard let start = json.range(of: pattern) else { return nil }
        let afterColon = json[start.upperBound...]
        guard let open = afterColon.firstIndex(of: "{") else { return nil }
        var depth = 0
        for (idx, ch) in afterColon.enumerated() {
            _ = idx
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    let end = afterColon.index(afterColon.startIndex, offsetBy: idx)
                    return String(afterColon[open...end])
                }
            }
        }
        return nil
    }

    static func arrayForValue(_ key: String, in json: String) -> [String]? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard afterColon.hasPrefix("[") else { return nil }
        var depth = 0
        var foundEnd: String.Index? = nil
        for (idx, ch) in afterColon.enumerated() {
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    foundEnd = afterColon.index(afterColon.startIndex, offsetBy: idx)
                    break
                }
            }
        }
        guard let end = foundEnd else { return nil }
        let innerStart = afterColon.index(afterColon.startIndex, offsetBy: 1)
        return Self.splitTopLevel(String(afterColon[innerStart..<end]))
    }

    static func splitTopLevel(_ inner: String) -> [String] {
        var elements: [String] = []
        var depth = 0
        var current = ""
        for ch in inner {
            if ch == "{" || ch == "[" { depth += 1 }
            if ch == "}" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 {
                elements.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            elements.append(current)
        }
        return elements
    }

    static func extractString(_ key: String, from json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("\"") {
            let rest = afterColon.dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[rest.startIndex..<close])
        }
        return nil
    }

    static func extractInt(_ key: String, from json: String) -> Int? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var numStr = ""
        for ch in afterColon {
            if ch == "," || ch == "}" || ch == "]" { break }
            numStr.append(ch)
        }
        return Int(numStr)
    }

    static func extractBool(_ key: String, from json: String) -> Bool? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("true") { return true }
        if afterColon.hasPrefix("false") { return false }
        return nil
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
}
