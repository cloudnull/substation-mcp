import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import Logging
import Atomics
@testable import OpenStackClient

@Suite("Transport")
struct TransportTests {
    private func makeTransport(baseURL: URL, token: String = "tok-123") -> Transport {
        let cloud = CloudEntry(name: "test", authURL: baseURL)
        return Transport(
            cloud: cloud,
            tokenSource: { token },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test-transport")
        )
    }

    // MARK: - Headers

    @Test func headersPresentOnRequest() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/headers") { req in
            let json = """
            {"x-auth-token":"\(req.headers["x-auth-token"] ?? "")","user-agent":"\(req.headers["user-agent"] ?? "")","request-id":"\(req.headers["x-openstack-request-id"] ?? "")","accept":"\(req.headers["accept"] ?? "")"}
            """
            return (200, json, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, body, requestID) = try await transport.request(
            method: "GET", service: "test", path: "/headers"
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(json["x-auth-token"] == "tok-123")
        #expect(json["user-agent"] == "substation-mcp/0.1.0")
        #expect(json["accept"] == "application/json")
        let rid = json["request-id"] ?? ""
        #expect(UUID(uuidString: rid) != nil)
        #expect(requestID == rid)
    }

    // Some Keystone versions (e.g. 3.14) only honor the token on the whoami
    // endpoint (GET /v3/auth/tokens) when it is sent as X-Subject-Token; they
    // ignore it on X-Auth-Token there. The transport must therefore present the
    // token on BOTH headers so the server-side validator works everywhere.
    @Test func presentsTokenOnXSubjectTokenToo() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/headers") { req in
            let json = """
            {"x-auth-token":"\(req.headers["x-auth-token"] ?? "")","x-subject-token":"\(req.headers["x-subject-token"] ?? "")"}
            """
            return (200, json, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, body, _) = try await transport.request(
            method: "GET", service: "test", path: "/headers"
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(json["x-auth-token"] == "tok-123")
        #expect(json["x-subject-token"] == "tok-123", "token must also be sent as X-Subject-Token")
    }

