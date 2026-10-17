import Foundation
import Logging

/// Per-request identity authority. Validates a presented Keystone token ID
/// against the Keystone `GET /v3/auth/tokens` endpoint, caches the result
/// keyed by token ID, and derives scopes.
public actor TokenValidator {
    private let transport: Transport
    private let cache: Cache
    private let servedProjects: Set<String>
    private let tokenCacheTTL: Duration
    private let policy: PolicyRoles
    private let logger: Logger
    private let cloudsFileURL: URL?

    public init(
        transport: Transport,
        cache: Cache,
        servedProjects: Set<String>,
        tokenCacheTTL: Duration = .seconds(60),
        policy: PolicyRoles = PolicyRoles(),
        logger: Logger = Logger(label: "token-validator"),
        cloudsFileURL: URL? = nil
    ) {
        self.transport = transport
        self.cache = cache
        self.servedProjects = servedProjects
        self.tokenCacheTTL = tokenCacheTTL
        self.policy = policy
        self.logger = logger
        self.cloudsFileURL = cloudsFileURL
    }

    /// Validate a presented token ID. Returns the validated token with derived scopes.
    ///
    /// - Parameter region: The region the client logged in via. When non-nil, the
    ///   whoami call is made against that region's Keystone endpoint (resolved from
    ///   `cloudsFile`) instead of the standing/default transport target. This ensures
    ///   the service catalog reflects the selected region's endpoints — required for
    ///   multi-region clouds where each region has its own auth_url and catalog.
    public func validate(_ tokenID: String, region: String? = nil) async throws -> ValidatedToken {
        let key = CacheKey(tokenID: tokenID, region: "_auth_", resource: "__token__", suffix: "")

        if let cached = await cache.get(key, ttl: tokenCacheTTL, as: Token.self) {
            let scopes = deriveScopes(roles: cached.roles, policy: policy)
            return ValidatedToken(token: cached, scopes: scopes)
        }

        // Resolve the regional Keystone base when a region was selected at login.
        var overrideBase: URL? = nil
        if let region, !region.isEmpty {
            let file = LoginMinter.resolvedCloudsFile(cloudsFileURL)
            if let file, let url = LoginMinter.regionAuthURL(region: region, cloudsFile: file) {
                overrideBase = url
            }
        }

        let (status, body, _) = try await transport.request(
            method: "GET",
            service: "keystone",
            path: "/v3/auth/tokens",
            tokenOverride: tokenID,
            overrideBase: overrideBase
        )

        guard status == 200 else {
            throw OpenStackError.normalize(
                body: body,
                status: status,
                service: "keystone",
                requestID: nil,
                hasAccessRules: false
            )
        }

        guard let token = try? Token.decode(from: body, tokenID: tokenID) else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Failed to decode token response"
            )
        }

        guard servedProjects.isEmpty || servedProjects.contains(token.project.id) else {
            throw OpenStackError(
                service: "keystone",
                status: 403,
                message: "Token project '\(token.project.id)' is not served by this instance"
            )
        }

        let timeToExpiry = token.expiresAt.timeIntervalSinceNow
        let ttl = min(tokenCacheTTL, .seconds(max(timeToExpiry, 1)))
        await cache.put(key, ttl: ttl, value: token)

        let scopes = deriveScopes(roles: token.roles, policy: policy)
        return ValidatedToken(token: token, scopes: scopes)
    }
}

