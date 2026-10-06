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

    public init(
        transport: Transport,
        cache: Cache,
        servedProjects: Set<String>,
        tokenCacheTTL: Duration = .seconds(60),
        policy: PolicyRoles = PolicyRoles(),
        logger: Logger = Logger(label: "token-validator")
    ) {
        self.transport = transport
        self.cache = cache
        self.servedProjects = servedProjects
        self.tokenCacheTTL = tokenCacheTTL
        self.policy = policy
        self.logger = logger
    }

    /// Validate a presented token ID. Returns the validated token with derived scopes.
    public func validate(_ tokenID: String) async throws -> ValidatedToken {
        let key = CacheKey(tokenID: tokenID, region: "_auth_", resource: "__token__", suffix: "")

        if let cached = await cache.get(key, ttl: tokenCacheTTL, as: Token.self) {
            let scopes = deriveScopes(roles: cached.roles, policy: policy)
            return ValidatedToken(token: cached, scopes: scopes)
        }

        let (status, body, _) = try await transport.request(
            method: "GET",
            service: "keystone",
            path: "/v3/auth/tokens",
            tokenOverride: tokenID
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
    public func mint(method: MintMethod) async throws -> Token {
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
                    projectName: method.projectName
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
        let (status, responseBody, _) = try await transport.request(
            method: "POST",
            service: "keystone",
            path: "/v3/auth/tokens",
            body: body,
            tokenOverride: "",
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
    /// correctly. The previous hand-built string interpolation broke on any
    /// password containing `"`, `\`, or a control character, producing invalid
    /// JSON that Keystone rejected with 400 "Expecting to find password in
    /// identity".
    private static func passwordBody(userID: String, domain: String?, password: String, projectName: String?) -> Data {
        var user: [String: Any] = ["name": userID]
        if let d = domain, !d.isEmpty {
            user["domain"] = ["name": d]
        }
        user["password"] = password

        var auth: [String: Any] = [
            "identity": [
                "methods": ["password"],
                "user": user,
            ],
        ]
        if let p = projectName, !p.isEmpty {
            auth["scope"] = ["project": ["name": p]]
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
