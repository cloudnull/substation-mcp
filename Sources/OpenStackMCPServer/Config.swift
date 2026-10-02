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
        authProfile: String = "keystone_token",
        authScopes: String = "coarse",
        authKeystoneURL: String? = nil,
        authTokenCacheTTL: Int = 60,
        authFailedAuthPerMinute: Int = 10,
        authLoginPageEnabled: Bool = true,
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
        policyMaxCallsPerMinute: Int = 120,
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
}
