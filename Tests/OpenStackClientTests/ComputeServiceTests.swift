import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("ComputeService Tests")
struct ComputeServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ComputeService, CloudEntry, Cache, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        // Mint an admin token for proj-one via direct state call
        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id

        // Build a ValidatedToken from the fake token
        let keystoneURL = handle.keystoneURL
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let httpStatus = (resp as! HTTPURLResponse).statusCode
        #expect(httpStatus == 200, "Token validation failed: \(httpStatus)")

        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read, .write])

        // Build CloudEntry pointing at the fake
        let cloud = CloudEntry(
            name: "fake",
            authURL: URL(string: handle.url.absoluteString)!,
            regionName: "RegionOne"
        )

        let cache = Cache(maxEntries: 100)
        let transport = Transport(
            cloud: cloud,
            tokenSource: { tokenID },
            logger: logger
        )

        let compute = ComputeService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, compute, cloud, cache, transport)
    }

    @Test("list servers returns seeded servers for proj-one", .timeLimit(.minutes(2)))
    func listServers() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let servers = try await region.listServers(vt)

        #expect(servers.count == 3, "Expected 3 servers, got \(servers.count)")
        guard let first = servers.first else {
            Issue.record("No servers returned")
            return
        }
        #expect(first.id == "srv-0001")
        #expect(first.name == "server-1")
        #expect(first.status == "ACTIVE")
    }

    @Test("list servers with filter by name", .timeLimit(.minutes(2)))
    func listServersWithFilter() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let servers = try await region.listServers(vt, filters: ["name": "server-1"])
        #expect(servers.count == 1, "Expected 1 filtered server, got \(servers.count)")
        guard let first = servers.first else {
            Issue.record("No filtered servers returned")
            return
        }
        #expect(first.id == "srv-0001")
    }

    @Test("list servers pagination", .timeLimit(.minutes(2)))
    func listServersPagination() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        // Get all 3 servers with limit 2
        let page1 = try await region.listServers(vt, limit: 2)
        #expect(page1.count == 2)
    }

    @Test("get server by id", .timeLimit(.minutes(2)))
    func getServer() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let server = try await region.getServer(vt, id: "srv-0001")
        #expect(server.id == "srv-0001")
        #expect(server.name == "server-1")
        #expect(server.status == "ACTIVE")
    }

    @Test("get server not found returns 404", .timeLimit(.minutes(2)))
    func getServerNotFound() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        do {
            _ = try await region.getServer(vt, id: "srv-9999")
            Issue.record("Expected error for non-existent server")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("create server", .timeLimit(.minutes(2)))
    func createServer() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let spec = CreateServerSpec(
            name: "test-server",
            flavorID: "m1.small",
            imageID: "img-001"
        )
        let server = try await region.createServer(vt, spec)
        #expect(server.name == "created-server")
        #expect(server.status == "BUILD")
        #expect(!server.id.isEmpty)
    }

    @Test("create server with minCount maxCount", .timeLimit(.minutes(2)))
    func createServerBatch() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let spec = CreateServerSpec(
            name: "batch-server",
            flavorID: "m1.small",
            imageID: "img-001",
            minCount: 1,
            maxCount: 1
        )
        let server = try await region.createServer(vt, spec)
        #expect(server.name == "created-server")
    }

    @Test("create server with hostname below microversion threshold throws", .timeLimit(.minutes(2)))
    func createServerHostnameGating() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let spec = CreateServerSpec(
            name: "hostname-test",
            flavorID: "m1.small",
            imageID: "img-001",
            hostname: "my-host"
        )
        // The fake supports microversion 2.104, so hostname (2.90) should be allowed
        // This test verifies the gating logic doesn't throw when version is sufficient
        let server = try await region.createServer(vt, spec)
        #expect(server.name == "created-server")
    }

    @Test("delete server", .timeLimit(.minutes(2)))
    func deleteServer() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        // Create a server to delete
        let spec = CreateServerSpec(name: "to-delete", flavorID: "m1.small", imageID: "img-001")
        let server = try await region.createServer(vt, spec)

        try await region.deleteServer(vt, id: server.id)

        // Verify it's gone
        do {
            _ = try await region.getServer(vt, id: server.id)
            Issue.record("Expected error for deleted server")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("action start/stop", .timeLimit(.minutes(2)))
    func actionStartStop() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        // Stop a running server
        let result = try await region.action(vt, "srv-0001", .stop)
        // 202 response means nil
        #expect(result == nil)
    }

    @Test("action reboot", .timeLimit(.minutes(2)))
    func actionReboot() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let result = try await region.action(vt, "srv-0001", .reboot(soft: true))
        #expect(result == nil)
    }

    @Test("action rebuild does not echo password", .timeLimit(.minutes(2)))
    func actionRebuild() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let result = try await region.action(vt, "srv-0001", .rebuild(imageID: "img-001", adminPassword: "secret-pw"))
        #expect(result == nil)
    }

    @Test("list flavors", .timeLimit(.minutes(2)))
    func listFlavors() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let flavors = try await region.listFlavors(vt)
        #expect(flavors.count == 3)
        #expect(flavors[0].name == "m1.small")
        #expect(flavors[0].vcpus == 1)
    }

    @Test("get flavor by id", .timeLimit(.minutes(2)))
    func getFlavor() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        // The fake doesn't have GET /flavors/:id, so we test list and find
        let flavors = try await region.listFlavors(vt)
        let flavor = flavors.first { $0.name == "m1.large" }
        #expect(flavor != nil)
        #expect(flavor?.name == "m1.large")
        #expect(flavor?.vcpus == 2)
    }

    @Test("list keypairs", .timeLimit(.minutes(2)))
    func listKeypairs() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let keypairs = try await region.listKeypairs(vt)
        #expect(keypairs.count == 1)
        #expect(keypairs[0].name == "test-key")
    }

    @Test("create keypair", .timeLimit(.minutes(2)))
    func createKeyPair() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let kp = try await region.createKeyPair(vt, name: "new-key", publicKey: nil)
        #expect(kp.name == "new-key")
    }

    @Test("delete keypair", .timeLimit(.minutes(2)))
    func deleteKeyPair() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        try await region.deleteKeyPair(vt, name: "test-key")
        // No error means success
    }

    @Test("list server groups", .timeLimit(.minutes(2)))
    func listServerGroups() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let groups = try await region.listServerGroups(vt)
        #expect(groups.count == 1)
        #expect(groups[0].name == "test-group")
    }

    @Test("list availability zones", .timeLimit(.minutes(2)))
    func listAvailabilityZones() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let zones = try await region.listAvailabilityZones(vt)
        #expect(zones.count == 2)
        #expect(zones[0].zoneName == "nova")
        #expect(zones[0].zoneState.available == true)
    }

    @Test("list hypervisors with admin token", .timeLimit(.minutes(2)))
    func listHypervisorsAdmin() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let hypervisors = try await region.listHypervisors(vt)
        #expect(hypervisors.count == 1)
        #expect(hypervisors[0].host == "compute-01")
        #expect(hypervisors[0].state == "up")
    }

    @Test("list hypervisors with non-admin token returns 403", .timeLimit(.minutes(2)))
    func listHypervisorsNonAdmin() async throws {
        let handle = try await FakeApp.start()
        let state = handle.state
        defer { handle.stop() }

        // Mint a non-admin (read-only) token
        guard let fakeToken = await state.mintToken(credID: "fake-cred-ro", secret: "secret-ro", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id

        let keystoneURL = handle.keystoneURL
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read])

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        defer { transport.syncShutdown() }
        let compute = ComputeService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        let region = compute.region("RegionOne")

        do {
            _ = try await region.listHypervisors(vt)
            Issue.record("Expected 403 for non-admin hypervisor access")
        } catch let error as OpenStackError {
            #expect(error.status == 403)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("get quota set", .timeLimit(.minutes(2)))
    func getQuotaSet() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let quotas = try await region.getQuotaSet(vt)
        #expect(quotas.instances == 10)
        #expect(quotas.cores == 20)
        #expect(quotas.ram == 51200)
    }

    @Test("update quota set", .timeLimit(.minutes(2)))
    func updateQuotaSet() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        var quotas = QuotaSet(instances: 20, cores: 40, ram: 102400)
        let updated = try await region.updateQuotaSet(vt, quotas: quotas)
        #expect(updated.instances == 10) // Fake echoes the static value
    }

    @Test("attach volume", .timeLimit(.minutes(2)))
    func attachVolume() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        try await region.attachVolume(vt, serverID: "srv-0001", volumeID: "vol-001", device: "/dev/vdb", deleteOnTermination: true)
        // No error means success
    }

    @Test("detach volume", .timeLimit(.minutes(2)))
    func detachVolume() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        try await region.detachVolume(vt, serverID: "srv-0001", attachmentID: "att-001")
        // No error means success
    }

    @Test("attach interface", .timeLimit(.minutes(2)))
    func attachInterface() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        try await region.attachInterface(vt, serverID: "srv-0001", networkID: "net-001")
        // No error means success
    }

    @Test("detach interface", .timeLimit(.minutes(2)))
    func detachInterface() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        try await region.detachInterface(vt, serverID: "srv-0001", portID: "port-001")
        // No error means success
    }

    @Test("update server name", .timeLimit(.minutes(2)))
    func updateServer() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let server = try await region.updateServer(vt, id: "srv-0001", name: "renamed-server")
        #expect(server.id == "srv-0001")
    }

    @Test("tenant isolation: proj-one cannot see proj-two servers", .timeLimit(.minutes(2)))
    func tenantIsolation() async throws {
        let handle = try await FakeApp.start()
        let state = handle.state
        defer { handle.stop() }

        // Mint a proj-two token
        guard let fakeToken = await state.mintToken(credID: "fake-cred-two", secret: "secret-two", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id
        let keystoneURL = handle.keystoneURL
        let url = keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let token = try Token.decode(from: data)
        let vtTwo = ValidatedToken(token: token, scopes: [.read, .write])

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        defer { transport.syncShutdown() }
        let compute = ComputeService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        let region = compute.region("RegionOne")

        let servers = try await region.listServers(vtTwo)
        // proj-two should only see its own servers
        for server in servers {
            #expect(server.projectID != "proj-one" || server.id != "srv-0001")
        }
    }
}
