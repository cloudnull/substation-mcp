import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - Stateless OAuth 2.1 authorization server (P2)
//
// The MCP server fronts Keystone as an OAuth 2.1 authorization server using
// the authorization-code + PKCE grant (RFC 7636). It is **stateless**:
//   - authorization codes and `stst.at.` access tokens are HS256 JWTs signed
//     with the shared OAuth server secret,
//   - clients register via **deterministic** DCR (RFC 7591): the `client_id`
//     is derived from the normalized registration payload, so there is no
//     server-side client store and registration is idempotent,
//   - there is no in-memory code store: a code is single-use by construction
//     because its claims are bound to exactly one (client_id, redirect_uri,
//     code_challenge) and the embedded Keystone token id lets the token
//     endpoint re-derive the identity without any stored grant.
//
// The authorization endpoint mints a fresh Keystone token via the same
// `LoginMinter` the URL-mode login page uses, so a human (or a DEBUG
// `dev-mint`) can complete the browser step, and the code returned in the
// redirect URL carries that Keystone token id.
//
// The MCP gate (HummingbirdMCP) receives a `CompositeTokenValidator` that
// routes `stst.at.`-prefixed bearers to JWT verification and everything else
// to the existing Keystone `TokenValidator` — so P1 bearer auth is untouched.

/// A verified authorization-code grant, reconstructed purely from the code
/// JWT's claims.
struct OAuthCodeGrant: Sendable {
    let clientID: String
    let redirectURI: String
    let codeChallenge: String     // PKCE S256
    let scope: String             // space-separated, may be empty
    let keystoneTokenID: String   // "osk"
    let projectID: String         // "prj"
    let keystoneExpiry: Date      // "kexp"
}

/// Errors a token / authorize request can fail with, mapped to RFC 6749 §5.2
/// `error` + `error_description`.
enum OAuthProtocolError: Error {
    case invalidRequest(description: String)     // 400
    case invalidClient(description: String)      // 400
    case invalidGrant(description: String)       // 400
    case unsupportedGrantType                    // 400
    case unauthorizedClient(description: String) // 400

    var error: String {
        switch self {
        case .invalidRequest:
            return "invalid_request"
        case .invalidClient:
            return "invalid_client"
        case .invalidGrant:
            return "invalid_grant"
        case .unsupportedGrantType:
            return "unsupported_grant_type"
        case .unauthorizedClient:
            return "unauthorized_client"
        }
    }
    var description: String {
        switch self {
        case .invalidRequest(let d), .invalidClient(let d), .invalidGrant(let d),
             .unauthorizedClient(let d):
            return d
        case .unsupportedGrantType:
            return "Unsupported grant_type; only authorization_code is supported."
        }
    }
}

public struct OAuthAuthorizationServer: Sendable {
    /// Shared OAuth HS256 signing secret.
    public let secret: String
    public let issuer: String
    public let codeTTL: Int
    public let tokenTTL: Int
    public let endpoint: String        // MCP base path, e.g. "/v1"
    /// Whether the DEBUG-only dev-mint helper is mounted.
    public let devMintEnabled: Bool
    /// Mints the Keystone token at the authorize step (same seam the login
    /// page uses). Kept on the server so the authorize handler + dev-mint can
    /// produce a token without a second actor hop from the router.
    public let minter: LoginMinter
    /// Re-validates the embedded Keystone token id at the token endpoint
    /// (cached) — the same instance the MCP gate uses, so one cache is shared.
    public let tokenValidator: TokenValidator
    public let logger: Logger
    /// The short-lived single-use authorization-code replay set. The *only*
    /// piece of server-side state (a stateless AS otherwise holds nothing);
    /// instance-local so each AS (and each test) has its own replay window.
    public let codeReplayStore: CodeReplayStore

    public init(
        secret: String,
        issuer: String,
        codeTTL: Int = 120,
        tokenTTL: Int = 3600,
        endpoint: String = "/v1",
        devMintEnabled: Bool = false,
        minter: LoginMinter,
        tokenValidator: TokenValidator,
        codeReplayStore: CodeReplayStore = CodeReplayStore(ttl: 300),
        sharedReplayCache: Bool = false,
        sharedReplayCacheOverride: (host: String, port: Int)? = nil,
        logger: Logger = Logger(label: "oauth-as")
    ) {
        self.secret = secret
        self.issuer = issuer
        self.codeTTL = codeTTL
        self.tokenTTL = tokenTTL
        self.endpoint = endpoint
        self.devMintEnabled = devMintEnabled
        self.minter = minter
        self.tokenValidator = tokenValidator
        // Shared (memcached) replay store when requested: the endpoint is
        // discovered from each token's Keystone service catalog (spec §6.5)
        // unless an explicit override is configured. Falls back to the local
        // store on any cache failure (fail-open), so this never breaks the
        // flow.
        if sharedReplayCache {
            let override = sharedReplayCacheOverride
            self.codeReplayStore = CodeReplayStore(
                shared: SharedCodeReplayStore(
                    client: MemcachedClient(logger: Logger(label: "oauth-as.memcached")),
                    resolver: ReplayStoreEndpointResolver(
                        overrideHost: override?.host,
                        overridePort: override?.port
                    ),
                    issuer: issuer
                ),
                logger: Logger(label: "oauth-as.replay")
            )
        } else {
            self.codeReplayStore = codeReplayStore
        }
        self.logger = logger
    }

