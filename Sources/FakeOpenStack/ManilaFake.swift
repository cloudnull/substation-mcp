import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Manila (shared file systems) implementation.
///
/// Routes live under `/share/v2/*`. Standard collection/item shape:
/// collection at `/shares`, items at `/shares/{id}`, and share access as a
/// sub-collection at `/shares/{id}/access` with items at
/// `/shares/{id}/access/{aid}`. List responses wrap items in a keyed envelope
/// (`{"shares":[...]}`, `{"share_access_list":[...]}`); item and POST
/// responses return the bare object. Errors use the Manila shape:
/// `{"message": ..., "code": ..., "title": ...}`.
public struct ManilaFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/share/v2"

        // MARK: - Shares

        router.get("\(base)/shares") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let shares = await state.listShares(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = shares.map { Self.shareJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"shares":[\(items)]}
            """)
        }

        router.get("\(base)/shares/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let s = await state.getShare(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Share \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.shareJSON(s))
        }

        router.post("\(base)/shares") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("share", in: body) ?? body
            let name = Self.extractString("name", from: inner) ?? ""
            let size = Self.extractInt("share_size", from: inner) ?? 1
            let stype = Self.extractString("share_type", from: inner) ?? "generic"
            let desc = Self.extractString("description", from: inner)
            let isPublic = Self.extractBool("is_public", from: inner) ?? false
            let s = await state.createShare(projectID: token.projectID, name: name, shareSize: size, shareType: stype, description: desc, isPublic: isPublic)
            return Self.jsonResponse(status: .created, body: Self.shareJSON(s))
        }

        router.delete("\(base)/shares/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteShare(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Share \(id) could not be found.")
            }
            return Self.noContent()
        }

        // MARK: - Share access (sub-collection under a share)

        router.get("\(base)/shares/:id/access") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let shareID = ctx.parameters.get("id") ?? ""
            guard await state.getShare(id: shareID, projectID: token.projectID) != nil else {
                return Self.itemNotFound(message: "Share \(shareID) could not be found.")
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let accesses = await state.listShareAccess(shareID: shareID, projectID: token.projectID, limit: limit, marker: marker)
            let items = accesses.map { Self.accessJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"share_access_list":[\(items)]}
            """)
        }

        router.get("\(base)/shares/:id/access/:aid") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let shareID = ctx.parameters.get("id") ?? ""
            let aid = ctx.parameters.get("aid") ?? ""
            guard let a = await state.getShareAccess(id: aid, shareID: shareID, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Share access \(aid) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.accessJSON(a))
        }

        router.post("\(base)/shares/:id/access") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let shareID = ctx.parameters.get("id") ?? ""
            guard await state.getShare(id: shareID, projectID: token.projectID) != nil else {
                return Self.itemNotFound(message: "Share \(shareID) could not be found.")
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let accessTo = Self.extractString("access_to", from: body) ?? ""
            let accessType = Self.extractString("access_type", from: body) ?? "ip"
            let accessProtocol = Self.extractString("access_protocol", from: body) ?? "nfs"
            let a = await state.createShareAccess(projectID: token.projectID, shareID: shareID, accessTo: accessTo, accessType: accessType, accessProtocol: accessProtocol)
            return Self.jsonResponse(status: .created, body: Self.accessJSON(a))
        }

        router.delete("\(base)/shares/:id/access/:aid") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let shareID = ctx.parameters.get("id") ?? ""
            let aid = ctx.parameters.get("aid") ?? ""
            guard await state.deleteShareAccess(id: aid, shareID: shareID, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Share access \(aid) could not be found.")
            }
            return Self.noContent()
        }
    }

    // MARK: - JSON builders

    static func shareJSON(_ s: FakeState.FakeShare) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(s.id)\"")
        parts.append("\"name\":\"\(s.name)\"")
        parts.append("\"status\":\"\(s.status)\"")
        parts.append("\"share_size\":\(s.shareSize)")
        parts.append("\"share_type\":\"\(s.shareType)\"")
        if let d = s.description { parts.append("\"description\":\"\(d)\"") } else { parts.append("\"description\":\"\"") }
        parts.append("\"is_public\":\(s.isPublic)")
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func accessJSON(_ a: FakeState.FakeShareAccess) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(a.id)\"")
        parts.append("\"share_id\":\"\(a.shareID)\"")
        parts.append("\"access_to\":\"\(a.accessTo)\"")
        parts.append("\"access_type\":\"\(a.accessType)\"")
        parts.append("\"access_protocol\":\"\(a.accessProtocol)\"")
        parts.append("\"state\":\"\(a.state)\"")
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
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        manilaError(status: .unauthorized, message: "Unauthorized")
    }

    static func itemNotFound(message: String) -> Response {
        manilaError(status: .notFound, message: message)
    }

    static func manilaError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .notFound: code = 404
        case .unauthorized: code = 401
        default: code = 500
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: """
            {"message":"\(message)","code":\(code),"title":"\(status == .notFound ? "itemNotFound" : "error")"}
            """))
        )
    }
}
