import Foundation
import HTTPTypes
import Hummingbird
import MCP
import Logging

// MARK: - Configuration

/// Configuration for the MCP HTTP route (spec §7.1).
public struct MCPConfig: Sendable {
    public var endpoint: String
    public var legacyEndpoint: String
    public var allowedOrigins: [String]
    public var maxBodyBytes: Int
    public var maxSessions: Int
    public var maxStreamsPerSession: Int
    public var idleTTL: TimeInterval
    public var maxLifetime: TimeInterval
    public var cleanupInterval: Duration
    public var publicURL: String?

    public init(
        endpoint: String = "/v1",
        legacyEndpoint: String = "/mcp",
        allowedOrigins: [String] = ["localhost"],
        maxBodyBytes: Int = 1_048_576,
        maxSessions: Int = 1000,
        maxStreamsPerSession: Int = 1,
        idleTTL: TimeInterval = 3600,
        maxLifetime: TimeInterval = 86_400,
        cleanupInterval: Duration = .seconds(60),
        publicURL: String? = nil
    ) {
        self.endpoint = endpoint
        self.legacyEndpoint = legacyEndpoint
        self.allowedOrigins = allowedOrigins
        self.maxBodyBytes = maxBodyBytes
        self.maxSessions = maxSessions
        self.maxStreamsPerSession = maxStreamsPerSession
        self.idleTTL = idleTTL
        self.maxLifetime = maxLifetime
        self.cleanupInterval = cleanupInterval
        self.publicURL = publicURL
    }
}

// MARK: - Login request/response

/// A URL-mode login request (Task 18 wires this to `LoginMinter`).
public struct LoginRequest: Sendable {
    public let elicitationId: String
    public let method: String
    public let appCredId: String?
    public let secret: String?
    public let userName: String?
    public let password: String?
    public let projectName: String?

    public init(
        elicitationId: String,
        method: String,
        appCredId: String? = nil,
        secret: String? = nil,
        userName: String? = nil,
        password: String? = nil,
        projectName: String? = nil
    ) {
        self.elicitationId = elicitationId
        self.method = method
        self.appCredId = appCredId
        self.secret = secret
        self.userName = userName
        self.password = password
        self.projectName = projectName
    }
}

/// The result of a login.
public struct LoginResponse: Sendable {
    public let tokenID: String
    public let storePath: String
    public let completion: Bool

    public init(tokenID: String, storePath: String, completion: Bool) {
        self.tokenID = tokenID
        self.storePath = storePath
        self.completion = completion
    }
}

// MARK: - The MCP route

/// Mounts the MCP Streamable-HTTP route (plus PRM and login routes) onto a
/// Hummingbird router.
///
/// The adapter is OpenStack-free: it takes a `TokenValidating` seam, a
/// `serverFactory` (which builds the per-request `Server`), a `WriteToolGate`
/// (which tool names require `openstack:write`), and injected closures for the
/// Protected Resource Metadata document and the login page.
public struct MCPRoute: Sendable {
    let config: MCPConfig
    let validator: any TokenValidating
    let serverFactory: @Sendable (ValidatedIdentity) async -> Server
    let gate: WriteToolGate
    let terminated: @Sendable (String) -> Void
    let logger: Logger
    let registry: SessionRegistry
    let failedAuthLimiter: FailedAuthLimiter
    /// Fired when a new MCP session is registered (spec §12: `osmcp_sessions_active`).
    let onSessionStart: @Sendable () -> Void
    /// Fired when an MCP session is terminated/evicted (spec §12: `osmcp_sessions_active`).
    let onSessionEnd: @Sendable () -> Void

