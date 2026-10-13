import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer

// MARK: - Topology tests (os_topology)
//
// Covers the anchor types from spec §8.8 (server, network, router,
// floating_ip, subnet, port), the depth cap, unsupported anchors, and
// diagnosis findings (port-security rule check, router-without-gateway).

@Suite("Topology Tests", .timeLimit(.minutes(3)))
struct TopologyTests {

    @Test("server anchor depth 2 shows port, subnet, network", )
    func serverAnchor() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Give srv-0003 a port on net-int (routed via router-1) so the graph
        // has a real path to walk.
        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("net-int"),
            "target_type": .string("network"),
        ])
        // Attach the seeded volume to the server for the volume edge.
        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdb")]),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0003"),
            "depth": .int(2),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("srv-0003") == true, "Server node should be present")
        #expect(text?.contains("port") == true, "Port node should be present")
        #expect(text?.contains("subnet-int") == true, "Subnet node should be present")
        #expect(text?.contains("net-int") == true, "Network node should be present")
        #expect(text?.contains("interface") == true, "interface edge kind should be present")
        #expect(text?.contains("fixed_ip") == true, "fixed_ip edge kind should be present")
    }

    @Test("server anchor depth 3 adds the router + gateway network", )
    func serverAnchorDepth3() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("net-int"),
            "target_type": .string("network"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0003"),
            "depth": .int(3),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("router-1") == true, "Router node should appear at depth 3, got: \(text ?? "nil")")
        #expect(text?.contains("router_interface") == true, "router_interface edge should appear")
        #expect(text?.contains("net-ext") == true, "Gateway network should appear at depth 3")
    }

    @Test("network anchor lists subnets, ports, and the attached router", )
    func networkAnchor() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("network"),
            "id_or_name": .string("net-int"),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("subnet-int") == true, "Subnet should appear")
        #expect(text?.contains("subnet_of") == true, "subnet_of edge should appear")
        #expect(text?.contains("port-001") != true, "port-001 is on net-ext, not net-int")
    }

    @Test("network anchor shows only routers with a real interface port (ISSUE 7)")
    func networkAnchorNoPhantomRouter() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // A second gateway-only router: external gateway on net-ext but NO interface
        // port on subnet-int. The old heuristic ("any gateway router whose gateway-net
        // != this net") drew a PHANTOM router_interface edge to net-int; the fixed code
        // requires a real device_owner=network:router_interface port and must not show it.
        let rt = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("router"),
            "spec": .object([
                "name": .string("e2e-gw-noif"),
                "external_gateway_info": .object(["network_id": .string("net-ext")]),
            ]),
        ])
        #expect(rt.isError != true, "create second router failed: \(firstText(rt.content) ?? "")")
        let rtText = firstText(rt.content) ?? ""
        guard let rtData = rtText.data(using: .utf8),
              let rtObj = try? JSONSerialization.jsonObject(with: rtData) as? [String: Any] else {
            throw OpenStackError(service: "test", status: 500, message: "unparseable router create result: \(rtText)")
        }
        let ghostID = ((rtObj["data"] as? [String: Any])?["id"] as? String) ?? ""
        #expect(!ghostID.isEmpty, "expected created ghost router to carry an id, got: \(rtText)")

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("network"),
            "id_or_name": .string("net-int"),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("router-1") == true, "The real interface-owning router should appear, got: \(text)")
        #expect(text.contains(ghostID) != true, "Phantom router edge for a gateway-only router leaked into topology: \(text)")
    }
    @Test("router anchor shows the gateway network", )
    func routerAnchor() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("router"),
            "id_or_name": .string("router-1"),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("router-1") == true)
        #expect(text?.contains("net-ext") == true, "Gateway network should appear")
        #expect(text?.contains("router_gateway") == true, "router_gateway edge should appear")
    }

    @Test("floating_ip anchor traces the path to the external network", )
    func floatingIPAnchor() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Associate fip-001 with port-001 (on subnet-ext) so the path exists.
        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("floating_ip"),
            "source": .string("fip-001"),
            "source_type": .string("floating_ip"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("floating_ip"),
            "id_or_name": .string("fip-001"),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("fip-001") == true)
        #expect(text?.contains("net-ext") == true, "External network should appear")
        #expect(text?.contains("floating_ip_network") == true, "floating_ip_network edge should appear")
    }

    @Test("subnet and port anchors resolve", )
    func subnetAndPortAnchors() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let subnetResult = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("subnet"),
            "id_or_name": .string("subnet-int"),
        ])
        #expect(subnetResult.isError != true, "Subnet topology failed: \(String(describing: firstText(subnetResult.content)))")
        let subnetText = firstText(subnetResult.content)
        #expect(subnetText?.contains("net-int") == true, "Owning network should appear")

        let portResult = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("port"),
            "id_or_name": .string("port-001"),
        ])
        #expect(portResult.isError != true, "Port topology failed: \(String(describing: firstText(portResult.content)))")
        let portText = firstText(portResult.content)
        #expect(portText?.contains("net-ext") == true, "Owning network should appear")
    }

    @Test("unsupported anchor is rejected", )
    func unsupportedAnchor() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("volume"),
            "id_or_name": .string("seed-vol"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("Unsupported topology anchor") == true, "Should name the anchor error, got: \(text ?? "nil")")
        #expect(text?.contains("server") == true, "Error should list supported anchors")
    }

    @Test("diagnosis flags a missing ingress rule for the asked protocol", )
    func diagnosisMissingRule() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // port-001 is attached to srv-0001 for this test.
        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "depth": .int(1),
            "diagnosis": .bool(true),
            "diagnose": .object(["protocol": .string("tcp"), "port": .int(22)]),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("no ingress rule") == true, "Finding should flag the missing rule, got: \(text ?? "nil")")
        #expect(text?.contains("tcp") == true)
        #expect(text?.contains("22") == true)
    }

    @Test("diagnosis: a matching ingress rule suppresses the finding", )
    func diagnosisMatchingRule() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Add an ssh ingress rule to the default SG (port-001's only group).
        let createRule = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("security_group_rule"),
            "spec": .object([
                "security_group_id": .string("sg-default"),
                "direction": .string("ingress"),
                "ethertype": .string("IPv4"),
                "protocol": .string("tcp"),
                "port_range_min": .int(22),
                "port_range_max": .int(22),
                "remote_ip_prefix": .string("0.0.0.0/0"),
            ]),
        ])
        #expect(createRule.isError != true, "Rule create failed: \(String(describing: firstText(createRule.content)))")

        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "depth": .int(1),
            "diagnosis": .bool(true),
            "diagnose": .object(["protocol": .string("tcp"), "port": .int(22)]),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("no ingress rule") != true, "No finding expected when the rule matches, got: \(text ?? "nil")")
    }

    @Test("diagnosis flags a SHUTOFF server", )
    func diagnosisShutoffServer() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0002"),
            "action": .string("stop"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0002"),
            "diagnosis": .bool(true),
        ])
        #expect(result.isError != true, "Topology failed: \(String(describing: firstText(result.content)))")
        let text = firstText(result.content)
        #expect(text?.contains("SHUTOFF") == true, "Finding should name the SHUTOFF server, got: \(text ?? "nil")")
    }

    @Test("read-only token can call os_topology", )
    func readOnlyCanTopology() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_topology", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "depth": .int(1),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("srv-0001") == true)
    }
}
