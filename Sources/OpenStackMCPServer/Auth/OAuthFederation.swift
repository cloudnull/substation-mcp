import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

import OpenStackClient

// MARK: - Keystone OS-FEDERATION passthrough (Design A: browser bounce)
//
// Flow:
//   1. MCP client asks its user to sign in via `GET <issuer>/federate?client_id&redirect_uri&code_challenge&state&scope[&region]`.
//      The server responds 302 to Keystone's IdP-specific WebSSO route:
//        `<keystone>/v3/auth/OS-FEDERATION/identity_providers/{idp}/protocol/{protocol}/websso?origin=<callback>&relay_state=<opaque>`
//   2. User authenticates at the cloud's IdP (SAML/OIDC round trip happens entirely
//      between the user's browser and the IdP — substation is not involved).
//   3. Keystone posts an **unscoped** token back to `origin` (our callback URL). We
//      verify the origin matches our own public URL (or an explicitly-allowed one),
//      capture the unscoped token into a short-lived in-memory relay state keyed by
//      the opaque `relay_state`, then render a project picker page fed by
//      `GET /v3/auth/projects` (the OS-FEDERATION spec route for unscoped tokens).
//   4. User picks a project → we exchange the unscoped token for a scoped one via
//      `LoginMinter.exchangeUnscopedForScoped`, mint an OAuth authorization code with
//      the existing `mintCode` machinery, and 302 to `redirect_uri` with `?code=...&state=...`.
//
// This works only where the cloud's **Keystone** is itself the SAML/OIDC service
// provider AND its operator has allowed a third-party `origin`. Stock Rackspace
// Skyline does NOT qualify (its Shibboleth SP entityID points at `skyline.api.*`)
// — for those clouds use the paste-token form field (Route B) instead.

// MARK: - Relay state store
//
// In-memory, instance-local, TTL-capped. Each entry binds an opaque relay-state
// string (sent as `relay_state` to Keystone, which returns it verbatim on the
// callback) to the OAuth params needed to complete the PKCE redirect later. No
// sensitive material beyond what the authorize endpoint already receives; the
// unscoped token id IS sensitive so it is kept only for the ~5-minute window
// between the two hops of the browser flow. Entries are single-use.

public struct FedRelayStateStore: Sendable {
    /// A pending federation relay entry: the OAuth params bound to an opaque
    /// `relay_state` string, plus (after the callback hop) the unscoped token id.
    public struct Entry: Sendable {
        public let expiresAt: Date
        public let clientID: String
        public let redirectURI: String
        public let codeChallenge: String
        public let state: String
        public let scope: String
        public let region: String?
        public let unscopedTokenID: String
    }

    private final class Box: @unchecked Sendable {
        var map: [String: Entry] = [:]
        let lock = NSLock()
    }

    private let box: Box
    public let ttl: TimeInterval
    public init(ttl: TimeInterval = 300) {
        self.box = Box()
        self.ttl = ttl
    }

    /// Generate an opaque relay-state token and record the OAuth params.
    public func put(
        clientID: String, redirectURI: String, codeChallenge: String,
        state: String, scope: String, region: String?, unscopedTokenID: String
    ) -> String {
        let relay = Self.newOpaqueToken(byteCount: 24)
        box.lock.lock()
        defer { box.lock.unlock() }
        purgeLocked()
        box.map[relay] = .init(
            expiresAt: Date().addingTimeInterval(ttl),
            clientID: clientID, redirectURI: redirectURI, codeChallenge: codeChallenge,
            state: state, scope: scope, region: region, unscopedTokenID: unscopedTokenID
        )
        return relay
    }

    /// Single-use fetch. Returns nil if unknown or expired.
    public func take(_ relay: String) -> Entry? {
        box.lock.lock()
        defer { box.lock.unlock() }
        guard let e = box.map.removeValue(forKey: relay) else { return nil }
        if e.expiresAt < Date() { return nil }
        return e
    }

    private func purgeLocked() {
        let now = Date()
        for (k, v) in box.map where v.expiresAt < now { box.map[k] = nil }
    }

