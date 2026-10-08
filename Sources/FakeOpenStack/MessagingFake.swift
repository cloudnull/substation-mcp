import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake ZaQar (messaging) implementation.
///
/// Routes live under `/v1/:project/queues` — ZaQar is project-scoped. The
/// list response is a bare JSON array of queue *names*; a single queue returns
/// the metadata object. Errors use the ZaQar shape
/// `{"error": "...", "type": "...", "href": "..."}`.
public struct MessagingFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/v1/:project/queues"

        router.get(RouterPath(base)) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let names = await state.listZaQarQueues(projectID: token.projectID)
            let body = names.map { "\"\($0)\"" }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "[\(body)]")
        }

        router.get(RouterPath("\(base)/:name")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = ctx.parameters.get("name") ?? ""
            guard await state.getZaQarQueue(name: name, projectID: token.projectID) else {
                return Self.notFound("Queue \(name) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"name":"\(name)","messages_count":0,"created_at":"2026-01-01T00:00:00.000Z"}
            """)
        }
    }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func unauthorized() -> Response {
        Response(status: .unauthorized, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":\"Unauthorized\",\"type\":\"http://zaqar.fake/401\"}")))
    }

    static func notFound(_ message: String) -> Response {
        Response(status: .notFound, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":\"\(message)\",\"type\":\"http://zaqar.fake/404\"}")))
    }
}
