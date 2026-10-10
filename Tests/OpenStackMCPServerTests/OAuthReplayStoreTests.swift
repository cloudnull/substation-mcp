import Testing
import Foundation
import Logging
import NIOConcurrencyHelpers
import OpenStackClient
@testable import OpenStackMCPServer

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - In-process memcached fake (transport seam)
//
// Conforms to `MemcachedTransport` so the *behavior* of the shared replay
// store (cross-replica single-use, fail-open) is testable deterministically
// without sockets. Real-socket tests of the NIO client are opt-in below.

final class FakeMemcached: MemcachedTransport, @unchecked Sendable {
    private var keys = Set<String>()
    private let lock = NIOLockedValueBox<Bool>(false)
    /// When non-nil, every `add` throws this (simulates an unreachable cache).
    var failure: Error?

    func add(
        key: String, value: String, ttl: Int, host: String, port: Int
    ) async throws -> Bool {
        if let failure { throw failure }
        return lock.withLockedValue { _ in
            if keys.contains(key) { return false }
            keys.insert(key)
            return true
        }
    }
}

// MARK: - Catalog helpers

private func makeVT(
    catalog: [CatalogEntry],
    tokenID: String = "tok-1",
    projectID: String = "proj-1"
) -> ValidatedToken {
    let token = Token(
        id: tokenID,
        expiresAt: Date(timeIntervalSince1970: 9_999_999_999),
        project: IdentityRef(id: projectID),
        domain: IdentityRef(id: "default"),
        user: IdentityRef(id: "user-1"),
        roles: ["admin"],
        catalog: catalog
    )
    return ValidatedToken(token: token, scopes: [.read, .write])
}

private func memcachedCatalogEntry(host: String, port: Int, region: String = "RegionOne") -> CatalogEntry {
    CatalogEntry(
        type: "memcached",
        name: "memcached",
        endpoints: [
            CatalogEndpoint(region: region, interface: "public", url: URL(string: "http://\(host):\(port)")!),
        ]
    )
}

private func computeCatalogEntry(host: String = "127.0.0.1", port: Int = 1111) -> CatalogEntry {
    CatalogEntry(
        type: "compute",
        name: "nova",
        endpoints: [
            CatalogEndpoint(region: "RegionOne", interface: "public", url: URL(string: "http://\(host):\(port)/nova")!),
        ]
    )
}

// MARK: - Local store

@Suite("LocalCodeReplayStore")
struct LocalCodeReplayStoreTests {
    @Test("first record returns false (not a replay)")
    func firstRecord() async {
        let store = LocalCodeReplayStore(ttl: 300)
        let vt = makeVT(catalog: [])
        #expect(await store.record("jti-a", vt: vt) == false)
    }

    @Test("second record of the same jti returns true (replay)")
    func replayDetected() async {
        let store = LocalCodeReplayStore(ttl: 300)
        let vt = makeVT(catalog: [])
        _ = await store.record("jti-b", vt: vt)
        #expect(await store.record("jti-b", vt: vt) == true)
        #expect(await store.record("jti-c", vt: vt) == false)
    }
}

// MARK: - Endpoint resolution from the token catalog

@Suite("ReplayStoreEndpointResolver")
struct ReplayStoreEndpointResolverTests {
    @Test("resolves a memcached catalog endpoint (host + port)")
    func catalogResolution() async throws {
        let resolver = ReplayStoreEndpointResolver()
        let vt = makeVT(catalog: [computeCatalogEntry(), memcachedCatalogEntry(host: "10.0.0.5", port: 11211)])
        let (host, port) = try await resolver.resolve(vt)
        #expect(host == "10.0.0.5")
        #expect(port == 11211)
    }

    @Test("throws noEndpoint when the catalog has no memcached entry")
    func noEndpoint() async throws {
        let resolver = ReplayStoreEndpointResolver()
        let vt = makeVT(catalog: [computeCatalogEntry()])
        do {
            _ = try await resolver.resolve(vt)
            Issue.record("expected noEndpoint")
        } catch let e as ReplayStoreError {
            guard case .noEndpoint = e else {
                Issue.record("wrong error: \(e)")
                return
            }
        }
    }

    @Test("explicit override wins over the catalog")
    func overrideWins() async throws {
        let resolver = ReplayStoreEndpointResolver(
            overrideHost: "127.0.0.1",
            overridePort: 11999
        )
        let vt = makeVT(catalog: [memcachedCatalogEntry(host: "10.0.0.5", port: 11211)])
        let (host, port) = try await resolver.resolve(vt)
        #expect(host == "127.0.0.1")
        #expect(port == 11999)
    }

    @Test("internal interface is preferred when the cloud advertises it")
    func internalPreference() async throws {
        let resolver = ReplayStoreEndpointResolver(preferredInterface: "internal")
        let vt = makeVT(catalog: [CatalogEntry(
            type: "memcached",
            name: "memcached",
            endpoints: [
                CatalogEndpoint(region: "RegionOne", interface: "public", url: URL(string: "http://public.mem:11211")!),
                CatalogEndpoint(region: "RegionOne", interface: "internal", url: URL(string: "http://internal.mem:11211")!),
            ]
        )])
        let (host, port) = try await resolver.resolve(vt)
        #expect(host == "internal.mem")
        #expect(port == 11211)
    }
}

// MARK: - Shared store (in-process fake transport)

