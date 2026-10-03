import Testing
import Foundation
import Logging
import Atomics
@testable import OpenStackClient

@Suite("Microversion")
struct MicroversionTests {
    @Test func roundTrip() throws {
        let v = try #require(Microversion("2.79"))
        #expect(v.stringValue == "2.79")
        #expect(v.major == 2)
        #expect(v.minor == 79)
    }

    @Test func numericComparison_notLexicographic() throws {
        let v79 = try #require(Microversion("2.79"))
        let v104 = try #require(Microversion("2.104"))
        #expect(v79 < v104, "2.79 < 2.104 numerically (79 < 104), not lexicographically")
        #expect(v104 > v79)
    }

    @Test func equal() throws {
        let a = try #require(Microversion("2.79"))
        let b = try #require(Microversion("2.79"))
        #expect(a == b)
    }

    @Test func differentMinor() throws {
        let a = try #require(Microversion("2.78"))
        let b = try #require(Microversion("2.79"))
        #expect(a < b)
    }

    @Test func garbage_returnsNil() {
        #expect(Microversion("garbage") == nil)
        #expect(Microversion("") == nil)
        #expect(Microversion("2") == nil)
        #expect(Microversion("2.79.1") == nil)
    }
}

@Suite("NovaFeature")
struct NovaFeatureTests {
    @Test func deleteOnTermination_at278() throws {
        let v = try #require(Microversion("2.78"))
        #expect(!NovaFeature.deleteOnTermination.available(in: v))
    }

    @Test func deleteOnTermination_at279() throws {
        let v = try #require(Microversion("2.79"))
        #expect(NovaFeature.deleteOnTermination.available(in: v))
    }

    @Test func asyncVolumeAttach_at2100() throws {
        let v = try #require(Microversion("2.100"))
        #expect(!NovaFeature.asyncVolumeAttach.available(in: v))
    }

    @Test func asyncVolumeAttach_at2101() throws {
        let v = try #require(Microversion("2.101"))
        #expect(NovaFeature.asyncVolumeAttach.available(in: v))
    }

    @Test func hostname_at290() throws {
        let v90 = try #require(Microversion("2.90"))
        let v89 = try #require(Microversion("2.89"))
        #expect(!NovaFeature.hostname.available(in: v89))
        #expect(NovaFeature.hostname.available(in: v90))
    }
}

@Suite("EndpointResolver")
struct EndpointResolverTests {
    private func makeCatalog() -> ServiceCatalog {
        ServiceCatalog(entries: [
            CatalogEntry(
                type: "compute",
                name: "nova",
                endpoints: [
                    CatalogEndpoint(region: "RegionOne", interface: "public", url: URL(string: "http://public.example.com")!),
                    CatalogEndpoint(region: "RegionOne", interface: "internal", url: URL(string: "http://internal.example.com")!),
                    CatalogEndpoint(region: "RegionTwo", interface: "internal", url: URL(string: "http://internal2.example.com")!)
                ]
            ),
            CatalogEntry(
                type: "network",
                name: "neutron",
                endpoints: [
                    CatalogEndpoint(region: "RegionOne", interface: "public", url: URL(string: "http://net.example.com")!)
                ]
            )
        ])
    }

    @Test func resolvesPublicPrefered() throws {
        let resolver = EndpointResolver(catalog: makeCatalog(), preferredInterface: "public")
        let url = try resolver.endpoint(serviceType: "compute", region: "RegionOne")
        #expect(url.absoluteString == "http://public.example.com")
    }

    @Test func fallsBackToInternal() throws {
        let resolver = EndpointResolver(catalog: makeCatalog(), preferredInterface: "public")
        let url = try resolver.endpoint(serviceType: "compute", region: "RegionTwo")
        #expect(url.absoluteString == "http://internal2.example.com")
    }