    public init(
        config: MCPConfig,
        validator: any TokenValidating,
        serverFactory: @escaping @Sendable (ValidatedIdentity) async -> Server,
        gate: WriteToolGate = WriteToolGate(),
        terminated: @escaping @Sendable (String) -> Void,
        logger: Logger = Logger(label: "hummingbird-mcp"),
        failedAuthPerMinute: Int = 10,
        clock: @escaping @Sendable () -> Date = { Date() },
        onSessionStart: @escaping @Sendable () -> Void = {},
        onSessionEnd: @escaping @Sendable () -> Void = {},
        onAuthFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.failedAuthLimiter = FailedAuthLimiter(
            limitPerMinute: failedAuthPerMinute,
            clock: clock,
            onFailure: onAuthFailure
        )
        self.validator = validator
        self.serverFactory = serverFactory
        self.gate = gate
        self.terminated = terminated
        self.logger = logger
        self.onSessionStart = onSessionStart
        self.onSessionEnd = onSessionEnd
        self.registry = SessionRegistry(
            idleTTL: config.idleTTL,
            maxLifetime: config.maxLifetime,
            cleanupInterval: config.cleanupInterval,
            terminated: terminated,
            logger: logger
        )
    }

    /// Install the MCP route, PRM route, and login route onto `router`.
    ///
    /// - Parameters:
    ///   - router: The Hummingbird router to install into.
    ///   - prm: Closure returning the Protected Resource Metadata JSON body.
    ///     Served at `/.well-known/oauth-protected-resource` and
    ///     `/.well-known/oauth-protected-resource/v1`.
    ///   - login: Closure handling the URL-mode login page (GET renders the
    ///     form, POST mints a token). Served at `<endpoint>/login`.
    public func install(
        on router: Router<BasicRequestContext>,
        prm: (@Sendable () -> Data)? = nil,
        login: (@Sendable (LoginRequest) async -> LoginResponse)? = nil
    ) {
        let mcpHandler = self.makeMCPHandler()
        installMCPRoutes(on: router, endpoint: config.endpoint, mcpHandler: mcpHandler)
        if config.legacyEndpoint != config.endpoint {
            installMCPRoutes(on: router, endpoint: config.legacyEndpoint, mcpHandler: mcpHandler)
        }
        installPRM(on: router, prm: prm)
        installLogin(on: router, endpoint: config.endpoint, login: login)
        if config.legacyEndpoint != config.endpoint {
            installLogin(on: router, endpoint: config.legacyEndpoint, login: login)
        }
    }

    private func installMCPRoutes(
        on router: Router<BasicRequestContext>,
        endpoint: String,
        mcpHandler: @escaping @Sendable (Request) async -> Response
    ) {
        let path = RouterPath(endpoint)
        let responder: @Sendable (Request, BasicRequestContext) async throws -> Response = { request, _ in
            await mcpHandler(request)
        }
        router.on(path, method: .post, use: responder)
        router.on(path, method: .get, use: responder)
        router.on(path, method: .delete, use: responder)
    }

