import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Gnocchi (metric) implementation.
///
/// Routes live under `/v1/*`, mirroring the live-validated IAD3 meterng
/// surface:
///   GET    /v1/metric                       bare array; `name=`, `resource_id=`,
///                                           `archive_policy.name=`, `limit=` filters
///   POST   /v1/metric                       create (201)
///   GET    /v1/metric/{id}                  item (404 for foreign-project ids)
///   DELETE /v1/metric/{id}                  delete (204)
///   GET    /v1/metric/{id}/measures         raw triples; `aggregation=` +
///                                           `granularity=` → aggregated buckets
///                                           (unknown method/granularity → 404,
///                                           relative `start=` → 400, like meterng)
///   GET    /v1/resource                     resource-type map `{name: href}`
///   GET    /v1/archive_policy               policy array
/// Errors use the Gnocchi shape `{"error": "...", "type": "..."}`.
public struct MetricFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/v1"

        router.get(RouterPath("\(base)/metric")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let resourceID = Self.queryParam("resource_id", from: req)
            let ap = Self.queryParam("archive_policy.name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let items = await state.listGnocchiMetrics(projectID: token.projectID, name: name, resourceID: resourceID, archivePolicy: ap, limit: limit)
            let body = items.map { Self.metricJSON($0) }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "[\(body)]")
        }

        router.post(RouterPath("\(base)/metric")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            guard let ap = Self.extractString("archive_policy_name", from: body), !ap.isEmpty else {
                return Self.jsonResponse(status: .badRequest, body: "{\"error\":\"archive_policy_name is required\",\"type\":\"http://gnocchi.fake/400\"}")
            }
            let policies = await state.gnocchiArchivePolicies()
            if !policies.contains(where: { $0.name == ap }) {
                return Self.jsonResponse(status: .notFound, body: "{\"error\":\"Archive policy \(ap) does not exist\",\"type\":\"http://gnocchi.fake/404\"}")
            }
            let m = await state.createGnocchiMetric(
                projectID: token.projectID,
                archivePolicy: ap,
                name: Self.extractString("name", from: body),
                unit: Self.extractString("unit", from: body),
                creator: token.userID
            )
            return Self.jsonResponse(status: .created, body: Self.metricJSON(m))
        }

        router.get(RouterPath("\(base)/metric/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let m = await state.getGnocchiMetric(id: id, projectID: token.projectID) else {
                return Self.jsonResponse(status: .notFound, body: "{\"error\":\"Metric \(id) could not be found\",\"type\":\"http://gnocchi.fake/404\"}")
            }
            return Self.jsonResponse(status: .ok, body: Self.metricJSON(m))
        }

        router.delete(RouterPath("\(base)/metric/:id")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard await state.deleteGnocchiMetric(id: id, projectID: token.projectID) else {
                return Self.jsonResponse(status: .notFound, body: "{\"error\":\"Metric \(id) could not be found\",\"type\":\"http://gnocchi.fake/404\"}")
            }
            return Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
        }

        router.get(RouterPath("\(base)/metric/:id/measures")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let m = await state.getGnocchiMetric(id: id, projectID: token.projectID) else {
                return Self.jsonResponse(status: .notFound, body: "{\"error\":\"Metric \(id) could not be found\",\"type\":\"http://gnocchi.fake/404\"}")
            }
            let agg = Self.queryParam("aggregation", from: req)
            let gran = Self.queryParam("granularity", from: req)
            let start = Self.queryParam("start", from: req)
            // meterng rejects relative windows outright.
            if let start, start.hasPrefix("-P") || start.hasPrefix("+P") {
                return Self.jsonResponse(status: .badRequest, body: "{\"error\":\"Invalid start parameter \(start)\",\"type\":\"http://gnocchi.fake/400\"}")
            }
            if (agg == nil) != (gran == nil) {
                // Gnocchi silently ignores a lone aggregation/granularity and
                // returns raw measures.
                return Self.jsonResponse(status: .ok, body: Self.measuresJSON(m.measures))
            }
            guard let agg, let gran else {
                return Self.jsonResponse(status: .ok, body: Self.measuresJSON(m.measures))
            }
            let policy = await state.gnocchiArchivePolicies().first { $0.name == (m.archivePolicy ?? "low") }
            guard let policy, policy.methods.contains(agg), policy.granularity == gran else {
                return Self.jsonResponse(status: .notFound, body: "{\"error\":\"Aggregation method '\(agg)' at granularity \(gran) does not exist\",\"type\":\"http://gnocchi.fake/404\"}")
            }
            // Coarse aggregation: mean of the raw values, single bucket.
            let values = m.measures.map { $0.last ?? 0 }
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            let bucket: [Double] = [m.measures.first?.first ?? 0, Self.parseGranularity(gran), mean]
            return Self.jsonResponse(status: .ok, body: Self.measuresJSON([bucket]))
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

        router.get(RouterPath("\(base)/archive_policy")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let policies = await state.gnocchiArchivePolicies()
            let body = policies.map { p in
                let methods = p.methods.map { "\"\($0)\"" }.joined(separator: ",")
                return "{\"name\":\"\(p.name)\",\"back_window\":0,\"aggregation_methods\":[\(methods)],\"definition\":[{\"timespan\":\"\(p.timespan)\",\"granularity\":\"\(p.granularity)\",\"points\":10080}]}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "[\(body)]")
        }
    }

    static func metricJSON(_ m: FakeState.FakeGnocchiMetric) -> String {
        var parts = ["\"id\":\"\(m.id)\"", "\"name\":\"\(m.name)\""]
        if let u = m.unit { parts.append("\"unit\":\"\(u)\"") }
        if let r = m.resourceID { parts.append("\"resource_id\":\"\(r)\"") }
        if let c = m.creator { parts.append("\"creator\":\"\(c)\"") }
        if let ap = m.archivePolicy { parts.append("\"archive_policy\":{\"name\":\"\(ap)\"}") }
        parts.append("\"created\":\"\(m.created)\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// `[ts, gran, value]` triples; timestamps as ISO-8601 like Gnocchi's
    /// measures endpoint.
    static func measuresJSON(_ measures: [[Double]]) -> String {
        "[" + measures.map { row in
            let ts = Date(timeIntervalSince1970: row.first ?? 0).ISO8601FormatString
            let cells = ([ts] + row.dropFirst().map { String($0) }).joined(separator: ",")
            return "[\(cells)]"
        }.joined(separator: ",") + "]"
    }

    /// "0:05:00" → 300 seconds.
    static func parseGranularity(_ g: String) -> Double {
        let parts = g.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return Double(g) ?? 300 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func readBody(_ req: Request) async throws -> String {
        var data = ""
        for try await buffer in req.body {
            data += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        }
        return data
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

private extension Date {
    var ISO8601FormatString: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "\"\(f.string(from: self))\""
    }
}
