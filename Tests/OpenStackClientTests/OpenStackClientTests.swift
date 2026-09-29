import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("OpenStackClient Facade Tests")
struct OpenStackClientTests {
    let logger = Logger(label: "test")

    // MARK: - Setup helpers

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ValidatedToken, OpenStackClient, CloudEntry, Cache, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        // Mint token for proj-one (admin)
        guard let fakeTokenOne = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token one")
        }

        // Mint token for proj-two
        guard let fakeTokenTwo = await state.mintToken(credID: "fake-cred-two", secret: "secret-two", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token two")
        }

        // Decode both tokens via Keystone
        let vtOne = try await decodeToken(id: fakeTokenOne.id, keystoneURL: handle.keystoneURL)
        let vtTwo = try await decodeToken(id: fakeTokenTwo.id, keystoneURL: handle.keystoneURL)

        let cloud = CloudEntry(
            name: "fake",
            authURL: URL(string: handle.url.absoluteString)!,
            regionName: nil  // no explicit region → fall back to token catalog
        )

        let cache = Cache(maxEntries: 100)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { fakeTokenOne.id },
            logger: logger
        )

        let validator = TokenValidator(
            transport: transport,
            cache: cache,
            servedProjects: []
        )

        let client = OpenStackClient(
            cloud: cloud,
            transport: transport,
            cache: cache,
            validator: validator,
            logger: logger
        )

        return (handle, vtOne, vtTwo, client, cloud, cache, transport)
    }

    private func decodeToken(id: String, keystoneURL: URL) async throws -> ValidatedToken {
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(id, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpStatus = (resp as! HTTPURLResponse).statusCode
        #expect(httpStatus == 200, "Token validation failed: \(httpStatus)")
        let token = try Token.decode(from: data)
        return ValidatedToken(token: token, scopes: [.read, .write])
    }

    // MARK: - Regions

    @Test("regions returns distinct regions from token catalog", .timeLimit(.minutes(2)))
    func regions() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let regions = await client.regions(vtOne)
        #expect(Set(regions) == ["RegionOne", "RegionTwo"], "Expected both regions, got \(regions)")
        #expect(regions.count == 2, "Expected 2 distinct regions, got \(regions.count)")
    }

    // MARK: - Whoami

    @Test("whoami returns identity context", .timeLimit(.minutes(2)))
    func whoami() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let identity = await client.whoami(vtOne)
        #expect(identity.project.id == "proj-one")
        #expect(identity.roles.contains("admin"))
        #expect(identity.scopes.contains(.write))
        #expect(Set(identity.regions) == ["RegionOne", "RegionTwo"])
        // volumev3 should only have RegionOne
        #expect(identity.services["volumev3"] == ["RegionOne"], "volumev3 should be RegionOne only, got \(String(describing: identity.services["volumev3"]))")
        // compute should have both
        #expect(Set(identity.services["compute"] ?? []) == ["RegionOne", "RegionTwo"])
    }

    // MARK: - Default region

    @Test("compute region defaults to first catalog region when cloud has no regionName", .timeLimit(.minutes(2)))
    func defaultRegion() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.defaultRegion(vtOne)
        #expect(region == "RegionOne", "Expected RegionOne as default, got \(region)")
    }

    // MARK: - No-endpoint (Review Focus 3)

    @Test("blockStorage in RegionTwo throws no-endpoint error", .timeLimit(.minutes(2)))
    func noEndpoint() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.blockStorage(region: "RegionTwo")
        do {
            _ = try await region.getVolume(vtOne, id: "seed-vol")
            Issue.record("Expected no-endpoint error for volumev3 in RegionTwo")
        } catch let error as OpenStackError {
            #expect(error.code == "no-endpoint", "Expected no-endpoint, got \(error.code): \(error.message)")
        }
    }

    @Test("blockStorage in RegionOne works", .timeLimit(.minutes(2)))
    func blockStorageRegionOne() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.blockStorage(region: "RegionOne")
        let vol = try await region.getVolume(vtOne, id: "seed-vol")
        #expect(vol.id == "seed-vol")
        #expect(vol.status == "available")
    }

    @Test("compute in RegionTwo works (nova has RegionTwo endpoint)", .timeLimit(.minutes(2)))
    func computeRegionTwo() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // compute has a RegionTwo endpoint in the catalog, so this should not
        // throw a no-endpoint error. The actual list call may return an empty
        // list (no seeded servers in RegionTwo) but must not fail on endpoint
        // resolution.
        let region = await client.compute(region: "RegionTwo")
        do {
            let servers = try await region.listServers(vtOne)
            // May be empty — the point is no no-endpoint error
            _ = servers
        } catch let error as OpenStackError where error.code == "no-endpoint" {
            Issue.record("Unexpected no-endpoint for compute in RegionTwo: \(error.message)")
        }
    }

    // MARK: - Service accessors return usable regions

    @Test("compute accessor returns region that can list servers", .timeLimit(.minutes(2)))
    func computeAccessor() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.compute(region: "RegionOne")
        let servers = try await region.listServers(vtOne)
        #expect(servers.count >= 1, "Expected at least 1 seeded server, got \(servers.count)")
        #expect(servers.allSatisfy { $0.status == "ACTIVE" }, "All seeded servers should be ACTIVE")
    }

    @Test("network accessor returns region that can list networks", .timeLimit(.minutes(2)))
    func networkAccessor() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.network(region: "RegionOne")
        let networks = try await region.listNetworks(vtOne)
        #expect(networks.count >= 2, "Expected at least 2 seeded networks, got \(networks.count)")
    }

    @Test("image accessor returns region that can list images", .timeLimit(.minutes(2)))
    func imageAccessor() async throws {
        let (handle, vtOne, _, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = await client.image(region: "RegionOne")
        let images = try await region.listImages(vtOne)
        #expect(images.count >= 1, "Expected at least 1 seeded image, got \(images.count)")
        #expect(images.contains { $0.id == "img-1" }, "Expected img-1 in results")
    }

    // MARK: - Cross-token: different token, same client

    @Test("second token works through the same client", .timeLimit(.minutes(2)))
    func crossToken() async throws {
        let (handle, _, vtTwo, client, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // proj-two token should work for network (both regions have neutron)
        let region = await client.network(region: "RegionOne")
        let networks = try await region.listNetworks(vtTwo)
        // proj-two has net-two in RegionOne
        #expect(networks.contains { $0.id == "net-two" }, "Expected net-two for proj-two, got \(networks.map(\.id))")
    }
}
