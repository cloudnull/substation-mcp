import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Keystone v3 implementation.
public struct KeystoneFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState, baseHost: @escaping @Sendable () -> String) {
        let prefix = RouterPath("/keystone/v3")
        let rootPrefix = RouterPath("/v3")
        let authTokens = RouterPath("/keystone/v3/auth/tokens")
        // Root-level auth-tokens alias: the MCP server's shared transport is
        // rooted at the cloud's base URL so it can reach BOTH Keystone
        // (validation: GET/POST /v3/auth/tokens) and the services
        // (nova/neutron/cinder/glance hang off the same base host, e.g.
        // <base>/nova). The fake therefore serves Keystone at the root as well
        // as under /keystone/v3. Existing tests that mint/validate via
        // <base>/keystone/v3 keep working against the prefixed routes.
        let rootAuthTokens = RouterPath("/v3/auth/tokens")

        router.get(prefix) { _, _ in
            Self.jsonResponse(status: .ok, body: """
            {"version":{"id":"v3.14","status":"stable","max_microversion":"3.14"}}
            """)
        }
        router.get(rootPrefix) { _, _ in
            Self.jsonResponse(status: .ok, body: """
            {"version":{"id":"v3.14","status":"stable","max_microversion":"3.14"}}
            """)
        }

        let mintHandler: @Sendable (Request, BasicRequestContext) async throws -> Response = { req, context in
            let body = try await Self.readBody(req)
            guard let data = body.data(using: .utf8), !data.isEmpty else {
                return Self.jsonResponse(status: .badRequest, body: """
                {"error":{"code":"badRequest","title":"Invalid request body"}}
                """)
            }

            struct AppCred: Decodable { let id: String; let secret: String }
            struct DomainRef: Decodable { let name: String? }
            struct User: Decodable { let name: String; let password: String?; let domain: DomainRef? }
            // Real Keystone uses snake_case keys ("application_credential").
            // Swift's synthesized Decodable expects camelCase, so map the keys.
            struct Identity: Decodable {
                let methods: [String]
                let applicationCredential: AppCred?
                let user: User?
                enum CodingKeys: String, CodingKey {
                    case methods
                    case applicationCredential = "application_credential"
                    case user
                }
            }
            struct Auth: Decodable { let identity: Identity }
            struct AuthBody: Decodable { let auth: Auth }

            guard let parsed = try? JSONDecoder().decode(AuthBody.self, from: data) else {
                return Self.jsonResponse(status: .badRequest, body: """
                {"error":{"code":"badRequest","title":"Invalid request body"}}
                """)
            }

            let identity = parsed.auth.identity
            let token: FakeState.FakeToken?

            if identity.methods.contains("application_credential"),
               let appCred = identity.applicationCredential {
                token = await state.mintToken(credID: appCred.id, secret: appCred.secret, domain: nil, password: nil, userID: nil)
            } else if identity.methods.contains("password"),
                      let user = identity.user {
                token = await state.mintToken(credID: user.name, secret: user.password ?? "", domain: user.domain?.name, password: user.password, userID: user.name)
            } else {
                token = nil
            }

            guard let token else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"The request you have made requires authentication"}}
                """)
            }

            let host = baseHost()
            let catalogJSON = Self.buildCatalog(baseHost: host)
            let expiresISO = token.expiresAt.ISO8601Format()
            let rolesJSON = token.roles.map { "\"\($0)\"" }.joined(separator: ",")

            var res = Self.jsonResponse(status: .created, body: """
            {"token":{"id":"\(token.id)","expires_at":"\(expiresISO)","project":{"id":"\(token.projectID)","name":"\(token.projectName)"},"domain":{"id":"\(token.domainID)","name":"\(token.domainName)"},"user":{"id":"\(token.userID)","name":"\(token.userName)","domain":{"id":"\(token.userDomain)","name":"Default"}},"roles":[\(rolesJSON)],"catalog":\(catalogJSON)}}
            """)
            res.headers[FakeHeaders.xSubjectToken] = token.id
            return res
        }
        router.post(authTokens, use: mintHandler)
        router.post(rootAuthTokens, use: mintHandler)

        let validateHandler: @Sendable (Request, BasicRequestContext) async throws -> Response = { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken] else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                """)
            }

            guard let token = await state.validateToken(tokenID) else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Could not find token"}}
                """)
            }

            let host = baseHost()
            let catalogJSON = Self.buildCatalog(baseHost: host)
            let expiresISO = token.expiresAt.ISO8601Format()
            let rolesJSON = token.roles.map { "\"\($0)\"" }.joined(separator: ",")

            return Self.jsonResponse(status: .ok, body: """
            {"token":{"id":"\(token.id)","expires_at":"\(expiresISO)","project":{"id":"\(token.projectID)","name":"\(token.projectName)"},"domain":{"id":"\(token.domainID)","name":"\(token.domainName)"},"user":{"id":"\(token.userID)","name":"\(token.userName)","domain":{"id":"\(token.userDomain)","name":"Default"}},"roles":[\(rolesJSON)],"catalog":\(catalogJSON)}}
            """)
        }
        router.get(authTokens, use: validateHandler)
        router.get(rootAuthTokens, use: validateHandler)

        // MARK: - Catalog: services + endpoints (register-catalog)

        let services = RouterPath("/keystone/v3/services")
        router.get(services) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                """)
            }
            let svcs = await state.listServices()
            let json = svcs.map { s in
                "{\"id\":\"\(s.id)\",\"type\":\"\(s.type)\",\"name\":\"\(s.name)\",\"description\":\"\(s.description)\"}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"services\":[\(json)]}")
        }
        router.post(services) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                """)
            }
            let body = try await Self.readBody(req)
            guard let data = body.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(SvcWrap.self, from: data),
                  let svc = parsed.service else {
                return Self.jsonResponse(status: .badRequest, body: """
                {"error":{"code":"badRequest","title":"Invalid service body"}}
                """)
            }
            let created = await state.createService(type: svc.type, name: svc.name ?? "service", description: svc.description ?? "")
            return Self.jsonResponse(status: .created, body: """
            {"service":{"id":"\(created.id)","type":"\(created.type)","name":"\(created.name)","description":"\(created.description)"}}
            """)
        }

        // POST /keystone/v3/services/:id/endpoints
        router.post(RouterPath("/keystone/v3/services/:id/endpoints")) { req, context in
            let svcID = context.parameters.get("id") ?? ""
            guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                """)
            }
            let knownService = await state.listServices().contains(where: { $0.id == svcID })
            if !knownService {
                return Self.jsonResponse(status: .notFound, body: """
                {"error":{"code":"serviceNotFound","title":"Service not found"}}
                """)
            }
            let body = try await Self.readBody(req)
            guard let data = body.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(EPWrap.self, from: data),
                  let ep = parsed.endpoint else {
                return Self.jsonResponse(status: .badRequest, body: """
                {"error":{"code":"badRequest","title":"Invalid endpoint body"}}
                """)
            }
            let created = await state.createEndpoint(serviceID: svcID, interface: ep.interface, regionID: ep.region_id ?? "RegionOne", url: ep.url)
            return Self.jsonResponse(status: .created, body: """
            {"endpoint":{"id":"\(created.id)","service_id":"\(created.serviceID)","interface":"\(created.interface)","region_id":"\(created.regionID)","url":"\(created.url)"}}
            """)
        }
        // GET /keystone/v3/endpoints
        let endpointsPath = RouterPath("/keystone/v3/endpoints")
        router.get(endpointsPath) { req, _ in
            guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                return Self.jsonResponse(status: .unauthorized, body: """
                {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                """)
            }
            let serviceID = Self.queryParam("service_id", from: req)
            let eps = await state.listEndpoints(serviceID: serviceID)
            let json = eps.map { e in
                "{\"id\":\"\(e.id)\",\"service_id\":\"\(e.serviceID)\",\"interface\":\"\(e.interface)\",\"region_id\":\"\(e.regionID)\",\"url\":\"\(e.url)\"}"
            }.joined(separator: ",")
            return Self.jsonResponse(status: .ok, body: "{\"endpoints\":[\(json)]}")
        }
    }

    struct SvcWrap: Decodable { struct Svc: Decodable { let type: String; let name: String?; let description: String? }; let service: Svc? }
    struct EPWrap: Decodable { struct EP: Decodable { let interface: String; let region_id: String?; let url: String }; let endpoint: EP? }

    static func queryParam(_ name: String, from req: Request) -> String? {
        req.uri.queryParameters[Substring(name)].map { String($0) }
    }

    static func readBody(_ req: Request) async throws -> String {
        var data = Data()
        for try await buffer in req.body {
            data.append(contentsOf: buffer.readableBytesView)
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func buildCatalog(baseHost: String) -> String {
        """
        [{"type":"identity","name":"keystone","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/keystone/v3"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/keystone/v3"}]},{"type":"compute","name":"nova","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/nova"},{"region":"RegionOne","interface":"internal","url":"\(baseHost)/nova-internal"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/nova-r2"}]},{"type":"network","name":"neutron","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/neutron/v2.0"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/neutron-r2/v2.0"}]},{"type":"volumev3","name":"cinder","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/cinder/v3"}]},{"type":"image","name":"glance","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/glance/v2"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/glance-r2/v2"}]},{"type":"object-store","name":"swift","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/swift/v1"}]},{"type":"key-manager","name":"barbican","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/barbican/v1"}]},{"type":"loadbalancer","name":"octavia","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/loadbalancer/v1"}]},{"type":"dns","name":"designate","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/designate/v3"}]},{"type":"container","name":"magnum","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/container"}]},{"type":"orchestration","name":"heat","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/orchestration/v1"}]},{"type":"mcp","name":"openstack-mcp","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/v1"}]}]
        """
    }

    static func jsonResponse(status: HTTPResponse.Status, body: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }
}
