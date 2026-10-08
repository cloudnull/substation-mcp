import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Trove (database) implementation.
///
/// Routes live under `/v1.0/:project/*` — Trove is project-scoped, mirroring
/// IAD3's catalog URL (`.../v1.0/<project>`). List responses are keyed
/// envelopes (`{"instances":[...]}`, `{"flavors":[...]}`, `{"datastores":[...]}`);
/// items and POST responses return the bare object.
public struct DatabaseFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/v1.0/:project"

        router.get(RouterPath("\(base)/instances")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let marker = Self.queryParam("marker", from: req)
            let items = await state.listDatabaseInstances(projectID: token.projectID, name: name, limit: limit, marker: marker)
            let body = items.map { Self.instanceJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"instances\":[\(body)]}")
        }

        router.get(RouterPath("\(base)/instances/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let i = await state.getDatabaseInstance(id: id, projectID: token.projectID) else {
                return Self.notFound("Instance \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.instanceJSON(i))
        }

        router.post(RouterPath("\(base)/instances")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let name = Self.extractString("name", from: body) ?? ""
            let flavor = Self.extractString("flavorRef", from: body)
            let vol = Self.extractInt("size", from: body)
            let created = await state.createDatabaseInstance(projectID: token.projectID, name: name, flavorRef: flavor, volumeSize: vol)
            return Self.jsonResponse(status: .created, body: Self.instanceJSON(created))
        }

        router.delete(RouterPath("\(base)/instances/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteDatabaseInstance(id: id, projectID: token.projectID) else {
                return Self.notFound("Instance \(id) could not be found.")
            }
            return Self.noContent()
        }

        router.get(RouterPath("\(base)/flavors")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let items = await state.listDatabaseFlavors(projectID: token.projectID)
            let body = items.map { Self.flavorJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"flavors\":[\(body)]}")
        }

        router.get(RouterPath("\(base)/datastores")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let items = await state.listDatabaseDatastores(projectID: token.projectID)
            let body = items.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name ?? "")\"}" }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"datastores\":[\(body)]}")
        }
    }

    static func instanceJSON(_ i: FakeState.FakeDatabaseInstance) -> String {
        var parts = ["\"id\":\"\(i.id)\""]
        parts.append("\"name\":\"\(i.name)\"")
        parts.append("\"status\":\"\(i.status)\"")
        if let f = i.flavorRef { parts.append("\"flavorRef\":\"\(f)\"") }
        parts.append("\"volume\":{\"size\":\(i.volumeSize)}")
        if let v = i.versionNumber { parts.append("\"versionNumber\":\"\(v)\"") }
        parts.append("\"created\":\"\(i.created)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func flavorJSON(_ f: FakeState.FakeDatabaseFlavor) -> String {
        var parts = ["\"id\":\"\(f.id)\""]
        if let n = f.name { parts.append("\"name\":\"\(n)\"") }
        parts.append("\"vcpus\":\(f.vcpus)")
        parts.append("\"ram\":\(f.ram)")
        parts.append("\"disk\":\(f.disk)")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func readBody(_ req: Request) async throws -> String {
        var data = Data()
        for try await buffer in req.body { data.append(contentsOf: buffer.readableBytesView) }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func extractString(_ key: String, from json: String) -> String? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard afterColon.hasPrefix("\"") else { return nil }
        let rest = afterColon.dropFirst()
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<close])
    }

    static func extractInt(_ key: String, from json: String) -> Int? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var numStr = ""
        for ch in afterColon { if ch == "," || ch == "}" || ch == "]" { break }; numStr.append(ch) }
        return Int(numStr)
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        Response(status: .unauthorized, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"message\":\"The request you have made requires authentication.\"}")))
    }

    static func notFound(_ message: String) -> Response {
        Response(status: .notFound, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"message\":\"\(message)\"}")))
    }
}