    @Test func noTokenMeansNoXSubjectTokenHeader() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/headers") { req in
            let json = """
            {"x-subject-token":"\(req.headers["x-subject-token"] ?? "")"}
            """
            return (200, json, [("Content-Type", "application/json")])
        }

        // tokenOverride: "" suppresses the standing token source (anonymous req).
        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, body, _) = try await transport.request(
            method: "GET", service: "test", path: "/headers", tokenOverride: ""
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(json["x-subject-token"] == "", "no token => no X-Subject-Token header")
    }

    // MARK: - Retry

    @Test func retriesOn503ForGET() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let attempts = ManagedAtomic(0)
        server.addHandler("/flaky") { _ in
            attempts.wrappingIncrement(by: 1, ordering: .relaxed)
            let n = attempts.load(ordering: .relaxed)
            if n < 3 {
                return (503, "unavailable", [("Content-Type", "text/plain")])
            }
            return (200, #"{"ok":true}"#, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        let (status, _, _) = try await transport.request(
            method: "GET", service: "test", path: "/flaky"
        )
        #expect(status == 200)
        #expect(attempts.load(ordering: .relaxed) == 3)
    }

    @Test func noRetryOnPOST() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let attempts = ManagedAtomic(0)
        server.addHandler("/no-retry") { _ in
            attempts.wrappingIncrement(by: 1, ordering: .relaxed)
            return (503, "unavailable", [("Content-Type", "text/plain")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(
                method: "POST", service: "test", path: "/no-retry", body: .init("{}".utf8)
            )
            #expect(false, "should have thrown")
        } catch {
            #expect(attempts.load(ordering: .relaxed) == 1)
        }
    }

    // MARK: - Error normalization

    @Test func normalizesNovaError() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/error-nova") { _ in
            let body = #"{"itemNotFound": {"message": "Instance not found."}}"#
            return (404, body, [("Content-Type", "application/json")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(method: "GET", service: "nova", path: "/error-nova")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.status == 404)
            #expect(err.code == "itemNotFound")
            #expect(err.message == "Instance not found.")
            #expect(err.service == "nova")
        }
    }

    @Test func normalizesGlancePlainText() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/glance-missing") { _ in
            return (400, "Image not found", [("Content-Type", "text/plain")])
        }

        let transport = makeTransport(baseURL: server.baseURL)
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(method: "GET", service: "glance", path: "/glance-missing")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.status == 400)
            #expect(err.code == nil)
            #expect(err.message == "Image not found")
            #expect(err.service == "glance")
        }
    }

    // MARK: - Timeout

    @Test func timeoutOnSlowEndpoint() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/slow") { _ in
            try await Task.sleep(for: .seconds(2))
            return (200, "late", [("Content-Type", "text/plain")])
        }

        // Use a transport with a 300ms read timeout so the 2s endpoint times out
        let cloud = CloudEntry(name: "test", authURL: server.baseURL)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-123" },
            maxConnectionsPerHost: 4,
            requestTimeout: .milliseconds(300),
            logger: Logger(label: "test-transport")
        )
        defer { transport.syncShutdown() }
        do {
            _ = try await transport.request(
                method: "GET", service: "test", path: "/slow"
            )
            #expect(false, "should have timed out")
        } catch let err as OpenStackError {
            #expect(err.retriable == true)
            #expect(err.status == 0)
        }
    }

    // MARK: - Multi-endpoint routing (per-service endpoint resolution)

    /// Proves the client routes a service call to the catalog's per-service host
    /// (Rackspace-style: nova on its own host with a `/v2.1` root) and strips the
    /// client's `basePath`, instead of always going under the cloud authURL.
    @Test func routesComputeToCatalogHostAndStripsBasePath() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        // The catalog's nova endpoint is <server>/v2.1 (Rackspace-style: the
        // host is the nova host, the path is the version root). The client's
        // basePath is "nova"; the request must arrive at /v2.1/servers/detail
        // (nova stripped), NOT /nova/v2.1/... or under the authURL host.
        let hit = PathRecorder()
        server.addHandler("/v2.1/servers/detail") { req in
            hit.record(req.path)
            return (200, #"{"servers":[]}"#, [("Content-Type", "application/json")])
        }

        // authURL points at a DIFFERENT, unreachable host: if the client wrongly
        // routed under authURL the request would fail (connection error), so
        // success proves it used the catalog host.
        let unreachable = URL(string: "http://127.0.0.1:1")! // port 1 = nothing
        let cloud = CloudEntry(name: "rs", authURL: unreachable, regionName: "R1")
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-rs" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test-routing")
        )
        let cache = Cache()
        let region = ComputeRegion(
            cloud: cloud, transport: transport, cache: cache,
            logger: Logger(label: "test-routing"),
            defaultRegion: "R1", basePath: "nova"
        )
        let token = Token(
            id: "tok-rs",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            project: IdentityRef(id: "p1", name: "P", domain: nil),
            domain: IdentityRef(id: "d1", name: "D", domain: nil),
            user: IdentityRef(id: "u1", name: "U", domain: nil),
            roles: ["member"],
            catalog: [
                CatalogEntry(type: "compute", name: "nova", endpoints: [
                    CatalogEndpoint(region: "R1", interface: "public", url: server.baseURL.appendingPathComponent("v2.1"))
                ])
            ]
        )
        let vt = ValidatedToken(token: token, scopes: [.read])

        let servers = try await region.listServers(vt)
        #expect(servers.isEmpty, "expected an empty server list from the stub")
        #expect(hit.path == "/v2.1/servers/detail", "client should have hit /v2.1/servers/detail (basePath stripped), got \(hit.path)")
    }

    /// Nova sends its negotiated microversion header on data-plane requests.
    /// The stub serves the REAL version-doc format at the nova root (`/v2.1`)
    /// and records the header on the `/v2.1/servers/detail` call. The header
    /// must be `X-OpenStack-Nova-API-Version` with the negotiated value
    /// (min(serverMax 2.100, clientMax 2.104) = 2.100).
    @Test func sendsNegotiatedMicroversionHeaderOnNovaRequests() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        // Real nova version doc at the service root. Because the catalog URL is
        // the authoritative root (<server>/v2.1, pathPrefix empty), the version
        // doc is fetched at the base root (<server>/v2.1, no trailing slash).
        let versionDoc = #"{"versions":[{"id":"v2.1","status":"CURRENT","version":"2.100","min_version":"2.1"}]}"#
        let vdocHits = PathRecorder()
        server.addHandler("/v2.1") { req in
            vdocHits.record(req.path)
            return (200, versionDoc, [("Content-Type", "application/json")])
        }
        let mvHeader = HeaderRecorder("X-OpenStack-Nova-API-Version")
        server.addHandler("/v2.1/servers/detail") { req in
            mvHeader.record(req.headers)
            return (200, #"{"servers":[]}"#, [("Content-Type", "application/json")])
        }

        let unreachable = URL(string: "http://127.0.0.1:1")!
        let cloud = CloudEntry(name: "rs", authURL: unreachable, regionName: "R1")
        let transport = Transport(
            cloud: cloud, tokenSource: { "tok-rs" },
            maxConnectionsPerHost: 4, requestTimeout: .seconds(10),
            logger: Logger(label: "test-mv-header")
        )
        defer { transport.syncShutdown() }
        let cache = Cache()
        let region = ComputeRegion(
            cloud: cloud, transport: transport, cache: cache,
            logger: Logger(label: "test-mv-header"),
            defaultRegion: "R1", basePath: "nova"
        )
        let token = Token(
            id: "tok-rs",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            project: IdentityRef(id: "p1", name: "P", domain: nil),
            domain: IdentityRef(id: "d1", name: "D", domain: nil),
            user: IdentityRef(id: "u1", name: "U", domain: nil),
            roles: ["member"],
            catalog: [
                CatalogEntry(type: "compute", name: "nova", endpoints: [
                    CatalogEndpoint(region: "R1", interface: "public", url: server.baseURL.appendingPathComponent("v2.1"))
                ])
            ]
        )
        let vt = ValidatedToken(token: token, scopes: [.read])

        _ = try await region.listServers(vt)
        #expect(vdocHits.path != nil, "version doc should have been fetched, hit: \(String(describing: vdocHits.path))")
        #expect(mvHeader.value == "2.100",
                "nova should send X-OpenStack-Nova-API-Version: 2.100 (negotiated), got \(String(describing: mvHeader.value))")
    }

    /// Proves the neutron special-case: when the catalog URL omits the version
    /// root (Rackspace advertises neutron at `.../neutron/`), the client uses the
    /// catalog host + the version root (`v2.0`), not the full basePath
    /// (`neutron/v2.0`) which would add a spurious `/neutron` segment.
    @Test func routesNeutronWithVersionRootWhenCatalogOmitsIt() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let hit = PathRecorder()
        server.addHandler("/v2.0/networks") { req in
            hit.record(req.path)
            return (200, #"{"networks":[]}"#, [("Content-Type", "application/json")])
        }

        let unreachable = URL(string: "http://127.0.0.1:1")!
        let cloud = CloudEntry(name: "rs", authURL: unreachable, regionName: "R1")
        let transport = Transport(
            cloud: cloud, tokenSource: { "tok-rs" },
            maxConnectionsPerHost: 4, requestTimeout: .seconds(10),
            logger: Logger(label: "test-routing")
        )
        let cache = Cache()
        let region = NetworkRegion(
            cloud: cloud, transport: transport, cache: cache,
            logger: Logger(label: "test-routing"),
            defaultRegion: "R1", basePath: "neutron/v2.0"
        )
        let token = Token(
            id: "tok-rs",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            project: IdentityRef(id: "p1", name: "P", domain: nil),
            domain: IdentityRef(id: "d1", name: "D", domain: nil),
            user: IdentityRef(id: "u1", name: "U", domain: nil),
            roles: ["member"],
            catalog: [
                // Rackspace-style: neutron endpoint path omits the /v2.0 root.
                CatalogEntry(type: "network", name: "neutron", endpoints: [
                    CatalogEndpoint(region: "R1", interface: "public", url: server.baseURL.appendingPathComponent("neutron"))
                ])
            ]
        )
        let vt = ValidatedToken(token: token, scopes: [.read])

        let networks = try await region.listNetworks(vt)
        #expect(networks.isEmpty)
        #expect(hit.path == "/v2.0/networks", "neutron should hit /v2.0/networks (host + version root), got \(hit.path)")
    }

    /// Rackspace advertises glance at the bare host (no /v2). The client must
    /// use the catalog host + the version root (v2), so images land at
    /// /v2/images (not /images, which would hit glance's 300 version root).
    @Test func routesGlanceWithVersionRootWhenCatalogOmitsIt() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let hit = PathRecorder()
        server.addHandler("/v2/images") { req in
            hit.record(req.path)
            return (200, #"{"images":[]}"#, [("Content-Type", "application/json")])
        }

        let unreachable = URL(string: "http://127.0.0.1:1")!
        let cloud = CloudEntry(name: "rs", authURL: unreachable, regionName: "R1")
        let transport = Transport(
            cloud: cloud, tokenSource: { "tok-rs" },
            maxConnectionsPerHost: 4, requestTimeout: .seconds(10),
            logger: Logger(label: "test-routing")
        )
        let cache = Cache()
        let region = ImageRegion(
            cloud: cloud, transport: transport, cache: cache,
            logger: Logger(label: "test-routing"),
            basePath: "glance/v2", defaultRegion: "R1"
        )
        let token = Token(
            id: "tok-rs",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            project: IdentityRef(id: "p1", name: "P", domain: nil),
            domain: IdentityRef(id: "d1", name: "D", domain: nil),
            user: IdentityRef(id: "u1", name: "U", domain: nil),
            roles: ["member"],
            catalog: [
                // Rackspace-style: glance endpoint omits the /v2 root.
                CatalogEntry(type: "image", name: "glance", endpoints: [
                    CatalogEndpoint(region: "R1", interface: "public", url: server.baseURL)
                ])
            ]
        )
        let vt = ValidatedToken(token: token, scopes: [.read])

        let images = try await region.listImages(vt)
        #expect(images.isEmpty)
        #expect(hit.path == "/v2/images", "glance should hit /v2/images (host + version root), got \(String(describing: hit.path))")
    }
}

/// Thread-safe single-slot path recorder for @Sendable test handlers.
final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _path = path
    }
    var path: String? {
        lock.lock(); defer { lock.unlock() }
        return _path
    }
}

final class HeaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    private let name: String
    init(_ name: String) { self.name = name }
    func record(_ headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _value = headers[name.lowercased()]
    }
    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
