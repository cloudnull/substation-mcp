import Foundation
import Logging

/// Tunables for a deployed `OpenStackClient`. One client is shared per
/// deployment; per-request identity comes from the `ValidatedToken` each
/// operation receives.
public struct ClientSettings: Sendable {
    public var requestTimeout: Duration
    public var maxConnectionsPerHost: Int
    public var cacheMaxEntries: Int
    public var tokenCacheTTL: Duration
    /// Per-resource cache TTL overrides, keyed by resource name (e.g. "volume").
    public var ttlOverrides: [String: Duration]

    public init(
        requestTimeout: Duration = .seconds(60),
        maxConnectionsPerHost: Int = 16,
        cacheMaxEntries: Int = 2000,
        tokenCacheTTL: Duration = .seconds(60),
        ttlOverrides: [String: Duration] = [:]
    ) {
        self.requestTimeout = requestTimeout
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.cacheMaxEntries = cacheMaxEntries
        self.tokenCacheTTL = tokenCacheTTL
        self.ttlOverrides = ttlOverrides
    }
}

/// Stateless-per-identity facade over the OpenStack service clients.
///
/// The client holds one shared `Transport`, `Cache`, and `TokenValidator`,
/// plus the (optional) cloud entry. It is **stateless with respect to
/// identity**: every region/service operation takes the request's
/// `ValidatedToken` (e.g. `client.compute(region:).listServers(vt, ...)`),
/// and `regions(_:)` / `whoami(_:)` read from that token's catalog.
///
/// Region resolution defaults to the token-catalog's region for the cloud
/// (or the cloud's `regionName` when set), else the first region in the
/// token's catalog.
public actor OpenStackClient {
    private let cloud: CloudEntry
    private let transport: Transport
    private let cache: Cache
    private let validator: TokenValidator
    private let logger: Logger

    /// Shared version negotiators, keyed by service type, so that repeated
    /// `compute(region:)` calls (even with different tokens) reuse the same
    /// cached version docs.
    private let computeNegotiator: VersionNegotiator
    private let cinderNegotiator: VersionNegotiator

    public init(
        cloud: CloudEntry,
        transport: Transport,
        cache: Cache,
        validator: TokenValidator,
        logger: Logger = Logger(label: "openstack-client")
    ) {
        self.cloud = cloud
        self.transport = transport
        self.cache = cache
        self.validator = validator
        self.logger = logger
        self.computeNegotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            profile: ServiceVersionProfile.profile(for: "compute")!
        )
        self.cinderNegotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            profile: ServiceVersionProfile.profile(for: "volumev3")!
        )
    }

    // MARK: - Service accessors

    /// Region-bound Nova compute client.
    public func compute(region: String? = nil) -> ComputeRegion {
        ComputeService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Neutron network client.
    public func network(region: String? = nil) -> NetworkRegion {
        NetworkService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Cinder v3 block-storage client.
    public func blockStorage(region: String? = nil) -> BlockStorageRegion {
        BlockStorageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Glance v2 image client.
    public func image(region: String? = nil) -> ImageRegion {
        ImageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Swift object-storage client (phase 2).
    public func objectStorage(region: String? = nil) -> ObjectStorageRegion {
        ObjectStorageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Barbican key-manager client (phase 2).
    public func keyManager(region: String? = nil) -> KeyManagerRegion {
        KeyManagerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Octavia load-balancer client (phase 2).
    public func loadBalancer(region: String? = nil) -> LoadBalancerRegion {
        LoadBalancerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Designate DNS client (phase 2).
    public func dns(region: String? = nil) -> DNSRegion {
        DNSService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Magnum container-infrastructure client (phase 2).
    public func containerInfra(region: String? = nil) -> ContainerRegion {
        ContainerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Heat orchestration client (phase 2).
    public func orchestration(region: String? = nil) -> OrchestrationRegion {
        OrchestrationService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Manila shared-file-systems client (phase 2).
    public func share(region: String? = nil) -> ShareRegion {
        ShareService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Placement client (per-host resource provider inventory —
    /// the authoritative GPU/RAM/vCPU source).
    public func placement(region: String? = nil) -> PlacementRegion {
        PlacementService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Trove database client (phase 2 — IAD3 gap-fill).
    public func database(region: String? = nil) -> DatabaseRegion {
        DatabaseService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Gnocchi metric client (phase 2 — IAD3 gap-fill).
    public func metric(region: String? = nil) -> MetricRegion {
        MetricService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound ZaQar messaging client (phase 2 — IAD3 gap-fill).
    public func messaging(region: String? = nil) -> MessagingRegion {
        MessagingService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Blazar reservation client (phase 2 — IAD3 gap-fill).
    public func reservation(region: String? = nil) -> ReservationRegion {
        ReservationService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    /// Region-bound Freezer backup client (phase 2 — IAD3 gap-fill).
    public func backup(region: String? = nil) -> BackupRegion {
        BackupService(cloud: cloud, transport: transport, cache: cache, logger: logger)
            .region(region)
    }

    // MARK: - Identity

    /// The distinct regions advertised in the token's service catalog.
    public func regions(_ vt: ValidatedToken) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in vt.token.catalog {
            for ep in entry.endpoints where !seen.contains(ep.region) {
                seen.insert(ep.region)
                ordered.append(ep.region)
            }
        }
        return ordered
    }

    /// The identity context of a validated token.
    public func whoami(_ vt: ValidatedToken) -> Whoami {
        Whoami(
            project: vt.token.project,
            domain: vt.token.domain,
            roles: vt.token.roles,
            scopes: vt.scopes,
            expiresAt: vt.token.expiresAt,
            regions: regions(vt),
            services: serviceMap(for: vt)
        )
    }

    private func serviceMap(for vt: ValidatedToken) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for entry in vt.token.catalog {
            var regions = Set<String>()
            for ep in entry.endpoints { regions.insert(ep.region) }
            map[entry.type] = regions.sorted()
        }
        return map
    }

    // MARK: - Region resolution helper

    /// The effective region for a request: an explicit region, else the
    /// cloud's configured region, else the first region in the token's
    /// catalog.
    public func defaultRegion(_ vt: ValidatedToken) -> String {
        cloud.regionName ?? vt.token.catalog.first?.endpoints.first?.region ?? "RegionOne"
    }

    /// Raw Neutron router-interface PUT/DELETE (add/remove_router_interface).
    ///
    /// The phase 1 `NetworkService` does not model router interfaces; this
    /// narrow escape hatch keeps the link executor from widening the service
    /// surface. The request is retried per the transport's rules (PUT is
    /// not retried; DELETE is).
    public func routerInterface(
        _ vt: ValidatedToken,
        method: String,
        routerID: String,
        subnetID: String,
        region: String? = nil
    ) async throws -> (status: Int, body: Data, requestID: String?) {
        let body: Data?
        if method == "PUT" {
            body = "{\"subnet_id\":\"\(subnetID)\"}".data(using: .utf8)
        } else {
            body = nil
        }
        return try await transport.request(
            method: method,
            service: "network",
            path: "neutron/v2.0/routers/\(routerID)\(method == "PUT" ? "/add_router_interface" : "/remove_router_interface")",
            body: body,
            tokenOverride: vt.token.id
        )
    }
}