    /// The OAuth path prefix, e.g. `/v1/oauth`.
    public var path: String {
        let trimmed = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return trimmed + "/oauth"
    }

    // MARK: - RFC 8414 metadata

    public func metadata() -> [String: Any] {
        // RFC 8414 §2: the endpoints MUST be absolute URIs. They are derived
        // from the issuer (which is itself absolute — `<public_url><endpoint>/oauth`)
        // so they stay correct behind a proxy regardless of the request Host.
        [
            "issuer": issuer,
            "authorization_endpoint": "\(issuer)/authorize",
            "token_endpoint": "\(issuer)/token",
            "registration_endpoint": "\(issuer)/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["client_secret_basic", "none"],
            "scopes_supported": ["openstack:read", "openstack:write"],
        ]
    }

    // MARK: - Deterministic DCR (RFC 7591)

    /// Derive the deterministic `client_id` from a normalized registration
    /// payload. Identical registrations always yield the same `client_id`
    /// (the SHA-256 of the sorted-keys JSON of the normalized payload), so
    /// registration is idempotent with no server-side client store.
    public static func deriveClientID(from normalized: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            return "client_" + sha256Hex(String(normalized.count))
        }
        let digest = SHA256.hash(data: data)
        return "client_" + String(Base64URL.encode(Data(digest)).prefix(32))
    }

    /// Normalize an RFC 7591 registration body to the stable DCR key shape:
    /// only the client-identifying fields, each array sorted.
    static func normalizeRegistration(_ body: [String: Any]) -> [String: Any] {
        var norm: [String: Any] = [:]
        if let name = body["client_name"] as? String { norm["client_name"] = name }
        if let redirect = body["redirect_uris"] as? [String], !redirect.isEmpty {
            norm["redirect_uris"] = redirect.sorted()
        }
        if let grants = body["grant_types"] as? [String] {
            norm["grant_types"] = grants.sorted()
        }
        if let responseTypes = body["response_types"] as? [String] {
            norm["response_types"] = responseTypes.sorted()
        }
        if let method = body["token_endpoint_auth_method"] as? String {
            norm["token_endpoint_auth_method"] = method
        }
        return norm
    }

    /// The deterministic `client_secret` for a derived `client_id`, bound to
    /// the server secret so a different AS cannot forge it.
    static func deriveClientSecret(clientID: String, serverSecret: String) -> String {
        hmacSHA256Base64URL(key: serverSecret, message: "substation-dcr-" + clientID)
    }

    /// Whether `redirectURI` is a permitted loopback redirect (RFC 8252):
    /// http/https on localhost / 127.0.0.1 / ::1 with any port and path.
    static func isLoopbackRedirectURI(_ redirectURI: String) -> Bool {
        guard let url = URL(string: redirectURI),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return false }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        return (scheme == "http" || scheme == "https") && loopbackHosts.contains(host)
    }
    // MARK: - JWT mint/verify (authorization code + access token)

    /// Mint an authorization-code JWT. The claims are bound to the
    /// (client_id, redirect_uri, code_challenge) triple and carry the minted
    /// Keystone token id, its project, and its expiry, so the token endpoint
    /// is stateless and can cap the access-token TTL without a round-trip.
    func mintCode(
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        scope: String,
        keystoneTokenID: String,
        projectID: String,
        keystoneTokenExpiry: Date
    ) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        // A code can never outlive the Keystone token it wraps.
        let codeExp = min(now + codeTTL, Int(keystoneTokenExpiry.timeIntervalSince1970))
        let claims: [String: AnyCodableValue] = [
            "iss": .string(issuer),
            "aud": .string("substation-mcp"),
            "iat": .int(now),
            "exp": .int(codeExp),
            "jti": .string(UUID().uuidString),
            "client_id": .string(clientID),
            "redirect_uri": .string(redirectURI),
            "challenge": .string(codeChallenge),
            "sco": .string(scope),
            "osk": .string(keystoneTokenID),
            "prj": .string(projectID),
            "kexp": .int(Int(keystoneTokenExpiry.timeIntervalSince1970)),
        ]
        return signJWT(claims: claims, secret: secret)
    }

    /// Verify and parse an authorization-code JWT, enforcing the bound
    /// client_id and redirect_uri. PKCE is checked separately at the token
    /// endpoint (it compares `S256(code_verifier)` against the stored
    /// challenge). Throws on expiry, bad signature, or any bound mismatch.
    func verifyCode(_ code: String, clientID: String, redirectURI: String) throws -> OAuthCodeGrant {
        let now = Int(Date().timeIntervalSince1970)
        let jwt = try verifyJWT(code, secret: secret, now: now, expectedIssuer: issuer)
        guard
            let osk = jwt.string("osk"), !osk.isEmpty,
            let prj = jwt.string("prj"), !prj.isEmpty,
            let challenge = jwt.string("challenge"), !challenge.isEmpty,
            let cid = jwt.string("client_id"),
            let ruri = jwt.string("redirect_uri"),
            let kexp = jwt.int("kexp")
        else { throw OAuthProtocolError.invalidGrant(description: "Malformed authorization code.") }
        guard constantTimeEquals(cid, clientID) else {
            throw OAuthProtocolError.unauthorizedClient(description: "client_id does not match the authorization code.")
        }
        guard ruri == redirectURI else {
            throw OAuthProtocolError.invalidGrant(description: "redirect_uri does not match the authorization request.")
        }
        return OAuthCodeGrant(
            clientID: cid,
            redirectURI: ruri,
            codeChallenge: challenge,
            scope: jwt.string("sco") ?? "",
            keystoneTokenID: osk,
            projectID: prj,
            keystoneExpiry: Date(timeIntervalSince1970: TimeInterval(kexp))
        )
    }

    /// Mint a `stst.at.`-prefixed access token embedding the validated
    /// Keystone token id + project + scopes. The expiry is capped at both the
    /// configured `tokenTTL` and the Keystone token's own expiry.
    func mintAccessToken(
        keystoneTokenID: String,
        projectID: String,
        scopes: [String],
        clientID: String,
        keystoneTokenExpiry: Date
    ) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let exp = min(now + tokenTTL, Int(keystoneTokenExpiry.timeIntervalSince1970))
        let claims: [String: AnyCodableValue] = [
            "iss": .string(issuer),
            "aud": .string("substation-mcp"),
            "iat": .int(now),
            "exp": .int(exp),
            "jti": .string(UUID().uuidString),
            "client_id": .string(clientID),
            "osk": .string(keystoneTokenID),
            "prj": .string(projectID),
            "sco": .string(scopes.joined(separator: " ")),
        ]
        let jwt = signJWT(claims: claims, secret: secret) ?? ""
        return OAuthAccessTokenPrefix + jwt
    }

    /// Verify a `stst.at.` access token and resolve the embedded Keystone
    /// token id through the existing, caching `TokenValidator`, returning the
    /// `ValidatedIdentity` the MCP gate needs. The JWT signature/issuer/expiry
    /// are checked first; the Keystone token is then re-validated (cached) so
    /// steady-state MCP requests make no extra round-trip.
    func validateAccessToken(_ bearer: String, validator: TokenValidator, logger: Logger) async throws -> ValidatedIdentity {
        // bearer is guaranteed to start with the prefix by the composite.
        let jwtPart = String(bearer.dropFirst(OAuthAccessTokenPrefix.count))
        let now = Int(Date().timeIntervalSince1970)
        do {
            let verified = try verifyJWT(jwtPart, secret: secret, now: now, expectedIssuer: issuer)
            guard let at = verified.asOAuthAccessToken() else {
                throw TokenValidationError(message: "Access token JWT missing required claims")
            }
            let vt = try await validator.validate(at.tokenID)
            return ValidatedIdentity(
                tokenID: vt.token.id,
                projectID: vt.token.project.id,
                scopes: at.scopes.isEmpty ? vt.scopes.map { $0.rawValue } : at.scopes,
                raw: AnyTokenPayload(data: try JSONEncoder().encode(vt.token))
            )
        } catch let e as OAuthJWTError {
            logger.debug("OAuth access token verification failed", metadata: ["error": "\(e)"])
            throw TokenValidationError(message: "OAuth access token verification failed")
        }
    }
}