    /// 192 bits → 48 base64url chars, URL-safe without padding.
    static func newOpaqueToken(byteCount: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

// MARK: - Routes + handlers

extension OAuthAuthorizationServer {
    /// Mount the federation surface onto the router. Call only when `federationEnabled`.
    /// Paths are absolute under `<endpoint>/oauth`: `/federate` (entry 302),
    /// `/federation/callback` (Keystone's `origin`), `/federation/pick-project`.
    public func installFederation(on router: Hummingbird.Router<BasicRequestContext>) {
        let server = self
        let relayStore = FedRelayStateStore(ttl: 300)
        let base = self.path

        // GET /oauth/federate — the MCP client redirects the user here first.
        // Validates the standard OAuth authorize params, then 302s to Keystone's
        // IdP-specific WebSSO route with our callback as `origin`.
        router.on(RouterPath(base + "/federate"), method: .get) { context, _ in
            await server.handleFederate(context, relayStore: relayStore)
        }

        // GET|POST /oauth/federation/callback — Keystone relays the unscoped token
        // here. GET handles the rare IdP that issues a plain redirect; POST handles
        // the normal form_post binding (the OS-FEDERATION default for WebSSO).
        router.on(RouterPath(base + "/federation/callback"), method: .get) { context, _ in
            await server.handleFederationCallback(context, postBody: nil, relayStore: relayStore)
        }
        router.on(RouterPath(base + "/federation/callback"), method: .post) { context, _ in
            let body = try? await Self.readBody(context, limit: 65_536)
            return await server.handleFederationCallback(context, postBody: body, relayStore: relayStore)
        }

        // POST /oauth/federation/pick-project — the user selected a project on the
        // picker page; exchange + mint code + redirect to the client.
        router.on(RouterPath(base + "/federation/pick-project"), method: .post) { context, _ in
            let body = try? await Self.readBody(context, limit: 65_536)
            return await server.handleFedPickProject(context, postBody: body, relayStore: relayStore)
        }
    }

    // MARK: GET /federate — build the WebSSO redirect

    func handleFederate(_ context: Request, relayStore: FedRelayStateStore) async -> Response {
        let q = context.uri.queryParameters
        func qp(_ n: String) -> String? { q[Substring(n)].map(String.init) }

        let clientID = qp("client_id") ?? ""
        let responseType = qp("response_type") ?? "code"
        let redirectURI = qp("redirect_uri") ?? ""
        let state = qp("state") ?? ""
        let challenge = qp("code_challenge") ?? ""
        let ccm = qp("code_challenge_method") ?? ""
        let scope = qp("scope") ?? ""
        let region = qp("region").flatMap { $0.isEmpty ? nil : $0 }

        guard responseType == "code" else {
            return Self.oauthError(.invalidRequest(description: "Only response_type=code is supported."), state: state, redirectURI: redirectURI)
        }
        guard !clientID.isEmpty else {
            return Self.oauthError(.invalidRequest(description: "Missing client_id."), state: state, redirectURI: redirectURI)
        }
        guard !redirectURI.isEmpty, Self.isLoopbackRedirectURI(redirectURI) else {
            return Self.oauthError(.invalidRequest(description: "redirect_uri must be a loopback URI."), state: state, redirectURI: "")
        }
        guard !challenge.isEmpty, ccm.uppercased() == "S256" else {
            return Self.oauthError(.invalidRequest(description: "code_challenge (S256) is required."), state: state, redirectURI: redirectURI)
        }
        guard federationEnabled, let idp = federationIdP, !idp.isEmpty else {
            return Response(status: .badGateway, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"federation_not_configured"}"#)))
        }
        let protocolName = federationProtocol ?? "saml2"
        guard let keystone = keystoneBaseURL(region: region) else {
            return Response(status: .badGateway, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"keystone_endpoint_unresolvable"}"#)))
        }
        // The `origin` parameter MUST point back to this server's callback. We
        // derive it from the issuer (which is absolute and includes the endpoint).
        let callbackURL = Self.federationCallbackURL(issuer: issuer)
        guard let cbu = callbackURL else {
            return Response(status: .badGateway, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"callback_url_malformed"}"#)))
        }

        // We do NOT yet know the unscoped token id (that arrives on the
        // callback). But we need an opaque relay_state NOW that binds the OAuth
        // params. We issue it before bouncing; the callback validates + re-binds
        // the entry once it learns the token id.
        let relay = relayStore.put(
            clientID: clientID, redirectURI: redirectURI, codeChallenge: challenge,
            state: state, scope: scope, region: region, unscopedTokenID: ""
        )
        var comps = URLComponents(url: keystone, resolvingAgainstBaseURL: false)!
        comps.path = "/v3/auth/OS-FEDERATION/identity_providers/\(idp)/protocol/\(protocolName)/websso"
        comps.queryItems = [
            URLQueryItem(name: "origin", value: cbu.absoluteString),
            URLQueryItem(name: "relay_state", value: relay),
        ]
        guard let target = comps.url else {
            return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: #"{"error":"websso_url_build_failed"}"#)))
        }
        logger.info("Federate → \(target.absoluteString)", metadata: ["client": .string(clientID)])
        return Response(status: .found, headers: [.location: target.absoluteString, .cacheControl: "no-store"], body: .init())
    }

    // MARK: /federation/callback — receive the unscoped token, show the picker

    func handleFederationCallback(_ context: Request, postBody: Data?, relayStore: FedRelayStateStore) async -> Response {
        // Parse params from query OR form body (form_post sends them in the body).
        var fields: [String: String] = [:]
        let q = context.uri.queryParameters
        for (k, v) in q { fields[String(k)] = String(v) }
        if let postBody, !postBody.isEmpty {
            let ct = context.headers[.contentType] ?? ""
            let f = Self.parseFormOrJSON(postBody, contentType: ct)
            for (k, v) in f where fields[k] == nil || v != "" { fields[k] = v }
        }

        // Defense-in-depth: Keystone echoes `origin` back in the POST form (per
        // the OS-FEDERATION spec the form contains the original request params).
        // When present, it MUST match our expected callback host. (We cannot rely
        // on this alone — an attacker who can reach the IdP could set origin —
        // but checking it rejects the obvious mis-configuration early.)
        if let echoedOrigin = fields["origin"], let ou = URL(string: echoedOrigin) {
            guard Self.originAllowed(host: ou.host(), allowlist: federationOriginAllowlist, issuer: issuer) else {
                logger.warning("Federation callback rejected: disallowed origin '\(echoedOrigin)'")
                return Self.errorHTML(message: "This federated session was started from a different Substation instance. Please restart sign-in.")
            }
        }

        guard let relay = fields["relay_state"], !relay.isEmpty else {
            return Self.errorHTML(message: "Missing relay_state. Please restart sign-in.")
        }
        let unscopedTokenID = fields["unscoped_token"] ?? fields["token"] ?? ""
        guard !unscopedTokenID.isEmpty else {
            logger.warning("Federation callback missing unscoped_token", metadata: ["relay": .string(String(relay.prefix(8)))])
            return Self.errorHTML(message: "The identity provider did not return a token. Please restart sign-in.")
        }
        guard let entry = relayStore.take(relay) else {
            // Single-use + TTL expired. The flow must restart.
            return Self.errorHTML(message: "This federated session expired or was already completed. Please restart sign-in.")
        }
        // Re-bind the token to a fresh relay entry. (take already consumed the
        // original; pick-project will consume this rebound one.)
        let reboundRelay = relayStore.put(
            clientID: entry.clientID, redirectURI: entry.redirectURI, codeChallenge: entry.codeChallenge,
            state: entry.state, scope: entry.scope, region: entry.region, unscopedTokenID: unscopedTokenID
        )

        // Verify the token is actually a federation token from the configured IdP
        // BEFORE rendering anything (trust boundary — same check as listFedProjects).
        do {
            let projects = try await minter.listFedProjects(
                fedTokenID: unscopedTokenID,
                expectedIdP: federationIdP,
                region: entry.region,
                cloudsFile: cloudsFileURL
            )
            let html = pickerHTML(
                relay: reboundRelay,
                projects: projects,
                region: entry.region,
                cloudName: cloudName
            )
            return Response(status: .ok, headers: [.contentType: "text/html"], body: .init(byteBuffer: ByteBuffer(string: html)))
        } catch {
            let msg: String
            if let osErr = error as? OpenStackError {
                msg = "Verification failed (\(osErr.status)): \(osErr.message)"
            } else {
                msg = "Verification failed."
            }
            logger.warning("Federation callback verification failed", metadata: ["reason": .string(msg)])
            return Self.errorHTML(message: "Your federated token could not be verified against this cloud's identity provider. " + msg)
        }
    }

    // MARK: POST /federation/pick-project — exchange + mint code + redirect

    func handleFedPickProject(_ context: Request, postBody: Data?, relayStore: FedRelayStateStore) async -> Response {
        let fields = Self.parseFormOrJSON(postBody ?? Data(), contentType: context.headers[.contentType] ?? "")
        guard let relay = fields["relay_state"], !relay.isEmpty else {
            return Self.errorHTML(message: "Missing relay_state.")
        }
        let projectID = fields["project_id"] ?? ""
        guard !projectID.isEmpty else {
            return Self.errorHTML(message: "Select a project to continue.")
        }
        guard let entry = relayStore.take(relay), !entry.unscopedTokenID.isEmpty else {
            return Self.errorHTML(message: "This federated session expired. Please restart sign-in.")
        }
        do {
            let scoped = try await minter.exchangeUnscopedForScoped(
                unscopedTokenID: entry.unscopedTokenID,
                projectID: projectID,
                region: entry.region,
                cloudsFile: cloudsFileURL
            )
            guard let code = mintCode(
                clientID: entry.clientID, redirectURI: entry.redirectURI, codeChallenge: entry.codeChallenge,
                scope: entry.scope, keystoneTokenID: scoped.id, projectID: scoped.project.id,
                keystoneTokenExpiry: scoped.expiresAt,
                region: entry.region
            ) else {
                return Self.errorHTML(message: "Could not issue an authorization code. Please restart sign-in.")
            }
            return Self.redirectWithCode(code: code, redirectURI: entry.redirectURI, state: entry.state)
        } catch {
            let reason: String
            if let osErr = error as? OpenStackError { reason = "exchange-\(osErr.status)" } else { reason = "unknown" }
            logger.warning("Federation project exchange failed", metadata: ["reason": .string(reason)])
            return Self.errorHTML(message: "Could not exchange your federated session for a project-scoped token. Please restart sign-in.")
        }
    }

    // MARK: helpers

    /// Resolve the regional Keystone base URL for the WebSSO route. Uses the
    /// same clouds.yaml lookup as minting so multi-region clouds resolve the
    /// correct identity endpoint. Falls back to the first cloud's auth_url when
    /// no region is specified.
    func keystoneBaseURL(region: String?) -> URL? {
        guard let file = LoginMinter.resolvedCloudsFile(cloudsFileURL) else { return nil }
        if let region, !region.isEmpty {
            if let url = LoginMinter.regionAuthURL(region: region, cloudsFile: file) { return url }
        }
        return try? CloudConfig.loadStrict(file: file).clouds.first?.authURL
    }

    static func federationCallbackURL(issuer: String) -> URL? {
        URL(string: issuer + "/federation/callback")
    }

    static func originAllowed(host: String?, allowlist: [String], issuer: String) -> Bool {
        guard let h = host, let issuerHost = URL(string: issuer)?.host() else { return false }
        if h == issuerHost { return true }
        return allowlist.contains { a in
            a == h || a.hasSuffix("." + h) || h.hasSuffix("." + a)
        }
    }

    // MARK: HTML pages

    static func errorHTML(message: String) -> Response {
        let esc = message.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Substation — Sign-in problem</title>
        <style>body{font-family:system-ui,-apple-system,sans-serif;background:#0e1116;color:#e6e6e6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.card{max-width:440px;padding:32px;border:1px solid #2a2f3a;border-radius:12px;text-align:center}h1{font-size:18px;margin:0 0 12px}.sub{color:#9aa4b2;font-size:14px;line-height:1.5}</style></head>
        <body><div class="card"><h1>Sign-in problem</h1><p class="sub">\(esc)</p></div></body></html>
        """
        return Response(status: .badGateway, headers: [.contentType: "text/html"], body: .init(byteBuffer: ByteBuffer(string: html)))
    }

    func pickerHTML(relay: String, projects: [LoginMinter.DetectedProject], region: String?, cloudName: String?) -> String {
        let options: String
        if projects.isEmpty {
            options = """
              <option value="" disabled selected>No federated projects found</option>
            """
        } else {
            options = projects.map { p -> String in
                let dom = (p.domainName ?? "").isEmpty ? "" : " (\(Self.htmlEsc(p.domainName!)))"
                return "<option value=\"\(Self.htmlAttr(p.id))\">\(Self.htmlEsc(p.name))\(dom)</option>"
            }.joined(separator: "\n")
        }
        let regionLine: String
        if let r = region, !r.isEmpty {
            let escR = Self.htmlEsc(r)
            regionLine = "<p class=\"sub\">Region: \(escR)</p>"
        } else {
            regionLine = ""
        }
        let cloudLine: String
        if let c = cloudName, !c.isEmpty {
            let escC = Self.htmlEsc(c)
            cloudLine = "<p class=\"sub\">Cloud: \(escC)</p>"
        } else {
            cloudLine = ""
        }
        let action = path + "/federation/pick-project"
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Substation — Choose a project</title>
        <style>body{font-family:system-ui,-apple-system,sans-serif;background:#0e1116;color:#e6e6e6;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.card{max-width:460px;padding:32px;border:1px solid #2a2f3a;border-radius:12px}h1{font-size:18px;margin:0 0 4px}.sub{color:#9aa4b2;font-size:13px;margin:4px 0}select{width:100%;padding:10px;margin:16px 0;background:#171c26;color:#e6e6e6;border:1px solid #2a2f3a;border-radius:8px}button{width:100%;padding:12px;background:#d4a017;color:#0e1116;border:none;border-radius:8px;font-weight:600;cursor:pointer;font-size:15px}.disabled{opacity:.5;cursor:not-allowed}</style></head>
        <body><div class="card">
          <h1>Welcome — choose a project</h1>
          <p class="sub">You signed in via federation. Pick the project this session should operate in.</p>
          \(cloudLine)\(regionLine)
          <form method="POST" action="\(action)">
            <input type="hidden" name="relay_state" value="\(Self.htmlAttr(relay))">
            <select name="project_id" required>\(options)</select>
            <button type="submit"\(projects.isEmpty ? " disabled" : "")>Continue</button>
          </form>
        </div></body></html>
        """
    }

    static func htmlEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func htmlAttr(_ s: String) -> String {
        htmlEsc(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
