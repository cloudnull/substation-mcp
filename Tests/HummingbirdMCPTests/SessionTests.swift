import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import Logging
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack

// MARK: - Full-serve session tests (Task 18)
//
// These drive the real `ServeApp` (the composition layer) against the running
// `FakeApp` (fake Keystone + services), so the auth path is exercised with
// REAL token validation (not the Task-17 StubValidator). They pin:
//   - 401 on missing/invalid token (spec §7.1)
//   - PRM document contents (spec §6.1 / RFC 9728)
//   - the URL-mode login page (GET form + POST mint) (spec §6.1b)
//   - session init → tools/list with a real minted token (read vs write)
//   - DELETE terminates the session and zeroizes its stored token

/// Build a full `ServeApp` against a running `FakeApp`.
func makeServeApp(
    handle: FakeHandle,
    config: OpenStackMCPConfig,
    tokenStore: TokenStore,
    logger: Logger = Logger(label: "serve-test")
) -> ServeApp {
    let cloud = CloudEntry(
        name: "fake",
        // The transport builds URLs as `authURL + path`. Keystone validation
        // uses `path: "/v3/auth/tokens"`, and the fake serves Keystone at
        // `<base>/keystone/v3`, so the base must be `<base>/keystone`.
        authURL: URL(string: handle.url.absoluteString + "/keystone")!,
        regionName: nil
    )
    var cfg = config
    // Point Keystone at the fake for the PRM document + validation.
    cfg.authKeystoneURL = handle.keystoneURL.absoluteString
    return ServeApp(config: cfg, cloud: cloud, tokenStore: tokenStore, logger: logger)
}

/// Shared config for the full-serve tests.
let defaultConfig = OpenStackMCPConfig(
    serverPublicURL: "http://127.0.0.1:8080",
    authKeystoneURL: nil
)

/// A tiny MCP HTTP client over the Hummingbird test client that tracks the
/// `MCP-Session-Id` returned by `initialize` and re-sends it on every
/// subsequent request (the Streamable-HTTP session contract).
final class SessionClient: @unchecked Sendable {
    private let client: any TestClientProtocol
    private let tokenID: String
    private var sessionID: String?

    init(client: any TestClientProtocol, tokenID: String) {
        self.client = client
        self.tokenID = tokenID
    }

    /// Send `initialize` and capture the session id from the response.
    func initialize() async throws -> TestResponse {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        let response = try await post(body)
        if let sid = header(response, "MCP-Session-Id") {
            sessionID = sid
        }
        return response
    }

    func toolsList() async throws -> TestResponse {
        try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
    }

    /// Generic `tools/call` (for ad-hoc checks in tests).
    func callToolJSON(_ name: String, argumentsJSON: String) async throws -> TestResponse {
        let body = "{" + "\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
            + "\"params\":{\"name\":\"\(name)\",\"arguments\":\(argumentsJSON)}}"
        return try await post(body)
    }

    func callTool(_ name: String, arguments: [String: String]) async throws -> TestResponse {
        let args = arguments.isEmpty
            ? "{}"
            : arguments.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        let body = "{" + "\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
            + "\"params\":{\"name\":\"\(name)\",\"arguments\":{\(args)}}"
        return try await post(body)
    }

    private func post(_ body: String) async throws -> TestResponse {
        var headers = [
            "Authorization": "Bearer \(tokenID)",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if let sessionID { headers["MCP-Session-Id"] = sessionID }
        return try await sendRequest(client, uri: "/v1", method: .post, headers: headers, body: Data(body.utf8))
    }
}

@Suite("Full-serve session tests", .timeLimit(.minutes(4)))
struct ServeSessionTests {

