import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Gnocchi (metric) implementation.
///
/// Routes live under `/v1/*`. `GET /v1/metric` returns a bare JSON array of
/// metric objects (optionally filtered by `name=`); `GET /v1/resource` returns
/// the resource-type map `{name: href}`. Errors use the Gnocchi shape
/// `{"error": "...", "type": "..."}`.
public struct MetricFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/v1"

        router.get(RouterPath("\(base)/metric")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let items = await state.listGnocchiMetrics(projectID: token.projectID, name: name, limit: limit)
            let body = items.map { Self.metricJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "[\(body)]")
        }

        router.get(RouterPath("\(base)/resource")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let types = await state.gnocchiResourceTypes()
            let entries = types.map { "\"\($0)\":\"http://gnocchi.fake/v1/resource/\($0)\"" }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\(entries)}")
        }
    }

    static func metricJSON(_ m: FakeState.FakeGnocchiMetric) -> String {
        var parts = ["\"id\":\"\(m.id)\"", "\"name\":\"\(m.name)\""]
        if let u = m.unit { parts.append("\"unit\":\"\(u)\"") }
        if let r = m.resourceID { parts.append("\"resource_id\":\"\(r)\"") }
        parts.append("\"created\":\"\(m.created)\"")
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
            body: .init(byteBuffer: .init(string: "{\"error\":\"Unauthorized\",\"type\":\"http://gnocchi.fake/401\"}")))
    }
}