// MARK: - Composite token validator (P2: stst.at.* → OAuth, else → Keystone)

/// Routes bearer tokens to the right validator on every MCP request:
/// `stst.at.`-prefixed tokens go to the stateless OAuth AS (JWT verify +
/// embedded Keystone id delegation); anything else falls through to the
/// existing Keystone `AppTokenValidator`, so P1 bearer auth is byte-for-byte
/// unchanged.
///
/// The OAuth path resolves the embedded Keystone token id through the shared
/// caching `TokenValidator` (the same instance `AppTokenValidator` wraps), so
/// an OAuth session and a raw-Keystone session validate against one cache.
public struct CompositeTokenValidator: TokenValidating, Sendable {
    private let oauth: OAuthAuthorizationServer?
    private let keystone: AppTokenValidator
    private let tokenValidator: TokenValidator
    private let logger: Logger

    public init(
        oauth: OAuthAuthorizationServer?,
        keystone: AppTokenValidator,
        tokenValidator: TokenValidator,
        logger: Logger = Logger(label: "composite-token-validator")
    ) {
        self.oauth = oauth
        self.keystone = keystone
        self.tokenValidator = tokenValidator
        self.logger = logger
    }

    public func validate(tokenID: String) async throws -> ValidatedIdentity {
        if let oauth, tokenID.hasPrefix(OAuthAccessTokenPrefix) {
            return try await oauth.validateAccessToken(tokenID, validator: tokenValidator, logger: logger)
        }
        return try await keystone.validate(tokenID: tokenID)
    }
}
