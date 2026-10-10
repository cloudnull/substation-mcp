import Foundation
import HummingbirdMCP

/// All configuration keys from spec §11.2 with the Global-Constraints defaults.
///
/// Loaded via swift-configuration with providers in priority order:
/// command-line flags → environment (`OSMCP_` prefix, `__` separator) →
/// YAML file (`--config`) → defaults.
public struct OpenStackMCPConfig: Sendable {
    // MARK: server
    public var serverHost: String
    public var serverPort: Int
    public var serverEndpoint: String
    public var serverAllowedOrigins: [String]
    public var serverMaxBodyBytes: Int
    public var serverMetricsToken: String?
    public var serverPublicURL: String?
    public var serverTLSCert: String?
    public var serverTLSKey: String?

    // MARK: auth
    public var authProfile: String
    public var authScopes: String
    public var authKeystoneURL: String?
    public var authTokenCacheTTL: Int        // seconds
    public var authFailedAuthPerMinute: Int
    public var authLoginPageEnabled: Bool

    // MARK: oauth (stateless OAuth 2.1 AS, P3)
    /// The shared HS256 secret that signs authorization codes and `stst.at.`
    /// access tokens. **Recommended for production** (set an operator-chosen
    /// high-entropy value). When left unset with `auth.profile == "oauth"` the
    /// server derives a deterministic dev secret from the resolved issuer
    /// (see ``oauthSecretResolved``) so the OAuth experience is zero-config;
    /// the derived secret is not a substitute for an explicit one, and it
    /// changes whenever the issuer (public URL / host:port) changes, which
    /// invalidates previously issued `stst.at.` tokens.
    public var oauthServerSecret: String?
    /// Authorization-code TTL in seconds. The code JWT's `exp` also never
    /// exceeds the embedded Keystone token's own expiry.
    public var oauthCodeTTL: Int
    /// Maximum access-token TTL in seconds. The issued token's `exp` is capped
    /// at the embedded Keystone token's remaining lifetime.
    public var oauthTokenTTL: Int
    /// Explicit issuer override. Defaults to `<publicURL><endpoint>/oauth`
    /// (the RFC 8414 issuer must equal the URL the metadata is served under).
    public var oauthIssuer: String?
    /// Authorization-code replay store backend: `local` (default — in-memory,
    /// instance-local, single-replica) or `memcached` (shared across replicas;
    /// the endpoint is discovered from each token's Keystone service catalog
    /// — service type `memcached`, interface preference public → internal →
    /// admin — or overridden by `oauth.replay_store_endpoint`).
    public var oauthReplayStore: String
    /// Explicit memcached endpoint `host:port` override for the shared replay
    /// store. When unset, the endpoint is resolved from the token's Keystone
    /// service catalog (the normal OpenStack endpoint-discovery mechanism).
    /// Ignored unless `oauth.replay_store == "memcached"`.
    public var oauthReplayStoreEndpoint: String?

    // MARK: clouds
    public var cloudsDefault: String?
    public var cloudsAllowed: [String]
    public var cloudsFile: String?

    // MARK: session
    public var sessionIdleTTL: Int           // seconds
    public var sessionMaxLifetime: Int       // seconds
    public var sessionMaxSessions: Int
    public var sessionMaxStreamsPerSession: Int

    // MARK: policy
    public var policyReadOnly: Bool
    public var policyDenyResources: [String]
    public var policyMaxListLimit: Int
    public var policyMaxCallsPerMinute: Int

    // MARK: client
    public var clientRequestTimeout: Int     // seconds
    public var clientMaxConnectionsPerHost: Int

    // MARK: log
    public var logLevel: String
    public var logFormat: String
    public var logAudit: Bool

