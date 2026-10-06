import Testing
import Foundation
import Logging
import Atomics
@testable import OpenStackClient

@Suite("TokenValidator")
struct TokenValidatorTests {
    private func makeTokenResponse(projectID: String, roles: [String], tokenID: String = "tok-test", expiresIn: TimeInterval = 3600) -> String {
        let expires = Date().addingTimeInterval(expiresIn).ISO8601Format()
        return """
        {
          "token": {
            "id": "\(tokenID)",
            "expires_at": "\(expires)",
            "project": {"id": "\(projectID)", "name": "test-project"},
            "domain": {"id": "default", "name": "Default"},
            "user": {"id": "user-1", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "roles": [\(roles.map { "\"\($0)\"" }.joined(separator: ","))],
            "catalog": [
              {
                "type": "compute",
                "name": "nova",
                "endpoints": [
                  {"region": "SAT0", "interface": "public", "url": "http://nova.example.com/v2.1"}
                ]
              }
            ]
          }
        }
        """
    }

    // Real Keystone v3 clouds (e.g. sat0) return a token body that differs from
    // the minimal fixture above in several ways: no top-level `id`, no top-level
    // `domain` (project-scoped tokens only carry `user.domain`), and `roles` as
    // objects {"id","name"} rather than strings. `Token.decode` must accept all
    // of these standard shapes, or serve-path validation 500s on live clouds.
    @Test func decodeRealKeystoneV3Shape() async throws {
        let body = """
        {
          "token": {
            "expires_at": "2026-10-02T13:03:34.000000Z",
            "issued_at": "2026-10-02T01:03:34.000000Z",
            "methods": ["password"],
            "is_domain": false,
            "user": {"id": "user-1", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "project": {"id": "proj-one", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "roles": [
              {"id": "role-1", "name": "reader"},
              {"id": "role-2", "name": "admin"}
            ],
            "catalog": [
              {
                "type": "compute",
                "name": "nova",
                "endpoints": [
                  {"region": "SAT0", "interface": "public", "url": "https://nova.api.example.com/v2.1"}
                ]
              }
            ]
          }
        }
        """
        let token = try Token.decode(from: Data(body.utf8))
        // No `id` in the body and no tokenID passed: decoded to a placeholder,
        // not a throw.
        #expect(token.id == "unknown")
        #expect(token.project.id == "proj-one")
        #expect(token.project.name == "admin")
        #expect(token.user.name == "admin")
        // Role objects collapse to their names.
        #expect(token.roles.contains("reader"))
        #expect(token.roles.contains("admin"))
        #expect(token.catalog.count == 1)
        #expect(token.catalog.first?.endpoints.first?.region == "SAT0")
    }

    /// Rackspace/Keystone whoami bodies omit `token.id`. The decode must fall
    /// back to the presented `tokenID` (the real token to send upstream), not
    /// "unknown" — otherwise data-plane calls carry no valid token and 401.
    @Test func decodeMissingID_fallsBackToPresentedTokenID() throws {
        let body = """
        {
          "token": {
            "expires_at": "2026-10-02T13:03:34.000000Z",
            "is_domain": false,
            "user": {"id": "user-1", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "project": {"id": "proj-one", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "roles": ["member"],
            "catalog": []
          }
        }
        """
        let token = try Token.decode(from: Data(body.utf8), tokenID: "the-presented-token")
        #expect(token.id == "the-presented-token")
        #expect(token.project.id == "proj-one")
    }

    /// When the body DOES carry an id (e.g. a minted token), the id wins over
    /// the tokenID fallback.
    @Test func decodeWithID_prefersBodyID() throws {
        let body = """
        {
          "token": {
            "id": "body-id-wins",
            "expires_at": "2026-10-02T13:03:34.000000Z",
            "user": {"id": "user-1", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "project": {"id": "proj-one", "name": "admin", "domain": {"id": "default", "name": "Default"}},
            "roles": ["member"],
            "catalog": []
          }
        }
        """
        let token = try Token.decode(from: Data(body.utf8), tokenID: "the-presented-token")
        #expect(token.id == "body-id-wins")
    }

