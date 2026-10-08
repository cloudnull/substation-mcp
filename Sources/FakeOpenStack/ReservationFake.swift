import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Blazar (reservation) implementation.
///
/// Routes live under `/v1/reservations` and `/v1/allocations` (IAD3's catalog
/// URL carries `/v1`). List responses are keyed envelopes
/// (`{"reservations":[...]}`, `{"allocations":[...]}`); items and POST
/// responses return the bare object. Errors use the Blazar shape
/// `{"error": <code>, "error_message": "..."}`.
public struct ReservationFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        router.get(RouterPath("/reservation/v1/reservations")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let items = await state.listBlazarReservations(projectID: token.projectID, name: name, limit: limit)
            let body = items.map { Self.reservationJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"reservations\":[\(body)]}")
        }

        router.get(RouterPath("/reservation/v1/reservations/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let r = await state.getBlazarReservation(id: id, projectID: token.projectID) else {
                return Self.notFound("Reservation \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.reservationJSON(r))
        }

        router.post(RouterPath("/reservation/v1/reservations")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let name = Self.extractString("name", from: body)
            let flavorID = Self.extractString("flavor_id", from: body)
            let created = await state.createBlazarReservation(projectID: token.projectID, name: name, flavorID: flavorID)
            return Self.jsonResponse(status: .created, body: Self.reservationJSON(created))
        }

        router.delete(RouterPath("/reservation/v1/reservations/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteBlazarReservation(id: id, projectID: token.projectID) else {
                return Self.notFound("Reservation \(id) could not be found.")
            }
            return Self.noContent()
        }

        router.get(RouterPath("/reservation/v1/allocations")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let items = await state.listBlazarAllocations(projectID: token.projectID)
            let body = items.map { Self.allocationJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"allocations\":[\(body)]}")
        }

        router.get(RouterPath("/reservation/v1/allocations/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let a = await state.getBlazarAllocation(id: id, projectID: token.projectID) else {
                return Self.notFound("Allocation \(id) could not be found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.allocationJSON(a))
        }
    }

    static func reservationJSON(_ r: FakeState.FakeBlazarReservation) -> String {
        var parts = ["\"id\":\"\(r.id)\"", "\"status\":\"\(r.status)\""]
        if let n = r.name { parts.append("\"name\":\"\(n)\"") }
        if let a = r.allocationID { parts.append("\"allocation_id\":\"\(a)\"") }
        if let f = r.flavorID { parts.append("\"flavor_id\":\"\(f)\"") }
        parts.append("\"created\":\"\(r.created)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func allocationJSON(_ a: FakeState.FakeBlazarAllocation) -> String {
        var parts = ["\"id\":\"\(a.id)\"", "\"status\":\"\(a.status)\""]
        if let n = a.nodeID { parts.append("\"node_id\":\"\(n)\"") }
        if let r = a.reservationID { parts.append("\"reservation_id\":\"\(r)\"") }
        parts.append("\"created\":\"\(a.created)\"")
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

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        Response(status: .unauthorized, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":401,\"error_message\":\"Unauthorized\"}")))
    }

    static func notFound(_ message: String) -> Response {
        Response(status: .notFound, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"error\":404,\"error_message\":\"\(message)\"}")))
    }
}