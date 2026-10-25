import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Octavia (load balancer) implementation.
///
/// Routes mirror the REAL Octavia route table so a client bug against a live
/// cloud reproduces here:
///   * collections are namespaced under `lbaas`:
///     `/loadbalancer/v2/lbaas/{loadbalancers,listeners,pools,healthmonitors}`
///     (`V2Controller.lbaas` + `BaseV2Controller` in
///     `octavia/api/v2/controllers/__init__.py`).
///   * members are a POOL SUB-resource:
///     `/loadbalancer/v2/lbaas/pools/{pool_id}/members[/{member_id}]`
///     (`PoolsController._lookup` hands `pools/{id}/members` to
///     `MemberController(pool_id)`). There is deliberately **no** top-level
///     `/lbaas/members` route: a POST there answers `405 Method Not Allowed`,
///     exactly like the real service (defect #7).
///   * single-item GET/POST/PUT return the BARE object; lists return the keyed
///     envelope (`{"listeners":[…]}`).
///   * unset scalars come back as JSON `null` (`"name":null`), which is what
///     Octavia serialises and what broke strict decoders (defect #5).
///   * errors use the Octavia shape:
///     `{"faultblock": {"code": …, "title": …, "description": …}}`.
public struct OctaviaFake {
    private static let base = "/loadbalancer/v2/lbaas"

    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = Self.base