    @Test func missingService_throws() {
        let resolver = EndpointResolver(catalog: makeCatalog(), preferredInterface: "public")
        do {
            _ = try resolver.endpoint(serviceType: "image", region: "RegionOne")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.code == "no-endpoint")
            #expect(err.message.contains("image"))
            #expect(err.message.contains("RegionOne"))
        } catch {
            #expect(false, "wrong error type: \(error)")
        }
    }

    @Test func missingRegion_throws() {
        let resolver = EndpointResolver(catalog: makeCatalog(), preferredInterface: "public")
        do {
            _ = try resolver.endpoint(serviceType: "compute", region: "RegionThree")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.code == "no-endpoint")
            #expect(err.message.contains("RegionThree"))
        } catch {
            #expect(false, "wrong error type: \(error)")
        }
    }

    // MARK: - resolveEndpoint (per-service base + prefix for multi-endpoint routing)

    /// A catalog that mirrors the fake's conventional layout: every endpoint URL
    /// carries the service's full base (service-name + version), matching the
    /// client's basePath.
    private func makeConventionalCatalog() -> ServiceCatalog {
        ServiceCatalog(entries: [
            CatalogEntry(type: "compute", name: "nova", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://keystone.local/nova")!)
            ]),
            CatalogEntry(type: "network", name: "neutron", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://keystone.local/neutron/v2.0")!)
            ]),
            CatalogEntry(type: "volumev3", name: "cinder", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://keystone.local/cinder/v3")!)
            ])
        ])
    }

    /// A catalog that mirrors Rackspace: each service on its own host, and the
    /// neutron endpoint omits the version root (real API is at /v2.0).
    private func makeRackspaceCatalog() -> ServiceCatalog {
        ServiceCatalog(entries: [
            CatalogEntry(type: "compute", name: "nova", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://nova.api.sjc3.example.com/v2.1")!)
            ]),
            CatalogEntry(type: "network", name: "neutron", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://neutron.api.sjc3.example.com/neutron")!)
            ]),
            CatalogEntry(type: "volumev3", name: "cinder", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://cinder.api.sjc3.example.com/v3")!)
            ])
        ])
    }

    @Test func conventionalCatalog_usesCatalogURLAsRoot() throws {
        // Fake/conventional: the catalog URL already carries the service root,
        // so the client's basePath is dropped (pathPrefix == "").
        let r = EndpointResolver(catalog: makeConventionalCatalog(), preferredInterface: "public")
        // nova: serviceRoot empty -> catalog URL is always the authoritative
        // root, basePath dropped.
        let nova = try r.resolveEndpoint(serviceType: "compute", region: "R1", basePath: "nova", serviceRoot: "", fallbackBase: URL(string: "http://keystone.local")!)
        #expect(nova.base.absoluteString == "http://keystone.local/nova")
        #expect(nova.pathPrefix == "")

        let net = try r.resolveEndpoint(serviceType: "network", region: "R1", basePath: "neutron/v2.0", serviceRoot: "v2.0", fallbackBase: URL(string: "http://keystone.local")!)
        #expect(net.base.absoluteString == "http://keystone.local/neutron/v2.0")
        #expect(net.pathPrefix == "")
    }

    @Test func rackspaceCatalog_usesCatalogURLAsRoot() throws {
        // Multi-endpoint, catalog carries the version root: use it in full and
        // drop the client basePath.
        let r = EndpointResolver(catalog: makeRackspaceCatalog(), preferredInterface: "public")
        // nova: serviceRoot empty -> the Rackspace catalog URL (nova.api/v2.1)
        // is used in full and the basePath is dropped.
        let nova = try r.resolveEndpoint(serviceType: "compute", region: "SJC3", basePath: "nova", serviceRoot: "", fallbackBase: URL(string: "https://keystone.api.sjc3.example.com")!)
        #expect(nova.base.absoluteString == "https://nova.api.sjc3.example.com/v2.1")
        #expect(nova.pathPrefix == "")

        let cinder = try r.resolveEndpoint(serviceType: "volumev3", region: "SJC3", basePath: "cinder/v3", serviceRoot: "v3", fallbackBase: URL(string: "https://keystone.api.sjc3.example.com")!)
        #expect(cinder.base.absoluteString == "https://cinder.api.sjc3.example.com/v3")
        #expect(cinder.pathPrefix == "")
    }

    @Test func rackspaceNeutron_omitsVersion_usesHostAndServiceRoot() throws {
        // Rackspace neutron catalog path is /neutron (no version). The real API
        // is at the host's /v2.0. So: base = catalog host, pathPrefix = the
        // service root (v2.0), NOT the full basePath (neutron/v2.0) — that would
        // add a spurious /neutron segment.
        let r = EndpointResolver(catalog: makeRackspaceCatalog(), preferredInterface: "public")
        let net = try r.resolveEndpoint(serviceType: "network", region: "SJC3", basePath: "neutron/v2.0", serviceRoot: "v2.0", fallbackBase: URL(string: "https://keystone.api.sjc3.example.com")!)
        #expect(net.base.absoluteString == "https://neutron.api.sjc3.example.com")
        #expect(net.pathPrefix == "v2.0")
    }

    @Test func missingCatalogEndpoint_fallsBackToAuthURLWithBasePath() throws {
        // Service absent from the catalog (e.g. designate not on Rackspace): use
        // the cloud authURL with the full basePath — the single-endpoint behavior.
        let r = EndpointResolver(catalog: makeRackspaceCatalog(), preferredInterface: "public")
        let fb = URL(string: "https://keystone.api.sjc3.example.com")!
        let dns = try r.resolveEndpoint(serviceType: "dns", region: "SJC3", basePath: "designate/v3", serviceRoot: "v3", fallbackBase: fb)
        #expect(dns.base.absoluteString == "https://keystone.api.sjc3.example.com")
        #expect(dns.pathPrefix == "designate/v3")
    }

    /// A Rackspace catalog where glance/barbican/octavia endpoints omit the
    /// version root (Rackspace advertises them at the bare host). The resolver
    /// must append the service's version root so the request reaches the real
    /// API (e.g. glance at /v2, barbican/octavia at /v1).
    private func makeRackspaceNoVersionCatalog() -> ServiceCatalog {
        ServiceCatalog(entries: [
            CatalogEntry(type: "image", name: "glance", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://glance.api.sjc3.example.com")!)
            ]),
            CatalogEntry(type: "key-manager", name: "barbican", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://barbican.api.sjc3.example.com")!)
            ]),
            CatalogEntry(type: "load-balancer", name: "octavia", endpoints: [
                CatalogEndpoint(region: "SJC3", interface: "public", url: URL(string: "https://octavia.api.sjc3.example.com")!)
            ])
        ])
    }

    @Test func rackspaceGlanceBarbicanOctavia_omitVersion_useHostAndServiceRoot() throws {
        let r = EndpointResolver(catalog: makeRackspaceNoVersionCatalog(), preferredInterface: "public")
        let fb = URL(string: "https://keystone.api.sjc3.example.com")!

        let glance = try r.resolveEndpoint(serviceType: "image", region: "SJC3", basePath: "glance/v2", serviceRoot: "v2", fallbackBase: fb)
        #expect(glance.base.absoluteString == "https://glance.api.sjc3.example.com")
        #expect(glance.pathPrefix == "v2")

        let barbican = try r.resolveEndpoint(serviceType: "key-manager", region: "SJC3", basePath: "barbican/v1", serviceRoot: "v1", fallbackBase: fb)
        #expect(barbican.base.absoluteString == "https://barbican.api.sjc3.example.com")
        #expect(barbican.pathPrefix == "v1")

        // Rackspace octavia is v2 (the catalog omits the version root; the client
        // adds the v2 serviceRoot).
        let octavia = try r.resolveEndpoint(serviceType: "load-balancer", region: "SJC3", basePath: "loadbalancer/v2", serviceRoot: "v2", fallbackBase: fb)
        #expect(octavia.base.absoluteString == "https://octavia.api.sjc3.example.com")
        #expect(octavia.pathPrefix == "v2")
    }

    /// The same services in a conventional (fake) catalog where the version root
    /// IS present: the resolver uses the catalog URL in full (strips basePath).
    @Test func conventionalGlanceBarbicanOctavia_catalogCarriesVersion() throws {
        let r = EndpointResolver(catalog: ServiceCatalog(entries: [
            CatalogEntry(type: "image", name: "glance", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://k.local/glance/v2")!)
            ]),
            CatalogEntry(type: "key-manager", name: "barbican", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://k.local/barbican/v1")!)
            ]),
            CatalogEntry(type: "load-balancer", name: "octavia", endpoints: [
                CatalogEndpoint(region: "R1", interface: "public", url: URL(string: "http://k.local/loadbalancer/v2")!)
            ])
        ]), preferredInterface: "public")

        let glance = try r.resolveEndpoint(serviceType: "image", region: "R1", basePath: "glance/v2", serviceRoot: "v2", fallbackBase: URL(string: "http://k.local")!)
        #expect(glance.base.absoluteString == "http://k.local/glance/v2")
        #expect(glance.pathPrefix == "")

        let octavia = try r.resolveEndpoint(serviceType: "load-balancer", region: "R1", basePath: "loadbalancer/v2", serviceRoot: "v2", fallbackBase: URL(string: "http://k.local")!)
        #expect(octavia.base.absoluteString == "http://k.local/loadbalancer/v2")
        #expect(octavia.pathPrefix == "")
    }
}

