import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Fake Placement implementation.
///
/// Routes live under `/placement/*` (the service root is the catalog URL
/// itself — Placement has no version path). Real Placement semantics:
/// - `GET /resource_providers` → `{"resource_providers": [...]}` — the list is
///   a page; the last entry's `resource_providers.next` link carries the
///   continuation.
/// - `GET /resource_providers/{uuid}` → `{"resource_provider": {...}}`
/// - `GET /resource_providers/{uuid}/inventories` → `{"inventories": {VCPU: {total, ...}, ...}}`
/// - `GET /resource_providers/{uuid}/usages` → `{"usages": {VCPU: N, ...}}`
/// - Errors use the Placement shape: `{"fault": {"title": ..., "code": ..., "explanation": ...}}`
public struct PlacementFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState) {
        let base = "/placement"

        router.get(RouterPath("\(base)/resource_providers")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  let token = await state.validateToken(tokenID) else {
                return Self.unauthorized()
            }
            let name = Self.queryParam("name", from: req)
            let limit = Self.queryParam("limit", from: req).flatMap { Int($0) }
            let marker = Self.queryParam("marker", from: req)
            let rps = await state.listResourceProviders(name: name, limit: limit, marker: marker)
            let items = rps.map { Self.providerJSON($0, withNext: false) }.joined(separator: ",")
            _ = token
            return Self.jsonResponse(status: .ok, body: """
            {"resource_providers":[\(items)]}
            """)
        }

        router.get(RouterPath("\(base)/resource_providers/:uuid")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let uuid = ctx.parameters.get("uuid") ?? ""
            guard let rp = await state.getResourceProvider(uuid: uuid) else {
                return Self.fault(status: .notFound, title: "Not Found", explanation: "No resource provider found for UUID \(uuid).")
            }
            return Self.jsonResponse(status: .ok, body: """
            {"resource_provider":\(Self.providerJSON(rp, withNext: true))}
            """)
        }

        router.get(RouterPath("\(base)/resource_providers/:uuid/inventories")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let uuid = ctx.parameters.get("uuid") ?? ""
            guard let inv = await state.resourceProviderInventories(uuid: uuid) else {
                return Self.fault(status: .notFound, title: "Not Found", explanation: "No resource provider found for UUID \(uuid).")
            }
            // Real Placement inventories wrap each entry in {total, reserved, ...}.
            let entries = inv.keys.sorted().map { key -> String in
                "\"\(key)\":{\"total\":\(inv[key] ?? 0)}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"inventories":{\(entries)}}
            """)
        }

        router.get(RouterPath("\(base)/resource_providers/:uuid/usages")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let uuid = ctx.parameters.get("uuid") ?? ""
            guard let usages = await state.resourceProviderUsages(uuid: uuid) else {
                return Self.fault(status: .notFound, title: "Not Found", explanation: "No resource provider found for UUID \(uuid).")
            }
            let entries = usages.keys.sorted().map { key -> String in
                "\"\(key)\":\(usages[key] ?? 0)"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"usages":{\(entries)}}
            """)
        }

