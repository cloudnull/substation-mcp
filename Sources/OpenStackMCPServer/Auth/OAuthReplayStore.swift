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
// The shared backend **falls open by default** (`failOpen`, default true):
// any discovery or cache failure degrades that one exchange to the local
// store (with a warning log), so a memcached outage never breaks the OAuth
// flow — it only degrades to single-replica replay semantics until the
// cache is reachable again. Set `failOpen == false` to fail closed instead:
// a shared-store error then rejects the code rather than risk a
// cross-replica replay.

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
/// ``seen(_:vt:)`` never throws when the shared backend is fail-open (the
/// default); with ``CodeReplayStore/init(shared:ttl:logger:failOpen:)``
/// configured fail-closed, a shared-store error re-throws and the token
/// endpoint rejects the code.
public actor CodeReplayStore {
    private let shared: SharedCodeReplayStore?
    private let local: LocalCodeReplayStore
    private let logger: Logger
    /// Whether a shared-store error degrades to local enforcement (default)
    /// or fails the exchange.
    private let failOpen: Bool

    /// Instance-local construction (the original default; single-replica
    /// semantics, zero external dependencies).
    public init(ttl: Int = 300, logger: Logger = Logger(label: "oauth-replay")) {
        self.shared = nil
        self.local = LocalCodeReplayStore(ttl: ttl)
        self.logger = logger
        self.failOpen = true
    }

    /// Shared (multi-replica) construction: `shared` first, failing open to
    /// `local` whenever discovery or the cache errors.
    public init(shared: SharedCodeReplayStore, ttl: Int = 300, logger: Logger, failOpen: Bool = true) {
        self.shared = shared
        self.local = LocalCodeReplayStore(ttl: ttl)
        self.logger = logger
        self.failOpen = failOpen
    }

    /// The original surface: local enforcement only (no catalog to discover a
    /// shared endpoint from).
    public func seen(_ jti: String) async -> Bool {
        await local.record(jti)
    }

    /// Token-endpoint entry point: shared-first. A shared-store error either
    /// degrades to local enforcement (fail-open, the default; never throws)
    /// or re-throws so the token endpoint rejects the code (fail-closed).
    public func seen(_ jti: String, vt: ValidatedToken) async throws -> Bool {
        if let shared {
            do {
                return try await shared.record(jti, vt: vt)
            } catch where failOpen {
                logger.warning(
                    "Shared replay store unavailable; using instance-local enforcement",
                    metadata: ["reason": .string(String(describing: error))]
                )
            } catch {
                logger.error(
                    "Shared replay store unavailable; rejecting authorization code (fail-closed)",
                    metadata: ["reason": .string(String(describing: error))]
                )
                throw error
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
        let servers = try await resolver.resolve(vt)
        guard let (host, port) = RendezvousHashRouter.route(key: keyPrefix + jti, servers: servers) else {
            throw ReplayStoreError.noEndpoint
        }
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

/// Resolves the memcached server list from a validated token's Keystone
/// service catalog — the same mechanism (and interface preference) the server
/// uses for Nova/Neutron/Cinder (spec §6.5), so a `memcached` service with an
/// internal endpoint is reachable exactly like any other internal-network
/// service.
///
/// An explicit override (`oauth.replay_store_endpoint`) wins over the catalog
/// when set; it may be a single `host:port` or a comma-separated list for
/// multi-server deployments (routed via ``RendezvousHashRouter``).
public actor ReplayStoreEndpointResolver {
    /// The Keystone service type that advertises the shared replay cache.
    public static let serviceType = "memcached"

    private let preferredInterface: String
    /// Explicit override servers. When non-empty, the catalog is not consulted.
    private let overrideServers: [(host: String, port: Int)]

    public init(
        preferredInterface: String = "public",
        overrideServers: [(host: String, port: Int)] = []
    ) {
        self.preferredInterface = preferredInterface
        self.overrideServers = overrideServers
    }

    /// Resolve the server list for this token's catalog. An explicit override
    /// (one or more valid `host:port` pairs) wins over the catalog. Probes the
    /// catalog's advertised regions in order. Throws
    /// ``ReplayStoreError/noEndpoint`` when neither source yields a usable
    /// server.
    public func resolve(_ vt: ValidatedToken) throws -> [(host: String, port: Int)] {
        if !overrideServers.isEmpty { return overrideServers }
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
                return [(host: host, port: port)]
            }
        }
        throw ReplayStoreError.noEndpoint
    }
}

/// Deterministically routes a memcached key to exactly one server in a
/// multi-server pool using **Rendezvous Hashing** (HRW / Highest Random
/// Weight) — the same algorithm used by pymemcache's `HashClient` and
/// oslo.cache's memcached backend.
///
/// For each candidate server we compute a stable 64-bit hash of
/// `"node-key"` and pick the server with the highest score. This has two
/// properties modulo hashing does not have:
///
/// 1. When a server is removed only ~1/N of keys remap (vs 100%).
/// 2. Adding a server also remaps only ~1/N of existing keys.
///
/// The hash is FNV-1a 64-bit chosen because:
/// - It is trivially implementable (no external dependency).
/// - It is stable across languages and platforms (unlike Swift's built-in
///   `Hasher`, which is randomly seeded per process and would break
///   cross-replica agreement).
/// - Its avalanche quality is more than sufficient for picking among the
///   small number of memcached nodes (≤ dozens in practice).
///
/// Ties are broken deterministically by lexicographic node label so every
/// replica agrees on the winner without sharing any state.
public struct RendezvousHashRouter: Sendable {
    /// Compute the FNV-1a 64-bit hash of `data`.
    private static func fnv1a64(_ data: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325   // offset basis
        for b in data {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3      // prime
        }
        return h
    }

    /// Pick the winning server for `key` among `servers`. Returns nil when
    /// `servers` is empty.
    public static func route(
        key: String,
        servers: [(host: String, port: Int)]
    ) -> (host: String, port: Int)? {
        guard !servers.isEmpty else { return nil }
        if servers.count == 1 { return servers[0] }
        var bestIdx = 0
        var bestScore: UInt64 = 0
        for (i, s) in servers.enumerated() {
            let label = "\(s.host):\(s.port)"
            let payload = Array((label + "-" + key).utf8)
            let score = fnv1a64(payload)
            if score > bestScore || (score == bestScore && label > "\(servers[bestIdx].host):\(servers[bestIdx].port)") {
                bestScore = score
                bestIdx = i
            }
        }
        return servers[bestIdx]
    }
}

public enum ReplayStoreError: Error, Sendable {
    case noEndpoint
    case badEndpoint(url: String)
}