@Suite("NeutronExtensions")
struct NeutronExtensionsTests {
    @Test func hasAlias() {
        let ext = NeutronExtensions(aliases: ["router", "address-group"])
        #expect(ext.has("address-group"))
        #expect(!ext.has("qos"))
    }
}

@Suite("VersionNegotiator")
struct VersionNegotiatorTests {
    /// The real nova/cinder version-doc format: {"versions":[{...}]}.
    private func makeRealVersionDoc(maxVersion: String, status: String = "CURRENT") -> String {
        """
        {
          "versions": [
            {"id": "v2.0", "status": "SUPPORTED", "min_version": "2.1"},
            {"id": "v2.1", "status": "\(status)", "version": "\(maxVersion)", "min_version": "2.1"}
          ]
        }
        """
    }

    /// The legacy object form (used by the fake): {"version":{"max_version":...}}.
    private func makeLegacyVersionDoc(maxVersion: String) -> String {
        """
        {
          "version": {
            "id": "v2.1",
            "status": "stable",
            "max_version": "\(maxVersion)",
            "min_version": "2.1"
          }
        }
        """
    }

    private func novaProfile() -> ServiceVersionProfile {
        ServiceVersionProfile(
            serviceType: "compute",
            hasMicroversion: true,
            headerName: "X-OpenStack-Nova-API-Version",
            clientMax: Microversion(major: 2, minor: 104),
            floor: Microversion(major: 2, minor: 79)
        )
    }