    // A token may carry roles as plain strings (the legacy/fixture shape) or as
    // objects. Both must decode; mixed lists are legal too.
    @Test func decodeRolesAsStringsAndObjects() async throws {
        let body = """
        {
          "token": {
            "id": "tok-x",
            "expires_at": "2026-10-02T13:03:34.000000Z",
            "project": {"id": "p", "name": "p", "domain": {"id": "d", "name": "D"}},
            "domain": {"id": "d", "name": "D"},
            "user": {"id": "u", "name": "u", "domain": {"id": "d", "name": "D"}},
            "roles": ["member", {"id": "r", "name": "admin"}],
            "catalog": []
          }
        }
        """
        let token = try Token.decode(from: Data(body.utf8))
        #expect(token.roles.contains("member"))
        #expect(token.roles.contains("admin"))
    }

    @Test func validateHappyPath_readScope() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let body = makeTokenResponse(projectID: "proj-one", roles: ["member"], tokenID: "tok-1")
        server.addHandler("/v3/auth/tokens") { req in
            #expect(req.headers["x-auth-token"] == "tok-1")
            return (200, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let cache = Cache(maxEntries: 100)
        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: ["proj-one"]
        )

        let validated = try await validator.validate("tok-1")
        #expect(validated.token.project.id == "proj-one")
        #expect(validated.scopes == [.read], "member without write role should get read only")
    }

    @Test func validateHappyPath_writeScope() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let body = makeTokenResponse(projectID: "proj-one", roles: ["admin"], tokenID: "tok-2")
        server.addHandler("/v3/auth/tokens") { _ in
            (200, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let cache = Cache(maxEntries: 100)
        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: ["proj-one"]
        )

        let validated = try await validator.validate("tok-2")
        #expect(validated.scopes.contains(.read))
        #expect(validated.scopes.contains(.write), "admin should get write scope")
    }

    @Test func audienceCheck_403() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let body = makeTokenResponse(projectID: "proj-evil", roles: ["admin"], tokenID: "tok-evil")
        server.addHandler("/v3/auth/tokens") { _ in
            (200, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let cache = Cache(maxEntries: 100)
        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: ["proj-one"] // proj-evil NOT in list
        )

        do {
            _ = try await validator.validate("tok-evil")
            #expect(false, "should have thrown 403")
        } catch let err as OpenStackError {
            #expect(err.status == 403)
        }
    }

    @Test func cacheKeyedByTokenID() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let counter = ManagedAtomic(0)
        let bodyA = makeTokenResponse(projectID: "proj-a", roles: ["member"], tokenID: "tok-a")
        let bodyB = makeTokenResponse(projectID: "proj-b", roles: ["admin"], tokenID: "tok-b")
        server.addHandler("/v3/auth/tokens") { req in
            counter.wrappingIncrement(by: 1, ordering: .relaxed)
            let token = req.headers["x-auth-token"] ?? ""
            let body = token == "tok-a" ? bodyA : bodyB
            return (200, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let cache = Cache(maxEntries: 100)
        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: ["proj-a", "proj-b"]
        )

        // Validate token A
        let va = try await validator.validate("tok-a")
        #expect(va.token.project.id == "proj-a")

        // Validate token B — must NOT return A's cached entry
        let vb = try await validator.validate("tok-b")
        #expect(vb.token.project.id == "proj-b", "Token B must return B's project, not A's")
        #expect(vb.scopes.contains(.write), "Token B has admin role")

        // Validate token A again — should be cached (no new Keystone hit)
        let hitsBefore = counter.load(ordering: .relaxed)
        let va2 = try await validator.validate("tok-a")
        #expect(va2.token.project.id == "proj-a")
        #expect(counter.load(ordering: .relaxed) == hitsBefore, "Token A should be served from cache")
    }

