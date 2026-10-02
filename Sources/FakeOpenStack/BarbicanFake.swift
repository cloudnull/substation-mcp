import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Barbican (key manager) implementation.
///
/// Routes live under `/barbican/v1/*`. Standard OpenStack REST shape:
/// collections at `/secrets` and `/containers`, items at `/secrets/{id}`.
/// List responses wrap items in a keyed envelope (`{"secrets":[...]}`); item
/// responses wrap in `{"secret":{...}}`. Errors use the Barbican shape:
/// `{"title": "...", "description": "...", "http_code": ...}`.
public struct BarbicanFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/barbican/v1"

        // MARK: - Secrets

        router.get("\(base)/secrets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let name = Self.queryParam("name", from: req)
            let type = Self.queryParam("type", from: req)
            let secs = await state.listSecrets(projectID: token.projectID, name: name, type: type, limit: limit, marker: marker)
            let items = secs.map { Self.secretObjectJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"secrets":[\(items)],"secrets_links":{}}
            """)
        }

        router.get("\(base)/secrets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let sec = await state.getSecret(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Secret \(id) could not be found.")
            }
            // The secret detail includes the payload + content type.
            return Self.jsonResponse(status: .ok, body: Self.secretDetailJSON(sec))
        }

        router.post("\(base)/secrets") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("secret", in: body) ?? body
            let name = Self.extractString("name", from: inner)
            let type = Self.extractString("type", from: inner) ?? "opaque"
            let algorithm = Self.extractString("algorithm", from: inner)
            let bitSize = Self.extractInt("bit_size", from: inner)
            let mode = Self.extractString("mode", from: inner)
            let secret = Self.extractString("secret", from: inner)
            let visibility = Self.extractString("visibility", from: inner)
            let sec = await state.createSecret(
                projectID: token.projectID, name: name, type: type, algorithm: algorithm,
                bitSize: bitSize, mode: mode, secret: secret, visibility: visibility
            )
            return Self.jsonResponse(status: .created, body: Self.secretObjectJSON(sec))
        }

        router.delete("\(base)/secrets/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSecret(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Secret \(id) could not be found.")
            }
            return Self.noContent()
        }

        // MARK: - Containers

        router.get("\(base)/containers") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let name = Self.queryParam("name", from: req)
            let ctns = await state.listSecretContainers(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = ctns.map { Self.containerJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"containers":[\(items)],"containers_links":{}}
            """)
        }

        router.get("\(base)/containers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let ctn = await state.getSecretContainer(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Container \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.containerJSON(ctn))
        }

        router.delete("\(base)/containers/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteSecretContainer(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Container \(id) could not be found.")
            }
            return Self.noContent()
        }
    }

    // MARK: - JSON builders

    static func secretObjectJSON(_ s: FakeState.FakeSecret) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(s.id)\"")
        if let name = s.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"type\":\"\(s.type)\"")
        parts.append("\"status\":\"\(s.status)\"")
        if let alg = s.algorithm { parts.append("\"algorithm\":\"\(alg)\"") }
        if let bit = s.bitSize { parts.append("\"bit_size\":\(bit)") }
        if let mode = s.mode { parts.append("\"mode\":\"\(mode)\"") }
        parts.append("\"is_secret\":\(s.isSecret)")
        parts.append("\"visibility\":\"\(s.visibility)\"")
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"updated_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func secretDetailJSON(_ s: FakeState.FakeSecret) -> String {
        // The secret detail response is the secret metadata + payload fields.
        var parts: [String] = []
        parts.append("\"id\":\"\(s.id)\"")
        if let name = s.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"type\":\"\(s.type)\"")
        parts.append("\"status\":\"\(s.status)\"")
        if let alg = s.algorithm { parts.append("\"algorithm\":\"\(alg)\"") }
        if let bit = s.bitSize { parts.append("\"bit_size\":\(bit)") }
        if let mode = s.mode { parts.append("\"mode\":\"\(mode)\"") }
        parts.append("\"is_secret\":\(s.isSecret)")
        parts.append("\"visibility\":\"\(s.visibility)\"")
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"updated_at\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"payload\":\"\(s.payload)\"")
        parts.append("\"payload_content_type\":\"\(s.payloadContentType)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func containerJSON(_ c: FakeState.FakeSecretContainer) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(c.id)\"")
        if let name = c.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"type\":\"\(c.type)\"")
        let refs = c.secretRefs.map { "\"\($0)\"" }.joined(separator: ",")
        parts.append("\"secret_refs\":[\(refs)]")
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
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        Self.barbicanError(status: .unauthorized, message: "Unauthorized")
    }

    static func itemNotFound(message: String) -> Response {
        Self.barbicanError(status: .notFound, message: message)
    }

    static func barbicanError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .notFound: code = 404
        case .unauthorized: code = 401
        case .badRequest: code = 400
        default: code = 500
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: """
            {"title":"\(status == .notFound ? "itemNotFound" : "error")","description":"\(message)","http_code":\(code)}
            """))
        )
    }
}