        registerCollection(router, state: state, base: base, collection: "loadbalancers") { state, projectID, req in
            let name = Self.queryParam("name", from: req)
            let items = await state.listLoadBalancers(projectID: projectID, name: name, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.loadBalancerJSON($0) }
        } listID: { state, id, projectID in
            await state.getLoadBalancer(id: id, projectID: projectID).map(Self.loadBalancerJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("loadbalancer", in: body) ?? body
            let lb = await state.createLoadBalancer(
                projectID: projectID,
                name: Self.extractString("name", from: inner),
                vipAddress: Self.extractString("vip_address", from: inner),
                vipSubnetID: Self.extractString("vip_subnet_id", from: inner))
            // Test-only fault injection (ISSUE 18): the LB IS created server-side,
            // but the response body is a minimal/non-JSON shape (like Rackspace
            // octavia), forcing the client to recover via list-read-back.
            if let raw = await state.consumeLBCreateRawBodyNext() { return raw }
            return Self.envelope("loadbalancer", Self.loadBalancerJSON(lb))
        } update: { state, id, projectID, body in
            let inner = Self.objectForKey("loadbalancer", in: body) ?? body
            return await state.updateLoadBalancer(
                id: id, projectID: projectID,
                name: Self.extractString("name", from: inner),
                description: Self.extractString("description", from: inner)
            ).map(Self.loadBalancerJSON)
        }

        registerCollection(router, state: state, base: base, collection: "listeners") { state, projectID, req in
            let items = await state.listListeners(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.listenerJSON($0) }
        } listID: { state, id, projectID in
            await state.getListener(id: id, projectID: projectID).map(Self.listenerJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("listener", in: body) ?? body
            let l = await state.createListener(
                projectID: projectID,
                name: Self.extractString("name", from: inner),
                protocolName: Self.extractString("protocol", from: inner) ?? "HTTP",
                protocolPort: Self.extractInt("protocol_port", from: inner) ?? 80,
                loadBalancerID: Self.extractString("loadbalancer_id", from: inner),
                defaultPoolID: Self.extractString("default_pool_id", from: inner))
            // Defect #5 fault injection: the listener IS created, the response is
            // the minimal/optional-fields-absent shape that used to fail our
            // decoder. Consumed once.
            if let raw = await state.consumeListenerCreateRawBodyNext() { return raw }
            return Self.envelope("listener", Self.listenerJSON(l))
        } update: { state, id, projectID, body in
            let inner = Self.objectForKey("listener", in: body) ?? body
            return await state.updateListener(
                id: id, projectID: projectID,
                name: Self.extractString("name", from: inner),
                defaultPoolID: Self.extractString("default_pool_id", from: inner),
                clearsDefaultPool: Self.keyIsPresent("default_pool_id", in: inner) && Self.extractString("default_pool_id", from: inner) == nil
            ).map(Self.listenerJSON)
        }

        registerCollection(router, state: state, base: base, collection: "pools") { state, projectID, req in
            let items = await state.listPools(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.poolJSON($0) }
        } listID: { state, id, projectID in
            await state.getPool(id: id, projectID: projectID).map(Self.poolJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("pool", in: body) ?? body
            // Octavia requires one of loadbalancer_id / listener_id and derives
            // the LB from the listener when only the listener is given.
            let listenerID = Self.extractString("listener_id", from: inner)
            var loadBalancerID = Self.extractString("loadbalancer_id", from: inner)
            if loadBalancerID == nil, let listenerID {
                loadBalancerID = await state.getListener(id: listenerID, projectID: projectID)?.loadBalancerID
            }
            if loadBalancerID == nil {
                return Self.ERROR_MARKER + "Must provide at least one of: loadbalancer_id, listener_id"
            }
            let p = await state.createPool(
                projectID: projectID,
                name: Self.extractString("name", from: inner),
                protocolName: Self.extractString("protocol", from: inner) ?? "HTTP",
                lbAlgorithm: Self.extractString("lb_algorithm", from: inner) ?? "ROUND_ROBIN",
                loadBalancerID: loadBalancerID,
                healthMonitorID: Self.extractString("healthmonitor_id", from: inner),
                listenerID: listenerID)
            return Self.envelope("pool", Self.poolJSON(p))
        } update: { state, id, projectID, body in
            let inner = Self.objectForKey("pool", in: body) ?? body
            // PoolPUT has no listener_id: a pool cannot be re-bound by updating
            // the pool. Reject it the way Octavia does (unknown attribute).
            if Self.keyIsPresent("listener_id", in: inner) {
                return Self.ERROR_MARKER + "Unrecognized attributes in request body: listener_id"
            }
            return await state.updatePool(
                id: id, projectID: projectID,
                name: Self.extractString("name", from: inner),
                description: Self.extractString("description", from: inner),
                lbAlgorithm: Self.extractString("lb_algorithm", from: inner)
            ).map(Self.poolJSON)
        }

        registerCollection(router, state: state, base: base, collection: "healthmonitors") { state, projectID, req in
            let items = await state.listHealthMonitors(projectID: projectID, limit: Self.queryParam("limit", from: req).flatMap { Int($0) } ?? 25, marker: Self.queryParam("marker", from: req))
            return items.map { Self.healthMonitorJSON($0) }
        } listID: { state, id, projectID in
            await state.getHealthMonitor(id: id, projectID: projectID).map(Self.healthMonitorJSON)
        } create: { state, projectID, body in
            let inner = Self.objectForKey("healthmonitor", in: body) ?? body
            let poolID = Self.extractString("pool_id", from: inner)
            let h = await state.createHealthMonitor(
                projectID: projectID,
                name: Self.extractString("name", from: inner),
                type: Self.extractString("type", from: inner) ?? "PING",
                delay: Self.extractInt("delay", from: inner),
                timeout: Self.extractInt("timeout", from: inner),
                maxRetries: Self.extractInt("max_retries", from: inner),
                poolID: poolID)
            return Self.envelope("healthmonitor", Self.healthMonitorJSON(h))
        } update: { state, id, projectID, body in
            let inner = Self.objectForKey("healthmonitor", in: body) ?? body
            return await state.updateHealthMonitor(
                id: id, projectID: projectID,
                name: Self.extractString("name", from: inner),
                delay: Self.extractInt("delay", from: inner),
                timeout: Self.extractInt("timeout", from: inner),
                maxRetries: Self.extractInt("max_retries", from: inner)
            ).map(Self.healthMonitorJSON)
        }

        // MARK: Members — pool sub-resource only.

        router.get("\(base)/pools/:id/members") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else { return Self.unauthorized() }
            let poolID = ctx.parameters.get("id") ?? ""
            guard await state.getPool(id: poolID, projectID: token.projectID) != nil else {
                return Self.octaviaError(status: .notFound, message: "Pool with id \(poolID) not found.")
            }
            let items = await state.listMembers(projectID: token.projectID, poolID: poolID)
            let bodies = items.map { Self.memberJSON($0) }
            return Self.jsonResponse(status: .ok, body: "{\"members\":[\(bodies.joined(separator: ","))]}")
        }

        router.post("\(base)/pools/:id/members") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else { return Self.unauthorized() }
            let poolID = ctx.parameters.get("id") ?? ""
            guard await state.getPool(id: poolID, projectID: token.projectID) != nil else {
                return Self.octaviaError(status: .notFound, message: "Pool with id \(poolID) not found.")
            }
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("member", in: body) ?? body
            // `address` is the real Octavia member attribute; `protocol_address`
            // does not exist and is rejected as an unknown attribute.
            if Self.keyIsPresent("protocol_address", in: inner) {
                return Self.octaviaError(status: .badRequest, message: "Unrecognized attributes in request body: protocol_address")
            }
            guard let address = Self.extractString("address", from: inner),
                  let port = Self.extractInt("protocol_port", from: inner) else {
                return Self.octaviaError(status: .badRequest, message: "Invalid input for field/attribute address.")
            }
            let m = await state.createMember(
                projectID: token.projectID,
                name: Self.extractString("name", from: inner),
                address: address,
                protocolPort: port,
                subnetID: Self.extractString("subnet_id", from: inner),
                weight: Self.extractInt("weight", from: inner),
                adminStateUp: Self.extractBool("admin_state_up", from: inner),
                poolID: poolID)
            if let raw = await state.consumeMemberCreateRawBodyNext() { return Self.jsonResponse(status: .created, body: raw) }
            return Self.jsonResponse(status: .created, body: Self.envelope("member", Self.memberJSON(m)))
        }

        router.get("\(base)/pools/:id/members/:member_id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else { return Self.unauthorized() }
            let poolID = ctx.parameters.get("id") ?? ""
            let id = ctx.parameters.get("member_id") ?? ""
            guard let m = await state.getMember(id: id, projectID: token.projectID), m.poolID == poolID else {
                return Self.octaviaError(status: .notFound, message: "Member with id \(id) not found.")
            }
            return Self.jsonResponse(status: .ok, body: Self.memberJSON(m))
        }

        router.put("\(base)/pools/:id/members/:member_id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else { return Self.unauthorized() }
            let poolID = ctx.parameters.get("id") ?? ""
            let id = ctx.parameters.get("member_id") ?? ""
            guard let m = await state.getMember(id: id, projectID: token.projectID), m.poolID == poolID else {
                return Self.octaviaError(status: .notFound, message: "Member with id \(id) not found.")
            }
            _ = m
            let body = (try? await Self.readBody(req)) ?? "{}"
            let inner = Self.objectForKey("member", in: body) ?? body
            guard let updated = await state.updateMember(
                id: id, projectID: token.projectID,
                name: Self.extractString("name", from: inner),
                weight: Self.extractInt("weight", from: inner),
                adminStateUp: Self.extractBool("admin_state_up", from: inner)) else {
                return Self.octaviaError(status: .notFound, message: "Member with id \(id) not found.")
            }
            return Self.jsonResponse(status: .accepted, body: Self.memberJSON(updated))
        }

        router.delete("\(base)/pools/:id/members/:member_id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else { return Self.unauthorized() }
            let poolID = ctx.parameters.get("id") ?? ""
            let id = ctx.parameters.get("member_id") ?? ""
            guard let m = await state.getMember(id: id, projectID: token.projectID), m.poolID == poolID else {
                return Self.octaviaError(status: .notFound, message: "Member with id \(id) not found.")
            }
            _ = await state.deleteMember(id: id, projectID: token.projectID)
            return Self.noContent()
        }

        // A top-level members collection does not exist on Octavia: pecan finds
        // the `members` attribute nowhere under `/lbaas`, so the request falls
        // through to a method-not-allowed. Pinned here so a client that regresses
        // to `POST /lbaas/members` fails exactly like it did on IAD3 (defect #7).
        router.post("\(base)/members") { _, _ in
            Self.methodNotAllowed()
        }
        router.get("\(base)/members") { _, _ in
            Self.methodNotAllowed()
        }
    }

