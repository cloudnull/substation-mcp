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

        guard let token = try? Token.decode(from: body) else {
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
        //  - an explicit `Content-Type` is sent via `extraHeaders` so the
        //    body is always presented as JSON (the transport default is JSON
        //    too, but being explicit keeps the mint unambiguous);
        //  - POSTs are not retried by the transport, so a transient network
        //    error is surfaced rather than re-sent (minting twice would
        //    create two tokens).
        let (status, responseBody, _) = try await transport.request(
            method: "POST",
            service: "keystone",
            path: "/v3/auth/tokens",
            body: body,
            tokenOverride: "",
            extraHeaders: [("Content-Type", "application/json")]
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

        guard let token = try? Token.decode(from: responseBody) else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Failed to decode minted token"
            )
        }
        return token
    }

    // MARK: - JSON body builders

    private static func appCredBody(id: String, secret: String) -> Data {
        var json = "{"
        json += "\"auth\":{"
        json += "\"identity\":{"
        json += "\"methods\":[\"application_credential\"],"
        json += "\"application_credential\":{"
        json += "\"id\":\"\(id)\","
        json += "\"secret\":\"\(secret)\""
        json += "}}}"
        json += "}"
        return Data(json.utf8)
    }

    private static func passwordBody(userID: String, domain: String?, password: String, projectName: String?) -> Data {
        var user = "\"name\":\"\(userID)\""
        if let d = domain {
            user += ",\"domain\":{\"name\":\"\(d)\"}"
        }
        user += ",\"password\":\"\(password)\""

        var auth = "\"identity\":{\"methods\":[\"password\"],\"user\":{\(user)}}"
        if let p = projectName {
            auth += ",\"scope\":{\"project\":{\"name\":\"\(p)\"}}"
        }
        var json = "{"
        json += "\"auth\":{"
        json += auth
        json += "}"
        json += "}"
        return Data(json.utf8)
    }
}

// MARK: - Token decoding

extension Token {
    /// Decode a Token from a Keystone token response body.
    public static func decode(from data: Data) throws -> Token {
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
        struct RawToken: Codable {
            let id: String?
            let expires_at: String?
            let project: RawIdentityRef?
            let domain: RawIdentityRef?
            let user: RawIdentityRef?
            let roles: [String]?
            let catalog: [RawCatalogEntry]?
        }
        struct RawTokenResponse: Codable {
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

        guard let id = raw.id,
              let expiresStr = raw.expires_at,
              let expires = Self.parseISO8601(expiresStr),
              let project = raw.project,
              let domain = raw.domain,
              let user = raw.user else {
            throw OpenStackError(
                service: "keystone",
                status: 500,
                message: "Missing required fields in token"
            )
        }

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
            project: IdentityRef(id: project.id, name: project.name, domain: project.domain?.name),
            domain: IdentityRef(id: domain.id, name: domain.name),
            user: IdentityRef(id: user.id, name: user.name, domain: user.domain?.name),
            roles: raw.roles ?? [],
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
