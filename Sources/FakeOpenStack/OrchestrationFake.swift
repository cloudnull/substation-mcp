import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Heat (orchestration) implementation.
///
/// Routes live under `/orchestration/v1/*`. Standard collection/item shape:
/// collection at `/stacks`, items at `/stacks/{id}`, outputs at
/// `/stacks/{id}/outputs`. List responses wrap items in a keyed envelope
/// (`{"stacks":[...]}`); item and POST responses return the bare object.
/// Errors use the Heat shape: `{"message": ..., "code": ..., "title": ...}`.
public struct OrchestrationFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/orchestration/v1"

        // MARK: - Stacks

        router.get("\(base)/stacks") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("stack_name", from: req) ?? Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25
            let marker = Self.queryParam("marker", from: req)
            let stacks = await state.listHeatStacks(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let items = stacks.map { Self.stackJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"stacks":[\(items)]}
            """)
        }

        router.get("\(base)/stacks/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let s = await state.getHeatStack(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Stack \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.stackJSON(s))
        }

        router.get("\(base)/stacks/:id/outputs") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let s = await state.getHeatStack(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Stack \(id) could not be found.")
            }
            let outputs = s.outputs.map { Self.outputJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"outputs":[\(outputs)]}
            """)
        }

        router.post("\(base)/stacks") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let name = Self.extractString("stack_name", from: body) ?? Self.extractString("name", from: body) ?? ""
            // Parameters is a JSON object; extract key/value pairs.
            let params = Self.extractStringObject("parameters", from: body) ?? [:]
            let s = await state.createHeatStack(projectID: token.projectID, name: name, parameters: params)
            return Self.jsonResponse(status: .created, body: Self.stackJSON(s))
        }

        router.delete("\(base)/stacks/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteHeatStack(id: id, projectID: token.projectID) else {
                return Self.itemNotFound(message: "Stack \(id) could not be found.")
            }
            return Self.noContent()
        }
    }

    // MARK: - JSON builders

    static func stackJSON(_ s: FakeState.FakeHeatStack) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(s.id)\"")
        parts.append("\"stack_name\":\"\(s.name)\"")
        parts.append("\"status\":\"\(s.status)\"")
        parts.append("\"creation_time\":\"2026-01-01T00:00:00.000\"")
        parts.append("\"updated_at\":\"2026-01-01T00:00:00.000\"")
        if !s.parameters.isEmpty {
            let pairs = s.parameters.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            parts.append("\"parameters\":{\(pairs)}")
        }
        parts.append("\"description\":\"fake heat stack\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func outputJSON(_ o: FakeState.FakeStackOutput) -> String {
        var parts: [String] = []
        parts.append("\"output_key\":\"\(o.outputKey)\"")
        parts.append("\"output_value\":\"\(o.outputValue)\"")
        if let d = o.description { parts.append("\"description\":\"\(d)\"") }
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

    /// Extract a flat string->string JSON object under `key`.
    static func extractStringObject(_ key: String, from json: String) -> [String: String]? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":"),
              let open = afterKey[afterKey.index(after: colon)...].firstIndex(of: "{") else {
            return nil
        }
        let inner = afterKey[afterKey.index(after: open)...]
        guard let close = inner.firstIndex(of: "}") else { return nil }
        let elements = inner[..<close]
        var result: [String: String] = [:]
        for pair in elements.split(separator: ",") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.range(of: ":") else { continue }
            let k = trimmed[..<eq.lowerBound].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            let v = trimmed[eq.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            if !k.isEmpty { result[k] = v }
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
        heatError(status: .unauthorized, message: "Unauthorized")
    }

    static func itemNotFound(message: String) -> Response {
        heatError(status: .notFound, message: message)
    }

    static func heatError(status: HTTPResponse.Status, message: String) -> Response {
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
