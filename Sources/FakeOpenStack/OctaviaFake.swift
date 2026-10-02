import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Octavia (load balancer) implementation.
///
/// Routes live under `/loadbalancer/v1/*`. Standard OpenStack REST shape:
/// collections at `/loadbalancers`, `/listeners`, `/pools`, `/members`,
/// `/healthmonitors`; items at `/<collection>/{id}`. List responses wrap items
/// in a keyed envelope (`{"loadbalancers":[...]}`); item/POST responses return
/// the bare object. Errors use the Octavia shape:
/// `{"faultblock": {"code": ..., "title": ..., "description": ...}}`.
public struct OctaviaFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/loadbalancer/v1"

        registerCollection(router, state: state, base: base, collection: "loadbalancers") { state, projectID, req in
            let name = Self.queryParam("name", from: req)
            let items = await state.listLoadBalancers(projectID: projectID, name: name, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.loadBalancerJSON($0) }
        } listID: { state, id, projectID in
            await state.getLoadBalancer(id: id, projectID: projectID).map(Self.loadBalancerJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("loadbalancer", in: body) ?? body
            let name = Self.extractString("name", from: inner)
            let vip = Self.extractString("vip_address", from: inner)
            let lb = await state.createLoadBalancer(projectID: projectID, name: name, vipAddress: vip)
            return Self.loadBalancerJSON(lb)
        }

        registerCollection(router, state: state, base: base, collection: "listeners") { state, projectID, req in
            let items = await state.listListeners(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.listenerJSON($0) }
        } listID: { state, id, projectID in
            await state.getListener(id: id, projectID: projectID).map(Self.listenerJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("listener", in: body) ?? body
            let l = await state.createListener(projectID: projectID, name: Self.extractString("name", from: inner), protocolName: Self.extractString("protocol", from: inner) ?? "HTTP", protocolPort: Self.extractInt("protocol_port", from: inner) ?? 80, loadBalancerID: Self.extractString("loadbalancer_id", from: inner))
            return Self.listenerJSON(l)
        }

        registerCollection(router, state: state, base: base, collection: "pools") { state, projectID, req in
            let items = await state.listPools(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.poolJSON($0) }
        } listID: { state, id, projectID in
            await state.getPool(id: id, projectID: projectID).map(Self.poolJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("pool", in: body) ?? body
            let p = await state.createPool(projectID: projectID, name: Self.extractString("name", from: inner), protocolName: Self.extractString("protocol", from: inner) ?? "HTTP", lbAlgorithm: Self.extractString("lb_algorithm", from: inner) ?? "ROUND_ROBIN", loadBalancerID: Self.extractString("loadbalancer_id", from: inner), healthMonitorID: Self.extractString("health_monitor_id", from: inner))
            return Self.poolJSON(p)
        }

        registerCollection(router, state: state, base: base, collection: "members") { state, projectID, req in
            let items = await state.listMembers(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.memberJSON($0) }
        } listID: { state, id, projectID in
            await state.getMember(id: id, projectID: projectID).map(Self.memberJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("member", in: body) ?? body
            let m = await state.createMember(projectID: projectID, name: Self.extractString("name", from: inner), protocolAddress: Self.extractString("protocol_address", from: inner) ?? "", protocolPort: Self.extractInt("protocol_port", from: inner) ?? 80, weight: Self.extractInt("weight", from: inner), adminStateUp: Self.extractBool("admin_state_up", from: inner), poolID: Self.extractString("pool_id", from: inner))
            return Self.memberJSON(m)
        }

        registerCollection(router, state: state, base: base, collection: "healthmonitors") { state, projectID, req in
            let items = await state.listHealthMonitors(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.healthMonitorJSON($0) }
        } listID: { state, id, projectID in
            await state.getHealthMonitor(id: id, projectID: projectID).map(Self.healthMonitorJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("health_monitor", in: body) ?? body
            let h = await state.createHealthMonitor(projectID: projectID, name: Self.extractString("name", from: inner), type: Self.extractString("type", from: inner) ?? "PING", delay: Self.extractInt("delay", from: inner), timeout: Self.extractInt("timeout", from: inner), maxRetries: Self.extractInt("max_retries", from: inner), poolID: Self.extractString("pool_id", from: inner))
            return Self.healthMonitorJSON(h)
        }
    }

    // Registers GET <base>/<collection> (list), GET <base>/<collection>/:id,
    // POST <base>/<collection>, DELETE <base>/<collection>/:id. The closures
    // return JSON strings; the `list` closure returns the array items' JSON
    // strings.
    private static func registerCollection(
        _ router: Router<BasicRequestContext>, state: FakeState, base: String, collection: String,
        list: @escaping @Sendable (FakeState, String, Request) async -> [String],
        listID: @escaping @Sendable (FakeState, String, String) async -> String?,
        create: @escaping @Sendable (FakeState, String, String) async -> String
    ) {
        router.get("\(base)/\(collection)") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let items = await list(state, token.projectID, req)
            return Self.jsonResponse(status: .ok, body: "{\"\(collection)\":[\(items.joined(separator: ","))]}")
        }

        router.get("\(base)/\(collection)/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let json = await listID(state, id, token.projectID) else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            return Self.jsonResponse(status: .ok, body: json)
        }

        router.post("\(base)/\(collection)") { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let json = await create(state, token.projectID, body)
            return Self.jsonResponse(status: .created, body: json)
        }

        router.delete("\(base)/\(collection)/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            guard let json = await listID(state, id, token.projectID) else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            _ = json
            // Delete is dispatched via the specific state method by id.
            let deleted = await Self.deleteByID(state, collection: collection, id: id, projectID: token.projectID)
            guard deleted else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            return Self.noContent()
        }
    }

    static func deleteByID(_ state: FakeState, collection: String, id: String, projectID: String) async -> Bool {
        switch collection {
        case "loadbalancers": return await state.deleteLoadBalancer(id: id, projectID: projectID)
        case "listeners": return await state.deleteListener(id: id, projectID: projectID)
        case "pools": return await state.deletePool(id: id, projectID: projectID)
        case "members": return await state.deleteMember(id: id, projectID: projectID)
        case "healthmonitors": return await state.deleteHealthMonitor(id: id, projectID: projectID)
        default: return false
        }
    }

    // MARK: - JSON builders

    static func loadBalancerJSON(_ lb: FakeState.FakeLoadBalancer) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(lb.id)\"")
        if let name = lb.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"status\":\"\(lb.status)\"")
        parts.append("\"provisioning_status\":\"\(lb.provisioningStatus)\"")
        if let vip = lb.vipAddress { parts.append("\"vip_address\":\"\(vip)\"") } else { parts.append("\"vip_address\":null") }
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func listenerJSON(_ l: FakeState.FakeListener) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(l.id)\"")
        if let name = l.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"protocol\":\"\(l.protocolName)\"")
        parts.append("\"protocol_port\":\(l.protocolPort)")
        if let lb = l.loadBalancerID { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func poolJSON(_ p: FakeState.FakePool) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(p.id)\"")
        if let name = p.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"protocol\":\"\(p.protocolName)\"")
        parts.append("\"lb_algorithm\":\"\(p.lbAlgorithm)\"")
        if let lb = p.loadBalancerID { parts.append("\"loadbalancer_id\":\"\(lb)\"") }
        if let hm = p.healthMonitorID { parts.append("\"health_monitor_id\":\"\(hm)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func memberJSON(_ m: FakeState.FakeMember) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(m.id)\"")
        if let name = m.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"protocol_address\":\"\(m.protocolAddress)\"")
        parts.append("\"protocol_port\":\(m.protocolPort)")
        if let w = m.weight { parts.append("\"weight\":\(w)") }
        if let up = m.adminStateUp { parts.append("\"admin_state_up\":\(up)") }
        if let pool = m.poolID { parts.append("\"pool_id\":\"\(pool)\"") }
        if let s = m.status { parts.append("\"status\":\"\(s)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func healthMonitorJSON(_ h: FakeState.FakeHealthMonitor) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(h.id)\"")
        if let name = h.name { parts.append("\"name\":\"\(name)\"") } else { parts.append("\"name\":null") }
        parts.append("\"type\":\"\(h.type)\"")
        if let d = h.delay { parts.append("\"delay\":\(d)") }
        if let t = h.timeout { parts.append("\"timeout\":\(t)") }
        if let mr = h.maxRetries { parts.append("\"max_retries\":\(mr)") }
        if let pool = h.poolID { parts.append("\"pool_id\":\"\(pool)\"") }
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

    static func extractBool(_ key: String, from json: String) -> Bool? {
        let pattern = "\"\(key)\""
        guard let keyRange = json.range(of: pattern) else { return nil }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if afterColon.hasPrefix("true") { return true }
        if afterColon.hasPrefix("false") { return false }
        return nil
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: body)))
    }

    static func noContent() -> Response {
        Response(status: .noContent, headers: [:], body: .init(byteBuffer: .init(string: "")))
    }

    static func unauthorized() -> Response {
        octaviaError(status: .unauthorized, message: "Unauthorized")
    }

    static func octaviaError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .notFound: code = 404
        case .unauthorized: code = 401
        default: code = 500
        }
        let title = status == .notFound ? "itemNotFound" : "error"
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"faultblock\":{\"code\":\(code),\"title\":\"\(title)\",\"description\":\"\(message)\"}}"))
        )
    }
}