    /// Sentinel the collection closures use to signal "return an Octavia 400".
    static let ERROR_MARKER = "\u{00}OCTAVIA_ERROR\u{00}"

    // Registers GET <base>/<collection> (list), GET <base>/<collection>/:id,
    // POST <base>/<collection>, PUT <base>/<collection>/:id and
    // DELETE <base>/<collection>/:id. The closures return JSON strings; the
    // `list` closure returns the array items' JSON strings. `update` returns nil
    // for an unknown id and a `ERROR_MARKER`-prefixed string for a rejection.
    private static func registerCollection(
        _ router: Router<BasicRequestContext>, state: FakeState, base: String, collection: String,
        list: @escaping @Sendable (FakeState, String, Request) async -> [String],
        listID: @escaping @Sendable (FakeState, String, String) async -> String?,
        create: @escaping @Sendable (FakeState, String, String) async -> String,
        update: @escaping @Sendable (FakeState, String, String, String) async -> String?
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
            if json.hasPrefix(Self.ERROR_MARKER) {
                return Self.octaviaError(status: .badRequest, message: String(json.dropFirst(Self.ERROR_MARKER.count)))
            }
            return Self.jsonResponse(status: .created, body: json)
        }

        // Octavia's PUT handlers answer 202 Accepted with the updated object
        // (`provisioning_status: PENDING_UPDATE`).
        router.put("\(base)/\(collection)/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            let body = (try? await Self.readBody(req)) ?? "{}"
            guard let json = await update(state, id, token.projectID, body) else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            if json.hasPrefix(Self.ERROR_MARKER) {
                return Self.octaviaError(status: .badRequest, message: String(json.dropFirst(Self.ERROR_MARKER.count)))
            }
            return Self.jsonResponse(status: .accepted, body: json)
        }