    private func installPRM(on router: Router<BasicRequestContext>, prm: (@Sendable () -> Data)?) {
        guard let prm else { return }
        let serve: @Sendable (Request, BasicRequestContext) async throws -> Response = { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: prm()))
            )
        }
        router.get("/.well-known/oauth-protected-resource", use: serve)
        router.get("/.well-known/oauth-protected-resource/v1", use: serve)
    }

    // MARK: - Login page HTML

    /// The substation logo mark as an `<img>` tag, inlined via a base64 data
    /// URI so the login page has no external asset dependency. The source PNG
    /// lives at `Sources/HummingbirdMCP/Resources/substation-logo.png` and is
    /// embedded as `substationLogoBase64` (see `Logo.swift`, auto-generated).
    private static let logoImg = """
    <img src="data:image/png;base64,\(substationLogoBase64)" \
    alt="Substation" width="64" height="64" class="mark">
    """

    /// Shared CSS for the login + completion pages. A calm, centered card on a
    /// soft gradient, IBM Plex Sans, a gold-accented primary button matching the
    /// logo's lightning bolt, and form groups whose visibility is filtered by
    /// the selected authentication method (see the JS at the foot of the form).
    private static let loginCSS = """
    :root{
      --bg-1:#f7f9fc; --bg-2:#eef2f8;
      --card:#ffffff; --ink:#1f2733; --ink-soft:#5b6572; --ink-faint:#8b95a3;
      --line:#e2e8f1; --line-soft:#eef2f7;
      --gold:#F2B01E; --gold-ink:#7a5600; --gold-soft:#fdf4e0;
      --focus:#3b6fe0; --focus-ring:rgba(59,111,224,.18);
      --ok:#1f9d63; --ok-soft:#e9f7f0; --err:#c0392b; --err-soft:#fdecea;
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
    .wordmark .name{
      font-size:21px; font-weight:600; letter-spacing:.2em; color:#1f2d3d;
    }
    .wordmark .tag{
      font-family:var(--mono); font-size:11px; letter-spacing:.02em;
      color:#8a94a3; margin-top:6px;
    }
    .kicker{
      font-family:var(--mono); font-size:12px; letter-spacing:.02em;
      color:var(--gold-ink); margin:26px 0 8px; text-align:center;
    }
    .title{font-size:22px; font-weight:600; margin:0; text-align:center; letter-spacing:-.01em}
    .sub{font-size:13.5px; color:var(--ink-soft); margin:8px 0 0; text-align:center; line-height:1.5}
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
    .method-card{display:flex; flex-direction:column; gap:8px}
    .btn{
      width:100%; font-family:var(--font); font-size:14.5px; font-weight:600;
      color:var(--gold-ink); background:var(--gold); border:none;
      border-radius:var(--radius-s); padding:13px; cursor:pointer; margin-top:6px;
      transition:filter .15s,transform .05s; letter-spacing:.01em;
    }
    .btn:hover{filter:brightness(1.04)}
    .btn:active{transform:translateY(1px)}
    .btn:focus-visible{outline:none; box-shadow:0 0 0 4px var(--focus-ring)}
    .divider{height:1px; background:var(--line); margin:18px 0; border:none}
    .hint{font-size:12px; color:var(--ink-faint); margin:2px 0 0; line-height:1.5}
    .footer{text-align:center; margin-top:20px; font-size:12.5px; color:var(--ink-faint)}
    .footer code{font-family:var(--mono); font-size:11.5px; background:var(--line-soft); padding:2px 6px; border-radius:6px; color:var(--ink-soft)}
    /* method-filtered groups */
    .method-fields[data-method="app-cred"] .only-password{display:none}
    .method-fields[data-method="password"] .only-appcred{display:none}
    /* result pages */
    .result{display:flex; flex-direction:column; align-items:center; text-align:center; gap:6px}
    .result .icon{width:56px; height:56px; border-radius:50%; display:flex; align-items:center; justify-content:center; margin-bottom:8px}
    .result .icon.ok{background:var(--ok-soft); color:var(--ok)}
    .result .icon.err{background:var(--err-soft); color:var(--err)}
    .result .icon svg{width:28px; height:28px}
    .token-box{
      width:100%; margin-top:16px; font-family:var(--mono); font-size:12px;
      background:var(--line-soft); border:1px solid var(--line);
      border-radius:var(--radius-s); padding:12px 14px; word-break:break-all; color:var(--ink-soft);
    }
    .token-box .k{color:var(--ink-faint); display:block; margin-bottom:4px; font-size:11px; letter-spacing:.04em; text-transform:uppercase}
    """

    /// The login form page, rendered as a self-contained HTML document.
    /// Exposed as a static function so tests (and the preview tooling) can
    /// render it without a full server. The `endpoint` is shown in the footer
    /// so an operator knows which MCP URL they are authenticating against.
    static func loginHTML(endpoint: String) -> String {
        let loginPath = endpoint + "/login"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Substation — Sign in</title>
          <link rel="preconnect" href="https://fonts.googleapis.com">
          <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
          <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
          <style>\(Self.loginCSS)</style>
        </head>
        <body>
          <main class="card" role="main">
            <div class="brand">
              \(Self.logoImg)
              <div class="wordmark">
                <span class="name">SUBSTATION</span>
                <span class="tag">The Operator's Control Room</span>
              </div>
            </div>

            <div class="kicker">// sign in</div>
            <h1 class="title">Authenticate to your cloud</h1>
            <p class="sub">Mint a Keystone token to connect this MCP server to your OpenStack deployment.</p>

            <form method="POST" action="\(loginPath)">
              <div class="group">
                <label for="method">Method</label>
                <select id="method" name="method" class="field" onchange="substationFilter(this.value)">
                  <option value="app-cred" selected>Application credential</option>
                  <option value="password">User + password</option>
                </select>
              </div>

              <div class="method-fields" data-method="app-cred" id="methodFields">
                <div class="group only-appcred">
                  <label for="appCredId">Application credential ID</label>
                  <input class="field" id="appCredId" name="appCredId" type="text"
                         placeholder="e.g. 8f2c…d91a" autocomplete="off" spellcheck="false">
                </div>
                <div class="group only-appcred">
                  <label for="secret">Secret</label>
                  <input class="field" id="secret" name="secret" type="password"
                         placeholder="••••••••••••••••" autocomplete="off">
                </div>
                <div class="group only-password">
                  <label for="userName">User</label>
                  <input class="field" id="userName" name="userName" type="text"
                         placeholder="e.g. admin" autocomplete="username" spellcheck="false">
                </div>
                <div class="group only-password">
                  <label for="password">Password</label>
                  <input class="field" id="password" name="password" type="password"
                         placeholder="••••••••••••••••" autocomplete="current-password">
                </div>
                <div class="group only-password">
                  <label for="projectName">Project <span class="opt">optional</span></label>
                  <input class="field" id="projectName" name="projectName" type="text"
                         placeholder="e.g. admin" autocomplete="off" spellcheck="false">
                  <p class="hint">Omit for a domain-scoped token; set the cloud's admin project for cross-domain privileges.</p>
                </div>
              </div>

              <button type="submit" class="btn">Log in</button>

              <input type="hidden" name="elicitationId" value="E1">
            </form>

            <p class="footer">Serving <code>\(endpoint)</code> · token is stored for this session only</p>
          </main>
          <script>
            function substationFilter(method) {{
              var fields = document.getElementById('methodFields');
              if (fields) {{ fields.setAttribute('data-method', method); }}
            }}
            // initialise the field filter on load (defaults to app-cred)
            document.addEventListener('DOMContentLoaded', function() {{
              var sel = document.getElementById('method');
              if (sel) {{ substationFilter(sel.value); }}
            }});
          </script>
        </body>
        </html>
        """
    }

    private func installLogin(
        on router: Router<BasicRequestContext>,
        endpoint: String,
        login: (@Sendable (LoginRequest) async -> LoginResponse)?
    ) {
        let loginPath = endpoint + "/login"
        let loginRoutePath = RouterPath(loginPath)
        router.get(loginRoutePath) { _, _ in
            let html = Self.loginHTML(endpoint: endpoint)
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(data: html.data(using: .utf8)!))
            )
        }

        if let login {
            router.post(loginRoutePath) { [maxBodyBytes = config.maxBodyBytes, minter = login] request, _ in
                let data: Data
                do {
                    data = try await Self.drainBody(request.body, upTo: maxBodyBytes) ?? Data()
                } catch {
                    return Response(
                        status: .contentTooLarge,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"request body too large"}"#))
                    )
                }
                let req: LoginRequest
                do {
                    req = try Self.decodeLoginRequest(data)
                } catch {
                    return Response(
                        status: .badRequest,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"malformed login request"}"#))
                    )
                }
                let result = await minter(req)
                let html: String
                if result.completion {
                    html = """
                    <!DOCTYPE html>
                    <html lang="en"><head>
                    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>Substation — Signed in</title>
                    <link rel="preconnect" href="https://fonts.googleapis.com">
                    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
                    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
                    <style>\(Self.loginCSS)</style>
                    </head><body>
                    <main class="card" role="main">
                      <div class="brand">
                        \(Self.logoImg)
                        <div class="wordmark"><span class="name">SUBSTATION</span><span class="tag">The Operator's Control Room</span></div>
                      </div>
                      <div class="result">
                        <div class="icon ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg></div>
                        <h1 class="title">Signed in</h1>
                        <p class="sub">Your token was minted and stored for this session. You may close this tab.</p>
                        <div class="token-box"><span class="k">Token ID</span>\(result.tokenID)</div>
                      </div>
                    </main>
                    </body></html>
                    """
                } else {
                    // Mint failed: the completion page's "Token ID" element is
                    // empty, so the response is an error page instead. The
                    // failure reason is intentionally generic (the underlying
                    // error may quote credential material).
                    html = """
                    <!DOCTYPE html>
                    <html lang="en"><head>
                    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <title>Substation — Sign-in failed</title>
                    <link rel="preconnect" href="https://fonts.googleapis.com">
                    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
                    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
                    <style>\(Self.loginCSS)</style>
                    </head><body>
                    <main class="card" role="main">
                      <div class="brand">
                        \(Self.logoImg)
                        <div class="wordmark"><span class="name">SUBSTATION</span><span class="tag">The Operator's Control Room</span></div>
                      </div>
                      <div class="result">
                        <div class="icon err"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"/></svg></div>
                        <h1 class="title">Sign-in failed</h1>
                        <p class="sub">Credentials could not be validated. Check the details and try again, or contact your cloud administrator.</p>
                        <a class="btn" href="\(loginPath)">Try again</a>
                      </div>
                    </main>
                    </body></html>
                    """
                }
                return Response(
                    status: result.completion ? .ok : .badRequest,
                    headers: [.contentType: "text/html; charset=utf-8"],
                    body: .init(byteBuffer: ByteBuffer(data: html.data(using: .utf8)!))
                )
            }
        } else {
            router.post(loginRoutePath) { _, _ in
                Response(
                    status: .notImplemented,
                    headers: [.contentType: "text/plain"],
                    body: .init(byteBuffer: ByteBuffer(string: "Login not configured"))
                )
            }
        }
    }

    private static func decodeLoginRequest(_ data: Data) throws -> LoginRequest {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidRequest("malformed login JSON")
        }
        return LoginRequest(
            elicitationId: json["elicitationId"] as? String ?? "E1",
            method: json["method"] as? String ?? "app-cred",
            appCredId: json["appCredId"] as? String,
            secret: json["secret"] as? String,
            userName: json["userName"] as? String,
            password: json["password"] as? String,
            projectName: json["projectName"] as? String
        )
    }

    // MARK: - MCP request handler

    private func makeMCPHandler() -> @Sendable (Request) async -> Response {
        let route = self
        return { request in
            await route.handle(request)
        }
    }

    private func handle(_ hummingRequest: Request) async -> Response {
        // 1. Body size limit (spec §7.1.2: over-limit → 413).
        let bodyData: Data?
        do {
            bodyData = try await Self.drainBody(hummingRequest.body, upTo: config.maxBodyBytes)
        } catch {
            return .json(.contentTooLarge, #"{"error":"request body too large"}"#)
        }

        // 2. Auth: parse Bearer token (spec §7.1.1: missing → 401).
        guard let bearer = parseBearer(hummingRequest.headers) else {
            return .unauthorized(resourceMetadata: resourceMetadataURL)
        }

        // 3. Validate on EVERY request (spec §7.1.3). Cache lives in the validator.
        //    Failed validations are counted per source address (spec §7.1:
        //    `auth.failed_auth_per_minute`); once the window is exhausted,
        //    further attempts 429 **before** they reach Keystone.
        guard let identity = try? await validator.validate(tokenID: bearer) else {
            let sourceIP = clientIP(of: hummingRequest)
            guard await failedAuthLimiter.record(source: sourceIP) else {
                return .tooManyRequests()
            }
            return .unauthorized(resourceMetadata: resourceMetadataURL)
        }

        let httpMethod = hummingRequest.method.rawValue.uppercased()
        let sessionID = headerValue(hummingRequest.headers, "MCP-Session-Id")
        let isInitialize = isInitializeRequest(bodyData)

        // 4. Routed to an existing session.
        if let sessionID {
            guard let session = await registry.get(sessionID) else {
                return .json(.notFound, #"{"error":"session not found or expired"}"#)
            }

            // DELETE terminates the session (spec §7.1): remove it from the
            // registry (firing the `terminated` callback so a bound token can be
            // zeroized) and tear down the server.
            if httpMethod == "DELETE" {
                if let removed = await registry.terminate(sessionID) {
                    await removed.disconnect()
                    onSessionEnd()
                }
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true}"#))
                )
            }

            await registry.touch(sessionID)

            // Scope enforcement for write-gated tools (spec §7.1.3, Review Focus 3).
            if let scope = requiredScope(for: bodyData) {
                switch ScopeAuthorizer().authorize(identity, requiredScope: scope) {
                case .insufficientScope(let required):
                    return .forbiddenInsufficientScope(required: required, resourceMetadata: resourceMetadataURL)
                case .audienceMismatch:
                    return .forbiddenAudience(resourceMetadata: resourceMetadataURL)
                case .allow:
                    break
                }
            }

            let mcpRequest = MCP.HTTPRequest(
                method: httpMethod,
                headers: headerDict(hummingRequest.headers),
                body: bodyData,
                path: hummingRequest.uri.path
            )
            let response = await session.transport.handleRequest(mcpRequest)
            return mapResponse(response, sessionID: sessionID)
        }

        // 5. No session: only an `initialize` POST may create one.
        guard isInitialize, httpMethod == "POST" else {
            return .json(.badRequest, #"{"error":"missing or invalid session; send initialize first"}"#)
        }
        return await createSessionAndHandle(method: httpMethod, headers: hummingRequest.headers, body: bodyData, identity: identity)
    }

    /// The Protected Resource Metadata URL advertised in `WWW-Authenticate`
    /// challenges. Uses `publicURL` when configured, otherwise the well-known
    /// path relative to the serving host.
    private var resourceMetadataURL: String {
        let base = config.publicURL ?? ""
        return base + "/.well-known/oauth-protected-resource"
    }

    private func createSessionAndHandle(
        method: String,
        headers: HTTPFields,
        body: Data?,
        identity: ValidatedIdentity
    ) async -> Response {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: StandardValidationPipeline(validators: [
                ConfiguredOriginValidator(allowedOrigins: config.allowedOrigins),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]),
            retryInterval: nil,
            logger: logger
        )

        do {
            let server = await serverFactory(identity)
            try await server.start(transport: transport)
            let session = MCPSession(
                server: server,
                transport: transport,
                sessionID: sessionID,
                lastAccessedAt: Date(),
                createdAt: Date()
            )
            _ = await registry.register(session)
            onSessionStart()

            let mcpRequest = MCP.HTTPRequest(
                method: method,
                headers: headerDict(headers),
                body: body,
                path: config.endpoint
            )
            let response = await transport.handleRequest(mcpRequest)
            return mapResponse(response, sessionID: sessionID)
        } catch {
            await transport.disconnect()
            return .json(.internalServerError, #"{"error":"failed to create session"}"#)
        }
    }

    // MARK: - Request / header helpers

    /// Thrown when a request body exceeds the configured limit (→ 413).
    private struct BodyTooLargeError: Error {}

    /// Drain a `RequestBody` into at most `limit` bytes of `Data`.
    ///
    /// `RequestBody` is an `AsyncSequence` of `ByteBuffer`; we read until the
    /// stream ends or the limit is exceeded. Throws `BodyTooLargeError` when the
    /// body is larger than `limit` (spec §7.1.2: limit → 413).
    private static func drainBody(_ body: RequestBody, upTo limit: Int) async throws -> Data? {
        var consumed = 0
        var data = Data()
        for try await buffer in body {
            consumed += buffer.readableBytes
            if consumed > limit {
                throw BodyTooLargeError()
            }
            let bytes = buffer.readableBytesView
            data.append(contentsOf: bytes)
        }
        return data.isEmpty ? nil : data
    }

    private func headerDict(_ fields: HTTPFields) -> [String: String] {
        var dict: [String: String] = [:]
        for field in fields {
            let name = field.name.rawName
            if let existing = dict[name] {
                dict[name] = existing + ", " + field.value
            } else {
                dict[name] = field.value
            }
        }
        return dict
    }

    /// Build an `HTTPField.Name` from a string, force-unwrapping (our names are valid).
    private func headerName(_ raw: String) -> HTTPField.Name {
        HTTPField.Name(raw)!
    }

    /// Case-insensitive header lookup.
    /// The best-known client address for rate limiting: `X-Forwarded-For`'s
    /// first hop when present (behind a proxy), otherwise the peer address.
    private func clientIP(of request: Request) -> String {
        let forwardedName = HTTPField.Name("X-Forwarded-For")
        if let forwardedName, let forwarded = request.headers[forwardedName] {
            let first = forwarded.split(separator: ",").first?.trimmingCharacters(in: .whitespaces)
            if let first, !first.isEmpty {
                return first
            }
        }
        return "local"
    }

    private func headerValue(_ fields: HTTPFields, _ name: String) -> String? {
        fields[headerName(name)]
    }

    private func parseBearer(_ fields: HTTPFields) -> String? {
        guard let auth = headerValue(fields, "Authorization") else { return nil }
        let trimmed = auth.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2,
              String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }
        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    private func isInitializeRequest(_ data: Data?) -> Bool {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["method"] as? String == "initialize" else {
            return false
        }
        return true
    }

    /// Returns the required scope for a `tools/call` of a write-gated tool, or
    /// `nil` for reads/initialize/other. Write-gated tools come from ``WriteToolGate``.
    private func requiredScope(for data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["method"] as? String == "tools/call",
              let params = json["params"] as? [String: Any],
              let tool = params["name"] as? String else {
            return nil
        }
        return gate.requiresWrite(tool) ? "openstack:write" : nil
    }

    // MARK: - Response mapping (spec §7.1.4)

    private func mapResponse(_ response: MCP.HTTPResponse, sessionID: String? = nil) -> Response {
        var hummingHeaders: HTTPFields = [:]
        for (name, value) in response.headers {
            if let name = HTTPField.Name(name) {
                hummingHeaders[name] = value
            }
        }
        if let sessionID {
            hummingHeaders[headerName("MCP-Session-Id")] = sessionID
        }

        if case .stream(let stream, _) = response {
            hummingHeaders[headerName("Content-Type")] = "text/event-stream"
            let body = ResponseBody(asyncSequence: AsyncStream<ByteBuffer> { continuation in
                let task = Task {
                    do {
                        for try await chunk in stream {
                            continuation.yield(ByteBuffer(data: chunk))
                        }
                    } catch {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            })
            return Response(status: .ok, headers: hummingHeaders, body: body)
        }

        let status = HTTPResponse.Status(code: response.statusCode)
        let bodyData = response.bodyData ?? Data()
        if headerValue(hummingHeaders, "Content-Type") == nil {
            hummingHeaders[headerName("Content-Type")] = "application/json"
        }
        return Response(status: status, headers: hummingHeaders, body: .init(byteBuffer: ByteBuffer(data: bodyData)))
    }
}

// MARK: - Fixed session id generator

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

// MARK: - Configured origin validator

/// Sliding-window (1-minute) counter of failed token validations per source
/// address (spec §7.1: `auth.failed_auth_per_minute`). The first `limit`
/// failures in a window are answered with 401; the next failure in the same
/// window is rejected with 429 instead, so brute-force probing stops hitting
/// Keystone after the budget is spent.
public actor FailedAuthLimiter {
    private let limitPerMinute: Int
    private let clock: @Sendable () -> Date
    private var counts: [String: (windowStart: Date, count: Int)] = [:]
    /// Fired on every failed validation with the reason (`"rejected"` for the
    /// first `limit` failures answered 401, `"rate_limited"` for the over-budget
    /// failure answered 429). Lets the serve layer feed the
    /// `osmcp_auth_failures_total{reason}` metric without the adapter depending
    /// on a metrics implementation.
    private let onFailure: @Sendable (String) -> Void

    public init(
        limitPerMinute: Int,
        clock: @escaping @Sendable () -> Date = { Date() },
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.limitPerMinute = limitPerMinute
        self.clock = clock
        self.onFailure = onFailure
    }

    /// Record a failed validation for `source`. Returns `false` when the
    /// budget for this window is exhausted and the caller should 429.
    public func record(source: String) -> Bool {
        let now = clock()
        var entry = counts[source]
        if let e = entry, now.timeIntervalSince(e.windowStart) > 60 {
            entry = nil
        }
        if entry == nil {
            entry = (windowStart: now, count: 0)
        }
        if entry!.count >= limitPerMinute {
            counts[source] = entry
            onFailure("rate_limited")
            return false
        }
        entry = (windowStart: entry!.windowStart, count: entry!.count + 1)
        counts[source] = entry
        // Opportunistic sweep of fully-expired windows (cheap at this scale).
        for (key, e) in counts where now.timeIntervalSince(e.windowStart) > 60 {
            counts[key] = nil
        }
        onFailure("rejected")
        return true
    }
}

/// An `HTTPRequestValidator` that 403s a request whose `Origin` header is not
/// in `allowedOrigins`. Mirrors the SDK's `OriginValidator` but driven by the
/// deployment's configured origins (spec §7.1.1). Requests without an `Origin`
/// header (non-browser clients) always pass.
private struct ConfiguredOriginValidator: MCP.HTTPRequestValidator, Sendable {
    let allowedOrigins: [String]

    func validate(_ request: MCP.HTTPRequest, context: MCP.HTTPValidationContext) -> MCP.HTTPResponse? {
        guard let origin = request.header("Origin") else { return nil }
        // `"*"` is a wildcard that allows any origin.
        let allowed = allowedOrigins.contains("*") || allowedOrigins.contains(origin)
        guard !allowed else { return nil }
        return .error(statusCode: 403, .invalidRequest("Forbidden: Origin not allowed"))
    }
}

// MARK: - Response convenience builders

private extension Response {
    static func json(_ status: HTTPResponse.Status, _ json: String) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    /// 429 when the caller exceeds the failed-auth rate limit (spec §7.1).
    static func tooManyRequests() -> Response {
        Response(
            status: .tooManyRequests,
            headers: [.retryAfter: "60", .contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"too many failed authentication attempts"}"#))
        )
    }

    /// 401 with a `WWW-Authenticate: Bearer error="invalid_token", resource_metadata=...` challenge.
    static func unauthorized(resourceMetadata: String?) -> Response {
        var challenge = #"Bearer error="invalid_token""#
        if let resourceMetadata {
            challenge += ", resource_metadata=\"\(resourceMetadata)\""
        }
        return Response(
            status: .unauthorized,
            headers: [.wwwAuthenticate: challenge, .contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"unauthorized"}"#))
        )
    }

    /// 403 with `error="insufficient_scope"` and the required scope.
    static func forbiddenInsufficientScope(required: String, resourceMetadata: String?) -> Response {
        // NOTE: use a normal interpolated string here — `#""#` raw strings do NOT
        // expand `\(...)` interpolations, which would leak a literal `\(required)`.
        var challenge = "Bearer error=\"insufficient_scope\", scope=\"\(required)\""
        if let resourceMetadata {
            challenge += ", resource_metadata=\"\(resourceMetadata)\""
        }
        return Response(
            status: .forbidden,
            headers: [.wwwAuthenticate: challenge, .contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"insufficient_scope"}"#))
        )
    }

    /// 403 for an audience mismatch.
    static func forbiddenAudience(resourceMetadata: String?) -> Response {
        var challenge = #"Bearer error="invalid_target""#
        if let resourceMetadata {
            challenge += ", resource_metadata=\"\(resourceMetadata)\""
        }
        return Response(
            status: .forbidden,
            headers: [.wwwAuthenticate: challenge, .contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_target"}"#))
        )
    }
}
