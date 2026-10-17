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
    /// Shared bearer secret for **internal ops** routes — currently `/metrics`.
    /// When set, these routes require `Authorization: Bearer <ops_token>` and
    /// return 401 otherwise; when unset they behave as before (open). This is a
    /// topology-independent way to keep operational surfaces reachable only by
    /// authorized scrapers/operators without relying on network segmentation or
    /// spoofable proxy headers. Prefer this over ``serverMetricsToken`` (which
    /// remains accepted as an alias for `/metrics`). Note: `/healthz` and
    /// `/readyz` stay open deliberately — Kubernetes liveness/readiness probes
    /// cannot send auth headers, and their responses are intentionally coarse.
    public var serverOpsToken: String?
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
    /// The default Keystone domain name pre-filled in the user-domain field on
    /// the `/v1/login` and `/v1/oauth/authorize` pages (e.g. `default`,
    /// `rackspace_cloud_domain`). When unset, both forms fall back to
    /// `default`. Operators serving a cloud whose users live in a named
    /// domain set this so password login works without typing the domain.
    public var authDefaultDomain: String?

    // MARK: federation (Keystone OS-FEDERATION passthrough)
    /// Master switch for the Keystone federation passthrough surface. When
    /// true, the server mounts `GET <endpoint>/oauth/federate` + the websso
    /// callback and offers a "Federated" method on the login / authorize forms
    /// (see ``federationPasteToken``). The IdP round-trip happens in the user's
    /// browser via Keystone's WebSSO route; only works where the cloud's
    /// Keystone is itself the SAML/OIDC service provider and allows a
    /// third-party origin.
    public var federationEnabled: Bool
    /// The identity-provider name configured in Keystone (OS-FEDERATION
    /// `identity_providers/{idp}`) used in the IdP-specific WebSSO route.
    public var federationIdP: String?
    /// The federation protocol under that IdP: `saml2`, `oidc`, or `kerberos`.
    public var federationProtocol: String?
    /// Extra origins (host[:port]) the callback accepts in addition to this
    /// server's own public URL. Defense-in-depth: Keystone relays the
    /// unscoped token to the `origin` parameter verbatim, so we never trust a
    /// foreign origin by default.
    public var federationOriginAllowlist: [String]
    /// Enable the paste-token fallback for clouds whose federation SP lives on
    /// a portal rather than Keystone (e.g. Rackspace Skyline, where the Shibboleth
    /// SP entityID points at `skyline.api.*`). Adds a "Federated token" field to
    /// the login / authorize forms: the operator pastes an unscoped (or scoped)
    /// token they obtained from their portal session; the server exchanges it
    /// via `methods:["token"]`.
    public var federationPasteToken: Bool
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
    /// When true (default), a shared replay store failure falls back to the
    /// local store. When false, the token endpoint rejects the code rather
    /// than risk a cross-replica replay. Ignored unless
    /// `oauth.replay_store == "memcached"`.
    public var oauthReplayStoreFailOpen: Bool
    /// When true, mounts the `POST /oauth/dev-mint` headless protocol-test
    /// endpoint. This endpoint mints a Keystone token from raw form
    /// credentials and returns the full authorize redirect (code + state) in
    /// one step — it bypasses the browser consent flow and exists only for
    /// automated OAuth integration tests. **Default false.** A deployment that
    /// needs it must set `oauth.dev_mint_enabled: true` explicitly; there is no
    /// build-config fallback (the previous `#if DEBUG` auto-enable was removed
    /// so a debug binary shipped by accident cannot expose this surface).
    public var oauthDevMintEnabled: Bool

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
        serverOpsToken: String? = nil,
        serverPublicURL: String? = nil,
        serverTLSCert: String? = nil,
        serverTLSKey: String? = nil,
        authProfile: String = "oauth",
        authScopes: String = "coarse",
        authKeystoneURL: String? = nil,
        authTokenCacheTTL: Int = 60,
        authFailedAuthPerMinute: Int = 10,
        authLoginPageEnabled: Bool = true,
        authDefaultDomain: String? = nil,
        federationEnabled: Bool = false,
        federationIdP: String? = nil,
        federationProtocol: String? = nil,
        federationOriginAllowlist: [String] = [],
        federationPasteToken: Bool = true,
        oauthServerSecret: String? = nil,
        oauthCodeTTL: Int = 30,
        oauthTokenTTL: Int = 3600,
        oauthIssuer: String? = nil,
        oauthReplayStore: String = "local",
        oauthReplayStoreEndpoint: String? = nil,
        oauthReplayStoreFailOpen: Bool = true,
        oauthDevMintEnabled: Bool = false,
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
        self.serverOpsToken = serverOpsToken
        self.serverPublicURL = serverPublicURL
        self.serverTLSCert = serverTLSCert
        self.serverTLSKey = serverTLSKey
        self.authProfile = authProfile
        self.authScopes = authScopes
        self.authKeystoneURL = authKeystoneURL
        self.authTokenCacheTTL = authTokenCacheTTL
        self.authFailedAuthPerMinute = authFailedAuthPerMinute
        self.authLoginPageEnabled = authLoginPageEnabled
        self.authDefaultDomain = authDefaultDomain
        self.federationEnabled = federationEnabled
        self.federationIdP = federationIdP
        self.federationProtocol = federationProtocol
        self.federationOriginAllowlist = federationOriginAllowlist
        self.federationPasteToken = federationPasteToken
        self.oauthServerSecret = oauthServerSecret
        self.oauthCodeTTL = oauthCodeTTL
        self.oauthTokenTTL = oauthTokenTTL
        self.oauthIssuer = oauthIssuer
        self.oauthReplayStore = oauthReplayStore
        self.oauthReplayStoreEndpoint = oauthReplayStoreEndpoint
        self.oauthReplayStoreFailOpen = oauthReplayStoreFailOpen
        self.oauthDevMintEnabled = oauthDevMintEnabled
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

    /// Parse `oauth.replay_store_endpoint` into a list of `(host, port)` pairs,
    /// or nil when unset/malformed. Accepts a single `host:port` or a
    /// comma-separated list (`host1:port1,host2:port2,…`) for multi-server
    /// deployments using Rendezvous Hashing (HRW) to route each key to one
    /// server deterministically — the same algorithm pymemcache and oslo.cache
    /// use for their memcached pools. Malformed entries are skipped silently;
    /// if no valid entry remains the result is nil (the Keystone catalog then
    /// provides the endpoint).
    var oauthReplayStoreEndpoints: [(host: String, port: Int)]? {
        guard let raw = oauthReplayStoreEndpoint, !raw.isEmpty else { return nil }
        var out: [(host: String, port: Int)] = []
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let hp = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard hp.count == 2, let host = hp.first, !host.isEmpty,
                  let port = Int(hp[1]), (1...65535).contains(port)
            else { continue }
            out.append((host: String(host), port: port))
        }
        return out.isEmpty ? nil : out
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