    public init(
        serverHost: String = "127.0.0.1",
        serverPort: Int = 8080,
        serverEndpoint: String = "/v1",
        serverAllowedOrigins: [String] = ["localhost"],
        serverMaxBodyBytes: Int = 1_048_576,
        serverMetricsToken: String? = nil,
        serverPublicURL: String? = nil,
        serverTLSCert: String? = nil,
        serverTLSKey: String? = nil,
        authProfile: String = "oauth",
        authScopes: String = "coarse",
        authKeystoneURL: String? = nil,
        authTokenCacheTTL: Int = 60,
        authFailedAuthPerMinute: Int = 10,
        authLoginPageEnabled: Bool = true,
        oauthServerSecret: String? = nil,
        oauthCodeTTL: Int = 120,
        oauthTokenTTL: Int = 3600,
        oauthIssuer: String? = nil,
        oauthReplayStore: String = "local",
        oauthReplayStoreEndpoint: String? = nil,
        cloudsDefault: String? = nil,
        cloudsAllowed: [String] = [],
        cloudsFile: String? = nil,
        sessionIdleTTL: Int = 1800,
        sessionMaxLifetime: Int = 43_200,
        sessionMaxSessions: Int = 500,
        sessionMaxStreamsPerSession: Int = 4,
        policyReadOnly: Bool = false,
        policyDenyResources: [String] = [
            "project", "user", "group", "role", "role_assignment", "domain"
        ],
        policyMaxListLimit: Int = 200,
        policyMaxCallsPerMinute: Int = 1024,
        clientRequestTimeout: Int = 60,
        clientMaxConnectionsPerHost: Int = 16,
        logLevel: String = "info",
        logFormat: String = "json",
        logAudit: Bool = true
    ) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.serverEndpoint = serverEndpoint
        self.serverAllowedOrigins = serverAllowedOrigins
        self.serverMaxBodyBytes = serverMaxBodyBytes
        self.serverMetricsToken = serverMetricsToken
        self.serverPublicURL = serverPublicURL
        self.serverTLSCert = serverTLSCert
        self.serverTLSKey = serverTLSKey
        self.authProfile = authProfile
        self.authScopes = authScopes
        self.authKeystoneURL = authKeystoneURL
        self.authTokenCacheTTL = authTokenCacheTTL
        self.authFailedAuthPerMinute = authFailedAuthPerMinute
        self.authLoginPageEnabled = authLoginPageEnabled
        self.oauthServerSecret = oauthServerSecret
        self.oauthCodeTTL = oauthCodeTTL
        self.oauthTokenTTL = oauthTokenTTL
        self.oauthIssuer = oauthIssuer
        self.oauthReplayStore = oauthReplayStore
        self.oauthReplayStoreEndpoint = oauthReplayStoreEndpoint
        self.cloudsDefault = cloudsDefault
        self.cloudsAllowed = cloudsAllowed
        self.cloudsFile = cloudsFile
        self.sessionIdleTTL = sessionIdleTTL
        self.sessionMaxLifetime = sessionMaxLifetime
        self.sessionMaxSessions = sessionMaxSessions
        self.sessionMaxStreamsPerSession = sessionMaxStreamsPerSession
        self.policyReadOnly = policyReadOnly
        self.policyDenyResources = policyDenyResources
        self.policyMaxListLimit = policyMaxListLimit
        self.policyMaxCallsPerMinute = policyMaxCallsPerMinute
        self.clientRequestTimeout = clientRequestTimeout
        self.clientMaxConnectionsPerHost = clientMaxConnectionsPerHost
        self.logLevel = logLevel
        self.logFormat = logFormat
        self.logAudit = logAudit
    }

    /// Derive the adapter `MCPConfig` from this deployment config.
    public var mcpConfig: MCPConfig {
        MCPConfig(
            endpoint: serverEndpoint,
            legacyEndpoint: "/mcp",
            allowedOrigins: serverAllowedOrigins,
            maxBodyBytes: serverMaxBodyBytes,
            maxSessions: sessionMaxSessions,
            maxStreamsPerSession: sessionMaxStreamsPerSession,
            idleTTL: TimeInterval(sessionIdleTTL),
            maxLifetime: TimeInterval(sessionMaxLifetime),
            cleanupInterval: .seconds(60),
            publicURL: serverPublicURL
        )
    }

    /// The auth profile as the typed enum.
    public var authProfileEnum: AuthProfile {
        AuthProfile(rawValue: authProfile) ?? .keystoneToken
    }

    /// Whether P2 per-service scopes are enabled (`auth.scopes = per_service`).
    /// Default is `coarse`: a write-scoped token may mutate any service.
    public var authScopesPerService: Bool {
        authScopes == "per_service"
    }

    /// Projects this deployment serves; empty = serve all (the phase-1 default).
    public var servedProjects: Set<String> {
        []
    }

    // MARK: OAuth AS (P3)

    /// Whether the stateless OAuth 2.1 authorization server is enabled.
    /// `auth.profile == "oauth"` is sufficient: when no explicit
    /// `oauth.server_secret` is configured, ``oauthSecretResolved`` falls back
    /// to a deterministic dev secret derived from the resolved issuer, so the
    /// OAuth experience works with zero config. Deploying with an explicit
    /// secret is required for production (see ``oauthSecretResolved``).
    public var oauthEnabled: Bool {
        authProfileEnum == .oauth
    }

    /// The HS256 secret the AS signs with: the operator-configured
    /// `oauth.server_secret` when set, otherwise a deterministic dev secret
    /// `sha256Hex("substation-oauth-dev" + issuer)` derived from the resolved
    /// issuer. Derivation is a statelessness-friendly bootstrap, not a
    /// production control — anyone who knows the public URL can recompute
    /// it, so any deployment reachable by untrusted parties MUST set
    /// `oauth.server_secret` explicitly.
    public var oauthSecretResolved: String {
        if let secret = oauthServerSecret, !secret.isEmpty {
            return secret
        }
        return "dev-" + sha256Hex("substation-oauth-dev" + oauthIssuerResolved)
    }

    /// Parse `oauth.replay_store_endpoint` (`host:port`) into a tuple, or nil
    /// when unset/malformed. Malformed values are treated as unset (the token
    /// catalog then provides the endpoint).
    var oauthReplayStoreEndpointParsed: (host: String, port: Int)? {
        guard let raw = oauthReplayStoreEndpoint, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let host = parts.first, !host.isEmpty,
              let port = Int(parts[1]), (1...65535).contains(port)
        else { return nil }
        return (host: String(host), port: port)
    }

    /// The issuer the AS advertises. Defaults to
    /// `<publicURL><endpoint>/oauth` so the RFC 8414 `issuer` exactly matches
    /// the URL under which the metadata document is served
    /// (`<issuer>/.well-known/oauth-authorization-server`).
    public var oauthIssuerResolved: String {
        if let override = oauthIssuer, !override.isEmpty {
            return override
        }
        let rawBase = serverPublicURL ?? "http://\(serverHost):\(serverPort)"
        // Normalize: strip a trailing endpoint path so `https://host/v1` +
        // endpoint `/v1` doesn't produce `https://host/v1/v1/oauth`.
        var base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        let trimmedEndpoint = serverEndpoint.hasSuffix("/")
            ? String(serverEndpoint.dropLast()) : serverEndpoint
        if !trimmedEndpoint.isEmpty, trimmedEndpoint != "/", base.hasSuffix(trimmedEndpoint) {
            base = String(base.dropLast(trimmedEndpoint.count))
        }
        return base + trimmedEndpoint + "/oauth"
    }
}
