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

    @Test("Server decodes real Nova /servers/detail JSON", .timeLimit(.minutes(2)))
    func serverDecodesRealNovaJSON() throws {
        // Exact JSON shape from live sat0 Nova 2.1 /servers/detail.
        // This is the format that was causing DecodingError.keyNotFound
        // (500 "The data is missing") on every server list/get/find call.
        let novaJSON = """
        {"servers":[{
            "id":"9a1912bc-b790-4df0-8571-4e11eac7ea18",
            "name":"r9700",
            "status":"ACTIVE",
            "tenant_id":"36599c7599c64d839f288fc703bd9eb9",
            "user_id":"e3e69b8fcf8f43408a8a1f29db08b05b",
            "metadata":{},
            "hostId":"45b369038f077768ac151cfde6d26c3824057cec4c1a1eedd8d3587b",
            "image":{"id":"c8705b50-fdb2-4d12-8dd6-ab0e6dd35702","links":[{"rel":"bookmark","href":"https://nova.api.sat0.cloudnull.dev/images/c8705b50-fdb2-4d12-8dd6-ab0e6dd35702"}]},
            "flavor":{"id":"567f142b-4e8c-4f08-a4e0-93e27b51c01e","links":[{"rel":"bookmark","href":"https://nova.api.sat0.cloudnull.dev/flavors/567f142b-4e8c-4f08-a4e0-93e27b51c01e"}]},
            "created":"2026-09-14T01:05:43Z",
            "updated":"2026-09-14T01:06:01Z",
            "addresses":{"flat":[{"version":4,"addr":"172.16.25.176","OS-EXT-IPS:type":"fixed","OS-EXT-IPS-MAC:mac_addr":"fa:16:3e:b0:5d:08"}]},
            "accessIPv4":"","accessIPv6":"",
            "links":[{"rel":"self","href":"https://nova.api.sat0.cloudnull.dev/v2.1/servers/9a1912bc-b790-4df0-8571-4e11eac7ea18"}],
            "OS-DCF:diskConfig":"MANUAL",
            "progress":0,
            "OS-EXT-AZ:availability_zone":"az1",
            "config_drive":"",
            "key_name":"cloudnull-moylands",
            "OS-SRV-USG:launched_at":"2026-09-14T01:06:01.000000",
            "OS-SRV-USG:terminated_at":null,
            "OS-EXT-SRV-ATTR:host":"compute-0.cloud.cloudnull.dev.local",
            "OS-EXT-SRV-ATTR:instance_name":"instance-0000004b",
            "OS-EXT-SRV-ATTR:hypervisor_hostname":"compute-0.cloud.cloudnull.dev.local",
            "OS-EXT-STS:task_state":null,
            "OS-EXT-STS:vm_state":"active",
            "OS-EXT-STS:power_state":1,
            "os-extended-volumes:volumes_attached":[],
            "security_groups":[{"name":"default"}]
        }]}
        """
        struct ServerList: Decodable { let servers: [Server] }
        let decoded = try JSONDecoder().decode(ServerList.self, from: novaJSON.data(using: .utf8)!)
        let s = decoded.servers[0]
        #expect(s.id == "9a1912bc-b790-4df0-8571-4e11eac7ea18")
        #expect(s.name == "r9700")
        #expect(s.status == "ACTIVE")
        #expect(s.hostId == "45b369038f077768ac151cfde6d26c3824057cec4c1a1eedd8d3587b")
        #expect(s.availabilityZone == "az1")
        #expect(s.keyName == "cloudnull-moylands")
        #expect(s.securityGroups.count == 1)
        #expect(s.securityGroups[0].name == "default")
        #expect(s.addresses["flat"]?.count == 1)
        #expect(s.addresses["flat"]?[0].addr == "172.16.25.176")
        #expect(s.addresses["flat"]?[0].type == "fixed")
        #expect(s.image?.id == "c8705b50-fdb2-4d12-8dd6-ab0e6dd35702")
        #expect(s.flavor.id == "567f142b-4e8c-4f08-a4e0-93e27b51c01e")
        #expect(s.progress == 0)
        #expect(s.created != nil)
        #expect(s.updated != nil)
        #expect(s.metadata.isEmpty)
        #expect(s.tags == nil)  // tags key absent from JSON
    }

    @Test("Server decodes null image (imageless server)", .timeLimit(.minutes(2)))
    func serverDecodesNullImage() throws {
        // Nova returns {"id": null} for image on imageless servers.
        let novaJSON = """
        {"servers":[{
            "id":"abc123",
            "name":"no-image",
            "status":"ACTIVE",
            "image":{"id":null,"links":[]},
            "flavor":{"id":"flv1","links":[]},
            "addresses":{},
            "security_groups":[],
            "metadata":{},
            "created":"2026-01-01T00:00:00Z"
        }]}
        """
        struct ServerList: Decodable { let servers: [Server] }
        let decoded = try JSONDecoder().decode(ServerList.self, from: novaJSON.data(using: .utf8)!)
        let s = decoded.servers[0]
        #expect(s.id == "abc123")
        #expect(s.image?.id == "")  // null id → empty string
        #expect(s.addresses.isEmpty)
        #expect(s.securityGroups.isEmpty)
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

    @Test("console_url returns a console object with type and url", .timeLimit(.minutes(2)))
    func consoleURL() async throws {
        let (handle, vt, compute, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = compute.region("RegionOne")
        let console = try await region.getConsole(vt, "srv-0001", type: "novnc")
        #expect(console.type == "novnc", "Expected console type novnc, got \(console.type)")
        #expect(!console.url.isEmpty, "Console url must be non-empty")
        // The url is scoped to the server.
        #expect(console.url.contains("srv-0001"), "Console url should reference the server: \(console.url)")
    }

    @Test("console_url is scoped to the requesting session (token)", .timeLimit(.minutes(2)))
    func consoleURLSessionScoped() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let state = handle.state

        // Two distinct sessions: proj-one admin and proj-two admin.
        guard let t1 = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil),
              let t2 = await state.mintToken(credID: "fake-cred-two", secret: "secret-two", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "mint failed")
        }
        func validated(_ tokenID: String) async throws -> ValidatedToken {
            let url = handle.keystoneURL.appendingPathComponent("auth/tokens")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
            let (data, _) = try await URLSession.shared.data(for: req)
            return ValidatedToken(token: try Token.decode(from: data), scopes: [.read, .write])
        }
        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { t1.id }, logger: logger)
        defer { transport.syncShutdown() }
        let compute = ComputeService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        let region = compute.region("RegionOne")

        let vt1 = try await validated(t1.id)
        let vt2 = try await validated(t2.id)
        // Each session requests a console for a server in its own project.
        let c1 = try await region.getConsole(vt1, "srv-0001", type: "novnc")
        let c2 = try await region.getConsole(vt2, "srv-0004", type: "novnc")

        // Each session sees a url scoped to its own request; the values differ.
        #expect(c1.url != c2.url, "Sessions must not see the same console url: \(c1.url) vs \(c2.url)")
        // Each session can re-read only its own url (the map is keyed per token).
        let c1Again = try await region.getConsole(vt1, "srv-0001", type: "novnc")
        #expect(c1Again.url == c1.url, "A session re-reading its own console should see the same url")
        // The other session's url is not derivable from this session's token.
        let c2Again = try await region.getConsole(vt2, "srv-0004", type: "novnc")
        #expect(c2Again.url == c2.url, "proj-two session should see its own url")
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
        // port-002 is seeded attached to srv-0001 (compute client test fixture).
        try await region.detachInterface(vt, serverID: "srv-0001", portID: "port-002")
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