        router.get(RouterPath("\(base)/resource_providers/:uuid/allocations")) { req, ctx in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            let uuid = ctx.parameters.get("uuid") ?? ""
            guard let allocs = await state.providerAllocations(uuid: uuid) else {
                return Self.fault(status: .notFound, title: "Not Found", explanation: "No resource provider found for UUID \(uuid).")
            }
            let rp = await state.getResourceProvider(uuid: uuid)
            let consumerEntries = allocs.map { consumer, resources -> String in
                let res = resources.keys.sorted().map { "\"\($0)\":\(resources[$0] ?? 0)" }.joined(separator: ",")
                return "\"\(consumer)\":{\"resources\":{\(res)}}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"allocations":{\(consumerEntries)},"resource_provider_generation":\(rp?.generation ?? 1)}
            """)
        }

        router.get(RouterPath("\(base)/allocation_candidates")) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken],
                  await state.validateToken(tokenID) != nil else {
                return Self.unauthorized()
            }
            guard let resources = Self.queryParam("resources", from: req), !resources.isEmpty else {
                return Self.fault(status: .badRequest, title: "Bad Request", explanation: "Missing required query parameter: resources")
            }
            // Every provider whose inventory covers the resource group becomes
            // a candidate (real placement does full scheduling; the fake only
            // needs the response shape + plausible filtering).
            let firstGroup = resources.split(separator: ";").first.map(String.init) ?? resources
            let wanted = firstGroup.split(separator: ",").compactMap { pair -> (String, Int)? in
                let kv = pair.split(separator: ":", maxSplits: 1)
                guard kv.count == 2, let amount = Int(kv[1]) else { return nil }
                return (String(kv[0]), amount)
            }
            let rps = await state.listResourceProviders()
            let fitting = rps.filter { rp in
                wanted.allSatisfy { (klass, amount) in (rp.inventory[klass] ?? 0) >= amount }
            }
            let requests = fitting.map { rp -> String in
                let res = wanted.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
                return "{\"allocations\":{\"\(rp.uuid)\":{\"resources\":{\(res)}}},\"mappings\":{\"\":\"\(rp.uuid)\"}}"
            }.joined(separator: ",")
            let summaries = fitting.map { rp -> String in
                let inv = rp.inventory.keys.sorted().map { k in
                    "\"\(k)\":{\"total\":\(rp.inventory[k] ?? 0),\"reserved\":0,\"allocated\":\(rp.usages[k] ?? 0)}"
                }.joined(separator: ",")
                let traits = rp.traits.map { "\"\($0)\"" }.joined(separator: ",")
                return "\"\(rp.uuid)\":{\"name\":\"\(rp.name)\",\"generation\":\(rp.generation),\"resource_provider_generation\":\(rp.generation),\"inventories\":{\(inv)},\"aggregates\":[],\"traits\":[\(traits)]}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: """
            {"allocation_requests":[\(requests)],"meta":{"count":\(fitting.count),"limit":null,"marker":null},"provider_summaries":{\(summaries)}}
            """)
        }
    }

    // MARK: - JSON builders

    static func providerJSON(_ rp: FakeState.FakePlacementResourceProvider, withNext: Bool) -> String {
        var parts: [String] = []
        parts.append("\"uuid\":\"\(rp.uuid)\"")
        parts.append("\"name\":\"\(rp.name)\"")
        parts.append("\"generation\":\(rp.generation)")
        if !rp.traits.isEmpty {
            let traits = rp.traits.map { "\"\($0)\"" }.joined(separator: ",")
            parts.append("\"traits\":[\(traits)]")
        }
        let base = "/placement/resource_providers/\(rp.uuid)"
        // Real Placement emits `links` as an ARRAY of {rel, href} objects,
        // with one entry per sub-resource (the list view omits them to keep
        // the page compact; the detail view carries them all).
        var links: [String] = [
            "{\"rel\":\"self\",\"href\":\"\(base)\"}"
        ]
        if withNext {
            links.append("{\"rel\":\"resource_provider\",\"href\":\"\(base)\"}")
            links.append("{\"rel\":\"inventories\",\"href\":\"\(base)/inventories\"}")
            links.append("{\"rel\":\"usages\",\"href\":\"\(base)/usages\"}")
            links.append("{\"rel\":\"next\",\"href\":\"\(base)\"}")
        }
        parts.append("\"links\":[\(links.joined(separator: ","))]")
        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: - Helpers

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    // MARK: - Responses

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }

    static func unauthorized() -> Response {
        fault(status: .unauthorized, title: "Unauthorized", explanation: "The request you have made requires authentication.")
    }

    static func fault(status: HTTPResponse.Status, title: String, explanation: String) -> Response {
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
            {"fault":{"title":"\(title)","code":\(code),"explanation":"\(explanation)"}}
            """))
        )
    }
}
