import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - Serve app builder (spec §7.1, §7.3)

/// The fully-wired serve app: Hummingbird app + MCP route + health/readyz/
/// metrics routes, backed by an OpenStack client bound to one cloud.
///
/// This is the composition layer that turns the OpenStack-free Task-17 adapter
/// into a runnable HTTP server.
public struct ServeApp: Sendable {
    public let app: Application<RouterResponder<BasicRequestContext>>
    public let config: OpenStackMCPConfig
    public let wiring: CloudWiring

    /// Shut down the underlying HTTP client (and the Hummingbird app's
    /// event-loop group when it owns one). Call at process exit or test
    /// teardown to avoid the AsyncHTTPClient "not shut down before deinit"
    /// fatal error.
    public nonisolated func shutdown() {
        wiring.shutdown()
    }

    public init(
        config: OpenStackMCPConfig,
        cloud: CloudEntry,
        logger: Logger
    ) {
        self.config = config
        let wiring = CloudWiring(config: config, cloud: cloud, logger: logger)
        self.wiring = wiring

        // The OpenStack-specific seams.
        let gate = WriteToolGate(toolNames: [
            "os_create", "os_update", "os_delete", "os_action", "os_attach", "os_detach",
        ])
        let policy = Policy(
            readOnly: config.policyReadOnly,
            denyResources: Set(config.policyDenyResources),
            maxListLimit: config.policyMaxListLimit,
            maxCallsPerMinute: config.policyMaxCallsPerMinute
        )
        // The PRM `resource` is the canonical public base (spec §7.1: clients
        // fetch `resource + /.well-known/oauth-protected-resource`). The
        // adapter serves the PRM at the host's own well-known path, so when
        // `server.public_url` is unset we default it to the local bind
        // (host:port) so `resource` points at this server rather than at
        // Keystone.
        let publicURL = config.serverPublicURL
            ?? "http://\(config.serverHost):\(config.serverPort)"
        let keystoneURL = URL(string: config.authKeystoneURL ?? cloud.authURL?.absoluteString ?? "")

        // P3: the stateless OAuth 2.1 AS (the default auth profile). Built
        // before the PRM so the PRM can point `authorization_servers` at the
        // AS issuer. When `oauth.server_secret` is unset the server derives a
        // deterministic dev secret from the resolved issuer (zero-config
        // bootstrap; set an explicit secret for production).
        let minter = LoginMinter(transport: wiring.transport, logger: logger)
        let oauthServer: OAuthAuthorizationServer?
        if config.oauthEnabled {
            #if DEBUG
            let devMintEnabled = true
            #else
            let devMintEnabled = false
            #endif
            oauthServer = OAuthAuthorizationServer(
                secret: config.oauthSecretResolved,
                issuer: config.oauthIssuerResolved,
                codeTTL: config.oauthCodeTTL,
                tokenTTL: config.oauthTokenTTL,
                endpoint: config.serverEndpoint,
                devMintEnabled: devMintEnabled,
                minter: minter,
                tokenValidator: wiring.validator,
                logger: logger
            )
        } else {
            oauthServer = nil
        }

        let prmDocument = ProtectedResourceMetadata.document(
            publicURL: publicURL,
            authProfile: config.authProfileEnum,
            keystoneURL: keystoneURL,
            authServerURL: oauthServer.flatMap { URL(string: $0.issuer) },
            scopesSupported: config.authScopesPerService
                ? ["openstack:read", "openstack:write"] + Service.allServiceScopeNames
                : nil
        )

        // The MCP gate's validator: composite (OAuth + Keystone) when the AS is
        // enabled, otherwise the plain Keystone validator (P1 unchanged).
        let appValidator = AppTokenValidator(validator: wiring.validator)
        let routeValidator: any TokenValidating
        if let oauthServer {
            routeValidator = CompositeTokenValidator(
                oauth: oauthServer,
                keystone: appValidator,
                tokenValidator: wiring.validator,
                logger: logger
            )
        } else {
            routeValidator = appValidator
        }

        let loginPage = LoginPage(minter: minter, logger: logger)

        let serverFactory = wiring.makeServerFactory(
            policy: policy,
            scopeMode: config.authScopesPerService ? .perService : .coarse,
            logger: logger,
            auditEnabled: config.logAudit
        )

        let route = MCPRoute(
            config: MCPConfig(
                endpoint: config.serverEndpoint,
                legacyEndpoint: "/mcp",
                allowedOrigins: config.serverAllowedOrigins,
                maxBodyBytes: config.serverMaxBodyBytes,
                maxSessions: config.sessionMaxSessions,
                maxStreamsPerSession: config.sessionMaxStreamsPerSession,
                idleTTL: TimeInterval(config.sessionIdleTTL),
                maxLifetime: TimeInterval(config.sessionMaxLifetime),
                cleanupInterval: .seconds(60),
                publicURL: publicURL
            ),
            validator: routeValidator,
            serverFactory: serverFactory,
            gate: gate,
            terminated: { _ in
                // WS-A (Option 2): the server holds no minted token, so there is
                // nothing to zeroize on session end — the callback is a no-op.
            },
            logger: logger,
            onSessionStart: { OSMetrics.sessionStarted() },
            onSessionEnd: { OSMetrics.sessionEnded() },
            onAuthFailure: { reason in OSMetrics.authFailure(reason: reason) }
        )

        let router = Router<BasicRequestContext>()
        route.install(
            on: router,
            prm: {
                (try? prmDocument.json()) ?? Data()
            },
            login: config.authLoginPageEnabled ? loginPage.handler() : nil
        )

        // Mount the stateless OAuth AS routes when enabled (P2). These live
        // under `<endpoint>/oauth/*` plus the RFC 8414 metadata at
        // `<issuer>/.well-known/oauth-authorization-server`.
        if let oauthServer {
            oauthServer.install(on: router)
        }

        // Non-MCP routes (spec §7.3).
        router.get("/healthz") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/plain"],
                     body: .init(byteBuffer: ByteBuffer(string: "ok")))
        }
        router.get("/readyz") { [cloud, transport = wiring.transport, logger] _, _ in
            await ReadyzChecker.check(cloud: cloud, transport: transport, logger: logger)
        }
        router.get("/metrics") { [metricsToken = config.serverMetricsToken] context, _ in
            // Optional bearer-token gating (spec §7.3: `server.metrics_token`).
            if let metricsToken {
                let authName = HTTPField.Name("Authorization")
                let auth = authName.flatMap { context.headers[$0] } ?? ""
                guard auth == "Bearer \(metricsToken)" else {
                    return Response(status: .unauthorized, headers: [.contentType: "text/plain"],
                                    body: .init(byteBuffer: ByteBuffer(string: "unauthorized")))
                }
            }
            // Prometheus text exposition (spec §12). Bootstrapping is done at
            // process start (see main.swift) so the collector has every
            // registration; if it was never run (e.g. a unit test built the
            // ServeApp directly) render() still returns the (empty) registry.
            return Response(status: .ok, headers: [.contentType: "text/plain"],
                            body: .init(byteBuffer: ByteBuffer(string: MetricsCollector.render())))
        }

        let appConfig = ApplicationConfiguration(
            address: .hostname(config.serverHost, port: config.serverPort)
        )
        self.app = Application(router: router, configuration: appConfig)
    }
}

// MARK: - readyz (spec §7.3)

/// Readiness: Keystone reachable within 2 s. Never authenticates.
enum ReadyzChecker {
    static func check(cloud: CloudEntry, transport: Transport,
                      logger: Logger = Logger(label: "substation-mcp.readyz")) async -> Response {
        do {
            let (status, _, _) = try await transport.request(
                method: "GET", service: "keystone", path: "/v3", tokenOverride: ""
            )
            if (200..<400).contains(status) {
                return Response(status: .ok, headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: ByteBuffer(string: #"{"ready":true}"#)))
            }
            return Response(status: .serviceUnavailable, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"ready":false,"reason":"keystone returned \#(status)"}"#)))
        } catch {
            // Surface the real failure at error level so operators can diagnose
            // "keystone unreachable" without guessing (DNS, TLS, egress, etc.).
            logger.error("readyz: keystone check failed: \(error)")
            return Response(status: .serviceUnavailable, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"ready":false,"reason":"keystone unreachable"}"#)))
        }
    }
}
