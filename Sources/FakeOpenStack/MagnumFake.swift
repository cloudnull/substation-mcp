import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Magnum (container infrastructure) implementation.
///
/// Routes live under `/container/*`. Standard collection/item shape:
/// collections at `/containers` and `/cluster_templates`, items at
/// `/<collection>/{id}`. List responses wrap items in a keyed envelope
/// (`{"containers":[...]}`); item and POST responses return the bare object.
/// Errors use the Magnum shape: `{"faultblock": {"code": ..., "title": ...}}`.
public struct MagnumFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/container"

        // MARK: - Containers

        router.get("\(base)/containers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let clusters = await state.listMagnumClusters(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = clusters.map { Self.clusterJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"containers":[\(items)]}
            """)
        }

        router.get("\(base)/containers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let c = await state.getMagnumCluster(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Container \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.clusterJSON(c))
        }

        router.post("\(base)/containers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("container", in: body) ?? body
            let name = Self.extractString("name", from: inner) ?? ""
            let mc = Self.extractInt("master_count", from: inner)
            let nc = Self.extractInt("node_count", from: inner)
            let ct = Self.extractString("cluster_template_id", from: inner)
            let c = await state.createMagnumCluster(projectID: token.projectID, name: name, masterCount: mc, nodeCount: nc, clusterTemplateID: ct)
            return Self.jsonResponse(status: .created, body: Self.clusterJSON(c))
        }

        router.delete("\(base)/containers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteMagnumCluster(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Container \(id) could not be found.")
            }
            return Self.noContent()
        }

        // MARK: - Cluster templates

        router.get("\(base)/cluster_templates") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let templates = await state.listMagnumTemplates(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = templates.map { Self.templateJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"cluster_templates":[\(items)]}
            """)
        }

        router.get("\(base)/cluster_templates/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let t = await state.getMagnumTemplate(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Cluster template \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.templateJSON(t))
        }

        router.post("\(base)/cluster_templates") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("cluster_template", in: body) ?? body
            let name = Self.extractString("name", from: inner) ?? ""
            let mc = Self.extractInt("master_count", from: inner) ?? 1
            let nc = Self.extractInt("node_count", from: inner) ?? 0
            let t = await state.createMagnumTemplate(projectID: token.projectID, name: name, masterCount: mc, nodeCount: nc)
            return Self.jsonResponse(status: .created, body: Self.templateJSON(t))
        }

        router.delete("\(base)/cluster_templates/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteMagnumTemplate(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Cluster template \(id) could not be found.")
            }
            return Self.noContent()
        }
    }

    // MARK: - JSON builders

    static func clusterJSON(_ c: FakeState.FakeMagnumCluster) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(c.id)\"")
        parts.append("\"name\":\"\(c.name)\"")
        parts.append("\"status\":\"\(c.status)\"")
        parts.append("\"master_count\":\(c.masterCount)")
        parts.append("\"node_count\":\(c.nodeCount)")
        if let ct = c.clusterTemplateID { parts.append("\"cluster_template_id\":\"\(ct)\"") }
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"updated_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func templateJSON(_ t: FakeState.FakeMagnumTemplate) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(t.id)\"")
        parts.append("\"name\":\"\(t.name)\"")
        parts.append("\"master_count\":\(t.masterCount)")
        parts.append("\"node_count\":\(t.nodeCount)")
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
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

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        magnumError(status: .unauthorized, message: "Unauthorized")
    }

    static func itemNotFound(message: String) -> Response {
        magnumError(status: .notFound, message: message)
    }

    static func magnumError(status: HTTPResponse.Status, message: String) -> Response {
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
            {"faultblock":{"code":\(code),"title":"\(status == .notFound ? "itemNotFound" : "error")","description":"\(message)"}}
            """))
        )
    }
}