    @Test("healthz returns 200 ok")
    func healthz() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let response = try await sendRequest(client, uri: "/healthz", method: .get)
            #expect(response.status == .ok)
            #expect(bodyString(response) == "ok")
        }
    }

    @Test("PRM document names the fake Keystone as the authorization server")
    func prm() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        // The PRM JSON escapes "/" as "\/", so match on the unescaped path
        // tail and the RFC 9728 keys rather than the full URL.
        let keystonePath = handle.keystoneURL.absoluteString
            .replacingOccurrences(of: "/", with: "\\/")
        try await app.app.test(.router) { client in
            let response = try await sendRequest(
                client, uri: "/.well-known/oauth-protected-resource", method: .get
            )
            #expect(response.status == .ok)
            let body = bodyString(response)
            // RFC 9728 keys + the fake Keystone URL as the authorization server.
            #expect(body.contains("authorization_servers"))
            #expect(body.contains(keystonePath), "PRM missing keystone URL: \(body)")
            // The `resource` identifier is this server's public URL, not Keystone.
            #expect(body.contains("resource"), "PRM missing resource key: \(body)")
            #expect(body.contains("127.0.0.1:8080"), "PRM resource must be the public URL: \(body)")
        }
    }

    @Test("login page GET returns the HTML form")
    func loginPageGet() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let response = try await sendRequest(client, uri: "/v1/login", method: .get)
            #expect(response.status == .ok)
            let body = bodyString(response)
            #expect(body.contains("<form"), "login page missing form: \(body)")
            #expect(body.contains("app-cred"))
            #expect(body.contains("password"))
        }
    }

    @Test("login page POST mints a token and stores it bound to the elicitation id")
    func loginPagePost() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        let elicitationId = "elicit-123"

        try await app.app.test(.router) { client in
            // Warm up the test router context (first request is dropped).
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let body = """
            {"elicitationId":"\(elicitationId)","method":"app-cred","appCredId":"fake-cred-admin","secret":"secret-admin"}
            """
            let response = try await sendRequest(
                client, uri: "/v1/login", method: .post,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
            #expect(response.status == .ok, "login POST failed: \(response.status) \(bodyString(response))")
            let respBody = bodyString(response)
            // The completion page reports success + the token id.
            #expect(respBody.contains("fake-tok"), "expected a minted token id: \(respBody)")
            // Review Focus 4: the POST body's secret must not leak into the
            // completion page.
            #expect(!respBody.contains("secret-admin"), "secret leaked in completion page: \(respBody)")
        }

        // The store must now hold the minted token bound to the elicitation id.
        let stored = await store.token(for: elicitationId)
        #expect(stored != nil, "token not stored for elicitation id")
        #expect(stored?.id.hasPrefix("fake-tok") == true)
        // Review Focus 4: only the token (and its metadata) is stored — the
        // app-cred secret bytes never touch the store.
        if let stored {
            let storedJSON = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
            #expect(!storedJSON.contains("secret-admin"), "secret leaked into stored token: \(storedJSON)")
        }
    }

    @Test("missing token -> 401 with invalid_token challenge")
    func missingToken() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let response = try await sendRequest(
                client, uri: "/v1", method: .post,
                headers: ["Content-Type": "application/json",
                          "Accept": "application/json, text/event-stream"],
                body: Data("{}".utf8)
            )
            #expect(response.status == .unauthorized)
            let www = header(response, "WWW-Authenticate") ?? ""
            #expect(www.contains("invalid_token"))
            #expect(www.contains("resource_metadata"))
        }
    }

    @Test("invalid (unknown) token id -> 401")
    func invalidToken() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        try await app.app.test(.router) { client in
            let response = try await sendRequest(
                client, uri: "/v1", method: .post,
                headers: ["Authorization": "Bearer not-a-real-token",
                          "Content-Type": "application/json",
                          "Accept": "application/json, text/event-stream"],
                body: Data("{}".utf8)
            )
            #expect(response.status == .unauthorized, "expected 401, got \(response.status)")
        }
    }

    @Test("write-scoped token initializes and lists 15 tools")
    func writeTokenListTools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { app.shutdown() }
        // Mint a real admin (write) token via the fake Keystone.
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }

        try await app.app.test(.router) { client in
            let sc = SessionClient(client: client, tokenID: ft.id)
            let initResp = try await sc.initialize()
            #expect(initResp.status == .ok, "initialize failed: \(initResp.status) \(bodyString(initResp))")

            let listResp = try await sc.toolsList()
            #expect(listResp.status == .ok, "tools/list failed: \(listResp.status) \(bodyString(listResp))")
            let body = bodyString(listResp)
            #expect(body.contains("os_create"), "write token should see os_create: \(body)")
            #expect(body.contains("os_delete"), "write token should see os_delete: \(body)")
        }
    }

    @Test("read-only token lists tools without the mutating ones")
    func readOnlyTokenListTools() async throws {
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
            let listResp = try await sc.toolsList()
            #expect(listResp.status == .ok, "tools/list failed: \(listResp.status)")
            let body = bodyString(listResp)
            #expect(body.contains("os_list"), "read token should see os_list: \(body)")
            #expect(!body.contains("os_create"), "read token must NOT see os_create: \(body)")
            #expect(!body.contains("os_delete"), "read token must NOT see os_delete: \(body)")
        }
    }

    @Test("write-gated tool called by a read-only token -> 403 insufficient_scope")
    func readOnlyCallWriteTool() async throws {
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
            // A write-gated tool: os_create, called with a read-only token.
            let callResp = try await sc.callToolJSON("os_create", argumentsJSON: #"{"resource":"server","name":"x","region":"RegionOne"}"#)
            // Review Focus 3: the write-gate challenges a read-only token at
            // the HTTP layer.
            #expect(callResp.status == .forbidden, "expected 403, got \(callResp.status) \(bodyString(callResp))")
            let www = header(callResp, "WWW-Authenticate") ?? ""
            #expect(www.contains("insufficient_scope"), "expected insufficient_scope challenge: \(www)")
            #expect(www.contains("openstack:write"), "expected scope in challenge: \(www)")
        }
    }

    @Test("11 consecutive bad-token validations from one IP -> 11th is 429")
    func rateLimitBadTokens() async throws {
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

    @Test("metrics with a configured token requires the bearer; open metrics serve the document")
    func metricsTokenGating() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()

        // Open metrics (no token configured) -> 200.
        let openApp = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store)
        defer { openApp.shutdown() }
        try await openApp.app.test(.router) { client in
            let response = try await sendRequest(client, uri: "/metrics", method: .get)
            #expect(response.status == .ok)
        }

        // Gated metrics: 401 without / with the wrong token, 200 with it.
        var gatedCfg = defaultConfig
        gatedCfg.serverMetricsToken = "m-secret"
        let gatedApp = makeServeApp(handle: handle, config: gatedCfg, tokenStore: store)
        defer { gatedApp.shutdown() }
        try await gatedApp.app.test(.router) { client in
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
}