@Suite("SharedCodeReplayStore")
struct SharedCodeReplayStoreTests {
    /// Two `SharedCodeReplayStore` instances (simulating two replicas) that
    /// both resolve their endpoint to `10.0.0.5:11211` and share one
    /// `FakeMemcached` — the cross-replica guarantee.
    private func replica(
        _ fake: FakeMemcached,
        issuer: String = "http://issuer.example/v1/oauth"
    ) -> SharedCodeReplayStore {
        SharedCodeReplayStore(
            client: fake,
            resolver: ReplayStoreEndpointResolver(),
            issuer: issuer,
            ttl: 300
        )
    }

    @Test("two stores over one cache enforce cross-replica single-use")
    func crossReplicaReplay() async throws {
        let fake = FakeMemcached()
        let vt = makeVT(catalog: [memcachedCatalogEntry(host: "10.0.0.5", port: 11211)])
        let replicaA = replica(fake)
        let replicaB = replica(fake)
        let first = try await replicaA.record("shared-jti", vt: vt)
        let second = try await replicaB.record("shared-jti", vt: vt)
        #expect(first == false, "first redemption must be clean")
        #expect(second == true, "second replica must see the replay")
    }

    @Test("CodeReplayStore fails open to local when the cache errors")
    func failOpen() async throws {
        let fake = FakeMemcached()
        fake.failure = MemcachedError.timeout
        let vt = makeVT(catalog: [memcachedCatalogEntry(host: "10.0.0.5", port: 11211)])
        let store = CodeReplayStore(
            shared: replica(fake),
            logger: Logger(label: "test-replay")
        )
        let first = await store.seen("fo-1", vt: vt)
        let second = await store.seen("fo-1", vt: vt)
        #expect(first == false)
        #expect(second == true, "local fallback must still enforce single-use")
    }

    @Test("CodeReplayStore fails open when the catalog has no memcached entry")
    func failOpenNoCatalog() async throws {
        let fake = FakeMemcached()
        let vt = makeVT(catalog: [computeCatalogEntry()])
        let store = CodeReplayStore(
            shared: replica(fake),
            logger: Logger(label: "test-replay")
        )
        let first = await store.seen("nc-1", vt: vt)
        let second = await store.seen("nc-1", vt: vt)
        #expect(first == false)
        #expect(second == true)
    }

    @Test("default (local) CodeReplayStore enforces single-use in-process")
    func defaultLocal() async throws {
        let store = CodeReplayStore(ttl: 300)
        let vt = makeVT(catalog: [])
        let first = await store.seen("l-1", vt: vt)
        let second = await store.seen("l-1", vt: vt)
        #expect(first == false)
        #expect(second == true)
    }
}

// MARK: - Memcached wire protocol (opt-in integration)
//
// Real-socket tests of the NIO client. They self-skip unless
// OSMCP_IT_MEMCACHED is set to `host:port`, so `swift test` in CI (and in
// environments where raw NIO loopback TCP is unavailable) never touches a
// live memcached.

@Suite("MemcachedClient", .timeLimit(.minutes(5)))
struct MemcachedClientTests {
    @Test("add round-trips STORED then EXISTS against a real memcached")
    func wireProtocol() async throws {
        guard let raw = ProcessInfo.processInfo.environment["OSMCP_IT_MEMCACHED"],
              let sep = raw.firstIndex(of: ":"),
              let port = Int(raw[raw.index(after: sep)...])
        else {
            return // opt-in: no live memcached configured
        }
        let host = String(raw[..<sep])
        let client = MemcachedClient(connectTimeoutSeconds: 3, readTimeoutSeconds: 3)
        defer { client.shutdown() }
        let key = "stst-it-" + UUID().uuidString
        let first = try await client.add(key: key, value: "1", ttl: 5, host: host, port: port)
        let second = try await client.add(key: key, value: "1", ttl: 5, host: host, port: port)
        #expect(first == true, "first add should STORE")
        #expect(second == false, "second add should EXISTS")
    }
}

// MARK: - Config surface

@Suite("Config replay-store keys")
struct ConfigReplayStoreTests {
    @Test("defaults are local + no endpoint")
    func defaults() {
        let cfg = OpenStackMCPConfig()
        #expect(cfg.oauthReplayStore == "local")
        #expect(cfg.oauthReplayStoreEndpoint == nil)
        #expect(cfg.oauthReplayStoreEndpointParsed == nil)
    }

    @Test("endpoint override parses host:port")
    func endpointParsed() {
        var cfg = OpenStackMCPConfig()
        cfg.oauthReplayStore = "memcached"
        cfg.oauthReplayStoreEndpoint = "10.0.0.9:11211"
        let parsed = cfg.oauthReplayStoreEndpointParsed
        #expect(parsed?.host == "10.0.0.9")
        #expect(parsed?.port == 11211)
    }

    @Test("malformed endpoint parses to nil (catalog discovery takes over)")
    func endpointMalformed() {
        var cfg = OpenStackMCPConfig()
        cfg.oauthReplayStoreEndpoint = "no-port"
        #expect(cfg.oauthReplayStoreEndpointParsed == nil)
        var cfg2 = OpenStackMCPConfig()
        cfg2.oauthReplayStoreEndpoint = "host:99999"
        #expect(cfg2.oauthReplayStoreEndpointParsed == nil)
    }
}
