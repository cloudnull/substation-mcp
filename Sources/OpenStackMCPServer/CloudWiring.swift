import Foundation
import Hummingbird
import HummingbirdMCP
import Logging
import OpenStackClient

// MARK: - Cloud wiring (shared by serve + stdio + tests)

/// The fully-assembled OpenStack-side components for one cloud.
///
/// Built once per process (or per test) from a `CloudEntry`. Both the `serve`
/// (HTTP) and `stdio` commands — and the integration tests — use this to wire
/// the shared `Transport`/`Cache`/`TokenValidator`/`OpenStackClient` and to
/// build the per-identity `serverFactory`.
public struct CloudWiring: Sendable {
    public let cloud: CloudEntry
    public let transport: Transport
    public let cache: Cache
    public let validator: TokenValidator
    public let client: OpenStackClient

    /// Shut down the underlying HTTP client. Call when the wiring is done
    /// (e.g. at process exit or test teardown) to avoid the AsyncHTTPClient
    /// "not shut down before deinit" fatal error.
    public nonisolated func shutdown() {
        transport.syncShutdown()
    }

    public init(
        config: OpenStackMCPConfig,
        cloud: CloudEntry,
        logger: Logger
    ) {
        let transport = Transport(
            cloud: cloud,
            tokenSource: {
                // The server never authenticates with a standing credential in
                // HTTP mode; every request carries an explicit token override.
                // This source is a fallback that should not be hit.
                throw OpenStackError(
                    service: "keystone",
                    status: 500,
                    message: "No standing token source in stateless mode"
                )
            },
            maxConnectionsPerHost: config.clientMaxConnectionsPerHost,
            requestTimeout: .seconds(config.clientRequestTimeout),
            logger: logger
        )
        let cache = Cache(maxEntries: 2000)
        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: config.servedProjects,
            tokenCacheTTL: .seconds(config.authTokenCacheTTL)
        )
        let client = OpenStackClient(
            cloud: cloud,
            transport: transport,
            cache: cache,
            validator: validator,
            logger: logger
        )
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.validator = validator
        self.client = client
    }

    /// The `serverFactory` the adapter's `MCPRoute` needs: builds one MCP
    /// server per validated identity, with `RequestIdentity.cloudName` set from
    /// the cloud (spec §5.1 resource URIs are cloud-scoped).
    public func makeServerFactory(
        policy: Policy,
        catalog: ResourceCatalog = ResourceCatalog.phase1(),
        logger: Logger,
        auditEnabled: Bool = true
    ) -> @Sendable (ValidatedIdentity) async -> MCPServer {
        let clientCopy = client
        let cloudName = cloud.name
        return { identity in
            let scopes = identity.scopes.compactMap { TokenScope(rawValue: $0) }
            do {
                let vt = try validatedToken(fromRaw: identity.raw, scopes: scopes)
                let whoami = Whoami(
                    project: vt.token.project,
                    domain: vt.token.domain,
                    roles: vt.token.roles,
                    scopes: vt.scopes,
                    expiresAt: vt.token.expiresAt,
                    regions: vt.token.regions(),
                    services: vt.token.serviceMap()
                )
                let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: cloudName)
                let registry = ToolRegistry(
                    client: clientCopy,
                    catalog: catalog,
                    policy: policy,
                    identity: identity,
                    logger: logger,
                    auditEnabled: auditEnabled
                )
                return await registry.makeServer()
            } catch {
                let vt = ValidatedToken(
                    token: Token(
                        id: identity.tokenID,
                        expiresAt: Date().addingTimeInterval(3600),
                        project: IdentityRef(id: identity.projectID),
                        domain: IdentityRef(id: "default"),
                        user: IdentityRef(id: "unknown"),
                        roles: [],
                        catalog: []
                    ),
                    scopes: scopes
                )
                let whoami = Whoami(
                    project: IdentityRef(id: identity.projectID),
                    domain: IdentityRef(id: "default"),
                    roles: [],
                    scopes: vt.scopes,
                    expiresAt: vt.token.expiresAt
                )
                let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: cloudName)
                let registry = ToolRegistry(
                    client: clientCopy,
                    catalog: catalog,
                    policy: policy,
                    identity: identity,
                    logger: logger,
                    auditEnabled: auditEnabled
                )
                return await registry.makeServer()
            }
        }
    }
}

// MARK: - Token catalog helpers

extension Token {
    /// Ordered unique regions from the catalog.
    func regions() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in catalog {
            for ep in entry.endpoints where !seen.contains(ep.region) {
                seen.insert(ep.region)
                ordered.append(ep.region)
            }
        }
        return ordered
    }

    /// `serviceType -> sorted unique regions` from the catalog.
    func serviceMap() -> [String: [String]] {
        Dictionary(grouping: catalog, by: \.type).mapValues { entries in
            var seen = Set<String>()
            var ordered: [String] = []
            for entry in entries {
                for ep in entry.endpoints where !seen.contains(ep.region) {
                    seen.insert(ep.region)
                    ordered.append(ep.region)
                }
            }
            return ordered.sorted()
        }
    }
}
