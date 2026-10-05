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
        //
        // The catalog + identity routes are registered under BOTH the
        // `/keystone/v3` prefix and the bare `/v3` prefix. Real OpenStack clouds
        // expose `auth_url` as the Keystone version root (so `/v3/services` etc.
        // are the correct paths), while some catalogs mount Keystone under
        // `/keystone`. Registering both keeps the fake honest for either
        // convention — matching how the client builds these paths.

        func registerIdentity(_ prefix: String) {
            let services = RouterPath("\(prefix)/services")
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

            // POST \(prefix)/services/:id/endpoints
            router.post(RouterPath("\(prefix)/services/:id/endpoints")) { req, context in
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

            // POST \(prefix)/endpoints (flat path, service_id in the body).
            // RDO/Genestack Keystones support this form and 404 the nested
            // /services/:id/endpoints form, so the registrar uses it.
            router.post(RouterPath("\(prefix)/endpoints")) { req, _ in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: """
                    {"error":{"code":"forbidden","title":"Missing X-Auth-Token"}}
                    """)
                }
                let body = try await Self.readBody(req)
                guard let data = body.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(EPWrap.self, from: data),
                      let ep = parsed.endpoint,
                      let svcID = ep.service_id else {
                    return Self.jsonResponse(status: .badRequest, body: """
                    {"error":{"code":"badRequest","title":"Invalid endpoint body (missing service_id)"}}
                    """)
                }
                let knownService = await state.listServices().contains(where: { $0.id == svcID })
                if !knownService {
                    return Self.jsonResponse(status: .notFound, body: """
                    {"error":{"code":"serviceNotFound","title":"Service not found"}}
                    """)
                }
                let created = await state.createEndpoint(serviceID: svcID, interface: ep.interface, regionID: ep.region_id ?? "RegionOne", url: ep.url)
                return Self.jsonResponse(status: .created, body: """
                {"endpoint":{"id":"\(created.id)","service_id":"\(created.serviceID)","interface":"\(created.interface)","region_id":"\(created.regionID)","url":"\(created.url)"}}
                """)
            }
            // GET \(prefix)/endpoints
            let endpointsPath = RouterPath("\(prefix)/endpoints")
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

            // GET \(prefix)/domains
            let domains = RouterPath("\(prefix)/domains")
            router.get(domains) { req, _ in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let name = Self.queryParam("name", from: req)
                let list = await state.listDomains(name: name)
                let json = list.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }.joined(separator: ",")
                return Self.jsonResponse(status: .ok, body: "{\"domains\":[\(json)]}")
            }

            // GET/POST \(prefix)/users
            let users = RouterPath("\(prefix)/users")
            router.get(users) { req, _ in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let name = Self.queryParam("name", from: req)
                let domainID = Self.queryParam("domain_id", from: req)
                let list = await state.listIdentityUsers(name: name, domainID: domainID)
                let json = list.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"domain_id\":\"\($0.domainID)\",\"enabled\":\($0.enabled)}" }.joined(separator: ",")
                return Self.jsonResponse(status: .ok, body: "{\"users\":[\(json)]}")
            }
            router.post(users) { req, _ in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let body = try await Self.readBody(req)
                guard let data = body.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(UserWrap.self, from: data),
                      let u = parsed.user else {
                    return Self.jsonResponse(status: .badRequest, body: "{\"error\":{\"code\":\"badRequest\",\"title\":\"Invalid user body\"}}")
                }
                let created = await state.createIdentityUser(name: u.name, domainID: u.domain_id, enabled: u.enabled ?? true, password: u.password)
                return Self.jsonResponse(status: .created, body: "{\"user\":{\"id\":\"\(created.id)\",\"name\":\"\(created.name)\",\"domain_id\":\"\(created.domainID)\",\"enabled\":\(created.enabled)}}")
            }

            // GET \(prefix)/roles
            let roles = RouterPath("\(prefix)/roles")
            router.get(roles) { req, _ in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let name = Self.queryParam("name", from: req)
                let list = await state.listRoles(name: name)
                let json = list.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }.joined(separator: ",")
                return Self.jsonResponse(status: .ok, body: "{\"roles\":[\(json)]}")
            }

            // GET/POST \(prefix)/role_assignments
            // Domain-scoped role assignment (the documented v3 grant/check):
            //   GET /v3/domains/{domain_id}/users/{user_id}/roles
            //   PUT /v3/domains/{domain_id}/users/{user_id}/roles/{role_id}
            router.get(RouterPath("\(prefix)/domains/:domain_id/users/:user_id/roles")) { req, context in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let domainID = context.parameters.get("domain_id") ?? ""
                let userID = context.parameters.get("user_id") ?? ""
                let list = await state.roleAssignments(userID: userID, domainID: domainID)
                let json = list.map { "{\"id\":\"\($0.roleID)\",\"name\":\"\($0.roleID)\"}" }.joined(separator: ",")
                return Self.jsonResponse(status: .ok, body: "{\"roles\":[\(json)]}")
            }
            router.put(RouterPath("\(prefix)/domains/:domain_id/users/:user_id/roles/:role_id")) { req, context in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let domainID = context.parameters.get("domain_id") ?? ""
                let userID = context.parameters.get("user_id") ?? ""
                let roleID = context.parameters.get("role_id") ?? ""
                await state.addRoleAssignment(roleID: roleID, userID: userID, domainID: domainID)
                // 204 No Content (the real API returns 204 on grant).
                return Response(status: .noContent)
            }

            // Per-user application credentials (the documented v3 endpoints):
            //   GET  /v3/users/{user_id}/application_credentials
            //   POST /v3/users/{user_id}/application_credentials
            router.get(RouterPath("\(prefix)/users/:user_id/application_credentials")) { req, context in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let userID = context.parameters.get("user_id") ?? ""
                let list = await state.appCreds(userID: userID)
                let json = list.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }.joined(separator: ",")
                return Self.jsonResponse(status: .ok, body: "{\"application_credentials\":[\(json)]}")
            }
            router.post(RouterPath("\(prefix)/users/:user_id/application_credentials")) { req, context in
                guard let tokenID = req.headers[FakeHeaders.xAuthToken], await state.validateToken(tokenID) != nil else {
                    return Self.jsonResponse(status: .unauthorized, body: "{\"error\":{\"code\":\"forbidden\",\"title\":\"Missing X-Auth-Token\"}}")
                }
                let body = try await Self.readBody(req)
                guard let data = body.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(AppCredWrap.self, from: data),
                      let c = parsed.applicationCredential else {
                    return Self.jsonResponse(status: .badRequest, body: "{\"error\":{\"code\":\"badRequest\",\"title\":\"Invalid application_credential body\"}}")
                }
                // The owner is the user in the path (this is a per-user resource).
                let ownerID = context.parameters.get("user_id") ?? ""
                let created = await state.createAppCred(name: c.name, userID: ownerID, secret: c.secret)
                return Self.jsonResponse(status: .created, body: "{\"application_credential\":{\"id\":\"\(created.id)\",\"name\":\"\(created.name)\"}}")
            }
        }

        registerIdentity("/keystone/v3")
        registerIdentity("/v3")
    }

    struct SvcWrap: Decodable { struct Svc: Decodable { let type: String; let name: String?; let description: String? }; let service: Svc? }
    struct EPWrap: Decodable { struct EP: Decodable { let interface: String; let region_id: String?; let url: String; let service_id: String? }; let endpoint: EP? }
    struct UserWrap: Decodable { struct U: Decodable { let name: String; let domain_id: String; let enabled: Bool?; let password: String? }; let user: U? }
    struct RoleAssignWrap: Decodable { struct Scope: Decodable { let group: Group? }; struct Group: Decodable { let id: String? }; struct RA: Decodable { let role_id: String; let user_id: String; let scope: Scope? }; let roleAssignment: RA?; enum CodingKeys: String, CodingKey { case roleAssignment = "role_assignment" } }
    struct AppCredWrap: Decodable { struct C: Decodable { let name: String; let secret: String; let user_id: String? }; let applicationCredential: C?; enum CodingKeys: String, CodingKey { case applicationCredential = "application_credential" } }

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
        [{"type":"identity","name":"keystone","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/keystone/v3"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/keystone/v3"}]},{"type":"compute","name":"nova","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/nova"},{"region":"RegionOne","interface":"internal","url":"\(baseHost)/nova-internal"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/nova"}]},{"type":"network","name":"neutron","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/neutron/v2.0"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/neutron/v2.0"}]},{"type":"volumev3","name":"cinder","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/cinder/v3"}]},{"type":"image","name":"glance","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/glance/v2"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/glance/v2"}]},{"type":"object-store","name":"swift","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/swift/v1"}]},{"type":"key-manager","name":"barbican","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/barbican/v1"}]},{"type":"load-balancer","name":"octavia","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/loadbalancer/v2"}]},{"type":"dns","name":"designate","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/designate/v3"}]},{"type":"container-infra","name":"magnum","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/container"}]},{"type":"orchestration","name":"heat","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/orchestration/v1"}]},{"type":"sharev2","name":"manila","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/share/v2"}]},{"type":"mcp","name":"substation-mcp","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/v1"}]}]
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
