import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdMCP
import Logging
import NIOCore

import OpenStackClient

// MARK: - Stateless OAuth 2.1 AS routes (P2)
//
// Mounts the RFC 8414 metadata, deterministic DCR (`/register`), the
// authorization endpoint (`/authorize`, browser + headless dev-mint), and the
// token endpoint (`/token`, PKCE authorization_code) under `<endpoint>/oauth`.
// Every endpoint is stateless: the only "store" is a short-lived replay set
// that enforces single-use authorization codes on this instance (see the
// note on `CodeReplayStore`).

// MARK: - Single-use authorization codes
//
// The store itself now lives in `OAuthReplayStore.swift`: an instance-local
// in-memory set by default (single-replica semantics, the original
// `CodeReplayStore` behavior), optionally backed by memcached for
// multi-replica deployments (NO_OVERWRITE `add`, endpoint discovered from
// the token's Keystone service catalog, fail-open to local).

extension OAuthAuthorizationServer {
    /// Mount the AS routes onto `router`. Call only when OAuth is enabled.
    ///
    /// `Hummingbird.Router` is spelled out (with its context) because
    /// `OpenStackClient` also exports a `Router` (the Neutron resource) that
    /// would otherwise shadow it here.
    public func install(on router: Hummingbird.Router<BasicRequestContext>) {
        let base = self.path
        let server = self

        // RFC 8414 metadata — served at `<issuer>/.well-known/oauth-authorization-server`.
        router.on(RouterPath(base + "/.well-known/oauth-authorization-server"), method: .get) { _, _ in
            do {
                let data = try JSONSerialization.data(withJSONObject: server.metadata(), options: [.sortedKeys])
                return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
            } catch {
                return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_metadata"}"#)))
            }
        }

        // Deterministic DCR — POST /oauth/register (RFC 7591).
        router.on(RouterPath(base + "/register"), method: .post) { context, _ in
            await server.handleRegister(context)
        }

        // Authorization endpoint — GET renders the consent form (no creds),
        // POST (form or dev-mint) mints + redirects with a `code`.
        router.on(RouterPath(base + "/authorize"), method: .get) { context, _ in
            await server.handleAuthorize(context, postBody: nil)
        }
        router.on(RouterPath(base + "/authorize"), method: .post) { context, _ in
            let body = try? await Self.readBody(context, limit: 1_048_576)
            return await server.handleAuthorize(context, postBody: body)
        }

        // Token endpoint — POST /oauth/token (PKCE authorization_code).
        router.on(RouterPath(base + "/token"), method: .post) { context, _ in
            await server.handleToken(context)
        }

        // DEBUG-only headless helper — POST /oauth/dev-mint. Never mounted in
        // release builds (guarded by `devMintEnabled`, which ServeApp only sets
        // under `#if DEBUG`).
        if server.devMintEnabled {
            router.on(RouterPath(base + "/dev-mint"), method: .post) { context, _ in
                let body = try? await Self.readBody(context, limit: 1_048_576)
                return await server.handleDevMint(context, body: body)
            }
        }
    }

    // MARK: - DCR (RFC 7591, deterministic)

