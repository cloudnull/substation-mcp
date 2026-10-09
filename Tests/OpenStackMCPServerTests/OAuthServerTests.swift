import Testing
import Foundation
import HTTPTypes
import Logging
import NIOCore
import Hummingbird
import HummingbirdTesting
import OpenStackClient
@testable import OpenStackMCPServer
import FakeOpenStack

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OAuth 2.1 stateless AS tests (P2)
//
// Part 1: pure unit tests for the JWT primitives, PKCE, and deterministic DCR
// (no server). Part 2: raw-HTTP end-to-end protocol tests against a live
// `ServeApp` + `FakeOpenStack` (the external Swift SDK client cannot run
// discovery against a plain-HTTP local AS because its loopback-HTTP flag is
// package-private, so we drive the wire protocol directly).

private let testSecret = "unit-test-oauth-secret-do-not-use-in-prod"
private let testIssuer = "http://127.0.0.1:1/v1/oauth"

@Test("JWT sign/verify round-trips claims")
func jwtRoundTrip() throws {
    let now = Int(Date().timeIntervalSince1970)
    let claims: [String: AnyCodableValue] = [
        "iss": .string(testIssuer),
        "aud": .string("substation-mcp"),
        "iat": .int(now),
        "exp": .int(now + 60),
        "jti": .string("jti-1"),
        "osk": .string("fake-tok-0001"),
        "prj": .string("proj-one"),
        "sco": .string("openstack:read openstack:write"),
    ]
    let token = try #require(signJWT(claims: claims, secret: testSecret))
    let verified = try verifyJWT(token, secret: testSecret, now: now, expectedIssuer: testIssuer)
    #expect(verified.string("osk") == "fake-tok-0001")
    #expect(verified.string("prj") == "proj-one")
    #expect(verified.int("exp") == now + 60)
    #expect(verified.jti == "jti-1")
    #expect(verified.audience == ["substation-mcp"])
}

