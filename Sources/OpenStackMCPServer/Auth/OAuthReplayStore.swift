import Foundation
import Logging
import OpenStackClient

// MARK: - Authorization-code replay stores (P3: optional shared, multi-replica-safe)
//
// A stateless OAuth 2.1 AS keeps no server-side state *except* the single-use
// enforcement for authorization codes (RFC 6749 §4.1.2). The store is
// pluggable behind `CodeReplayStore`:
//
// - **Local** (default; `oauth.replay_store` unset or `local`) — the original
//   in-memory per-process set. Enforces replay within one instance, so a
//   multi-replica deployment needs the shared backend.
// - **Shared** (`oauth.replay_store: memcached`) — records redeemed `jti`s in
//   memcached with NO_OVERWRITE (`add`), so the *first* replica to redeem a
//   code wins and a replay is rejected cluster-wide. The memcached endpoint is
//   discovered the same way every other upstream is (spec §6.5): from the
//   **token's Keystone service catalog** (service type `memcached`, interface
//   preference public → internal → admin, over the normal internal network),
//   with an explicit `oauth.replay_store_endpoint` override for
//   non-catalog deployments.
//
// The shared backend is **fail-open**: any discovery or cache failure degrades
// that one exchange to the local store (with a warning log), so a memcached
// outage never breaks the OAuth flow — it only degrades to single-replica
// replay semantics until the cache is reachable again.

/// The seam the token endpoint calls: "was this code `jti` already redeemed
/// (and mark it if not)?"
public protocol CodeReplayRecording: Sendable {
    /// Returns `true` if `jti` has already been redeemed (a replay), else
    /// marks it redeemed and returns `false`. `vt` is the embedded Keystone
    /// token just re-validated at the token endpoint — the catalog source for
    /// shared-endpoint discovery.
    func record(_ jti: String, vt: ValidatedToken) async throws -> Bool
}

// MARK: - Local (in-memory, instance-local) store

/// The original in-memory, best-effort replay set. Enforces replay within one
/// process; expired entries are pruned opportunistically.
public actor LocalCodeReplayStore: CodeReplayRecording {
    private var redeemed: [String: Int] = [:]
    private let ttl: Int

    public init(ttl: Int = 300) { self.ttl = ttl }

    /// `vt` is unused for the local store; the `CodeReplayRecording` overload
    /// below and this one share the same backing set.
    public func record(_ jti: String) -> Bool {
        record(jti, vt: Self.dummyVT)
    }

    public func record(_ jti: String, vt: ValidatedToken) -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        redeemed = redeemed.filter { $0.value > now }
        if redeemed[jti] != nil { return true }
        redeemed[jti] = now + ttl
        return false
    }

    private static let dummyVT: ValidatedToken = ValidatedToken(
        token: Token(
            id: "_local_", expiresAt: .distantFuture,
            project: IdentityRef(id: "_local_"),
            domain: IdentityRef(id: "_local_"),
            user: IdentityRef(id: "_local_"),
            roles: [], catalog: []
        ),
        scopes: [.read]
    )
}

// MARK: - The AS-facing composition

/// The AS's replay store: a pluggable backend with fail-open degradation to
/// the local in-memory set. Retains the original `seen(_:)` surface for
/// callers that don't carry a catalog.
public actor CodeReplayStore {
    private let shared: SharedCodeReplayStore?
    private let local: LocalCodeReplayStore
    private let logger: Logger

    /// Instance-local construction (the original default; single-replica
    /// semantics, zero external dependencies).
    public init(ttl: Int = 300, logger: Logger = Logger(label: "oauth-replay")) {
        self.shared = nil
        self.local = LocalCodeReplayStore(ttl: ttl)
        self.logger = logger
    }

    /// Shared (multi-replica) construction: `shared` first, failing open to
    /// `local` whenever discovery or the cache errors.
    public init(shared: SharedCodeReplayStore, ttl: Int = 300, logger: Logger) {
        self.shared = shared
        self.local = LocalCodeReplayStore(ttl: ttl)
        self.logger = logger
    }

    /// The original surface: local enforcement only (no catalog to discover a
    /// shared endpoint from).
    public func seen(_ jti: String) async -> Bool {
        await local.record(jti)
    }

    /// Token-endpoint entry point: shared-first with fail-open local
    /// degradation. Never throws — a cache problem must not break the
    /// exchange.
    public func seen(_ jti: String, vt: ValidatedToken) async -> Bool {
        if let shared {
            do {
                return try await shared.record(jti, vt: vt)
            } catch {
                logger.warning(
                    "Shared replay store unavailable; using instance-local enforcement",
                    metadata: ["reason": .string(String(describing: error))]
                )
            }
        }
        return await local.record(jti, vt: vt)
    }
}

