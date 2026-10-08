import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Freezer (backup) implementation.
///
/// Routes live under `/v1.0/*`. Freezer addresses items by `backup_id` and
/// `schedule_id`. List responses are keyed envelopes (`{"backups":[...]}`,
/// `{"schedules":[...]}`); items return the bare object. Errors use the Freezer
/// shape `{"error": {"code": <n>, "title": "...", "message": "..."}}`.
public struct BackupFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/v1.0"

        router.get(RouterPath("\(base)/backup")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let items = await state.listFreezerBackups(projectID: token.projectID, limit: limit)
            let body = items.map { Self.backupJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"backups\":[\(body)]}")
        }

        router.get(RouterPath("\(base)/backup/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let b = await state.getFreezerBackup(id: id, projectID: token.projectID) else {
                return Self.notFound("Backup \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.backupJSON(b))
        }

        router.get(RouterPath("\(base)/schedule")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let items = await state.listFreezerSchedules(projectID: token.projectID, limit: limit)
            let body = items.map { Self.scheduleJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"schedules\":[\(body)]}")
        }

        router.get(RouterPath("\(base)/schedule/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let s = await state.getFreezerSchedule(id: id, projectID: token.projectID) else {
                return Self.notFound("Schedule \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.scheduleJSON(s))
        }
    }

    static func backupJSON(_ b: FakeState.FakeFreezerBackup) -> String {
        var parts = ["\"backup_id\":\"\(b.id)\""]
        parts.append("\"project_id\":\"\(b.projectID)\"")
        if let v = b.volumeID { parts.append("\"volume_id\":\"\(v)\"") }
        parts.append("\"status\":\"\(b.status)\"")
        if let s = b.size { parts.append("\"size\":\(s)") }
        if let l = b.lastBackup { parts.append("\"last_backup\":\"\(l)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func scheduleJSON(_ s: FakeState.FakeFreezerSchedule) -> String {
        var parts = ["\"id\":\"\(s.id)\""]
        if let v = s.volumeID { parts.append("\"volume_id\":\"\(v)\"") }
        parts.append("\"project_id\":\"\(s.projectID)\"")
        if let h = s.backupIntervalHours { parts.append("\"backup_interval_hours\":\(h)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func unauthorized() -> Response {
        Response(status: .unauthorized, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":{\"code\":401,\"title\":\"Unauthorized\",\"message\":\"The request you have made requires authentication.\"}}")))
    }

    static func notFound(_ message: String) -> Response {
        Response(status: .notFound, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":{\"code\":404,\"title\":\"Not Found\",\"message\":\"\(message)\"}}")))
    }
}