@Test("Expired JWT is rejected")
func jwtExpired() {
    let past = Int(Date().timeIntervalSince1970) - 10
    let claims: [String: AnyCodableValue] = [
        "iss": .string(testIssuer),
        "exp": .int(past),
        "osk": .string("t"),
        "prj": .string("p"),
    ]
    let token = signJWT(claims: claims, secret: testSecret)!
    do {
        _ = try verifyJWT(token, secret: testSecret, now: past + 20, expectedIssuer: testIssuer)
        Issue.record("expected expired error")
    } catch let e as OAuthJWTError {
        #expect(
            e == .expired(now: past + 20, exp: past),
            "expected .expired, got \(e)"
        )
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test("Tampered signature is rejected")
func jwtTamperedSignature() {
    let now = Int(Date().timeIntervalSince1970)
    let claims: [String: AnyCodableValue] = [
        "iss": .string(testIssuer),
        "exp": .int(now + 60),
        "osk": .string("t"),
        "prj": .string("p"),
    ]
    let token = signJWT(claims: claims, secret: testSecret)!
    // Flip one character of the signature.
    var chars = Array(token)
    if let lastDot = chars.lastIndex(of: ".") {
        let sigStart = chars.index(after: lastDot)
        if chars[sigStart] == "A" { chars[sigStart] = "B" } else { chars[sigStart] = "A" }
    }
    do {
        _ = try verifyJWT(String(chars), secret: testSecret, now: now, expectedIssuer: testIssuer)
        Issue.record("expected bad signature")
    } catch let e as OAuthJWTError {
        #expect(e == .badSignature, "expected .badSignature, got \(e)")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test("Wrong issuer is rejected")
func jwtWrongIssuer() {
    let now = Int(Date().timeIntervalSince1970)
    let claims: [String: AnyCodableValue] = [
        "iss": .string("http://attacker"),
        "exp": .int(now + 60),
        "osk": .string("t"),
        "prj": .string("p"),
    ]
    let token = signJWT(claims: claims, secret: testSecret)!
    do {
        _ = try verifyJWT(token, secret: testSecret, now: now, expectedIssuer: testIssuer)
        Issue.record("expected wrong issuer")
    } catch let e as OAuthJWTError {
        #expect(
            e == .wrongIssuer(expected: testIssuer, actual: "http://attacker"),
            "expected .wrongIssuer, got \(e)"
        )
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test("Access-token parse yields the expected shape")
func accessTokenParse() throws {
    let now = Int(Date().timeIntervalSince1970)
    let claims: [String: AnyCodableValue] = [
        "iss": .string(testIssuer),
        "exp": .int(now + 3600),
        "osk": .string("fake-tok-0009"),
        "prj": .string("proj-one"),
        "sco": .string("openstack:read openstack:write"),
        "client_id": .string("client_abc"),
    ]
    let token = signJWT(claims: claims, secret: testSecret)!
    let verified = try verifyJWT(token, secret: testSecret, now: now, expectedIssuer: testIssuer)
    let at = try #require(verified.asOAuthAccessToken())
    #expect(at.tokenID == "fake-tok-0009")
    #expect(at.projectID == "proj-one")
    #expect(at.scopes == ["openstack:read", "openstack:write"])
    #expect(at.clientID == "client_abc")
    #expect(at.issuer == testIssuer)
}

@Test("PKCE S256 challenge matches the RFC 7636 test vector")
func pkceS256() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let challenge = pkceS256Challenge(verifier)
    #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test("Constant-time compare is correct")
func constantTime() {
    #expect(constantTimeEquals("abc", "abc"))
    #expect(!constantTimeEquals("abc", "abd"))
    #expect(!constantTimeEquals("abc", "abcd"))
    #expect(!constantTimeEquals("", ""))
}

@Test("Deterministic DCR: same registration yields the same client_id (idempotency)")
func dcrIdempotency() {
    let a: [String: Any] = [
        "client_name": "substation-cli",
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "client_secret_basic",
        "redirect_uris": ["http://127.0.0.1:9999/callback"],
    ]
    let b: [String: Any] = [
        // Same client, different array order + an extra ignored field.
        "client_name": "substation-cli",
        "grant_types": ["refresh_token", "authorization_code"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "client_secret_basic",
        "redirect_uris": ["http://127.0.0.1:9999/callback"],
        "logo_uri": "https://ignored.example/logo.png",
    ]
    let idA = OAuthAuthorizationServer.deriveClientID(from: OAuthAuthorizationServer.normalizeRegistration(a))
    let idB = OAuthAuthorizationServer.deriveClientID(from: OAuthAuthorizationServer.normalizeRegistration(b))
    #expect(idA == idB, "idempotency: same client, different order/extras → same id (\(idA) vs \(idB))")
    #expect(idA.hasPrefix("client_"))
}

@Test("Deterministic DCR: different registrations yield different client_ids")
func dcrDistinctness() {
    let a = OAuthAuthorizationServer.deriveClientID(from: OAuthAuthorizationServer.normalizeRegistration([
        "client_name": "client-A", "redirect_uris": ["http://127.0.0.1:1/cb"],
    ]))
    let b = OAuthAuthorizationServer.deriveClientID(from: OAuthAuthorizationServer.normalizeRegistration([
        "client_name": "client-B", "redirect_uris": ["http://127.0.0.1:2/cb"],
    ]))
    #expect(a != b)
}

@Test("Deterministic DCR: client_secret is stable per client_id + server secret")
func dcrClientSecret() {
    let clientID = "client_abc123"
    let s1 = OAuthAuthorizationServer.deriveClientSecret(clientID: clientID, serverSecret: "srv-secret-1")
    let s2 = OAuthAuthorizationServer.deriveClientSecret(clientID: clientID, serverSecret: "srv-secret-1")
    let s3 = OAuthAuthorizationServer.deriveClientSecret(clientID: clientID, serverSecret: "srv-secret-2")
    #expect(s1 == s2, "same client_id + same server secret → same client_secret")
    #expect(s1 != s3, "different server secret → different client_secret")
    #expect(!s1.isEmpty)
}

@Test("Loopback redirect policy accepts loopback, rejects non-loopback")
func redirectPolicy() {
    #expect(OAuthAuthorizationServer.isLoopbackRedirectURI("http://127.0.0.1:9999/callback"))
    #expect(OAuthAuthorizationServer.isLoopbackRedirectURI("http://localhost:8080/oauth/callback"))
    #expect(OAuthAuthorizationServer.isLoopbackRedirectURI("https://[::1]:443/cb"))
    #expect(!OAuthAuthorizationServer.isLoopbackRedirectURI("https://example.com/cb"))
    #expect(!OAuthAuthorizationServer.isLoopbackRedirectURI("ftp://127.0.0.1/cb"))
}

@Test("Code mint/verify round-trip (unit)")
func mintAndVerifyCode() throws {
    let logger = Logger(label: "test")
    let cloud = CloudEntry(name: "x", authURL: URL(string: "http://127.0.0.1:1")!)
    let transport = Transport(
        cloud: cloud,
        tokenSource: { throw OpenStackError(service: "t", status: 500, message: "n/a") },
        logger: logger
    )
    let minter = LoginMinter(transport: transport)
    let validator = TokenValidator(transport: transport, cache: Cache(maxEntries: 10), servedProjects: [])
    let server = OAuthAuthorizationServer(
        secret: testSecret, issuer: testIssuer, codeTTL: 120, tokenTTL: 3600,
        endpoint: "/v1", devMintEnabled: false, minter: minter, tokenValidator: validator
    )
    let now = Date()
    let expiry = now.addingTimeInterval(3600)
    let code = try #require(server.mintCode(
        clientID: "client_x", redirectURI: "http://127.0.0.1:9999/cb",
        codeChallenge: "ch", scope: "openstack:read", keystoneTokenID: "tok-1",
        projectID: "proj-one", keystoneTokenExpiry: expiry
    ))
    let grant = try server.verifyCode(code, clientID: "client_x", redirectURI: "http://127.0.0.1:9999/cb")
    #expect(grant.keystoneTokenID == "tok-1")
    #expect(grant.projectID == "proj-one")
    #expect(grant.scope == "openstack:read")
    #expect(grant.clientID == "client_x")

    // Wrong client_id → unauthorized_client.
    do {
        _ = try server.verifyCode(code, clientID: "evil", redirectURI: "http://127.0.0.1:9999/cb")
        Issue.record("expected unauthorized_client")
    } catch let e as OAuthProtocolError {
        #expect(e.error == "unauthorized_client", "got \(e)")
    }
    // Wrong redirect_uri → invalid_grant.
    do {
        _ = try server.verifyCode(code, clientID: "client_x", redirectURI: "http://127.0.0.1:9999/other")
        Issue.record("expected invalid_grant for redirect mismatch")
    } catch let e as OAuthProtocolError {
        #expect(e.error == "invalid_grant")
    }
    transport.syncShutdown()
}

// MARK: - Part 2: raw-HTTP end-to-end protocol tests
//
// A real `ServeApp` (with the OAuth AS enabled via `authProfile = .oauth`) is
// driven over the Hummingbird router test client against a running `FakeApp`
// (fake Keystone + services). This exercises the full wire protocol:
// RFC 8414 discovery, deterministic DCR, the authorize endpoint (consent page +
// headless dev-mint), the PKCE token exchange, and the `CompositeTokenValidator`
// gate on a real MCP session.

// MARK: - E2E helpers

private func oauthIssuer(for handle: FakeHandle) -> String {
    // Fixed test issuer: the RFC 8414 metadata is served at
    // `http://127.0.0.1:1/v1/oauth/.well-known/oauth-authorization-server` and
    // the AS signs codes/access tokens with `testSecret`.
    return "http://127.0.0.1:1/v1/oauth"
}

private func oauthConfig(handle: FakeHandle, codeTTL: Int = 120, tokenTTL: Int = 3600) -> OpenStackMCPConfig {
    OpenStackMCPConfig(
        serverPublicURL: "http://127.0.0.1:1",
        authProfile: "oauth",
        authKeystoneURL: handle.keystoneURL.absoluteString,
        oauthServerSecret: testSecret,
        oauthCodeTTL: codeTTL,
        oauthTokenTTL: tokenTTL,
        oauthIssuer: oauthIssuer(for: handle)
    )
}

/// Build a full `ServeApp` with the OAuth AS enabled against a running FakeApp.
/// The cloud `authURL` is the fake's **base** URL so the shared transport
/// reaches both Keystone (`<base>/keystone/v3`) and the services (`<base>/nova`
/// etc.) — the token endpoint's `tokenValidator.validate` re-checks the embedded
/// Keystone id over this transport.
private func oauthServeApp(
    handle: FakeHandle,
    codeTTL: Int = 120,
    tokenTTL: Int = 3600,
    logger: Logger = Logger(label: "oauth-e2e")
) -> ServeApp {
    let cloud = CloudEntry(name: "fake", authURL: handle.url, regionName: nil)
    return ServeApp(config: oauthConfig(handle: handle, codeTTL: codeTTL, tokenTTL: tokenTTL), cloud: cloud, logger: logger)
}

// MARK: - Raw HTTP helpers

// NOTE: `bodyString`/`header`/`sendRequest` live in the HummingbirdMCPTests
// target (a different module), so we redefine them here for this target.

/// Extract a `TestResponse` body as a string.
private func bodyString(_ response: TestResponse) -> String {
    String(buffer: response.body)
}

/// Case-insensitive header lookup on a `TestResponse`.
private func header(_ response: TestResponse, _ name: String) -> String? {
    response.headers[HTTPField.Name(name)!]
}

/// Build `HTTPFields` from a string dictionary (for the Hummingbird test client).
private func httpFields(_ pairs: [String: String]) -> HTTPFields {
    var fields = HTTPFields()
    for (key, value) in pairs {
        if let name = HTTPField.Name(key) { fields[name] = value }
    }
    return fields
}

/// Send a request via the Hummingbird test client and return the `TestResponse`.
private func sendRequest(
    _ client: any TestClientProtocol,
    uri: String,
    method: HTTPRequest.Method,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> TestResponse {
    try await client.execute(
        uri: uri,
        method: method,
        headers: httpFields(headers),
        body: body.map { ByteBuffer(data: $0) }
    )
}

private func httpGet(_ client: any TestClientProtocol, uri: String, headers: [String: String] = [:]) async throws -> TestResponse {
    try await sendRequest(client, uri: uri, method: .get, headers: headers)
}

private func httpPost(_ client: any TestClientProtocol, uri: String, headers: [String: String] = [:], body: Data) async throws -> TestResponse {
    try await sendRequest(client, uri: uri, method: .post, headers: headers, body: body)
}

private func httpForm(_ client: any TestClientProtocol, uri: String, fields: [String: String]) async throws -> TestResponse {
    let body = fields.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    return try await httpPost(client, uri: uri, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
}

/// Parse the `Location` header into query/fragment fields (`code`, `state`,
/// `error`, `error_description`). Errors ride in the fragment (RFC 6749 §4.1.2.1);
/// a successful redirect carries `code` in the query.
private func parseLocation(_ location: String) -> [String: String] {
    let q: Substring
    if location.contains("#") {
        // Error case: RFC 6749 §4.1.2.1 — the error rides in the fragment.
        let hashIdx = location.lastIndex(of: "#")!
        q = location[location.index(after: hashIdx)...]
    } else {
        // Success case: the code rides in the query string.
        guard let qi = location.lastIndex(of: "?") else { return [:] }
        q = location[location.index(after: qi)...]
    }
    var out: [String: String] = [:]
    for pair in q.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if let key = kv.first { out[String(key)] = kv.count > 1 ? String(kv[1]) : "" }
    }
    return out
}

// MARK: - MCP JSON-RPC helpers

private let jsonrpcInitialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}"

private let jsonrpcToolsList = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#

/// Warm up the Hummingbird router test client (the first request is dropped by
/// the framework), then run `body` with the live test client.
@discardableResult
private func warmAndRun(
    _ app: ServeApp,
    _ body: @Sendable (any TestClientProtocol) async throws -> Void
) async throws {
    try await app.app.test(.router) { client in
        _ = try await httpGet(client, uri: "/healthz")
        try await body(client)
    }
}

// RFC 7636 §2.1 test vector (also pinned by the unit `pkceS256` test).
private let pkceVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
private let loopback = "http://127.0.0.1:9999/callback"

/// Build the `authorize` URL for a given client/challenge/state/scope.
private func authorizeURI(
    issuer: String, clientID: String, redirectURI: String = loopback,
    challenge: String, state: String, scope: String = "openstack:read",
    method: String = "S256"
) -> String {
    let c = challenge.isEmpty ? "" : "&code_challenge=\(challenge)&code_challenge_method=\(method)"
    return "\(issuer)/authorize?client_id=\(clientID)&response_type=code"
        + "&redirect_uri=\(redirectURI)\(c)&state=\(state)&scope=\(scope)"
}

// MARK: - Discovery + DCR + authorize

@Suite("OAuth AS raw-HTTP protocol", .timeLimit(.minutes(5)))
struct OAuthASProtocolTests {

    @Test("RFC 8414 metadata advertises issuer + endpoints")
    func metadata() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let r = try await httpGet(client, uri: issuer + "/.well-known/oauth-authorization-server")
            #expect(r.status == .ok, "metadata: \(r.status) \(bodyString(r))")
            // JSONSerialization escapes `/` as `\/`; unescape before matching.
            let body = bodyString(r).replacingOccurrences(of: "\\/", with: "/")
            #expect(body.contains("\"issuer\":\"\(issuer)\""), "issuer: \(body)")
            #expect(body.contains(issuer + "/authorize"), "authorize_endpoint: \(body)")
            #expect(body.contains(issuer + "/token"), "token_endpoint: \(body)")
            #expect(body.contains(issuer + "/register"), "registration_endpoint: \(body)")
            #expect(body.contains("authorization_code"), "grant: \(body)")
            #expect(body.contains("S256"), "challenge method: \(body)")
        }
    }

    @Test("Deterministic DCR over HTTP: same registration → identical client_id + secret")
    func dcrIdempotentOverHTTP() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        let reg = #"{"client_name":"substation-cli","redirect_uris":["\#(loopback)"],"grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"client_secret_basic"}"#
        try await warmAndRun(app) { client in
            let r1 = try await httpPost(client, uri: issuer + "/register", headers: ["Content-Type": "application/json"], body: Data(reg.utf8))
            #expect(r1.status == .created, "register: \(r1.status) \(bodyString(r1))")
            let r2 = try await httpPost(client, uri: issuer + "/register", headers: ["Content-Type": "application/json"], body: Data(reg.utf8))
            #expect(r2.status == .created)
            let b1 = bodyString(r1), b2 = bodyString(r2)
            #expect(b1 == b2, "DCR not idempotent:\n\(b1)\n\(b2)")
            #expect(b1.contains("\"client_id\":\"client_"), "client_id: \(b1)")
            #expect(b1.contains("\"client_secret\":"), "client_secret: \(b1)")
            #expect(b1.contains("client_secret_basic"), "auth method: \(b1)")
        }
    }

    @Test("authorize GET (no creds) renders the consent HTML page")
    func authorizeConsentPage() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        let clientID = "client_e2e"
        let challenge = pkceS256Challenge(pkceVerifier)
        try await warmAndRun(app) { client in
            let r = try await httpGet(client, uri: authorizeURI(issuer: issuer, clientID: clientID, challenge: challenge, state: "st-1"))
            #expect(r.status == .ok, "consent: \(r.status) \(bodyString(r))")
            let body = bodyString(r)
            #expect(body.contains("<form"), "no form: \(body)")
            #expect(body.contains("Authorize"), "no title: \(body)")
            #expect(body.contains(clientID), "client id missing: \(body)")
        }
    }

    @Test("dev-mint mints a code and 302-redirects with code + state")
    func devMintRedirection() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let r = try await httpForm(client, uri: issuer + "/dev-mint", fields: [
                "client_id": "client_e2e",
                "redirect_uri": loopback,
                "state": "st-42",
                "code_challenge": pkceS256Challenge(pkceVerifier),
                "scope": "openstack:read",
                "method": "app-cred",
                "appCredId": "fake-cred-admin",
                "secret": "secret-admin",
            ])
            #expect(r.status == .found, "dev-mint: \(r.status) \(bodyString(r))")
            let loc = try #require(header(r, "Location"))
            let f = parseLocation(loc)
            #expect(f["code"]?.isEmpty == false, "no code in \(loc)")
            #expect(f["state"] == "st-42", "state: \(f)")
            #expect(!f.keys.contains("error"), "unexpected error: \(f)")
        }
    }

    @Test("authorize with credentials POST redirects with a code")
    func authorizeCredsRedirect() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let uri = authorizeURI(issuer: issuer, clientID: "client_e2e", challenge: pkceS256Challenge(pkceVerifier), state: "st-7")
            let r = try await httpPost(client, uri: uri, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "method=app-cred&appCredId=fake-cred-admin&secret=secret-admin".utf8))
            #expect(r.status == .found, "authorize: \(r.status) \(bodyString(r))")
            let f = parseLocation(try #require(header(r, "Location")))
            #expect(f["code"]?.isEmpty == false, "no code: \(f)")
            #expect(f["state"] == "st-7", "state: \(f)")
        }
    }

    @Test("authorize rejects a non-loopback redirect_uri with an error")
    func authorizeRejectsNonLoopback() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        let uri = authorizeURI(issuer: issuer, clientID: "client_x", redirectURI: "https://example.com/cb",
                               challenge: pkceS256Challenge(pkceVerifier), state: "st-e")
        try await warmAndRun(app) { client in
            let r = try await httpGet(client, uri: uri)
            // A non-loopback redirect_uri is rejected with a 400 JSON error —
            // never an error redirect to an untrusted URI (that would leak
            // state/error info off-origin).
            #expect(r.status == .badRequest, "expected 400, got: \(r.status) \(bodyString(r))")
            let body = bodyString(r)
            #expect(body.contains("invalid_request"), "error: \(body)")
        }
    }

    @Test("authorize rejects a missing code_challenge with a fragment error")
    func authorizeRejectsNoChallenge() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        let uri = "\(issuer)/authorize?client_id=client_x&response_type=code&redirect_uri=\(loopback)"
        try await warmAndRun(app) { client in
            let r = try await httpGet(client, uri: uri)
            #expect(r.status == .found)
            let f = parseLocation(try #require(header(r, "Location")))
            #expect(f["error"] == "invalid_request", "error: \(f)")
        }
    }

    @Test("verifyClientSecret: constant-time compare accepts match, rejects mismatch")
    func verifyClientSecretCompare() {
        let id = "client_vcs"
        let good = OAuthAuthorizationServer.deriveClientSecret(clientID: id, serverSecret: testSecret)
        #expect(OAuthAuthorizationServer.verifyClientSecret(id, secret: good, serverSecret: testSecret))
        #expect(!OAuthAuthorizationServer.verifyClientSecret(id, secret: "not-the-secret", serverSecret: testSecret))
        #expect(!OAuthAuthorizationServer.verifyClientSecret(id, secret: "", serverSecret: testSecret))
    }
}