        router.delete("\(base)/\(collection)/:id") { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let id = ctx.parameters.get("id") ?? ""
            let cascade = (Self.queryParam("cascade", from: req) ?? "").lowercased() == "true"
            guard let json = await listID(state, id, token.projectID) else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            _ = json
            // A load balancer with children refuses a plain delete (Octavia's
            // "it has children"); ?cascade=true deletes the children too.
            if collection == "loadbalancers", !cascade,
               await state.loadBalancerHasChildren(id: id, projectID: token.projectID) {
                return Self.octaviaError(status: .badRequest,
                    message: "Validation failure: Cannot delete Load Balancer \(id) - it has children")
            }
            let deleted = await Self.deleteByID(state, collection: collection, id: id, projectID: token.projectID, cascade: cascade)
            guard deleted else {
                return Self.octaviaError(status: .notFound, message: "Item with id \(id) not found.")
            }
            return Self.noContent()
        }
    }

    static func deleteByID(_ state: FakeState, collection: String, id: String, projectID: String, cascade: Bool = false) async -> Bool {
        switch collection {
        case "loadbalancers": return await state.deleteLoadBalancer(id: id, projectID: projectID, cascade: cascade)
        case "listeners": return await state.deleteListener(id: id, projectID: projectID)
        case "pools": return await state.deletePool(id: id, projectID: projectID)
        case "healthmonitors": return await state.deleteHealthMonitor(id: id, projectID: projectID)
        default: return false
        }
    }

    // MARK: - JSON builders
    //
    // Field names are the Octavia WIRE names. Unset optionals are emitted as
    // JSON `null` (as Octavia does) rather than omitted, so a strict decoder
    // still trips here.

    static func loadBalancerJSON(_ lb: FakeState.FakeLoadBalancer) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(lb.id)\"")
        parts.append(quotedOrNull("name", lb.name))
        parts.append("\"provisioning_status\":\"\(lb.provisioningStatus)\"")
        parts.append("\"operating_status\":\"\(lb.status)\"")
        parts.append(quotedOrNull("vip_address", lb.vipAddress))
        parts.append(quotedOrNull("vip_subnet_id", lb.vipSubnetID))
        parts.append("\"created_at\":\"2026-01-01T00:00:00.000\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func listenerJSON(_ l: FakeState.FakeListener) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(l.id)\"")
        parts.append(quotedOrNull("name", l.name))
        parts.append("\"protocol\":\"\(l.protocolName)\"")
        parts.append("\"protocol_port\":\(l.protocolPort)")
        parts.append("\"provisioning_status\":\"ACTIVE\"")
        // Real Octavia: the parent LB is a `loadbalancers: [{id}]` reference list,
        // never a `loadbalancer_id` scalar, on every read.
        if let lb = l.loadBalancerID {
            parts.append("\"loadbalancers\":[{\"id\":\"\(lb)\"}]")
        } else {
            parts.append("\"loadbalancers\":[]")
        }
        parts.append(quotedOrNull("default_pool_id", l.defaultPoolID))
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func poolJSON(_ p: FakeState.FakePool) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(p.id)\"")
        parts.append(quotedOrNull("name", p.name))
        parts.append("\"protocol\":\"\(p.protocolName)\"")
        parts.append("\"lb_algorithm\":\"\(p.lbAlgorithm)\"")
        parts.append("\"provisioning_status\":\"ACTIVE\"")
        if let lb = p.loadBalancerID {
            parts.append("\"loadbalancers\":[{\"id\":\"\(lb)\"}]")
        } else {
            parts.append("\"loadbalancers\":[]")
        }
        if let listener = p.listenerID {
            parts.append("\"listeners\":[{\"id\":\"\(listener)\"}]")
        } else {
            parts.append("\"listeners\":[]")
        }
        // Wire name is `healthmonitor_id` (one word), null when unset.
        parts.append(quotedOrNull("healthmonitor_id", p.healthMonitorID))
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func memberJSON(_ m: FakeState.FakeMember) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(m.id)\"")
        parts.append(quotedOrNull("name", m.name))
        // `address`, not `protocol_address` — the latter is not an Octavia field.
        parts.append("\"address\":\"\(m.address)\"")
        parts.append("\"protocol_port\":\(m.protocolPort)")
        parts.append(quotedOrNull("subnet_id", m.subnetID))
        if let w = m.weight { parts.append("\"weight\":\(w)") } else { parts.append("\"weight\":null") }
        if let up = m.adminStateUp { parts.append("\"admin_state_up\":\(up)") } else { parts.append("\"admin_state_up\":null") }
        parts.append("\"provisioning_status\":\"ACTIVE\"")
        parts.append("\"operating_status\":\"\(m.status ?? "NO_MONITOR")\"")
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func healthMonitorJSON(_ h: FakeState.FakeHealthMonitor) -> String {
        var parts: [String] = []
        parts.append("\"id\":\"\(h.id)\"")
        parts.append(quotedOrNull("name", h.name))
        parts.append("\"type\":\"\(h.type)\"")
        if let d = h.delay { parts.append("\"delay\":\(d)") } else { parts.append("\"delay\":null") }
        if let t = h.timeout { parts.append("\"timeout\":\(t)") } else { parts.append("\"timeout\":null") }
        if let mr = h.maxRetries { parts.append("\"max_retries\":\(mr)") } else { parts.append("\"max_retries\":null") }
        if let pool = h.poolID {
            parts.append("\"pools\":[{\"id\":\"\(pool)\"}]")
        } else {
            parts.append("\"pools\":[]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// `"key":"value"` or `"key":null`, matching Octavia's null-for-unset style.
    static func quotedOrNull(_ key: String, _ value: String?) -> String {
        if let value { return "\"\(key)\":\"\(value)\"" }
        return "\"\(key)\":null"
    }

    /// Wrap a bare object body in Octavia's singular create/get envelope, e.g.
    /// `{"listener":{…}}`. Upstream Octavia returns the wrapped shape for
    /// POST/PUT/GET on every lbaas resource; the fake must match it so the
    /// client's envelope-first decode is exercised in tests (a bare-only fake
    /// let a wrapper-decode bug slip through to live clouds).
    static func envelope(_ key: String, _ objectJSON: String) -> String {
        "{\"\(key)\":\(objectJSON)}"
    }

    /// A create-listener body with the optional fields absent and the optionals
    /// Octavia does return set to null — the shape that used to decode as a
    /// failure and surface as `HTTP 500 … The data is missing` (defect #5).
    static func minimalListenerCreateBody(id: String, listenerID: String? = nil) -> String {
        let lb = listenerID.map { "\"loadbalancers\":[{\"id\":\"\($0)\"}]" } ?? "\"loadbalancers\":[]"
        return "{\"id\":\"\(id)\",\"name\":null,\"protocol\":\"HTTP\",\"protocol_port\":80,"
            + "\"provisioning_status\":\"PENDING_CREATE\",\"operating_status\":\"OFFLINE\","
            + "\"default_pool_id\":null,\"connection_limit\":null,\(lb)}"
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

    /// Whether `"key"` appears as a JSON key at all — needed to tell an omitted
    /// field apart from an explicit null (Octavia's PATCH semantics).
    static func keyIsPresent(_ key: String, in json: String) -> Bool {
        json.range(of: "\"\(key)\"") != nil
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

    static func methodNotAllowed() -> Response {
        Response(
            status: .methodNotAllowed,
            headers: [.contentType: "text/html; charset=UTF-8"],
            body: .init(byteBuffer: .init(string: "<html><body><h1>405 Method Not Allowed</h1><p>Method Not Allowed</p></body></html>"))
        )
    }

    static func octaviaError(status: HTTPResponse.Status, message: String) -> Response {
        let code: Int
        switch status {
        case .notFound: code = 404
        case .unauthorized: code = 401
        case .badRequest: code = 400
        default: code = 500
        }
        let title: String
        switch status {
        case .notFound: title = "itemNotFound"
        case .badRequest: title = "badRequest"
        default: title = "error"
        }
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: "{\"faultblock\":{\"code\":\(code),\"title\":\"\(title)\",\"description\":\"\(message)\"}}"))
        )
    }
}