    func handleRegister(_ context: Request) async -> Response {
        let body = (try? await Self.readBody(context, limit: 65_536)) ?? Data()
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.oauthError(.invalidRequest(description: "Malformed registration JSON."))
        }
        let normalized = Self.normalizeRegistration(obj)
        let clientID = Self.deriveClientID(from: normalized)
        let clientSecret = Self.deriveClientSecret(clientID: clientID, serverSecret: secret)
        let doc: [String: Any] = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "token_endpoint_auth_method": "client_secret_basic",
            "client_secret_expires_at": 0,
            "redirect_uris": normalized["redirect_uris"] as? [String] ?? [],
            "grant_types": normalized["grant_types"] as? [String] ?? [],
            "response_types": normalized["response_types"] as? [String] ?? ["code"],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
            return Response(status: .created, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
        } catch {
            return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_metadata"}"#)))
        }
    }

    // MARK: - Authorize endpoint

    func handleAuthorize(_ context: Request, postBody: Data?) async -> Response {
        let q = context.uri.queryParameters
        // Parse the POST body first so we can fall back to form fields for
        // OAuth params that arrive as hidden inputs (the browser consent form
        // POSTs everything — client_id, response_type, redirect_uri, etc. —
        // in the body, not the query string).
        var formFields: [String: String] = [:]
        if let postBody, !postBody.isEmpty {
            let ct = context.headers[.contentType] ?? ""
            formFields = Self.parseFormOrJSON(postBody, contentType: ct)
        }
        /// Look up a param in the query string first, then the POST body.
        func qp(_ name: String) -> String? {
            q[Substring(name)].map(String.init) ?? formFields[name]
        }

        let clientID = qp("client_id") ?? ""
        let responseType = qp("response_type") ?? ""
        let redirectURI = qp("redirect_uri") ?? ""
        let state = qp("state") ?? ""
        let challenge = qp("code_challenge") ?? ""
        let method = qp("code_challenge_method") ?? ""
        let scope = qp("scope") ?? ""

        guard responseType == "code" else {
            return Self.oauthError(.invalidRequest(description: "Only response_type=code is supported."), state: state, redirectURI: redirectURI)
        }
        guard !clientID.isEmpty else {
            return Self.oauthError(.invalidRequest(description: "Missing client_id."), state: state, redirectURI: redirectURI)
        }
        guard !redirectURI.isEmpty, Self.isLoopbackRedirectURI(redirectURI) else {
            return Self.oauthError(.invalidRequest(description: "redirect_uri must be a loopback URI."), state: state, redirectURI: "")
        }
        guard !challenge.isEmpty, method.uppercased() == "S256" else {
            return Self.oauthError(.invalidRequest(description: "code_challenge (S256) is required."), state: state, redirectURI: redirectURI)
        }

        // Determine whether the caller supplied credentials in the POST body.
        let hasCreds = !(formFields["appCredId"] ?? "").isEmpty || !(formFields["userName"] ?? "").isEmpty

        if hasCreds {
            do {
                guard let token = try await mintKeystone(fields: formFields) else {
                    return Self.oauthError(.invalidRequest(description: "Missing credential fields."), state: state, redirectURI: redirectURI)
                }
                guard let code = mintCode(
                    clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge,
                    scope: scope, keystoneTokenID: token.id, projectID: token.project.id,
                    keystoneTokenExpiry: token.expiresAt
                ) else {
                    return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"mint_failed"}"#)))
                }
                return Self.redirectWithCode(code: code, redirectURI: redirectURI, state: state)
            } catch {
                logger.warning("OAuth authorize mint failed", metadata: ["reason": "\(error)"])
                return Self.oauthError(.invalidRequest(description: "Mint failed (check credentials)."), state: state, redirectURI: redirectURI)
            }
        }

        // No credentials: render the consent / credential form (browser path).
        if postBody == nil {
            let html = authorizeHTML(clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge, state: state, scope: scope)
            return Response(status: .ok, headers: [.contentType: "text/html"], body: .init(byteBuffer: ByteBuffer(string: html)))
        }

        return Self.oauthError(.invalidRequest(description: "Credentials required to issue a code."), state: state, redirectURI: redirectURI)
    }

    /// Mint a Keystone token from form credentials (same seam as the login page).
    private func mintKeystone(fields: [String: String]) async throws -> Token? {
        let method = fields["method"] ?? "app-cred"
        if method == "password" {
            let uid = fields["userName"] ?? ""
            let pw = fields["password"] ?? ""
            guard !uid.isEmpty, !pw.isEmpty else { return nil }
            let m = MintMethod.password(
                userID: uid,
                domain: (fields["userDomain"] ?? "").isEmpty ? nil : fields["userDomain"],
                password: pw,
                projectName: (fields["projectName"] ?? "").isEmpty ? nil : fields["projectName"]
            )
            return try await minter.mint(method: m)
        } else {
            let id = fields["appCredId"] ?? ""
            let secret = fields["secret"] ?? ""
            guard !id.isEmpty, !secret.isEmpty else { return nil }
            let m = MintMethod.applicationCredential(id: id, secret: Array(secret.utf8).map { Int8(bitPattern: $0) })
            return try await minter.mint(method: m)
        }
    }
    // MARK: - Token endpoint

    func handleToken(_ context: Request) async -> Response {
        let body = (try? await Self.readBody(context, limit: 65_536)) ?? Data()
        let ct = context.headers[.contentType] ?? ""
        let params = Self.parseFormOrJSON(body, contentType: ct)

        // PKCE authorization_code is the only supported grant.
        guard params["grant_type"] == "authorization_code" else {
            return Self.oauthError(.unsupportedGrantType)
        }
        guard let code = params["code"], !code.isEmpty else {
            return Self.oauthError(.invalidRequest(description: "Missing code."))
        }
        guard let verifier = params["code_verifier"], (43...128).contains(verifier.count) else {
            return Self.oauthError(.invalidRequest(description: "code_verifier must be 43–128 characters."))
        }
        guard let redirectURI = params["redirect_uri"], !redirectURI.isEmpty else {
            return Self.oauthError(.invalidRequest(description: "Missing redirect_uri."))
        }
        // Client authentication (RFC 6749 §2.3 / §2.3.1). We support:
        //   - `client_secret_basic` — the client authenticates via the
        //     `Authorization: Basic base64(client_id:client_secret)` header and
        //     the `client_secret` is checked against the deterministic
        //     `deriveClientSecret(clientID:serverSecret:)`. A wrong/missing
        //     secret is rejected as `invalid_client`.
        //   - `none` (public clients) — the `client_id` is read from a `client_id`
        //     form field; no secret is required (PKCE is the auth factor, RFC 7636).
        //
        // When both a Basic header and a `client_id` form field are present, the
        // Basic header wins (it is the explicit client-auth assertion) and the
        // secret is validated.
        if let (basicClientID, basicSecret) = Self.basicCredentials(from: context) {
            guard Self.verifyClientSecret(basicClientID, secret: basicSecret, serverSecret: secret) else {
                return Self.oauthError(.invalidClient(description: "Invalid client credentials."))
            }
        } else if let formClientID = params["client_id"], !formClientID.isEmpty {
            // `none`: public client — PKCE-only, no secret.
            _ = formClientID
        } else {
            return Self.oauthError(.invalidClient(description: "Missing client_id (Basic auth or form)."))
        }
        let clientID = Self.clientID(from: context, body: params) ?? ""
        guard !clientID.isEmpty else {
            return Self.oauthError(.invalidClient(description: "Missing client_id (Basic auth or form)."))
        }

        // Verify the code JWT (signature, issuer, expiry, bound client_id/redirect_uri).
        let grant: OAuthCodeGrant
        do {
            grant = try verifyCode(code, clientID: clientID, redirectURI: redirectURI)
        } catch let e as OAuthProtocolError {
            return Self.oauthError(e)
        } catch {
            return Self.oauthError(.invalidGrant(description: "Invalid authorization code."))
        }

        // PKCE: S256(code_verifier) must equal the challenge bound to the code.
        let challengeNow = pkceS256Challenge(verifier)
        guard constantTimeEquals(challengeNow, grant.codeChallenge) else {
            return Self.oauthError(.invalidGrant(description: "PKCE verification failed."))
        }

        // Re-validate the embedded Keystone token (cached). Done before the
        // replay check so the token's catalog is available to discover the
        // shared replay-store endpoint (spec §6.5).
        let vt: ValidatedToken
        do {
            vt = try await tokenValidator.validate(grant.keystoneTokenID)
        } catch {
            logger.warning("OAuth token exchange failed", metadata: ["reason": "\(error)"])
            return Self.oauthError(.invalidGrant(description: "Embedded Keystone token is invalid or expired."))
        }

        // Single-use: reject replayed codes. Instance-local by default; when
        // `oauth.replay_store: memcached` is configured, `vt`'s catalog gives
        // the shared endpoint and the check is cluster-wide (fail-open to
        // local if the cache is unreachable).
        if await codeReplayStore.seen(jtiOf(code), vt: vt) {
            return Self.oauthError(.invalidGrant(description: "Authorization code already redeemed."))
        }

        do {
            let scopes = Self.scopes(from: params["scope"] ?? grant.scope)
            let accessToken = mintAccessToken(
                keystoneTokenID: vt.token.id,
                projectID: vt.token.project.id,
                scopes: scopes,
                clientID: grant.clientID,
                keystoneTokenExpiry: vt.token.expiresAt
            )
            let now = Int(Date().timeIntervalSince1970)
            let exp = min(now + tokenTTL, Int(vt.token.expiresAt.timeIntervalSince1970))
            let doc: [String: Any] = [
                "access_token": accessToken,
                "token_type": "Bearer",
                "expires_in": max(exp - now, 1),
                "scope": scopes.joined(separator: " "),
            ]
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
            logger.info("OAuth token issued", metadata: [
                "client_id": .string(grant.clientID),
                "project": .string(vt.token.project.id),
            ])
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
        } catch {
            logger.warning("OAuth token exchange failed", metadata: ["reason": "\(error)"])
            return Self.oauthError(.invalidGrant(description: "Embedded Keystone token is invalid or expired."))
        }
    }
    // MARK: - DEBUG-only headless helper

    /// `POST /oauth/dev-mint` — a headless protocol-test helper. Accepts the
    /// same credential fields as the authorize form plus the PKCE
    /// `code_verifier` (from which the `code_challenge` is derived), mints a
    /// Keystone token, and returns a 302 whose `Location` is the full
    /// `<redirect_uri>?code=…&state=…` — exactly what a real authorize
    /// response carries. This lets raw-HTTP e2e tests complete the whole
    /// OAuth loop without a browser. **Never mounted in release builds**
    /// (ServeApp only sets `devMintEnabled` under `#if DEBUG`).
    func handleDevMint(_ context: Request, body: Data?) async -> Response {
        guard devMintEnabled else {
            return Response(status: .notFound, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"disabled"}"#)))
        }
        let fields = body.flatMap { Self.parseFormOrJSON($0, contentType: context.headers[.contentType] ?? "") } ?? [:]
        let clientID = fields["client_id"] ?? "dev"
        let redirectURI = fields["redirect_uri"] ?? "http://127.0.0.1:9999/callback"
        let state = fields["state"] ?? "dev"
        let scope = fields["scope"] ?? ""
        // PKCE: accept either a precomputed challenge or a verifier we derive one from.
        let challenge: String
        if let precomputed = fields["code_challenge"], !precomputed.isEmpty {
            challenge = precomputed
        } else {
            challenge = pkceS256Challenge(fields["code_verifier"] ?? "devverifier0123456789abcdef0123456789abcdef0")
        }

        do {
            guard let token = try await mintKeystone(fields: fields) else {
                return Self.oauthError(.invalidRequest(description: "Credentials required."))
            }
            guard let code = mintCode(
                clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge,
                scope: scope, keystoneTokenID: token.id, projectID: token.project.id,
                keystoneTokenExpiry: token.expiresAt
            ) else {
                return Self.oauthError(.invalidRequest(description: "Mint failed."))
            }
            return Self.redirectWithCode(code: code, redirectURI: redirectURI, state: state)
        } catch {
            return Self.oauthError(.invalidRequest(description: "Mint failed: \(error)"))
        }
    }
    // MARK: - Shared helpers (stateless)

    /// Extract the JWT `jti` from a compact JWT (the code), for the replay store.
    private func jtiOf(_ code: String) -> String {
        let parts = code.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payData = Base64URL.decode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payData) as? [String: Any],
              let jti = obj["jti"] as? String, !jti.isEmpty
        else { return "jti-" + sha256Hex(code) }
        return jti
    }

    /// The `client_id` for a token request: Basic auth (`client_id:client_secret`)
    /// header or a `client_id` form field.
    static func clientID(from context: Request, body: [String: String]) -> String? {
        if let auth = context.headers[.authorization] {
            let trimmed = auth.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("basic ") {
                let b64 = String(trimmed.dropFirst(6))
                if let data = Data(base64Encoded: b64) {
                    let pair = String(decoding: data, as: UTF8.self)
                    if let colon = pair.firstIndex(of: ":") {
                        return String(pair[..<colon])
                    }
                }
            }
        }
        if let cid = body["client_id"], !cid.isEmpty { return cid }
        return nil
    }

    /// Split an `Authorization: Basic base64(client_id:client_secret)` header
    /// into `(clientID, clientSecret)`. Returns `nil` when the header is absent
    /// or not a valid Basic credential pair. The secret may be empty (the
    /// caller decides whether an empty secret is acceptable — for us it is not,
    /// because `verifyClientSecret` rejects a secret that does not match the
    /// deterministic derivation).
    static func basicCredentials(from context: Request) -> (clientID: String, clientSecret: String)? {
        guard let auth = context.headers[.authorization] else { return nil }
        let trimmed = auth.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("basic ") else { return nil }
        let b64 = String(trimmed.dropFirst(6))
        guard let data = Data(base64Encoded: b64) else { return nil }
        let pair = String(decoding: data, as: UTF8.self)
        guard let colon = pair.firstIndex(of: ":") else { return nil }
        let id = String(pair[..<colon])
        let secret = String(pair[pair.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        return (id, secret)
    }

    /// `client_secret_basic` check: does `secret` equal the deterministic
    /// `deriveClientSecret(clientID:serverSecret:)` for `clientID`? Constant-
    /// time compare so a wrong secret does not leak timing information.
    static func verifyClientSecret(_ clientID: String, secret: String, serverSecret: String) -> Bool {
        let expected = deriveClientSecret(clientID: clientID, serverSecret: serverSecret)
        return constantTimeEquals(secret, expected)
    }

    /// The scopes to issue: the requested `scope` (whitelisted). When no
    /// scope is explicitly requested, returns an empty array so the access
    /// token inherits the scopes derived from the underlying Keystone token
    /// (role-based: admin → read+write, member → read). An explicit
    /// `openstack:read` request still yields read-only.
    static func scopes(from raw: String) -> [String] {
        let allowed: Set<String> = ["openstack:read", "openstack:write"]
        let parts = raw.split(separator: " ").map(String.init).filter { allowed.contains($0) }
        return Array(parts)
    }

    /// Read a `RequestBody` into at most `limit` bytes.
    static func readBody(_ context: Request, limit: Int) async throws -> Data {
        var consumed = 0
        var data = Data()
        for try await buffer in context.body {
            consumed += buffer.readableBytes
            if consumed > limit { throw CancellationError() }
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    /// Parse a body as form-encoded or JSON into string fields.
    static func parseFormOrJSON(_ data: Data, contentType: String) -> [String: String] {
        let ct = contentType.lowercased()
        if ct.contains("application/json") {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj.reduce(into: [:]) { acc, kv in
                    if let s = kv.value as? String { acc[kv.key] = s }
                    else if let n = kv.value as? NSNumber { acc[kv.key] = n.stringValue }
                }
            }
            return [:]
        }
        let body = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first.flatMap({ $0.isEmpty ? nil : String($0) }) else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            fields[Self.percentDecode(key)] = Self.percentDecode(value)
        }
        if !fields.isEmpty { return fields }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj.reduce(into: [:]) { acc, kv in
                if let s = kv.value as? String { acc[kv.key] = s }
                else if let n = kv.value as? NSNumber { acc[kv.key] = n.stringValue }
            }
        }
        return [:]
    }

    /// Decode a percent-encoded form value (`+` is a space, `%XX` is a byte).
    static func percentDecode(_ s: String) -> String {
        let plusToSpace = s.replacingOccurrences(of: "+", with: "%20")
        return plusToSpace.removingPercentEncoding ?? s
    }

    /// Percent-encode a value for a Location query (RFC 3986 unreserved).
    static func urlEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func redirectWithCode(code: String, redirectURI: String, state: String) -> Response {
        let sep = redirectURI.contains("?") ? "&" : "?"
        let location = "\(redirectURI)\(sep)code=\(Self.urlEncode(code))&state=\(Self.urlEncode(state))"
        return Response(status: .found, headers: [.location: location, .contentType: "text/plain"], body: .init(byteBuffer: ByteBuffer(string: "Redirecting…")))
    }

    /// Carry an `OAuthProtocolError` in the redirect when a target is
    /// available (RFC 6749 §4.1.2.1), else return a JSON error body. `state`
    /// is echoed in the query string (where the SDK's code extractor reads it)
    /// and the error is placed in the fragment.
    static func oauthError(_ e: OAuthProtocolError, status: HTTPResponse.Status = .badRequest, state: String? = nil, redirectURI: String? = nil) -> Response {
        if let redirectURI, !redirectURI.isEmpty {
            let sep = redirectURI.contains("?") ? "&" : "?"
            var query = ""
            if let state, !state.isEmpty { query += "state=\(urlEncode(state))" }
            var frag = "error=\(urlEncode(e.error))&error_description=\(urlEncode(e.description))"
            if let state, !state.isEmpty { frag += "&state=\(urlEncode(state))" }
            let loc = query.isEmpty
                ? redirectURI + "#" + frag
                : redirectURI + sep + query + "#" + frag
            return Response(status: .found, headers: [.location: loc], body: .init())
        }
        let doc: [String: Any] = ["error": e.error, "error_description": e.description]
        let data = (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
        return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    // MARK: - Authorize (consent) page

    /// A minimal, self-contained consent/credential page. It re-posts the
    /// authorization query params plus the user's credentials to
    /// `<path>/authorize`, which mints a Keystone token and 302-redirects with
    /// the `code`.
    /// The OAuth authorization consent page. Matches the `/v1/login` page
    /// styling: Substation logo, IBM Plex Sans, centered card, gold-accented
    /// primary button, and method-filtered form groups (app-cred vs password).
    func authorizeHTML(clientID: String, redirectURI: String, codeChallenge: String, state: String, scope: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") }
        let action = "\(path)/authorize"
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Substation — Authorize</title>
        <link rel="icon" type="image/png" href="data:image/png;base64,\(substationLogoBase64)">
        <style>
        :root{
          --bg-1:#f7f9fc; --bg-2:#eef2f8;
          --card:#ffffff; --ink:#1f2733; --ink-soft:#5b6572; --ink-faint:#8b95a3;
          --line:#e2e8f1; --line-soft:#eef2f7;
          --gold:#F2B01E; --gold-ink:#7a5600; --gold-soft:#fdf4e0;
          --focus:#3b6fe0; --focus-ring:rgba(59,111,224,.18);
          --radius:16px; --radius-s:10px;
          --shadow:0 1px 2px rgba(16,24,40,.04),0 12px 32px -8px rgba(16,24,40,.12);
          --font:'IBM Plex Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
          --mono:'JetBrains Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
        }
        *{box-sizing:border-box}
        html,body{margin:0;padding:0}
        body{
          min-height:100vh; font-family:var(--font); color:var(--ink);
          background:linear-gradient(160deg,var(--bg-1) 0%,var(--bg-2) 100%);
          display:flex; align-items:center; justify-content:center;
          padding:40px 16px; -webkit-font-smoothing:antialiased;
        }
        .card{
          width:100%; max-width:440px; background:var(--card);
          border:1px solid var(--line); border-radius:var(--radius);
          box-shadow:var(--shadow); padding:40px 36px 34px;
        }
        .brand{display:flex; flex-direction:column; align-items:center; gap:12px; margin-bottom:4px}
        .brand .mark{width:64px; height:64px; display:block; border-radius:14px}
        .wordmark{display:flex; flex-direction:column; align-items:center; line-height:1}
        .wordmark .name{font-size:21px; font-weight:600; letter-spacing:.2em; color:#1f2d3d}
        .wordmark .tag{font-family:var(--mono); font-size:11px; letter-spacing:.02em; color:#8a94a3; margin-top:6px}
        .kicker{font-family:var(--mono); font-size:12px; letter-spacing:.02em; color:var(--gold-ink); margin:26px 0 8px; text-align:center}
        .title{font-size:22px; font-weight:600; margin:0; text-align:center; letter-spacing:-.01em}
        .sub{font-size:13.5px; color:var(--ink-soft); margin:8px 0 0; text-align:center; line-height:1.5}
        .sub code{font-family:var(--mono); font-size:11.5px; background:var(--line-soft); padding:2px 6px; border-radius:6px; color:var(--ink-soft); word-break:break-all}
        form{margin-top:24px}
        .group{margin-bottom:16px}
        .group label{display:block; font-size:12.5px; font-weight:500; color:var(--ink-soft); margin-bottom:6px}
        .group label .opt{color:var(--ink-faint); font-weight:400}
        .field{
          width:100%; font-family:var(--font); font-size:14px; color:var(--ink);
          background:#fff; border:1px solid var(--line); border-radius:var(--radius-s);
          padding:11px 13px; transition:border-color .15s,box-shadow .15s;
        }
        .field::placeholder{color:#b3bcc8}
        .field:focus{outline:none; border-color:var(--focus); box-shadow:0 0 0 4px var(--focus-ring)}
        select.field{appearance:none; -webkit-appearance:none; cursor:pointer;
          background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M2 4l4 4 4-4' stroke='%235b6572' stroke-width='1.5' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
          background-repeat:no-repeat; background-position:right 13px center; padding-right:34px}
        .btn{
          width:100%; font-family:var(--font); font-size:14.5px; font-weight:600;
          color:var(--gold-ink); background:var(--gold); border:none;
          border-radius:var(--radius-s); padding:13px; cursor:pointer; margin-top:6px;
          transition:filter .15s,transform .05s; letter-spacing:.01em;
        }
        .btn:hover{filter:brightness(1.04)}
        .btn:active{transform:translateY(1px)}
        .btn:focus-visible{outline:none; box-shadow:0 0 0 4px var(--focus-ring)}
        .footer{text-align:center; margin-top:20px; font-size:12.5px; color:var(--ink-faint)}
        .footer code{font-family:var(--mono); font-size:11.5px; background:var(--line-soft); padding:2px 6px; border-radius:6px; color:var(--ink-soft)}
        /* method-filtered groups */
        .method-fields[data-method="app-cred"] .only-password{display:none}
        .method-fields[data-method="password"] .only-appcred{display:none}
        </style></head>
        <body>
          <div class="card">
            <div class="brand">
              <img src="data:image/png;base64,\(substationLogoBase64)" alt="Substation" width="64" height="64" class="mark">
              <div class="wordmark"><span class="name">SUBSTATION</span><span class="tag">openstack mcp</span></div>
            </div>
            <p class="kicker">OAuth 2.1 · Authorization Code + PKCE</p>
            <h1 class="title">Authorize client</h1>
            <p class="sub"><code>\(esc(clientID))</code> will be redirected to<br><code>\(esc(redirectURI))</code> with an authorization code.</p>
            <form method="POST" action="\(esc(action))">
              <input type="hidden" name="client_id" value="\(esc(clientID))">
              <input type="hidden" name="response_type" value="code">
              <input type="hidden" name="redirect_uri" value="\(esc(redirectURI))">
              <input type="hidden" name="code_challenge" value="\(esc(codeChallenge))">
              <input type="hidden" name="code_challenge_method" value="S256">
              <input type="hidden" name="state" value="\(esc(state))">
              <input type="hidden" name="scope" value="\(esc(scope))">
              <div class="method-fields" id="mf" data-method="app-cred">
                <div class="group">
                  <label for="method">Method</label>
                  <select id="method" name="method" class="field" onchange="document.getElementById('mf').dataset.method=this.value">
                    <option value="app-cred" selected>Application credential</option>
                    <option value="password">User + password</option>
                  </select>
                </div>
                <div class="group only-appcred">
                  <label for="appCredId">Application credential ID</label>
                  <input id="appCredId" name="appCredId" type="text" class="field" autocomplete="off">
                </div>
                <div class="group only-appcred">
                  <label for="secret">Secret</label>
                  <input id="secret" name="secret" type="password" class="field" autocomplete="off">
                </div>
                <div class="group only-password">
                  <label for="userName">User</label>
                  <input id="userName" name="userName" type="text" class="field" autocomplete="off">
                </div>
                <div class="group only-password">
                  <label for="userDomain">Domain</label>
                  <input id="userDomain" name="userDomain" type="text" class="field" value="default">
                </div>
                <div class="group only-password">
                  <label for="password">Password</label>
                  <input id="password" name="password" type="password" class="field" autocomplete="current-password">
                </div>
                <div class="group">
                  <label for="projectName">Project <span class="opt">(optional)</span></label>
                  <input id="projectName" name="projectName" type="text" class="field">
                </div>
              </div>
              <button type="submit" class="btn">Authorize &amp; mint</button>
            </form>
            <p class="footer">Sign in to mint a Keystone token. The authorization code is single-use and expires in 30 seconds.</p>
          </div>
        </body></html>
        """
    }
}