/// Mint an authorization code via the headless `dev-mint` endpoint and return
/// the `(code, state)` pair. Used by the token-endpoint tests.
private func mintCodeViaDevMint(
    _ client: any TestClientProtocol,
    issuer: String,
    clientID: String,
    verifier: String = pkceVerifier,
    scope: String = "openstack:read",
    state: String = "st-mint"
) async throws -> (code: String, state: String) {
    let r = try await httpForm(client, uri: issuer + "/dev-mint", fields: [
        "client_id": clientID,
        "redirect_uri": loopback,
        "state": state,
        "code_verifier": verifier,
        "scope": scope,
        "method": "app-cred",
        "appCredId": "fake-cred-admin",
        "secret": "secret-admin",
    ])
    #expect(r.status == .found, "dev-mint: \(r.status) \(bodyString(r))")
    let f = parseLocation(try #require(header(r, "Location")))
    let code = try #require(f["code"])
    return (code, f["state"] ?? "")
}

// MARK: - Token endpoint (PKCE authorization_code)

@Suite("OAuth AS token endpoint", .timeLimit(.minutes(5)))
struct OAuthTokenEndpointTests {

    @Test("token exchange succeeds with the correct code_verifier")
    func exchangeSuccess() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=\(loopback)&client_id=client_e2e".utf8))
            #expect(r.status == .ok, "token: \(r.status) \(bodyString(r))")
            let body = bodyString(r)
            #expect(body.contains("\"access_token\":\"stst.at."), "access token: \(body)")
            #expect(body.contains("\"token_type\":\"Bearer\""), "type: \(body)")
            #expect(body.contains("\"expires_in\":"), "expires_in: \(body)")
            #expect(body.contains("openstack:read"), "scope: \(body)")
        }
    }

    @Test("replayed authorization code is rejected (single-use)")
    func codeReplayRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            let body = "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=\(loopback)&client_id=client_e2e"
            let first = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
            #expect(first.status == .ok, "first: \(first.status) \(bodyString(first))")

            let second = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
            #expect(second.status == .badRequest, "replay should be 400, got \(second.status)")
            #expect(bodyString(second).contains("invalid_grant"), "replay error: \(bodyString(second))")
        }
    }

    @Test("a wrong code_verifier is rejected (PKCE)")
    func wrongVerifierRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            let wrong = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa000"
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=authorization_code&code=\(code)&code_verifier=\(wrong)&redirect_uri=\(loopback)&client_id=client_e2e".utf8))
            #expect(r.status == .badRequest, "wrong verifier: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("invalid_grant"), "PKCE error: \(bodyString(r))")
        }
    }

    @Test("a mismatched client_id is rejected")
    func wrongClientRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=\(loopback)&client_id=client_evil".utf8))
            #expect(r.status == .badRequest, "wrong client: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("unauthorized_client"), "client error: \(bodyString(r))")
        }
    }

    @Test("a mismatched redirect_uri is rejected")
    func wrongRedirectRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=http://127.0.0.1:9999/other&client_id=client_e2e".utf8))
            #expect(r.status == .badRequest, "wrong redirect: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("invalid_grant"), "redirect error: \(bodyString(r))")
        }
    }

    @Test("an expired authorization code is rejected")
    func expiredCodeRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // codeTTL: 1 second. Wait for the code JWT to lapse before presenting it.
        let app = oauthServeApp(handle: handle, codeTTL: 1)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: "client_e2e")
            try await Task.sleep(nanoseconds: 1_200_000_000) // 1.2 s
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=\(loopback)&client_id=client_e2e".utf8))
            #expect(r.status == .badRequest, "expired code: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("invalid_grant"), "expiry error: \(bodyString(r))")
        }
    }

    @Test("an unsupported grant_type is rejected")
    func unsupportedGrantRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
                "grant_type=refresh_token&code=abc&client_id=client_e2e".utf8))
            #expect(r.status == .badRequest, "grant: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("unsupported_grant_type"), "grant error: \(bodyString(r))")
        }
    }

    // MARK: client_secret_basic (RFC 6749 §2.3.1)

    @Test("client_secret_basic: valid Basic auth token exchange succeeds over HTTP")
    func basicTokenExchangeValid() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }
        let issuer = oauthIssuer(for: handle)
        let id = "client_e2e_basic"
        let secret = OAuthAuthorizationServer.deriveClientSecret(clientID: id, serverSecret: testSecret)
        let basic = "Basic " + Data("\(id):\(secret)".utf8).base64EncodedString()
        let verifier = "verifier-basic-" + UUID().uuidString
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: id, verifier: verifier)
            let body = Data("grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&redirect_uri=\(loopback)".utf8)
            let r = try await httpPost(client, uri: issuer + "/token", headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": basic,
            ], body: body)
            #expect(r.status == .ok, "basic exchange: \(r.status) \(bodyString(r))")
            let text = bodyString(r)
            #expect(text.contains("\"access_token\":\"stst.at."), "token: \(text)")
            #expect(text.contains("openstack:read"), "scope: \(text)")
            #expect(r.headers[.location] == nil, "no redirect: \(text)")
        }
    }

    @Test("client_secret_basic: wrong secret → invalid_client")
    func basicTokenExchangeWrongSecret() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }
        let issuer = oauthIssuer(for: handle)
        let id = "client_e2e_basic_bad"
        let basic = "Basic " + Data("\(id):wrong-secret".utf8).base64EncodedString()
        let verifier = "verifier-basic-bad-" + UUID().uuidString
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: id, verifier: verifier)
            let body = Data("grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&redirect_uri=\(loopback)".utf8)
            let r = try await httpPost(client, uri: issuer + "/token", headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": basic,
            ], body: body)
            #expect(r.status == .badRequest, "wrong secret: \(r.status) \(bodyString(r))")
            let text = bodyString(r)
            #expect(text.contains("\"error\":\"invalid_client\""), "expected invalid_client: \(text)")
            #expect(!text.contains("access_token"), "leaked token: \(text)")
        }
    }

    @Test("client_secret_basic: no Basic header and no form client_id → invalid_client")
    func basicTokenExchangeNoCredentials() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }
        let issuer = oauthIssuer(for: handle)
        let id = "client_e2e_basic_none"
        let verifier = "verifier-basic-none-" + UUID().uuidString
        try await warmAndRun(app) { client in
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: id, verifier: verifier)
            let body = Data("grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&redirect_uri=\(loopback)".utf8)
            let r = try await httpPost(client, uri: issuer + "/token", headers: [
                "Content-Type": "application/x-www-form-urlencoded",
            ], body: body)
            #expect(r.status == .badRequest, "no creds: \(r.status) \(bodyString(r))")
            #expect(bodyString(r).contains("\"error\":\"invalid_client\""), "expected invalid_client: \(bodyString(r))")
        }
    }

    @Test("client_secret_basic: Basic header takes precedence over form client_id")
    func basicTokenExchangePrecedence() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }
        let issuer = oauthIssuer(for: handle)
        let goodID = "client_e2e_basic_prec_good"
        let evilID = "client_e2e_basic_prec_evil"
        let goodSecret = OAuthAuthorizationServer.deriveClientSecret(clientID: goodID, serverSecret: testSecret)
        let basic = "Basic " + Data("\(goodID):\(goodSecret)".utf8).base64EncodedString()
        try await warmAndRun(app) { client in
            // Body carries the *evil* client_id in the form. The Basic header must
            // win, and the code (issued to the good client) must validate.
            let verifier = "verifier-basic-prec-" + UUID().uuidString
            let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: goodID, verifier: verifier)
            let body = Data("grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&redirect_uri=\(loopback)&client_id=\(evilID)".utf8)
            let r = try await httpPost(client, uri: issuer + "/token", headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": basic,
            ], body: body)
            let text = bodyString(r)
            #expect(r.status == .ok, "precedence (Basic should win): \(r.status) \(text)")
            #expect(text.contains("access_token"), "expected success on good client: \(text)")

            // A code minted for the evil client cannot be redeemed with the good
            // client's Basic credentials → unauthorized_client (client_id mismatch).
            let verifier2 = "verifier-basic-prec2-" + UUID().uuidString
            let (evilCode, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: evilID, verifier: verifier2)
            let body2 = Data("grant_type=authorization_code&code=\(evilCode)&code_verifier=\(verifier2)&redirect_uri=\(loopback)".utf8)
            let r2 = try await httpPost(client, uri: issuer + "/token", headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": basic,
            ], body: body2)
            #expect(r2.status == .badRequest, "evil code vs good Basic: \(r2.status) \(bodyString(r2))")
            #expect(bodyString(r2).contains("unauthorized_client"), "expected unauthorized_client: \(bodyString(r2))")
        }
    }
}
// MARK: - Composite gate (OAuth + Keystone) on a real MCP session

