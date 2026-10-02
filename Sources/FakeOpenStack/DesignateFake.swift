import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Designate (DNS) implementation.
///
/// Routes live under `/designate/v3/*`. Standard collection/item shape:
/// collections at `/zones` and `/recordsets`, items at `/<collection>/{id}`.
/// List responses wrap items in a keyed envelope (`{"zones":[...]}`); item
/// and POST responses return the bare object. Errors use the Designate shape:
/// `{"title": ..., "detail": ...}`.
public struct DesignateFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/designate/v3"

        // MARK: - Zones

        router.get("\(base)/zones") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let zones = await state.listZones(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = zones.map { Self.zoneJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"zones":[\(items)]}
            """)
        }

        router.get("\(base)/zones/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let z = await state.getZone(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Zone \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.zoneJSON(z))
        }

        router.post("\(base)/zones") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("zone", in: body) ?? body
            let z = await state.createZone(projectID: token.projectID, name: Self.extractString("name", from: inner) ?? "", email: Self.extractString("email", from: inner), ttl: Self.extractInt("ttl", from: inner))
            return Self.jsonResponse(status: .created, body: Self.zoneJSON(z))
        }

        router.delete("\(base)/zones/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteZone(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Zone \(id) could not be found.")
            }
            return Self.noContent()
        }

        // MARK: - Record sets

        router.get("\(base)/recordsets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let zoneID = Self.queryParam("zone_id", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let rses = await state.listRecordSets(projectID: token.projectID, name: name, zoneID: zoneID, limit: limit, marker: marker)
            let items = rses.map { Self.recordSetJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"recordsets":[\(items)]}
            """)
        }

        router.get("\(base)/recordsets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let rs = await state.getRecordSet(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Record set \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.recordSetJSON(rs))
        }

        router.post("\(base)/recordsets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("recordset", in: body) ?? body
            // records is a JSON array; parse it out.
            let records = Self.extractStringArray("records", from: inner)
            let rs = await state.createRecordSet(projectID: token.projectID, name: Self.extractString("name", from: inner) ?? "", type: Self.extractString("type", from: inner) ?? "A", ttl: Self.extractInt("ttl", from: inner), records: records, zoneID: Self.extractString("zone_id", from: inner))
            return Self.jsonResponse(status: .created, body: Self.recordSetJSON(rs))
        }

        router.delete("\(base)/recordsets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteRecordSet(id: id, projectID: token.projectID) else {
                return Self.notFound(message: "Record set \(id) could not be found.")
            }
            return Self.noContent()
        }
    }

    // MARK: - JSON builders

    static func zoneJSON(_ z: FakeState.FakeZone) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(z.id)\"")
        parts.append("\"name\":\"\(z.name)\"")
        if let e = z.email { parts.append("\"email\":\"\(e)\"") } else { parts.append("\"email\":null") }
        parts.append("\"status\":\"\(z.status)\"")
        if let t = z.ttl { parts.append("\"ttl\":\(t)") }
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"updated_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func recordSetJSON(_ rs: FakeState.FakeRecordSet) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(rs.id)\"")
        parts.append("\"name\":\"\(rs.name)\"")
        parts.append("\"type\":\"\(rs.type)\"")
        if let t = rs.ttl { parts.append("\"ttl\":\(t)") }
        let recs = rs.records.map { "\"\($0)\"" }.joined(separator: ",")
        parts.append("\"records\":[\(recs)]")
        if let z = rs.zoneID { parts.append("\"zone_id\":\"\(z)\"") }
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

    static func extractStringArray(_ key: String, from json: String) -> [String] {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return [] }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":"),
              let open = afterKey[afterKey.index(after: colon)...].firstIndex(of: "[") else {
            return []
        }
        let inner = afterKey[afterKey.index(after: open)...]
        guard let close = inner.firstIndex(of: "]") else { return [] }
        let elements = inner[..<close]
        var result: [String] = []
        for elem in elements.split(separator: ",") {
            let trimmed = elem.trimmingCharacters(in: .whitespaces)
            let unquoted = trimmed.replacingOccurrences(of: "\"", with: "")
            if !unquoted.isEmpty { result.append(unquoted) }
        }
        return result
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        designateError(status: .unauthorized, message: "Unauthorized")
    }

    static func notFound(message: String) -> Response {
        designateError(status: .notFound, message: message)
    }

    static func designateError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .notFound: code = 404
        case .unauthorized: code = 401
        default: code = 500
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"title\":\"\(code)\",\"detail\":\"\(message)\"}"))
        )
    }
}
