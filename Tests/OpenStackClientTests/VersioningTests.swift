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
    private func makeNovaVersionDoc(maxVersion: String) -> String {
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

    @Test func negotiatesToServerMax() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        let counter = ManagedAtomic(0)
        server.addHandler("/") { _ in
            counter.wrappingIncrement(by: 1, ordering: .relaxed)
            return (200, makeNovaVersionDoc(maxVersion: "2.104"), [("Content-Type", "application/json")])
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
        let negotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            serviceType: "nova",
            clientMax: Microversion(major: 2, minor: 104),
            floor: Microversion(major: 2, minor: 79)
        )

        let v = try await negotiator.negotiate(region: "RegionOne")
        #expect(v == Microversion(major: 2, minor: 104))
        #expect(counter.load(ordering: .relaxed) == 1)

        // Second call should be cached
        let v2 = try await negotiator.negotiate(region: "RegionOne")
        #expect(v2 == v)
        #expect(counter.load(ordering: .relaxed) == 1, "Second call should hit cache")
    }

    @Test func belowFloor_throws() async throws {
        let server = TestServer()
        try server.start()
        defer { server.stop() }

        server.addHandler("/") { _ in
            (200, makeNovaVersionDoc(maxVersion: "2.78"), [("Content-Type", "application/json")])
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
        let negotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            serviceType: "nova",
            clientMax: Microversion(major: 2, minor: 104),
            floor: Microversion(major: 2, minor: 79)
        )

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
            (200, makeNovaVersionDoc(maxVersion: "2.200"), [("Content-Type", "application/json")])
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
        let negotiator = VersionNegotiator(
            transport: transport,
            cache: cache,
            serviceType: "nova",
            clientMax: Microversion(major: 2, minor: 104),
            floor: Microversion(major: 2, minor: 79)
        )

        let v = try await negotiator.negotiate(region: "RegionOne")
        #expect(v == Microversion(major: 2, minor: 104), "Should cap at clientMax")
    }
}