/// Minimal MCP Streamable-HTTP client over the Hummingbird test client that
/// presents a bearer token and tracks the `MCP-Session-Id`.
private func mcpInitialize(_ client: any TestClientProtocol, bearer: String) async throws -> (status: HTTPResponse.Status, sessionID: String?, body: String) {
    let r = try await httpPost(client, uri: "/v1", headers: [
        "Authorization": "Bearer \(bearer)",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ], body: Data(jsonrpcInitialize.utf8))
    return (r.status, header(r, "MCP-Session-Id"), bodyString(r))
}

private func mcpToolsList(_ client: any TestClientProtocol, bearer: String, sessionID: String?) async throws -> (status: HTTPResponse.Status, body: String) {
    var headers = [
        "Authorization": "Bearer \(bearer)",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    ]
    if let sessionID { headers["MCP-Session-Id"] = sessionID }
    let r = try await httpPost(client, uri: "/v1", headers: headers, body: Data(jsonrpcToolsList.utf8))
    return (r.status, bodyString(r))
}

/// Exchange a fresh dev-minted code for a `stst.at.` access token over HTTP.
private func exchangeAccessToken(_ client: any TestClientProtocol, issuer: String, clientID: String) async throws -> String {
    let (code, _) = try await mintCodeViaDevMint(client, issuer: issuer, clientID: clientID)
    let r = try await httpPost(client, uri: issuer + "/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(
        "grant_type=authorization_code&code=\(code)&code_verifier=\(pkceVerifier)&redirect_uri=\(loopback)&client_id=\(clientID)".utf8))
    #expect(r.status == .ok, "exchange: \(r.status) \(bodyString(r))")
    guard
        let data = bodyString(r).data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let at = obj["access_token"] as? String, at.hasPrefix(OAuthAccessTokenPrefix)
    else {
        throw OAuthProtocolError.invalidGrant(description: "no access token in \(bodyString(r))")
    }
    return at
}