    private func makeTransport(baseURL: URL, token: String = "tok-123") -> Transport {
        let cloud = CloudEntry(name: "test", authURL: baseURL)
        return Transport(
            cloud: cloud,
            tokenSource: { token },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
    }
}

@Suite("LoginMinter")
struct LoginMinterTests {
    // The Transport already sends `Content-Type: application/json` on every
    // request. If a caller ALSO passes it as an extraHeader, the request
    // carries TWO Content-Type headers, which Keystone 3.14 rejects with 400
    // ("Expecting to find application/json in Content-Type header"). The mint
    // must therefore send exactly ONE.
    @Test func mintSendsExactlyOneContentType() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let contentTypeCount = ManagedAtomic(0)
        let bodyHasAppCred = ManagedAtomic(0)
        server.addHandler("/v3/auth/tokens") { req in
            contentTypeCount.store(
                req.rawHeaders
                    .split(separator: "\n")
                    .filter { $0.lowercased().hasPrefix("content-type:") }.count,
                ordering: .relaxed
            )
            if String(decoding: req.body, as: UTF8.self).contains("application_credential") {
                bodyHasAppCred.store(1, ordering: .relaxed)
            }
            return (201, #"{"token":{"id":"tok-mint","expires_at":"2026-10-02T13:03:34.000000Z","project":{"id":"p","name":"p"},"user":{"id":"u","name":"u"},"roles":["admin"],"catalog":[]}}"#, [("Content-Type", "application/json")])
        }

        let transport = Transport(
            cloud: CloudEntry(name: "test", authURL: server.baseURL),
            tokenSource: { "" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }
        let minter = LoginMinter(transport: transport, logger: Logger(label: "test-minter"))
        _ = try await minter.mint(method: .applicationCredential(id: "ac-1", secret: Array("s".utf8).map { Int8($0) }))

        let count = contentTypeCount.load(ordering: .relaxed)
        #expect(count == 1, "mint must send exactly one Content-Type header, got \(count)")
        #expect(bodyHasAppCred.load(ordering: .relaxed) == 1, "mint body must be the app-cred form")
    }

    @Test func mintThrowsOn400() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }
        server.addHandler("/v3/auth/tokens") { _ in
            (400, #"{"error":{"code":400,"message":"bad","title":"Bad Request"}}"#, [("Content-Type", "application/json")])
        }
        let transport = Transport(
            cloud: CloudEntry(name: "test", authURL: server.baseURL),
            tokenSource: { "" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }
        let minter = LoginMinter(transport: transport, logger: Logger(label: "test-minter"))
        do {
            _ = try await minter.mint(method: .applicationCredential(id: "ac-1", secret: Array("s".utf8).map { Int8($0) }))
            #expect(false, "should have thrown 400")
        } catch let err as OpenStackError {
            #expect(err.status == 400)
        }
    }

    /// Regression: a password containing `"`, `\`, or a control character must
    /// be JSON-escaped in the mint body (previously hand-built string
    /// interpolation produced invalid JSON, which Keystone rejected with 400
    /// "Expecting to find password in identity").
    @Test func mintEscapesPasswordWithSpecialCharacters() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let capturedBody = Box<Data>(Data())
        server.addHandler("/v3/auth/tokens") { req in
            capturedBody.value = req.body
            return (201, #"{"token":{"id":"tok-mint","expires_at":"2026-10-02T13:03:34.000000Z","project":{"id":"p","name":"p"},"user":{"id":"u","name":"u"},"roles":["admin"],"catalog":[]}}"#, [("Content-Type", "application/json"), ("X-Subject-Token", "tok-mint")])
        }

        let transport = Transport(
            cloud: CloudEntry(name: "test", authURL: server.baseURL),
            tokenSource: { "" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }
        let minter = LoginMinter(transport: transport, logger: Logger(label: "test-minter"))

        // A password with a double-quote, a backslash, and a newline.
        let nastyPassword = "pa\"ss\\word\nwith-newline"
        _ = try await minter.mint(method: .password(
            userID: "admin", domain: "default",
            password: nastyPassword, projectName: "admin"
        ))

        let body = capturedBody.value
        // 1. The body must be VALID JSON (this is what was broken).
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let auth = obj["auth"] as! [String: Any]
        let identity = auth["identity"] as! [String: Any]
        // Keystone v3 password auth nests the user under identity.password
        // (the method name), NOT directly under identity. keystoneauth1 (the
        // openstack CLI) sends exactly this shape.
        #expect(identity["methods"] as? [String] == ["password"],
                "methods must be [\"password\"]: \(String(describing: identity["methods"]))")
        let passwordObj = identity["password"] as! [String: Any]
        let user = passwordObj["user"] as! [String: Any]
        // 2. The password must round-trip EXACTLY (escaped on the wire,
        //    decoded back to the original by a JSON parser).
        #expect(user["password"] as? String == nastyPassword,
                "password did not round-trip through JSON escaping: \(String(describing: user["password"]))")
        #expect(user["name"] as? String == "admin")
        #expect(user["domain"] as? [String: Any] != nil)
        // 3. The scope must be project-scoped when a project name is given,
        //    AND the project must carry a domain (Keystone requires it).
        let scope = auth["scope"] as? [String: Any]
        let project = scope?["project"] as? [String: Any]
        #expect(project?["name"] as? String == "admin",
                "project scope missing/wrong name: \(String(describing: project))")
        #expect(project?["domain"] as? [String: Any] != nil,
                "project scope must carry a domain: \(String(describing: project))")
    }

    /// Regression: an app-credential secret containing a double-quote must be
    /// JSON-escaped in the mint body.
    @Test func mintEscapesAppCredSecretWithSpecialCharacters() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let capturedBody = Box<Data>(Data())
        server.addHandler("/v3/auth/tokens") { req in
            capturedBody.value = req.body
            return (201, #"{"token":{"id":"tok-mint","expires_at":"2026-10-02T13:03:34.000000Z","project":{"id":"p","name":"p"},"user":{"id":"u","name":"u"},"roles":["admin"],"catalog":[]}}"#, [("Content-Type", "application/json"), ("X-Subject-Token", "tok-mint")])
        }

        let transport = Transport(
            cloud: CloudEntry(name: "test", authURL: server.baseURL),
            tokenSource: { "" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }
        let minter = LoginMinter(transport: transport, logger: Logger(label: "test-minter"))

        let nastySecret = "sec\"ret\\with-special"
        _ = try await minter.mint(method: .applicationCredential(
            id: "ac-1",
            secret: Array(nastySecret.utf8).map { Int8($0) }
        ))

        let body = capturedBody.value
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let auth = obj["auth"] as! [String: Any]
        let identity = auth["identity"] as! [String: Any]
        let ac = identity["application_credential"] as! [String: Any]
        #expect(ac["secret"] as? String == nastySecret,
                "app-cred secret did not round-trip through JSON escaping: \(String(describing: ac["secret"]))")
        #expect(ac["id"] as? String == "ac-1")
    }
}

/// A trivial Sendable box so a test can capture a value from an async handler.
private final class Box<T>: @unchecked Sendable where T: Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

@Suite("ScopeDerivation")
struct ScopeDerivationTests {
    @Test func memberGetsRead() {
        let scopes = deriveScopes(roles: ["member", "_member_"])
        #expect(scopes == [.read])
    }

    @Test func adminGetsReadWrite() {
        let scopes = deriveScopes(roles: ["admin"])
        #expect(scopes == [.read, .write])
    }

    @Test func customWriteRole() {
        let policy = PolicyRoles(writeRoles: ["operator", "admin"])
        let scopes = deriveScopes(roles: ["operator"], policy: policy)
        #expect(scopes == [.read, .write])
    }

    @Test func noWriteRole() {
        let scopes = deriveScopes(roles: ["reader"])
        #expect(scopes == [.read])
    }
}