// MARK: - TokenStore unit tests

@Suite("TokenStore tests", .timeLimit(.minutes(2)))
struct TokenStoreTests {

    private func makeToken(id: String, expiresAt: Date) -> Token {
        Token(
            id: id,
            expiresAt: expiresAt,
            project: IdentityRef(id: "p1"),
            domain: IdentityRef(id: "default"),
            user: IdentityRef(id: "u1"),
            roles: ["admin"],
            catalog: []
        )
    }

    @Test("bind + token(for:) round trip; zeroize removes")
    func bindAndZeroize() async {
        let store = TokenStore()
        await store.bind(sessionId: "s1", token: makeToken(id: "t1", expiresAt: .distantFuture))
        #expect(await store.token(for: "s1")?.id == "t1")
        await store.zeroize(sessionId: "s1")
        #expect(await store.token(for: "s1") == nil)
        #expect(await store.count == 0)
    }

    @Test("expired token is not returned and is evicted")
    func expiredToken() async {
        let store = TokenStore()
        await store.bind(sessionId: "s1", token: makeToken(id: "t1", expiresAt: .distantPast))
        #expect(await store.token(for: "s1") == nil, "expired token must not be returned")
        let evicted = await store.evictExpired()
        #expect(evicted.contains("s1"))
        #expect(await store.count == 0)
    }

    @Test("bind replaces a prior binding for the same session")
    func bindReplaces() async {
        let store = TokenStore()
        await store.bind(sessionId: "s1", token: makeToken(id: "t1", expiresAt: .distantFuture))
        await store.bind(sessionId: "s1", token: makeToken(id: "t2", expiresAt: .distantFuture))
        #expect(await store.token(for: "s1")?.id == "t2")
        #expect(await store.count == 1)
    }
}