/// Facilitates login by minting a Keystone token.
public actor LoginMinter {
    private let transport: Transport
    private let logger: Logger

    public init(transport: Transport, logger: Logger = Logger(label: "login-minter")) {
        self.transport = transport
        self.logger = logger
    }

    /// Mint a token using the given method.
    public func mint(method: MintMethod, region: String? = nil, domainScoped: Bool = false, cloudsFile: URL? = nil) async throws -> Token {
        let body: Data

        let id = method.appCredID
        let secretBytes = method.appCredSecret
        let uid = method.userID
        let pw = method.password

        switch method.kind {
        case .applicationCredential:
            if let id, let secretBytes {
                let secretString = String(decoding: secretBytes.map { UInt8($0) }, as: UTF8.self)
                body = Self.appCredBody(id: id, secret: secretString)
            } else {
                throw OpenStackError(
                    service: "keystone",
                    status: 400,
                    message: "Missing app-cred fields"
                )
            }

        case .password:
            if let uid, let pw {
                body = Self.passwordBody(
                    userID: uid,
                    domain: method.domain,
                    password: pw,
                    projectName: method.projectName,
                    domainScoped: domainScoped
                )
            } else {
                throw OpenStackError(
                    service: "keystone",
                    status: 400,
                    message: "Missing password auth fields"
                )
            }
        }

        // The token-mint endpoint needs a fresh, clean request:
        //  - `tokenOverride: ""` suppresses the `X-Auth-Token` header (a
        //    bogus token there makes Keystone reject the mint) instead of
        //    falling back to the standing token source;
        //  - the Transport already sends `Content-Type: application/json` on
        //    every request, so we must NOT add it again as an extraHeader —
        //    doing so produces a DUPLICATE Content-Type header, which Keystone
        //    3.14 rejects with 400 "Expecting to find application/json in
        //    Content-Type header";
        //  - POSTs are not retried by the transport, so a transient network
        //    error is surfaced rather than re-sent (minting twice would
        //    create two tokens).
        //
        // The minted token id is NOT in the response body (Keystone omits
        // `token.id` on mint) — it is carried in the `X-Subject-Token` response
        // header. We capture that header via `captureSubjectToken` and pass it
        // as the authoritative token id to `Token.decode`, so the stored token
        // has a real id (usable later as `X-Auth-Token`) rather than the
        // literal fallback `"unknown"`.
        // A tiny @unchecked-Sendable box so the (Sendable) closure can capture
        // a mutable target across the await without tripping region isolation.
        // The Transport invokes it exactly once, synchronously, on the
        // success path — no concurrent writes.
        final class SubjectTokenBox: @unchecked Sendable {
            var value: String?
        }
        let box = SubjectTokenBox()
        // When a region is specified, look up that region's Keystone endpoint
        // from the cloud config so multi-region clouds (each region having its
        // own auth_url) can be selected from the login/OAuth form.
        var overrideBase: URL? = nil
        if let region, !region.isEmpty {
            guard let file = Self.resolvedCloudsFile(cloudsFile), let regionURL = Self.regionAuthURL(region: region, cloudsFile: file) else {
                throw OpenStackError(
                    service: "keystone",
                    status: 400,
                    message: "Region '\(region)' is not configured in clouds.yaml"
                )
            }
            overrideBase = regionURL
        }
        let (status, responseBody, _) = try await transport.request(
            method: "POST",
            service: "keystone",
            path: "/v3/auth/tokens",
            body: body,
            tokenOverride: "",
            overrideBase: overrideBase,
            captureSubjectToken: { box.value = $0 }
        )

        guard status == 201 else {
            throw OpenStackError.normalize(
                body: responseBody,
                status: status,
                service: "keystone",
                requestID: nil,
                hasAccessRules: false
            )
        }

        guard let token = try? Token.decode(from: responseBody, tokenID: box.value) else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Failed to decode minted token"
            )
        }
        return token
    }

    /// A project returned by `detectProjects`.
    public struct DetectedProject: Sendable {
        public let id: String
        public let name: String
        public let domainName: String?
    }

    /// Detect the projects a user can access, using their username + password.
    ///
    /// Mints a **domain-scoped** (unscoped-project) token — no project in the
    /// auth body — then lists the caller's projects via `GET /v3/projects`.
    /// This is what the login/OAuth "Detect" button calls so the operator can
    /// pick a project from what the account actually reaches, instead of
    /// typing it blind. Application credentials are NOT supported here: they
    /// are already bound to a single project at creation time, so there is
    /// nothing to detect.
    ///
    /// - Returns: the list of accessible projects (may be empty).
    /// - Throws: `OpenStackError` if the credentials are invalid or Keystone
    ///   rejects the mint/list. The thrown message is intentionally not echoed
    ///   to the browser (it may quote credential material).
    public func detectProjects(user: String, domain: String?, password: String, region: String? = nil, cloudsFile: URL? = nil) async throws -> [DetectedProject] {
        // Live-verified against Rackspace IAD3 (user cloudnull @ rackspace_cloud_domain):
        //   - unscoped mint WITHOUT user.domain            → 400 "Expecting to find domain in user"
        //   - unscoped mint WITH user.domain (the real one) → 201; token id from X-Subject-Token
        //   - unscoped mint with WRONG user domain ("default") → 401
        //   - DOMAIN-SCOPED mint                            → 401
        //   - PROJECT-SCOPED mint                           → 401
        //   - GET /v3/projects (admin listing) with that token      → 403 identity:list_projects
        //   - GET /v3/users/{user_id}/projects (user id = fdff75…
        //     taken from the MINT RESPONSE, not the token header)    → 200, projects
        //
        // Consequences baked into this implementation:
        //   1. The caller's domain is REQUIRED — substituting "default" or omitting it
        //      makes Keystone reject valid credentials with a 401.
        //   2. Mint unscoped only — scoped variants are rejected by these endpoints.
        //   3. The user id for the per-user listing MUST come from the mint response
        //      body (`token.user.id`), never from the X-Subject-Token header (they differ).
        //   4. The listing MUST hit the same regional Keystone as the mint: tokens are
        //      not portable across regions and catalog region tags don't match form values.
        guard let d = (domain?.isEmpty == false) ? domain : nil else {
            throw OpenStackError(service: "keystone", status: 400,
                                  message: "domain_required: user domain is required for project detection")
        }
        // Resolve the region's Keystone endpoint up front so mint AND the project
        // listing below use the exact same regional auth_url.
        var regionalBase: URL? = nil
        if let region, !region.isEmpty {
            guard let file = Self.resolvedCloudsFile(cloudsFile), let url = Self.regionAuthURL(region: region, cloudsFile: file) else {
                throw OpenStackError(service: "keystone", status: 400,
                                      message: "Region '\(region)' is not configured in clouds.yaml")
            }
            regionalBase = url
        }
        // 1. Mint an UNSCOPED token carrying the user's domain — exactly the shape the
        //    working /login path uses. No scope block at all.
        let token: Token
        do {
            token = try await mint(
                method: .password(userID: user, domain: d, password: password, projectName: nil),
                region: region,
                domainScoped: false,
                cloudsFile: Self.resolvedCloudsFile(cloudsFile)
            )
        } catch {
            // Mint failed: credentials/domain/region problem. The raw error is
            // deliberately NOT echoed (it may quote credential material); the
            // caller matches on the "mint_failed" substring.
            throw OpenStackError(service: "keystone", status: 401,
                                  message: "mint_failed")
        }

        // 2. List the user's projects. Different clouds expose this differently:
        //    - GET /v3/users/{id}/projects works for regular member accounts on
        //      Rackspace (and similar) where the broader endpoint is admin-only.
        //    - GET /v3/projects works on clouds where the token carries the
        //      identity:list_projects role (e.g. many community OpenStacks).
        //    We try the member-friendly per-user endpoint first, then fall back
        //    to the global listing, so detection works across clouds without
        // We will use the loop below to try candidate paths.
        let userID = token.user.id
        guard !userID.isEmpty, userID != "unknown" else {
            throw OpenStackError(service: "keystone", status: 500,
                                  message: "could not determine user id from mint response")
        }
        let candidatePaths = ["/v3/users/\(userID)/projects", "/v3/projects"]
        var lastError: Error? = nil
        for path in candidatePaths {
            do {
                return try await self.listProjects(token: token, path: path, baseOverride: regionalBase)
            } catch {
                // Only fall through to the next endpoint when this one was
                // rejected (403/404). A transport-level failure (network, 5xx)
                // is not a reason to retry a different path — surface it.
                let isOpenStackErr = error is OpenStackError
                let code = (error as? OpenStackError)?.status ?? 0
                if isOpenStackErr && (code == 403 || code == 404) {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        // Both endpoints were rejected. Surface the most informative error.
        if let lastError {
            let msg = "\(lastError)"
            if msg.contains("list_forbidden") || msg.contains("not authorized") || msg.contains("403") {
                throw OpenStackError(service: "keystone", status: 403,
                                      message: "list_forbidden: user lacks permission to list their projects")
            }
            throw lastError
        }
        throw OpenStackError(service: "keystone", status: 500,
                              message: "no project-listing endpoint available")
    }

    /// Page through a Keystone project-listing endpoint and decode the results.
    ///
    /// `baseOverride` must be the SAME Keystone URL the token was minted
    /// against (the selected region's auth_url). Catalog-based endpoint
    /// selection is unreliable here: Rackspace's unscoped token catalogs do
    /// not tag identity endpoints with the region in a way that matches the
    /// form value, and hitting the wrong regional endpoint would either leak
    /// another region's projects or fail outright.
    private func listProjects(token: Token, path: String, baseOverride: URL?) async throws -> [DetectedProject] {
        var projects: [DetectedProject] = []
        var marker: String? = nil
        let limit = 100
        for _ in 0..<10 { // hard cap: 1000 projects
            var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
            if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
            let (status, body, _) = try await transport.request(
                method: "GET",
                service: "keystone",
                path: path,
                query: query,
                tokenOverride: token.id,
                overrideBase: baseOverride
            )
            guard status == 200 else {
                let normalized = OpenStackError.normalize(body: body, status: status, service: "keystone", requestID: nil, hasAccessRules: false)
                if status == 403 {
                    throw OpenStackError(service: "keystone", status: 403,
                                          message: "list_forbidden: user lacks permission to list their projects")
                }
                throw normalized
            }
            guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let arr = obj["projects"] as? [[String: Any]] else {
                break
            }
            for p in arr {
                guard let id = p["id"] as? String, let name = p["name"] as? String else { continue }
                let dom = (p["domain"] as? [String: Any])?["name"] as? String
                projects.append(DetectedProject(id: id, name: name, domainName: dom))
            }
            // Next-page marker: last project id (Keystone's default sort).
            if arr.count < limit { break }
            marker = (arr.last as? [String: Any])?["id"] as? String
            if marker == nil { break }
        }
        return projects
    }

    // MARK: - Region → Keystone auth URL lookup

    /// Resolve the clouds.yaml file for region lookups. When `explicit` is
    /// provided (the serve config's `clouds.file`), it wins; otherwise fall
    /// back to the same search order as `CloudConfig.resolvedFileURL`.
    static func resolvedCloudsFile(_ explicit: URL?) -> URL? {
        if let explicit { return explicit }
        if let envPath = ProcessInfo.processInfo.environment["OS_CLIENT_CONFIG_FILE"] {
            return URL(fileURLWithPath: envPath)
        }
        return CloudConfig.resolvedFileURL(explicit: nil)
    }

    /// Look up the Keystone `auth_url` for a named region from the process's
    /// clouds.yaml. Multi-region clouds (e.g. Rackspace IAD3/DFW3/SJC3) have
    /// one cloud entry per region, each with its own `auth_url`. The login and
    /// OAuth forms let the user pick a region; this resolves it to the correct
    /// Keystone endpoint so the token is minted against the right identity API.
    static func regionAuthURL(region: String, cloudsFile: URL) -> URL? {
        // Explicit file argument: the caller passes its own already-resolved
        // clouds.yaml path (serve's config.cloudsFile ?? OS_CLIENT_CONFIG_FILE),
        // so this stays correct in containers where the baked-in path is not on
        // CloudConfig's default search list.
        guard let config = try? CloudConfig.loadStrict(file: cloudsFile) else {
            return nil
        }
        // Match against regionName OR the cloud name itself (some configs use the name as region).
        return config.clouds.first { $0.regionName == region || $0.name == region }?.authURL
    }

    // MARK: - JSON body builders

    /// Build a Keystone app-credential mint body. JSON-serialized so a secret
    /// containing `"`, `\`, or a control character is escaped correctly. The
    /// previous hand-built string had the same invalid-JSON bug as
    /// `passwordBody`, which made Keystone reject the mint with 400.
    private static func appCredBody(id: String, secret: String) -> Data {
        let body: [String: Any] = [
            "auth": [
                "identity": [
                    "methods": ["application_credential"],
                    "application_credential": [
                        "id": id,
                        "secret": secret,
                    ],
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// Build a Keystone password-auth mint body. Uses `JSONSerialization` so
    /// user-supplied strings (user, domain, password, project) are JSON-escaped
    /// correctly.
    ///
    /// Two structural details (both verified against keystoneauth1, the library
    /// the `openstack` CLI uses):
    ///
    ///  1. When `methods: ["password"]`, the user object must be nested under
    ///     an `identity.password` key — i.e.
    ///     `{"auth":{"identity":{"methods":["password"],
    ///       "password":{"user":{"name":...,"domain":...,"password":...}}}}}`.
    ///     Keystone dispatches to the sub-object named after the method.
    ///     Placing `user` directly under `identity` made Keystone look for the
    ///     `password` sub-object, not find it, and reject the mint with 400
    ///     "Expecting to find password in identity".
    ///
    ///  2. A project-scoped token requires the project to carry a `domain` —
    ///     `{"scope":{"project":{"name":...,"domain":{"name":...}}}}`. Omitting
    ///     it makes Keystone reject the mint with 400 "Expecting to find domain
    ///     in project". keystoneauth1 sends `project_domain_name` from the
    ///     clouds.yaml; we default the project domain to the user's domain
    ///     (the common case, e.g. both `default`).
    private static func passwordBody(userID: String, domain: String?, password: String, projectName: String?, domainScoped: Bool = false) -> Data {
        var user: [String: Any] = ["name": userID]
        if let d = domain, !d.isEmpty {
            user["domain"] = ["name": d]
        }
        user["password"] = password

        var auth: [String: Any] = [
            "identity": [
                "methods": ["password"],
                "password": ["user": user],
            ],
        ]
        if let p = projectName, !p.isEmpty {
            var project: [String: Any] = ["name": p]
            // A project-scoped token must name the project's domain. Default to
            // the user's domain (the standard layout) when present.
            if let d = domain, !d.isEmpty {
                project["domain"] = ["name": d]
            }
            auth["scope"] = ["project": project]
        } else if domainScoped, let d = domain, !d.isEmpty {
            // Domain-scoped token: no project, but scoped to a domain. This is
            // what project-detection needs — an unscoped token is rejected by
            // some clouds (e.g. Rackspace), while a domain-scoped token carries
            // enough context to list the caller's accessible projects.
            auth["scope"] = ["domain": ["name": d]]
        }
        let body: [String: Any] = ["auth": auth]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }
}

// MARK: - Token decoding

extension Token {
    /// Decode a Token from a Keystone token response body.
    ///
    /// - Parameter tokenID: the token as presented on the request (the
    ///   `X-Auth-Token` / bearer). Keystone's whoami body omits `token.id`
    ///   (it is the request token, not a response field), so when the body has
    ///   no id we fall back to this — NOT "unknown" — so downstream calls can
    ///   send the real token upstream.
    public static func decode(from data: Data, tokenID: String? = nil) throws -> Token {
        struct RawDomain: Codable {
            let id: String
            let name: String?
        }
        struct RawIdentityRef: Codable {
            let id: String
            let name: String?
            let domain: RawDomain?
        }
        struct RawCatalogEndpoint: Codable {
            let region: String?
            let interface: String?
            let url: String
        }
        struct RawCatalogEntry: Codable {
            let type: String
            let name: String?
            let endpoints: [RawCatalogEndpoint]?
        }
        // Keystone v3 may express a role either as a plain string ("admin") or as
        // an object {"id","name"} (the default for live clouds). Accept both.
        struct RawRoleObject: Decodable {
            let id: String?
            let name: String?
        }
        struct RawRole: Decodable {
            let id: String?
            let name: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) {
                    name = str
                    id = nil
                } else {
                    let obj = try container.decode(RawRoleObject.self)
                    name = obj.name
                    id = obj.id
                }
            }
        }
        struct RawToken: Decodable {
            let id: String?
            let expires_at: String?
            let project: RawIdentityRef?
            let domain: RawIdentityRef?
            let user: RawIdentityRef?
            let roles: [RawRole]?
            let catalog: [RawCatalogEntry]?
        }
        struct RawTokenResponse: Decodable {
            let token: RawToken
        }

        var raw: RawToken
        if let wrapped = try? JSONDecoder().decode(RawTokenResponse.self, from: data) {
            raw = wrapped.token
        } else if let direct = try? JSONDecoder().decode(RawToken.self, from: data) {
            raw = direct
        } else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Unrecognized token response format"
            )
        }

        guard let expiresStr = raw.expires_at,
              let expires = Self.parseISO8601(expiresStr),
              let user = raw.user else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Missing required fields in token"
            )
        }

        // Unscoped tokens (application credentials minted without a project
        // scope, domain-scoped tokens, etc.) omit `project` from the whoami
        // body. Keystone's whoami response for an unscoped token carries the
        // user, domain, roles, and catalog but no project. Synthesize a
        // sentinel project so the Token (which requires a project) is well-
        // formed. The sentinel is clearly marked so downstream code that
        // checks `servedProjects` can recognize it.
        let project: IdentityRef
        if let p = raw.project {
            project = IdentityRef(id: p.id, name: p.name, domain: p.domain?.name)
        } else {
            project = IdentityRef(id: "unscoped", name: "unscoped", domain: nil)
        }

        // Keystone omits the token `id` from the whoami body (it is the request
        // token, not a field in the response) and omits a top-level `domain` on
        // project-scoped tokens. Synthesize sensible values for both. The id
        // falls back to the presented tokenID (the real token to send upstream),
        // never "unknown", so data-plane calls carry a valid token.
        let id = raw.id ?? tokenID ?? "unknown"
        let domain = raw.domain
            .map { IdentityRef(id: $0.id, name: $0.name) }
            ?? IdentityRef(id: user.domain?.id ?? "default", name: user.domain?.name)

        let catalogEntries: [CatalogEntry] = (raw.catalog ?? []).compactMap { entry in
            let endpoints: [CatalogEndpoint] = (entry.endpoints ?? []).compactMap { ep in
                guard let url = URL(string: ep.url) else { return nil }
                return CatalogEndpoint(
                    region: ep.region ?? "RegionOne",
                    interface: ep.interface ?? "public",
                    url: url
                )
            }
            return CatalogEntry(
                type: entry.type,
                name: entry.name ?? entry.type,
                endpoints: endpoints
            )
        }

        return Token(
            id: id,
            expiresAt: expires,
            project: project,
            domain: domain,
            user: IdentityRef(id: user.id, name: user.name, domain: user.domain?.name),
            roles: (raw.roles ?? []).compactMap { $0.name },
            catalog: catalogEntries
        )
    }

    private static func parseISO8601(_ str: String) -> Date? {
        // Try with fractional seconds first, then without
        var formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