    @Test func negotiatesToServerMax() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let counter = ManagedAtomic(0)
        server.addHandler("/") { _ in
            counter.wrappingIncrement(by: 1, ordering: .relaxed)
            return (200, makeLegacyVersionDoc(maxVersion: "2.104"), [("Content-Type", "application/json")])
        }

        let cloud = CloudEntry(name: "test", authURL: server.baseURL)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-123" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }

        let cache = Cache(maxEntries: 100)
        let negotiator = VersionNegotiator(transport: transport, cache: cache, profile: novaProfile())

        let v = try await negotiator.negotiate(region: "RegionOne")
        #expect(v.version == Microversion(major: 2, minor: 104))
        #expect(counter.load(ordering: .relaxed) == 1)

        // Second call should be cached
        let v2 = try await negotiator.negotiate(region: "RegionOne")
        #expect(v2.version == v.version)
        #expect(counter.load(ordering: .relaxed) == 1, "Second call should hit cache")
    }

    /// The real nova version-doc format ({"versions":[...]}) with HTTP 200.
    @Test func parsesRealNovaVersionDoc() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/") { _ in
            (200, makeRealVersionDoc(maxVersion: "2.100"), [("Content-Type", "application/json")])
        }
        let transport = Transport(cloud: CloudEntry(name: "t", authURL: server.baseURL),
            tokenSource: { "tok" }, logger: Logger(label: "test"))
        defer { transport.syncShutdown() }
        let negotiator = VersionNegotiator(transport: transport, cache: Cache(maxEntries: 100), profile: novaProfile())
        let v = try await negotiator.negotiate(region: "RegionOne")
        // Server max 2.100 < client max 2.104 -> negotiates to 2.100, and the
        // microversion header is populated.
        #expect(v.version == Microversion(major: 2, minor: 100))
        #expect(v.headerName == "X-OpenStack-Nova-API-Version")
        #expect(v.headerValue == "2.100")
    }

    /// Cinder's version doc returns HTTP 300 (Multiple Choices), not 200, and
    /// the header is `OpenStack-API-Version: volume 3.x`.
    @Test func cinderVersionDocAccepts300AndFormatsHeader() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        // Real cinder version doc: 300, {"versions":[{id:v3.0, status:CURRENT, version:"3.71"}]}
        let cinderDoc = """
        {"versions":[{"id":"v3.0","status":"CURRENT","version":"3.71","min_version":"3.0"}]}
        """
        server.addHandler("/") { _ in
            (300, cinderDoc, [("Content-Type", "application/json")])
        }
        let transport = Transport(cloud: CloudEntry(name: "t", authURL: server.baseURL),
            tokenSource: { "tok" }, logger: Logger(label: "test"))
        defer { transport.syncShutdown() }
        let profile = ServiceVersionProfile(
            serviceType: "volumev3",
            hasMicroversion: true,
            headerName: "OpenStack-API-Version",
            clientMax: Microversion(major: 3, minor: 70),
            headerValue: { "volume \($0.major).\($0.minor)" }
        )
        let negotiator = VersionNegotiator(transport: transport, cache: Cache(maxEntries: 100), profile: profile)
        let v = try await negotiator.negotiate(region: "RegionOne")
        // Server max 3.71 > client max 3.70 -> caps at 3.70, header "volume 3.70".
        #expect(v.version == Microversion(major: 3, minor: 70))
        #expect(v.headerName == "OpenStack-API-Version")
        #expect(v.headerValue == "volume 3.70")
    }

    @Test func belowFloor_throws() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/") { _ in
            (200, makeLegacyVersionDoc(maxVersion: "2.78"), [("Content-Type", "application/json")])
        }

        let cloud = CloudEntry(name: "test", authURL: server.baseURL)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-123" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }

        let cache = Cache(maxEntries: 100)
        let negotiator = VersionNegotiator(transport: transport, cache: cache, profile: novaProfile())

        do {
            _ = try await negotiator.negotiate(region: "RegionOne")
            #expect(false, "should have thrown")
        } catch let err as OpenStackError {
            #expect(err.message.contains("2.79"))
            #expect(err.message.contains("2.78"))
        } catch {
            #expect(false, "wrong error type: \(error)")
        }
    }

    @Test func negotiatesToClientMax_whenServerHigher() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/") { _ in
            (200, makeLegacyVersionDoc(maxVersion: "2.200"), [("Content-Type", "application/json")])
        }

        let cloud = CloudEntry(name: "test", authURL: server.baseURL)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { "tok-123" },
            maxConnectionsPerHost: 4,
            requestTimeout: .seconds(10),
            logger: Logger(label: "test")
        )
        defer { transport.syncShutdown() }

        let cache = Cache(maxEntries: 100)
        let negotiator = VersionNegotiator(transport: transport, cache: cache, profile: novaProfile())

        let v = try await negotiator.negotiate(region: "RegionOne")
        #expect(v.version == Microversion(major: 2, minor: 104), "Should cap at clientMax")
    }
}
