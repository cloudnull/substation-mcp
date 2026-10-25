import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("LoadBalancerService Tests", .timeLimit(.minutes(2)))
struct LoadBalancerServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, LoadBalancerService, Cache, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let tokenID = fakeToken.id

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

        let cloud = CloudEntry(
            name: "fake",
            authURL: URL(string: handle.url.absoluteString)!,
            regionName: "RegionOne"
        )
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        let svc = LoadBalancerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Load balancers

    @Test("list load balancers returns the seeded LB")
    func listLoadBalancers() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let lbs = try await region.listLoadBalancers(vt)
        #expect(lbs.count == 1)
        #expect(lbs.first?.id == "lb-1")
        #expect(lbs.first?.provisioning_status == "ACTIVE")
    }

    @Test("get load balancer by id")
    func getLoadBalancer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let lb = try await region.getLoadBalancer(vt, id: "lb-1")
        #expect(lb.id == "lb-1")
        #expect(lb.vip_address == "10.0.0.10")
    }

    @Test("create then delete a load balancer")
    func createDeleteLoadBalancer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateLoadBalancerSpec(name: "new-lb", vip_address: "10.0.0.99")
        let created = try await region.createLoadBalancer(vt, spec)
        #expect(created.id.hasPrefix("lb-"))
        #expect(created.provisioning_status == "ACTIVE")

        let lbs = try await region.listLoadBalancers(vt)
        #expect(lbs.contains { $0.id == created.id })

        try await region.deleteLoadBalancer(vt, id: created.id)
        let after = try await region.listLoadBalancers(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    @Test("load balancer with children refuses a plain delete; cascade deletes the children")
    func deleteLoadBalancerCascade() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let lb = try await region.createLoadBalancer(vt, CreateLoadBalancerSpec(name: "cascade-lb", vip_address: "10.0.0.98"))
        let listener = try await region.createListener(vt, CreateListenerSpec(name: "cascade-lst", protocolName: "HTTP", protocol_port: 80, load_balancer_id: lb.id))
        _ = try await region.createPool(vt, CreatePoolSpec(name: "cascade-pool", protocolName: "HTTP", lb_algorithm: "ROUND_ROBIN", load_balancer_id: lb.id, listener_id: listener.id))

        // A plain delete is refused while children exist (Octavia "it has children").
        do {
            try await region.deleteLoadBalancer(vt, id: lb.id)
            Issue.record("plain delete of an LB with children must be refused")
        } catch let e as OpenStackError {
            #expect(e.status == 400, "expected 400, got \(e.status): \(e.message)")
        }
        // The LB and its listener survive the refused delete.
        #expect(try await region.getLoadBalancer(vt, id: lb.id).id == lb.id)
        #expect(try await region.getListener(vt, id: listener.id).id == listener.id)

        // cascade:true deletes the LB and all children in one call.
        try await region.deleteLoadBalancer(vt, id: lb.id, cascade: true)
        let lbs = try await region.listLoadBalancers(vt)
        #expect(!lbs.contains { $0.id == lb.id }, "LB must be gone after cascade")
        let listeners = try await region.listListeners(vt)
        #expect(!listeners.contains { $0.id == listener.id }, "listener must be gone after cascade")
    }
    @Test("create load balancer recovers from a minimal/non-JSON response (ISSUE 18)")
    func createLoadBalancerRecoversFromEmptyBody() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Arm the fake to return an EMPTY create body (Rackspace octavia's minimal
        // response shape) for the next POST /loadbalancers. The real bug was that this
        // decoded as a LoadBalancer, threw, and surfaced as a false HTTP 500 even though
        // the LB was created. The client must instead read the LB back from the list.
        await handle.state.setLBCreateRawBodyNext("")

        let region = svc.region("RegionOne")
        let spec = CreateLoadBalancerSpec(name: "lb-empty-body", vip_address: "10.0.0.88")
        let created = try await region.createLoadBalancer(vt, spec)

        // No throw + we got a real, resolvable object, not the seed "lb-1".
        #expect(created.id.hasPrefix("lb-"))
        #expect(created.id != "lb-1")
        #expect(created.name == "lb-empty-body")
        // It must be present in the collection (proves the read-back found the true object).
        let lbs = try await region.listLoadBalancers(vt)
        #expect(lbs.contains { $0.id == created.id })
        #expect(lbs.first(where: { $0.name == "lb-empty-body" })?.id == created.id)
    }


    // MARK: - Pools

    @Test("list pools returns the seeded pool")
    func listPools() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let pools = try await region.listPools(vt)
        #expect(pools.count == 1)
        #expect(pools.first?.id == "pool-1")
        #expect(pools.first?.protocolName == "HTTP")
    }

    @Test("get pool by id")
    func getPool() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let p = try await region.getPool(vt, id: "pool-1")
        #expect(p.id == "pool-1")
        #expect(p.lb_algorithm == "ROUND_ROBIN")
    }

    // MARK: - Members

    @Test("list members returns the seeded member")
    func listMembers() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        // Members are a pool sub-resource: the client requires a pool id.
        let members = try await region.listMembers(vt, poolID: "pool-1")
        #expect(members.count == 1)
        #expect(members.first?.id == "member-1")
        #expect(members.first?.status == "ONLINE")
    }

    // MARK: - Create listener / health monitor

    @Test("create a listener")
    func createListener() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateListenerSpec(name: "web-listener", protocolName: "HTTP", protocol_port: 8080, load_balancer_id: "lb-1")
        let l = try await region.createListener(vt, spec)
        #expect(l.id.hasPrefix("listener-"))
        #expect(l.protocol_port == 8080)
        #expect(l.load_balancer_id == "lb-1")
    }

    @Test("create a health monitor")
    func createHealthMonitor() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateHealthMonitorSpec(name: "hm", type: "PING", delay: 5, timeout: 3, max_retries: 2, pool_id: "pool-1")
        let h = try await region.createHealthMonitor(vt, spec)
        #expect(h.id.hasPrefix("hm-"))
        #expect(h.type == "PING")
        #expect(h.delay == 5)
    }
}
