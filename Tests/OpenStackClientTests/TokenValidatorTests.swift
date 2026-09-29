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


