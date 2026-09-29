import Foundation
import Hummingbird
import Logging
import HTTPTypes
import NIOCore

/// Fake Keystone v3 implementation.
public struct KeystoneFake {
    public static func registerRoutes(_ router: Router<BasicRequestContext>, state: FakeState, baseHost: @escaping @Sendable () -> String) {
        let prefix = RouterPath("/keystone/v3")
        let authTokens = RouterPath("/keystone/v3/auth/tokens")

        router.get(prefix) { _, _ in
            Self.jsonResponse(status: .ok, body: """
            {"version":{"id":"v3.14","status":"stable","max_microversion":"3.14"}}
            """)
        }

        router.post(authTokens) { req, _ in
            let body = try await Self.readBody(req)
            guard let data = body.data(using: .utf8) else {
                return Self.jsonResponse(status: .badRequest, body: """
                {"error":{"code":"badRequest","title":"Invalid request body"}}
                """)
            }

            struct AppCred: Decodable { let id: String; let secret: String }
            struct DomainRef: Decodable { let name: String? }
            struct User: Decodable { let name: String; let password: String?; let domain: DomainRef? }
            struct Identity: Decodable { let methods: [String]; let applicationCredential: AppCred?; let user: User? }
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

        router.get(authTokens) { req, _ in
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
        [{"type":"identity","name":"keystone","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/keystone/v3"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/keystone/v3"}]},{"type":"compute","name":"nova","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/nova"},{"region":"RegionOne","interface":"internal","url":"\(baseHost)/nova-internal"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/nova-r2"}]},{"type":"network","name":"neutron","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/neutron/v2.0"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/neutron-r2/v2.0"}]},{"type":"volumev3","name":"cinder","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/cinder/v3"}]},{"type":"image","name":"glance","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/glance/v2"},{"region":"RegionTwo","interface":"public","url":"\(baseHost)/glance-r2/v2"}]},{"type":"mcp","name":"openstack-mcp","endpoints":[{"region":"RegionOne","interface":"public","url":"\(baseHost)/v1"}]}]
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
