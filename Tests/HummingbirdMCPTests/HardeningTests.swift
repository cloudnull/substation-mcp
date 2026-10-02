import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdMCP
import MCP
import Logging
import NIOConcurrencyHelpers
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack

// MARK: - Final hardening sweep (spec §12)
//
// These tests pin the security hardening checklist for the phase-1 server:
//   - default bind 127.0.0.1 (config default)
//   - body limit 413
//   - per-IP auth-failure limit 429
//   - per-token tool-call rate limit (121st call in a minute -> tool error)
//   - `user_data` never appears in any `os_get server` response
//   - `metrics_token` gating (401 without, 200 with)
//   - `session.max_lifetime` eviction (404 on the next request)
//   - token-per-request: an expired token on a live session -> 401
//   - tenant isolation (two projects, no cross-session resource leak)
//   - read-only token's mutating call -> 403 insufficient_scope
//   - login secret never stored (TokenStore round-trip)
//   - PRM document at both canonical and endpoint-scoped URLs
//
// Origin/CORS: the MCP 2025-11-25 spec does not mandate Origin checks on an
// HTTP+Bearer server; the bearer token is the boundary. No Origin assertion is
// made here (pinned as out of scope).

@Suite("Hardening sweep (spec §12)", .timeLimit(.minutes(6)))
struct HardeningTests {

    // MARK: - Config defaults

    @Test("default bind is 127.0.0.1 (localhost only)")
    func defaultBindLocalhost() {
        let cfg = OpenStackMCPConfig()
        #expect(cfg.serverHost == "127.0.0.1", "default host must be 127.0.0.1, got \(cfg.serverHost)")
    }

    // MARK: - Body limit