@Suite("Composite gate on a real MCP session", .timeLimit(.minutes(5)))
struct CompositeGateTests {

    @Test("an stst.at. access token opens an MCP session (OAuth path)")
    func oauthAccessTokenWorks() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let at = try await exchangeAccessToken(client, issuer: issuer, clientID: "client_e2e")
            let initResp = try await mcpInitialize(client, bearer: at)
            #expect(initResp.status == .ok, "initialize: \(initResp.status) \(initResp.body)")
            #expect(initResp.sessionID != nil, "no session id: \(initResp.body)")
            let list = try await mcpToolsList(client, bearer: at, sessionID: initResp.sessionID)
            #expect(list.status == .ok, "tools/list: \(list.status) \(list.body)")
            #expect(list.body.contains("os_list"), "tools missing: \(list.body)")
        }
    }

    @Test("a raw Keystone bearer token still works (Keystone path unchanged)")
    func keystoneBearerWorks() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        // Mint a plain Keystone token directly (no OAuth).
        guard let ft = await handle.state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            Issue.record("mint failed"); return
        }
        try await warmAndRun(app) { client in
            let initResp = try await mcpInitialize(client, bearer: ft.id)
            #expect(initResp.status == .ok, "initialize: \(initResp.status) \(initResp.body)")
            #expect(initResp.sessionID != nil, "no session id: \(initResp.body)")
            let list = try await mcpToolsList(client, bearer: ft.id, sessionID: initResp.sessionID)
            #expect(list.status == .ok, "tools/list: \(list.status) \(list.body)")
            #expect(list.body.contains("os_list"), "tools missing: \(list.body)")
        }
    }

    @Test("a garbage bearer token is rejected with 401")
    func garbageRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let app = oauthServeApp(handle: handle)
        defer { app.shutdown() }

        try await warmAndRun(app) { client in
            let initResp = try await mcpInitialize(client, bearer: "not-a-real-token")
            #expect(initResp.status == .unauthorized, "expected 401, got \(initResp.status) \(initResp.body)")
        }
    }

    @Test("an expired stst.at. access token is rejected with 401")
    func expiredAccessTokenRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // tokenTTL: 1 second so the access-token JWT lapses almost immediately.
        let app = oauthServeApp(handle: handle, tokenTTL: 1)
        defer { app.shutdown() }

        let issuer = oauthIssuer(for: handle)
        try await warmAndRun(app) { client in
            let at = try await exchangeAccessToken(client, issuer: issuer, clientID: "client_e2e")
            try await Task.sleep(nanoseconds: 1_300_000_000) // 1.3 s
            let initResp = try await mcpInitialize(client, bearer: at)
            #expect(initResp.status == .unauthorized, "expected 401, got \(initResp.status) \(initResp.body)")
        }
    }
}