// MARK: - Shared memcached-backed store

/// Records redeemed code `jti`s in memcached so every replica sees every
/// redemption. Uses NO_OVERWRITE (`add`): the first replica to redeem a code
/// wins (`STORED` → not a replay); a second redemption gets `EXISTS` → replay.
///
/// Key layout: `stst:<issuerFingerprint>:<jti>` where the 16-hex fingerprint
/// is `sha256Hex(issuer).prefix(16)` — namespacing keeps codes from different
/// issuers (a cloud's memcached is typically shared with Keystone and others)
/// from colliding.
public actor SharedCodeReplayStore: CodeReplayRecording {
    private let client: any MemcachedTransport
    private let resolver: ReplayStoreEndpointResolver
    private let keyPrefix: String
    private let ttl: Int

    public init(
        client: any MemcachedTransport,
        resolver: ReplayStoreEndpointResolver,
        issuer: String,
        ttl: Int = 300
    ) {
        self.client = client
        self.resolver = resolver
        self.ttl = ttl
        self.keyPrefix = "stst:" + sha256Hex(issuer).prefix(16) + ":"
    }

    /// NO_OVERWRITE-mark the `jti` for the cache endpoint resolved from
    /// `vt`'s catalog. Returns `false` (first redemption, `STORED`) or `true`
    /// (replay, `EXISTS`). Throws `ReplayStoreError` / `MemcachedError` —
    /// `CodeReplayStore.seen(_:vt:)` converts that to local-store use.
    public func record(_ jti: String, vt: ValidatedToken) async throws -> Bool {
        let (host, port) = try await resolver.resolve(vt)
        let stored = try await client.add(
            key: keyPrefix + jti,
            value: "1",
            ttl: ttl,
            host: host,
            port: port
        )
        // `stored == true`  →  key was created now (`STORED`) → first redemption.
        // `stored == false` → key already existed (`EXISTS`) → replay.
        return !stored
    }
}

// MARK: - Endpoint discovery from the token catalog

/// Resolves the memcached `host:port` from a validated token's Keystone
/// service catalog — the same mechanism (and interface preference) the server
/// uses for Nova/Neutron/Cinder (spec §6.5), so a `memcached` service with an
/// internal endpoint is reachable exactly like any other internal-network
/// service.
public actor ReplayStoreEndpointResolver {
    /// The Keystone service type that advertises the shared replay cache.
    public static let serviceType = "memcached"

    private let preferredInterface: String
    private let overrideHost: String?
    private let overridePort: Int?

    public init(
        preferredInterface: String = "public",
        overrideHost: String? = nil,
        overridePort: Int? = nil
    ) {
        self.preferredInterface = preferredInterface
        self.overrideHost = overrideHost
        self.overridePort = overridePort
    }

    /// Resolve the endpoint for this token's catalog. An explicit override
    /// (host AND port both set) wins over the catalog. Probes the catalog's
    /// advertised regions in order (the resolver filters by exact region
    /// match and regions are cloud-specific). Throws
    /// `ReplayStoreError.noEndpoint` when the catalog has no `memcached`
    /// entry and no override is configured.
    public func resolve(_ vt: ValidatedToken) throws -> (host: String, port: Int) {
        if let host = overrideHost, !host.isEmpty, let port = overridePort, port > 0 {
            return (host, port)
        }
        let resolver = EndpointResolver(
            catalog: ServiceCatalog(entries: vt.token.catalog),
            preferredInterface: preferredInterface
        )
        var regions: [String] = []
        var seenRegions = Set<String>()
        for entry in vt.token.catalog {
            for ep in entry.endpoints where !seenRegions.contains(ep.region) {
                seenRegions.insert(ep.region)
                regions.append(ep.region)
            }
        }
        for region in regions {
            if let url = try? resolver.endpoint(serviceType: Self.serviceType, region: region) {
                guard let host = url.host, !host.isEmpty, let port = url.port else {
                    throw ReplayStoreError.badEndpoint(url: url.absoluteString)
                }
                return (host, port)
            }
        }
        throw ReplayStoreError.noEndpoint
    }
}

public enum ReplayStoreError: Error, Sendable {
    case noEndpoint
    case badEndpoint(url: String)
}