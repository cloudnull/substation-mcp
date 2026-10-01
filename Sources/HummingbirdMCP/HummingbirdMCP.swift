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

    private func installLogin(
        on router: Router<BasicRequestContext>,
        endpoint: String,
        login: (@Sendable (LoginRequest) async -> LoginResponse)?
    ) {
        let loginPath = endpoint + "/login"
        let loginRoutePath = RouterPath(loginPath)
        router.get(loginRoutePath) { _, _ in
            let html = """
            <!DOCTYPE html><html><head><title>OpenStack MCP Login</title></head><body>
            <h1>OpenStack MCP Login</h1>
            <form method="POST" action="\(loginPath)">
              <label>Method:
                <select name="method">
                  <option value="app-cred">Application credential</option>
                  <option value="password">User + password</option>
                </select>
              </label><br>
              <label>Elicitation ID: <input name="elicitationId" value="E1"></label><br>
              <label>App cred ID: <input name="appCredId"></label><br>
              <label>Secret: <input name="secret" type="password"></label><br>
              <label>User: <input name="userName"></label><br>
              <label>Password: <input name="password" type="password"></label><br>
              <label>Project: <input name="projectName"></label><br>
              <button type="submit">Log in</button>
            </form>
            </body></html>
            """
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
                    <!DOCTYPE html><html><head><title>Login complete</title></head><body>
                    <h1>Login complete</h1>
                    <p>Your token was stored. You may close this tab.</p>
                    <p>Token ID: <code>\(result.tokenID)</code></p>
                    </body></html>
                    """
                } else {
                    // Mint failed: the completion page's "Token ID" element is
                    // empty, so the response is an error page instead. The
                    // failure reason is intentionally generic (the underlying
                    // error may quote credential material).
                    html = """
                    <!DOCTYPE html><html><head><title>Login failed</title></head><body>
                    <h1>Login failed</h1>
                    <p>Credentials could not be validated. Please try again or
                    contact your cloud administrator.</p>
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
