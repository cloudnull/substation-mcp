import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("NetworkService Tests")
struct NetworkServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, NetworkService, CloudEntry, Cache, Transport) {
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
        let transport = Transport(
            cloud: cloud,
            tokenSource: { tokenID },
            logger: logger
        )

        let network = NetworkService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, network, cloud, cache, transport)
    }

    // MARK: - Networks

    @Test("list networks returns seeded networks for proj-one", .timeLimit(.minutes(2)))
    func listNetworks() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let networks = try await region.listNetworks(vt)

        #expect(networks.count == 2, "Expected 2 proj-one networks, got \(networks.count)")
        let names = Set(networks.map { $0.name })
        #expect(names.contains("ext-net"))
        #expect(names.contains("int-net"))
    }

    @Test("get network by id", .timeLimit(.minutes(2)))
    func getNetwork() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let net = try await region.getNetwork(vt, id: "net-int")
        #expect(net.id == "net-int")
        #expect(net.name == "int-net")
        #expect(net.status == "ACTIVE")
    }

    @Test("create network", .timeLimit(.minutes(2)))
    func createNetwork() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreateNetworkSpec(name: "new-net", shared: false, adminStateUp: true)
        let net = try await region.createNetwork(vt, spec)
        #expect(net.name == "new-net")
        #expect(net.status == "ACTIVE")
        #expect(!net.id.isEmpty)

        // Verify it is listed
        let all = try await region.listNetworks(vt)
        #expect(all.contains { $0.id == net.id })
    }

    @Test("update network", .timeLimit(.minutes(2)))
    func updateNetwork() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = UpdateNetworkSpec(name: "renamed-net", shared: true)
        let updated = try await region.updateNetwork(vt, id: "net-int", spec)
        #expect(updated.id == "net-int")
        #expect(updated.name == "renamed-net")
    }

    @Test("delete network", .timeLimit(.minutes(2)))
    func deleteNetwork() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreateNetworkSpec(name: "doomed-net")
        let net = try await region.createNetwork(vt, spec)

        try await region.deleteNetwork(vt, id: net.id)

        do {
            _ = try await region.getNetwork(vt, id: net.id)
            Issue.record("Expected error for deleted network")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
            #expect(error.code == "ItemNotFound")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Subnets

    @Test("list subnets", .timeLimit(.minutes(2)))
    func listSubnets() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let subnets = try await region.listSubnets(vt)
        #expect(subnets.count == 2, "Expected 2 proj-one subnets, got \(subnets.count)")
        let names = Set(subnets.map { $0.name })
        #expect(names.contains("subnet-ext"))
        #expect(names.contains("subnet-int"))
    }

    @Test("create subnet with allocation pool", .timeLimit(.minutes(2)))
    func createSubnet() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreateSubnetSpec(
            networkID: "net-int",
            cidr: "192.168.1.128/25",
            ipVersion: 4,
            gateway: "192.168.1.129",
            name: "subnet-b",
            enableDHCP: true,
            allocationPools: [AllocationPool(start: "192.168.1.130", end: "192.168.1.254")]
        )
        let subnet = try await region.createSubnet(vt, spec)
        #expect(subnet.name == "subnet-b")
        #expect(subnet.ipVersion == 4)
        #expect(subnet.cidr == "192.168.1.128/25")
        #expect(subnet.gatewayIP == "192.168.1.129")
        #expect(subnet.enableDHCP == true)
        #expect(subnet.allocationPools.count == 1)
        #expect(subnet.allocationPools.first?.start == "192.168.1.130")
    }

    @Test("create subnet with unknown network throws InvalidInput", .timeLimit(.minutes(2)))
    func createSubnetBadNetwork() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreateSubnetSpec(networkID: "net-missing", cidr: "10.9.9.0/24", ipVersion: 4)
        do {
            _ = try await region.createSubnet(vt, spec)
            Issue.record("Expected error for subnet on unknown network")
        } catch let error as OpenStackError {
            #expect(error.status == 400)
            #expect(error.code == "InvalidInput")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("get and delete subnet", .timeLimit(.minutes(2)))
    func getDeleteSubnet() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreateSubnetSpec(networkID: "net-int", cidr: "192.168.1.0/26", ipVersion: 4, name: "temp-subnet")
        let subnet = try await region.createSubnet(vt, spec)

        let got = try await region.getSubnet(vt, id: subnet.id)
        #expect(got.id == subnet.id)
        #expect(got.cidr == "192.168.1.0/26")

        try await region.deleteSubnet(vt, id: subnet.id)
        do {
            _ = try await region.getSubnet(vt, id: subnet.id)
            Issue.record("Expected error for deleted subnet")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Ports

    @Test("list ports", .timeLimit(.minutes(2)))
    func listPorts() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let ports = try await region.listPorts(vt)
        #expect(ports.count == 1, "Expected 1 seeded port, got \(ports.count)")
        #expect(ports.first?.name == "port-seed")
    }

    @Test("create port with explicit fixed ip", .timeLimit(.minutes(2)))
    func createPortExplicitIP() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreatePortSpec(
            networkID: "net-int",
            fixedIPs: [PortFixedIP(ipAddress: "192.168.1.100")],
            name: "explicit-port"
        )
        let port = try await region.createPort(vt, spec)
        #expect(port.name == "explicit-port")
        #expect(port.status == "ACTIVE")
        #expect(port.fixedIPs.count == 1)
        #expect(port.fixedIPs.first?.ipAddress == "192.168.1.100")
        #expect(port.fixedIPs.first?.subnetID == "subnet-int")
    }

    @Test("create port with empty fixed ips auto-assigns from pool", .timeLimit(.minutes(2)))
    func createPortAutoAssign() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreatePortSpec(networkID: "net-int", fixedIPs: [], name: "auto-port")
        let port = try await region.createPort(vt, spec)
        #expect(port.name == "auto-port")
        #expect(port.fixedIPs.count == 1)
        let ip = port.fixedIPs.first?.ipAddress ?? ""
        #expect(ip.hasPrefix("192.168.1."), "Expected auto-assigned IP from subnet-int pool, got \(ip)")
    }

    @Test("create port with ip in use throws IpAddressInUse", .timeLimit(.minutes(2)))
    func createPortIPConflict() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        // 10.0.0.5 is assigned to the seeded port on subnet-ext
        let spec = CreatePortSpec(
            networkID: "net-ext",
            fixedIPs: [PortFixedIP(ipAddress: "10.0.0.5")],
            name: "conflict-port"
        )
        do {
            _ = try await region.createPort(vt, spec)
            Issue.record("Expected IpAddressInUse error")
        } catch let error as OpenStackError {
            #expect(error.status == 409)
            #expect(error.code == "IpAddressInUse")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("create port with extra dhcp opts and device attrs", .timeLimit(.minutes(2)))
    func createPortFull() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreatePortSpec(
            networkID: "net-int",
            fixedIPs: [PortFixedIP(ipAddress: "192.168.1.101")],
            name: "full-port",
            securityGroups: ["sg-default"],
            deviceID: "srv-0001",
            deviceOwner: "compute:nova",
            extraDHCPOpts: [ExtraDHCPOpt(optName: "domain-search", optValue: "example.com")],
            adminStateUp: true,
            portSecurityEnabled: false
        )
        let port = try await region.createPort(vt, spec)
        #expect(port.securityGroups.contains("sg-default"))
        #expect(port.deviceID == "srv-0001")
        #expect(port.deviceOwner == "compute:nova")
        #expect(port.extraDHCPOpts.count == 1)
        #expect(port.extraDHCPOpts.first?.optName == "domain-search")
        #expect(port.adminStateUp == true)
        #expect(port.portSecurityEnabled == false)
    }

    @Test("update and delete port", .timeLimit(.minutes(2)))
    func updateDeletePort() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let spec = CreatePortSpec(networkID: "net-int", fixedIPs: [PortFixedIP(ipAddress: "192.168.1.102")], name: "port-to-update")
        let port = try await region.createPort(vt, spec)

        let updated = try await region.updatePort(vt, id: port.id, name: "renamed-port", adminStateUp: false)
        #expect(updated.id == port.id)
        #expect(updated.name == "renamed-port")
        #expect(updated.adminStateUp == false)

        try await region.deletePort(vt, id: port.id)
        do {
            _ = try await region.getPort(vt, id: port.id)
            Issue.record("Expected error for deleted port")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Routers

    @Test("list routers", .timeLimit(.minutes(2)))
    func listRouters() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let routers = try await region.listRouters(vt)
        #expect(routers.count == 1)
        #expect(routers.first?.name == "router-1")
        #expect(routers.first?.externalGatewayInfo?.networkID == "net-ext")
    }

    @Test("create router and set external gateway", .timeLimit(.minutes(2)))
    func createRouterGateway() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let router = try await region.createRouter(vt, CreateRouterSpec(name: "new-router"))
        #expect(router.name == "new-router")
        #expect(router.externalGatewayInfo == nil)

        let withGW = try await region.updateRouter(
            vt,
            id: router.id,
            externalGatewayInfo: Router.ExternalGatewayInfo(networkID: "net-ext")
        )
        #expect(withGW.externalGatewayInfo?.networkID == "net-ext")
    }

    @Test("delete router", .timeLimit(.minutes(2)))
    func deleteRouter() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let router = try await region.createRouter(vt, CreateRouterSpec(name: "doomed-router"))
        try await region.deleteRouter(vt, id: router.id)
        do {
            _ = try await region.getRouter(vt, id: router.id)
            Issue.record("Expected error for deleted router")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Floating IPs

    @Test("list floating ips", .timeLimit(.minutes(2)))
    func listFloatingIPs() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let fips = try await region.listFloatingIPs(vt)
        #expect(fips.count == 1)
        #expect(fips.first?.floatingIP == "203.0.113.10")
        #expect(fips.first?.status == "DOWN")
    }

    @Test("associate floating ip via update", .timeLimit(.minutes(2)))
    func associateFloatingIP() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let updated = try await region.updateFloatingIP(vt, id: "fip-001", portID: "port-001", fixedIPAddress: nil)
        #expect(updated.status == "ACTIVE")
        #expect(updated.portID == "port-001")
    }

    @Test("disassociate floating ip via update", .timeLimit(.minutes(2)))
    func disassociateFloatingIP() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        // Associate first
        _ = try await region.updateFloatingIP(vt, id: "fip-001", portID: "port-001")
        // Then disassociate
        let updated = try await region.updateFloatingIP(vt, id: "fip-001", portID: nil)
        #expect(updated.status == "DOWN")
        #expect(updated.portID == nil)
    }

    @Test("create and delete floating ip", .timeLimit(.minutes(2)))
    func createDeleteFloatingIP() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let fip = try await region.createFloatingIP(vt, CreateFloatingIPSpec(floatingNetworkID: "net-ext"))
        #expect(fip.status == "DOWN")
        #expect(!fip.id.isEmpty)

        try await region.deleteFloatingIP(vt, id: fip.id)
        do {
            _ = try await region.getFloatingIP(vt, id: fip.id)
            Issue.record("Expected error for deleted fip")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Security groups

    @Test("list security groups", .timeLimit(.minutes(2)))
    func listSecurityGroups() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let groups = try await region.listSecurityGroups(vt)
        #expect(groups.count == 1)
        #expect(groups.first?.name == "default")
    }

    @Test("create and delete security group", .timeLimit(.minutes(2)))
    func createDeleteSecurityGroup() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let group = try await region.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "web", description: "Web tier"))
        #expect(group.name == "web")
        #expect(group.description == "Web tier")

        try await region.deleteSecurityGroup(vt, id: group.id)
        do {
            _ = try await region.getSecurityGroup(vt, id: group.id)
            Issue.record("Expected error for deleted sg")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("security group rules create and list", .timeLimit(.minutes(2)))
    func sgRulesCreateList() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let group = try await region.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "rules-test"))

        let rule = try await region.createSecurityGroupRule(
            vt,
            securityGroupID: group.id,
            direction: "ingress",
            ethertype: "IPv4",
            ipProtocol: "tcp",
            portRangeMin: 443,
            portRangeMax: 443,
            remoteIPPrefix: "0.0.0.0/0"
        )
        #expect(rule.direction == "ingress")
        #expect(rule.portRangeMin == 443)
        #expect(rule.portRangeMax == 443)
        #expect(rule.ipProtocol == "tcp")

        let rules = try await region.listSecurityGroupRules(vt, securityGroupID: group.id)
        #expect(rules.count == 1)
        #expect(rules.first?.id == rule.id)
    }

    @Test("security group rule delete", .timeLimit(.minutes(2)))
    func sgRuleDelete() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let group = try await region.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "rules-test-2"))
        let rule = try await region.createSecurityGroupRule(
            vt,
            securityGroupID: group.id,
            direction: "egress",
            ethertype: "IPv4",
            ipProtocol: "icmp"
        )

        try await region.deleteSecurityGroupRule(vt, id: rule.id)
        let rules = try await region.listSecurityGroupRules(vt, securityGroupID: group.id)
        #expect(rules.isEmpty)
    }

    // MARK: - Address groups (extension-gated)

    @Test("address groups work when extension present", .timeLimit(.minutes(2)))
    func addressGroupsWithExtension() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let group = try await region.createAddressGroup(vt, CreateAddressGroupSpec(name: "allow-list", description: "Allowed IPs"))
        #expect(group.name == "allow-list")
        #expect(group.description == "Allowed IPs")
        #expect(group.id != nil)

        let groups = try await region.listAddressGroups(vt)
        #expect(groups.contains { $0.name == "allow-list" })

        let got = try await region.getAddressGroup(vt, id: group.id!)
        #expect(got.name == "allow-list")

        try await region.deleteAddressGroup(vt, id: group.id!)
    }

    @Test("listAddressGroups throws feature error when extension absent", .timeLimit(.minutes(2)))
    func addressGroupsExtensionGated() async throws {
        let handle = try await FakeApp.start()
        let state = handle.state
        defer { handle.stop() }

        // Disable the address-group extension in this fake
        await state.removeExtension("address-group")

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
        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read, .write])

        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: "RegionOne")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        defer { transport.syncShutdown() }

        let network = NetworkService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        let region = network.region("RegionOne")

        do {
            _ = try await region.listAddressGroups(vt)
            Issue.record("Expected feature error for missing address-group extension")
        } catch let error as OpenStackError {
            #expect(error.code == "feature_unavailable")
            #expect(error.message.contains("address-group"))
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Quotas

    @Test("get quota", .timeLimit(.minutes(2)))
    func getQuota() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let quota = try await region.getQuota(vt)
        #expect(quota.network == 10)
        #expect(quota.subnet == 10)
        #expect(quota.port == 50)
    }

    @Test("update quota", .timeLimit(.minutes(2)))
    func updateQuota() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        let quota = try await region.updateQuota(vt, NetworkQuota(network: 20, subnet: 20, port: 100))
        #expect(quota.network == 10) // Fake echoes the static value
    }

    // MARK: - Errors and pagination

    @Test("404 NeutronError normalized with code ItemNotFound", .timeLimit(.minutes(2)))
    func neutron404Normalization() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        do {
            _ = try await region.getNetwork(vt, id: "net-missing")
            Issue.record("Expected 404 for missing network")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
            #expect(error.code == "ItemNotFound")
            #expect(error.service == "network")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("network pagination via limit and marker", .timeLimit(.minutes(2)))
    func networkPagination() async throws {
        let (handle, vt, network, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = network.region("RegionOne")
        // Seed an extra network so proj-one has 3+
        _ = try await region.createNetwork(vt, CreateNetworkSpec(name: "page-net-2"))

        let page1 = try await region.listNetworks(vt, limit: 2)
        #expect(page1.count == 2)
        guard let last = page1.last else {
            Issue.record("No last item in page 1")
            return
        }

        let page2 = try await region.listNetworks(vt, limit: 2, marker: last.id)
        #expect(page2.count >= 1)
        // page2 must not repeat page1 items
        let page1IDs = Set(page1.map { $0.id })
        for item in page2 {
            #expect(!page1IDs.contains(item.id))
        }
    }
}