    @Test("oversized request body -> 413 contentTooLarge")
    func bodyLimit413() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        var cfg = defaultConfig
        cfg.serverMaxBodyBytes = 100
        let app = makeServeApp(handle: handle, config: cfg, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let bigBody = String(repeating: "x", count: 200)
            let response = try await sendRequest(
                client, uri: "/v1", method: .post,
                headers: ["Authorization": "Bearer anything",
                          "Content-Type": "application/json",
                          "Accept": "application/json, text/event-stream"],
                body: Data(bigBody.utf8)
            )
            #expect(response.status == .contentTooLarge, "expected 413, got \(response.status)")
        }
    }

    // MARK: - Per-IP auth-failure rate limit

    @Test("per-IP auth-failure rate limit: 11th bad token -> 429")
    func perIPAuthRateLimit429() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        var cfg = defaultConfig
        cfg.authFailedAuthPerMinute = 10
        let app = makeServeApp(handle: handle, config: cfg, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            var statuses: [HTTPResponse.Status] = []
            for _ in 1...11 {
                let response = try await sendRequest(
                    client, uri: "/v1", method: .post,
                    headers: ["Authorization": "Bearer not-a-real-token",
                              "Content-Type": "application/json",
                              "Accept": "application/json, text/event-stream"],
                    body: Data("{}".utf8)
                )
                statuses.append(response.status)
            }
            let firstTen = statuses.prefix(10).filter { $0 == .unauthorized }
            #expect(firstTen.count == 10, "first 10 bad tokens should be 401: \(statuses)")
            #expect(statuses[10] == .tooManyRequests, "11th should be 429, got \(statuses[10])")
        }
    }

    // MARK: - Per-token tool-call rate limit

    @Test("per-token tool-call rate limit: 121st call in a minute -> tool error")
    func perTokenToolRateLimit() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        var cfg = defaultConfig
        cfg.policyMaxCallsPerMinute = 10
        let app = makeServeApp(handle: handle, config: cfg, tokenStore: store)
        defer { app.shutdown() }
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-ro", secret: "secret-ro", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        try await app.app.test(.router) { client in
            let sc = SessionClient(client: client, tokenID: ft.id)
            let initResp = try await sc.initialize()
            #expect(initResp.status == .ok, "initialize failed: \(initResp.status)")
            // 10 allowed calls (os_whoami is read-only, no external dependency).
            for _ in 1...10 {
                let r = try await sc.callToolJSON("os_whoami", argumentsJSON: "{}")
                #expect(r.status == .ok, "call \(r.status)")
            }
            // 11th call (121st analog) must be a tool-level rate-limit error.
            let throttled = try await sc.callToolJSON("os_whoami", argumentsJSON: "{}")
            #expect(throttled.status == .ok, "throttled call still 200 (isError tool error): \(throttled.status)")
            let body = bodyString(throttled)
            #expect(body.contains("Rate limit exceeded"), "expected rate-limit message: \(body)")
        }
    }

    // MARK: - user_data never echoed

    @Test("user_data is never present in an os_get server response")
    func userDataNeverEchoed() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeAppReachable(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-ro", secret: "secret-ro", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        try await app.app.test(.router) { client in
            let sc = SessionClient(client: client, tokenID: ft.id)
            let initResp = try await sc.initialize()
            #expect(initResp.status == .ok, "initialize failed: \(initResp.status)")
            // srv-0001 is seeded with user_data on the fake side.
            let r = try await sc.callToolJSON("os_get", argumentsJSON: #"{"resource":"server","id_or_name":"srv-0001","region":"RegionOne"}"#)
            #expect(r.status == .ok, "os_get failed: \(r.status)")
            let body = bodyString(r)
            #expect(!body.contains("user_data"), "user_data must not be echoed: \(body)")
            #expect(!body.contains("c2VjcmV0LXVzZXItZGF0YQ=="), "user_data value must not leak: \(body)")
            #expect(body.contains("srv-0001"), "expected server id: \(body)")
        }
    }

    // MARK: - metrics_token gating

    @Test("metrics_token gating: 401 without / wrong, 200 with the right bearer")
    func metricsTokenGating() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        var cfg = defaultConfig
        cfg.serverMetricsToken = "m-secret"
        let app = makeServeApp(handle: handle, config: cfg, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let noAuth = try await sendRequest(client, uri: "/metrics", method: .get)
            #expect(noAuth.status == .unauthorized, "no token should 401, got \(noAuth.status)")
            let wrong = try await sendRequest(client, uri: "/metrics", method: .get,
                                              headers: ["Authorization": "Bearer wrong"])
            #expect(wrong.status == .unauthorized, "wrong token should 401, got \(wrong.status)")
            let ok = try await sendRequest(client, uri: "/metrics", method: .get,
                                           headers: ["Authorization": "Bearer m-secret"])
            #expect(ok.status == .ok, "right token should 200, got \(ok.status)")
        }
    }

    // MARK: - session.max_lifetime eviction
    //
    // A session that survives its idle TTL but not its max lifetime is still
    // evicted (spec §12). The registry's `evictExpired` is the single code path
    // the background cleanup loop calls, so we pin it deterministically here
    // with controlled timestamps rather than sleeping through the 60s loop.

    @Test("registry: a session past max_lifetime is evicted even while recently idle")
    func maxLifetimeEviction() async {
        let reg = SessionRegistry(
            idleTTL: 3600,
            maxLifetime: 1,
            cleanupInterval: .seconds(60),
            terminated: { _ in },
            logger: Logger(label: "hardening-registry")
        )
        // Created 2s ago (past its 1s max lifetime), last accessed 1s ago
        // (well within the 3600s idle TTL): only max lifetime trips.
        let server = Server(name: "hardening-test", version: "1")
        let transport = StatefulHTTPServerTransport()
        let now = Date()
        let session = MCPSession(
            server: server,
            transport: transport,
            sessionID: "s-maxlife",
            lastAccessedAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(-2)
        )
        await reg.register(session)
        #expect(await reg.count == 1)
        let evicted = await reg.evictExpired(now: now)
        #expect(evicted.contains("s-maxlife"), "past-max-lifetime session must be evicted: \(evicted)")
        #expect(await reg.count == 0)

        // Contrast: a session within both idle TTL and max lifetime is NOT
        // evicted.
        let server2 = Server(name: "hardening-test2", version: "1")
        let transport2 = StatefulHTTPServerTransport()
        let fresh = MCPSession(
            server: server2,
            transport: transport2,
            sessionID: "s-fresh",
            lastAccessedAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(-1)
        )
        await reg.register(fresh)
        let evicted2 = await reg.evictExpired(now: now)
        #expect(!evicted2.contains("s-fresh"), "fresh session must not be evicted: \(evicted2)")
        #expect(await reg.count == 1)
    }

    // MARK: - Token-per-request: expired token on a live session -> 401

    @Test("expired token on a live session -> 401 (identity is per-token, not per-session)")
    func expiredTokenLiveSession401() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeAppReachable(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-ro", secret: "secret-ro", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        let tokenID = ft.id
        let state = handle.state // Sendable actor, safe to capture.
        try await app.app.test(.router) { client in
            let sc = SessionClient(client: client, tokenID: tokenID)
            let initResp = try await sc.initialize()
            #expect(initResp.status == .ok, "initialize failed: \(initResp.status)")
            #expect(header(initResp, "MCP-Session-Id") != nil, "no session id")
            // A valid in-session call before expiry.
            let before = try await sc.callToolJSON("os_whoami", argumentsJSON: "{}")
            #expect(before.status == .ok, "whoami before expiry should 200: \(before.status)")
            // Force the token to expire on the fake AND drop it from the
            // validator's token cache (the cache is token-id-keyed; without
            // invalidation the stale cached token would still validate).
            // This models real token revocation: the server must re-validate
            // against Keystone, see the token gone, and 401 the live session.
            await state.expireToken(tokenID)
            await app.wiring.cache.invalidate(resource: "__token__", tokenID: tokenID, region: "_auth_")
            // The SAME live session + now-expired token -> 401 invalid_token.
            let after = try await sc.callToolJSON("os_whoami", argumentsJSON: "{}")
            #expect(after.status == .unauthorized, "expired token on live session should 401, got \(after.status)")
            let www = header(after, "WWW-Authenticate") ?? ""
            #expect(www.contains("invalid_token"), "expected invalid_token challenge: \(www)")
        }
    }

    // MARK: - Tenant isolation

    @Test("tenant isolation: proj-one and proj-two sessions never see each other's resources")
    func tenantIsolation() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeAppReachable(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        guard let one = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ) else { throw OpenStackError(service: "test", status: 500, message: "mint one failed") }
        guard let two = await handle.state.mintToken(
            credID: "fake-cred-two", secret: "secret-two", domain: nil, password: nil, userID: nil
        ) else { throw OpenStackError(service: "test", status: 500, message: "mint two failed") }

        try await app.app.test(.router) { client in
            // proj-one session lists servers: must NOT see proj-two's server.
            let oneSc = SessionClient(client: client, tokenID: one.id)
            _ = try await oneSc.initialize()
            let oneList = try await oneSc.callToolJSON("os_list", argumentsJSON: #"{"resource":"server"}"#)
            #expect(oneList.status == .ok)
            let oneBody = bodyString(oneList)
            #expect(!oneBody.contains("server-two-1"), "proj-one must not see proj-two server: \(oneBody)")

            // proj-two session lists servers: must see its own server.
            let twoSc = SessionClient(client: client, tokenID: two.id)
            _ = try await twoSc.initialize()
            let twoList = try await twoSc.callToolJSON("os_list", argumentsJSON: #"{"resource":"server"}"#)
            #expect(twoList.status == .ok)
            let twoBody = bodyString(twoList)
            #expect(twoBody.contains("server-two-1"), "proj-two must see its own server: \(twoBody)")
        }
        // The token-metadata cache must not grow unbounded across the two
        // distinct tokens (login-minted bindings only, which are zeroized on
        // session end — none were minted here, so the store stays empty).
        let storeCount = await store.count
        #expect(storeCount <= 2, "cache should not grow unbounded: \(storeCount)")
    }

    // MARK: - Read-only mutating call -> 403 insufficient_scope

    @Test("read-only token's mutating call -> 403 insufficient_scope")
    func readOnlyMutating403() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-ro", secret: "secret-ro", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        try await app.app.test(.router) { client in
            let sc = SessionClient(client: client, tokenID: ft.id)
            _ = try await sc.initialize()
            let callResp = try await sc.callToolJSON("os_create", argumentsJSON: #"{"resource":"server","name":"x","region":"RegionOne"}"#)
            #expect(callResp.status == .forbidden, "expected 403, got \(callResp.status)")
            let www = header(callResp, "WWW-Authenticate") ?? ""
            #expect(www.contains("insufficient_scope"), "expected insufficient_scope: \(www)")
            #expect(www.contains("openstack:write"), "expected openstack:write in challenge: \(www)")
        }
    }

    // MARK: - Login secret never stored

    @Test("login-minted token: the credential secret is never stored")
    func loginSecretNeverStored() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeAppReachable(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        let elicitationId = "elicit-hardening"
        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let body = """
            {"elicitationId":"\(elicitationId)","method":"app-cred","appCredId":"fake-cred-admin","secret":"secret-admin"}
            """
            let response = try await sendRequest(
                client, uri: "/v1/login", method: .post,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
            #expect(response.status == .ok, "login POST failed: \(response.status)")
            let respBody = bodyString(response)
            #expect(!respBody.contains("secret-admin"), "secret leaked in completion page: \(respBody)")
        }
        let stored = await store.token(for: elicitationId)
        #expect(stored != nil, "token not stored for elicitation id")
        if let stored {
            let storedJSON = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
            #expect(!storedJSON.contains("secret-admin"), "secret leaked into stored token: \(storedJSON)")
        }
    }

    // MARK: - Login page is URL-mode (spec §6.1b): a server-rendered HTML form,
    // not a form-mode MCP elicitation. Credentials enter the server's page
    // out-of-band; the MCP client never sees them.

    @Test("GET /v1/login renders the URL-mode HTML form (not a form-mode elicitation)")
    func loginPageIsURLMode() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let response = try await sendRequest(client, uri: "/v1/login", method: .get)
            #expect(response.status == .ok, "login page should 200, got \(response.status)")
            let html = bodyString(response)
            #expect(html.contains("<form"), "URL-mode page renders an HTML form the user fills in the browser: \(html)")
            #expect(html.lowercased().contains("secret"), "form includes the credential field: \(html)")
            // The page is plain HTML served to a browser — it must not be an
            // MCP JSON-RPC elicitation response (form-mode credential collection
            // is forbidden, spec §6.1b).
            #expect(!html.hasPrefix("{"), "login page must be HTML, not a JSON-RPC elicitation envelope: \(html)")
        }
    }

    // MARK: - PRM at both URLs

    @Test("PRM document served at both canonical and endpoint-scoped URLs")
    func prmBothURLs() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            // Canonical (no resource parameter) URL.
            let r1 = try await sendRequest(client, uri: "/.well-known/oauth-protected-resource", method: .get)
            #expect(r1.status == .ok, "canonical PRM should 200, got \(r1.status)")
            let b1 = bodyString(r1)
            #expect(b1.contains("resource") && b1.contains("authorization_servers") && b1.contains("scopes_supported"),
                    "canonical PRM missing RFC 9728 keys: \(b1)")
            // Endpoint-scoped URL (resource = /v1).
            let r2 = try await sendRequest(client, uri: "/.well-known/oauth-protected-resource/v1", method: .get)
            #expect(r2.status == .ok, "scoped PRM should 200, got \(r2.status)")
            let b2 = bodyString(r2)
            #expect(b2.contains("resource") && b2.contains("authorization_servers") && b2.contains("scopes_supported"),
                    "scoped PRM missing RFC 9728 keys: \(b2)")
        }
    }

    // MARK: - PRM advertises per-service scopes only when enabled (P2)

    @Test("PRM advertises per-service scopes when auth.scopes = per_service")
    func prmPerServiceAdvertised() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        var cfg = defaultConfig
        cfg.authScopes = "per_service"
        let app = makeServeApp(handle: handle, config: cfg, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let r = try await sendRequest(client, uri: "/.well-known/oauth-protected-resource", method: .get)
            #expect(r.status == .ok, "PRM should 200, got \(r.status)")
            let body = bodyString(r)
            #expect(body.contains("compute:write"), "per-service mode should advertise compute:write: \(body)")
            #expect(body.contains("network:write"), "per-service mode should advertise network:write: \(body)")
            #expect(body.contains("openstack:write"), "base write scope still advertised: \(body)")
        }
    }

    @Test("PRM advertises only coarse scopes by default (auth.scopes = coarse)")
    func prmCoarseDefault() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let r = try await sendRequest(client, uri: "/.well-known/oauth-protected-resource", method: .get)
            #expect(r.status == .ok, "PRM should 200, got \(r.status)")
            let body = bodyString(r)
            #expect(body.contains("openstack:read") && body.contains("openstack:write"), "base scopes advertised: \(body)")
            #expect(!body.contains("compute:write"), "coarse mode must NOT advertise per-service scopes: \(body)")
        }
    }

    // MARK: - Console URL returned only to the requesting session (spec §12)

    /// Extract the `"url":"..."` value from the `console` object in an
    /// SSE-framed tools/call response. Returns the URL or nil.
    private func consoleURL(from body: String) -> String? {
        // Find the JSON payload (the last data: line).
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let dataLine = lines.last(where: { $0.hasPrefix("data:") }) else { return nil }
        let json = String(dataLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        // The tool result content text contains a JSON object with a "console".
        let marker = "\"console\""
        guard let consoleStart = json.range(of: marker)?.upperBound else { return nil }
        let rest = json[consoleStart...]
        let urlMarker = "\"url\":\""
        guard let urlStart = rest.range(of: urlMarker)?.upperBound else { return nil }
        let after = rest[urlStart...]
        guard let end = after.range(of: "\"") else { return nil }
        return String(after[..<end.lowerBound])
    }

    @Test("console_url is returned only to the requesting session")
    func consoleURLSessionScoped() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeAppReachable(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        guard let one = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ), let two = await handle.state.mintToken(
            credID: "fake-cred-two", secret: "secret-two", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        let box = URLBox()
        try await app.app.test(.router) { client in
            // proj-one session requests a console for its server.
            let oneSc = SessionClient(client: client, tokenID: one.id)
            _ = try await oneSc.initialize()
            let r1 = try await oneSc.callToolJSON(
                "os_action",
                argumentsJSON: #"{"resource":"server","id_or_name":"srv-0001","action":"console_url","type":"novnc","region":"RegionOne"}"#
            )
            #expect(r1.status == .ok, "console_url (one) failed: \(r1.status)")
            box.one = consoleURL(from: bodyString(r1))
            #expect(box.one != nil, "proj-one console url not returned")

            // proj-two session requests a console for its own server.
            let twoSc = SessionClient(client: client, tokenID: two.id)
            _ = try await twoSc.initialize()
            let r2 = try await twoSc.callToolJSON(
                "os_action",
                argumentsJSON: #"{"resource":"server","id_or_name":"srv-0004","action":"console_url","type":"novnc","region":"RegionOne"}"#
            )
            #expect(r2.status == .ok, "console_url (two) failed: \(r2.status)")
            box.two = consoleURL(from: bodyString(r2))
            #expect(box.two != nil, "proj-two console url not returned")
        }
        let urlOne = box.one
        let urlTwo = box.two
        // Each session gets its own console url; they differ (no cross-session
        // leakage of the url value).
        #expect(urlOne != nil && urlTwo != nil, "both console urls expected")
        #expect(urlOne != urlTwo, "sessions must not share a console url: \(urlOne ?? "?") vs \(urlTwo ?? "?")")
        // Each url is scoped to its requesting session's server.
        #expect(urlOne?.contains("srv-0001") == true, "one url should reference srv-0001: \(urlOne ?? "?")")
        #expect(urlTwo?.contains("srv-0004") == true, "two url should reference srv-0004: \(urlTwo ?? "?")")
    }
}

/// Thread-safe box for capturing two console urls across a @Sendable closure.
private final class URLBox: @unchecked Sendable {
    private let oneBox = NIOLockedValueBox(String?.none)
    private let twoBox = NIOLockedValueBox(String?.none)
    var one: String? {
        get { oneBox.withLockedValue { $0 } }
        set { oneBox.withLockedValue { $0 = newValue } }
    }
    var two: String? {
        get { twoBox.withLockedValue { $0 } }
        set { twoBox.withLockedValue { $0 = newValue } }
    }
}


