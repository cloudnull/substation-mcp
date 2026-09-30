import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer

// MARK: - Link (os_attach / os_detach) tests
//
// Covers the 7 links from spec §8.7: volume, interface, security_group,
// floating_ip, router_interface, router_gateway, and the rejected image link.
// Each test starts from the seeded fixture set (see FakeState.seed).

@Suite("Link Tools Tests", .timeLimit(.minutes(3)))
struct LinkToolsTests {

    // MARK: - volume

    @Test("volume attach + wait: in-use, ACTIVE", )
    func volumeAttachWait() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdb")]),
            "wait": .bool(true),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("in-use") == true, "Volume should be in-use after wait, got: \(text ?? "nil")")
        #expect(text?.contains("wait") == true, "Result should carry the wait outcome")
    }

    @Test("volume attach requires the device param", )
    func volumeAttachMissingDevice() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("device") == true, "Error should mention the device param, got: \(text ?? "nil")")
    }

    @Test("volume attach rejects an already in-use volume", )
    func volumeAttachBusyVolume() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // First attach drives the volume in-use.
        let first = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdb")]),
        ])
        #expect(first.isError != true)

        // Second attach should fail naming the in-use status.
        let second = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0002"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdc")]),
        ])
        #expect(second.isError == true)
        let text = firstText(second.content)
        #expect(text?.contains("in-use") == true, "Error should name the volume status, got: \(text ?? "nil")")
    }

    @Test("volume detach returns the volume to available", )
    func volumeDetach() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdb")]),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "wait": .bool(true),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("available") == true, "Volume should be available after detach wait, got: \(text ?? "nil")")
    }

    @Test("volume detach on a non-attached volume errors", )
    func volumeDetachNotAttached() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("no attachment") == true, "Error should say no attachment, got: \(text ?? "nil")")
    }

    // MARK: - interface

    @Test("interface attach to a network creates a port on the server", )
    func interfaceAttachNetwork() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("net-int"),
            "target_type": .string("network"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("interface") == true)

        // The port now exists on the server (verify via os_list ports filtered by device).
        let ports = try await bundle.mcpClient.callTool(name: "os_list", arguments: [
            "resource": .string("port"),
            "filters": .object(["device_id": .string("srv-0003")]),
        ])
        #expect(ports.isError != true)
        let portText = firstText(ports.content)
        #expect(portText?.contains("srv-0003") == true, "A port should exist for the server, got: \(portText ?? "nil")")
    }

    @Test("interface attach rejects a port already attached elsewhere", )
    func interfaceAttachBusyPort() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // port-001 is unattached in the seed; attach it to a server first.
        let first = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(first.isError != true)

        // Now attaching it again (to another server) should fail.
        let second = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(second.isError == true)
        let text = firstText(second.content)
        #expect(text?.contains("already attached") == true, "Error should name the port conflict, got: \(text ?? "nil")")
    }

    @Test("interface detach removes the port from the server", )
    func interfaceDetach() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let attach = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(attach.isError != true)

        let detach = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(detach.isError != true)

        let ports = try await bundle.mcpClient.callTool(name: "os_list", arguments: [
            "resource": .string("port"),
            "filters": .object(["device_id": .string("srv-0003")]),
        ])
        let portText = firstText(ports.content)
        #expect(portText?.contains("port-001") != true, "port-001 should no longer be on the server, got: \(portText ?? "nil")")
    }

    // MARK: - security_group

    @Test("security_group attach adds the group to the server's first port", )
    func securityGroupAttach() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Give srv-0003 a port first (seed has none on that server).
        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("interface"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("net-int"),
            "target_type": .string("network"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("security_group"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("default"),
            "target_type": .string("security_group"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("sg-default") == true, "The default SG id should appear, got: \(text ?? "nil")")
    }

    @Test("security_group detach removes it from the port", )
    func securityGroupDetach() async throws {
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
        let sgAttach = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("security_group"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("default"),
            "target_type": .string("security_group"),
        ])
        #expect(sgAttach.isError != true, "Security group attach failed: \(firstText(sgAttach.content) ?? "nil")")

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("security_group"),
            "source": .string("srv-0003"),
            "source_type": .string("server"),
            "target": .string("default"),
            "target_type": .string("security_group"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("security_groups") == true, "Result should list the remaining groups, got: \(text ?? "nil")")
    }

    @Test("security_group detach when not attached errors", )
    func securityGroupDetachNotAttached() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("security_group"),
            "source": .string("port-001"),
            "source_type": .string("port"),
            "target": .string("default"),
            "target_type": .string("security_group"),
        ])
        // port-001's seeded groups are ["sg-default"]; detaching "default"
        // resolves to sg-default and should succeed. To assert the not-attached
        // error we need a group that is NOT on the port: create one.
        if result.isError != true {
            // Create a second group and detach THAT — it's not attached.
            _ = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
                "resource": .string("security_group"),
                "spec": .object(["name": .string("sg-other"), "description": .string("other")]),
            ])
            let other = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
                "link": .string("security_group"),
                "source": .string("port-001"),
                "source_type": .string("port"),
                "target": .string("sg-other"),
                "target_type": .string("security_group"),
            ])
            #expect(other.isError == true)
            let text = firstText(other.content)
            #expect(text?.contains("not attached") == true, "Error should say not attached, got: \(text ?? "nil")")
        }
    }

    // MARK: - floating_ip

    @Test("floating_ip attach to a port succeeds", )
    func floatingIPAttachToPort() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("floating_ip"),
            "source": .string("fip-001"),
            "source_type": .string("floating_ip"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("203.0.113.10") == true, "Result should carry the FIP address, got: \(text ?? "nil")")
        #expect(text?.contains("port-001") == true)
    }

    @Test("floating_ip detach disassociates but keeps the FIP", )
    func floatingIPDetach() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("floating_ip"),
            "source": .string("fip-001"),
            "source_type": .string("floating_ip"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("floating_ip"),
            "source": .string("fip-001"),
            "source_type": .string("floating_ip"),
            "target": .string("port-001"),
            "target_type": .string("port"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("disassociated") == true, "Detach should be a disassociation, got: \(text ?? "nil")")

        // The FIP still exists.
        let get = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("floating_ip"),
            "id_or_name": .string("fip-001"),
        ])
        #expect(get.isError != true)
    }

    // MARK: - router_interface

    @Test("router_interface attach + detach round-trip", )
    func routerInterfaceRoundTrip() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Create a fresh router without a gateway so the attach is observable.
        let create = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("router"),
            "spec": .object(["name": .string("test-router")]),
        ])
        #expect(create.isError != true)
        // The fake assigns router-2 by counter.
        let routerID = "router-2"

        let attach = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("router_interface"),
            "source": .string(routerID),
            "source_type": .string("router"),
            "target": .string("subnet-int"),
            "target_type": .string("subnet"),
        ])
        #expect(attach.isError != true)

        let detach = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("router_interface"),
            "source": .string(routerID),
            "source_type": .string("router"),
            "target": .string("subnet-int"),
            "target_type": .string("subnet"),
        ])
        #expect(detach.isError != true)
    }

    @Test("router_interface attach rejects a subnet without a gateway IP", )
    func routerInterfaceNoGateway() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // The phase-1 create path does not expose gateway_ip, so seed the
        // no-gateway subnet directly in the fake's state and use the id the
        // seed returns (it's the next counter id, not the literal name).
        let state = handle.state
        let seeded = await state.createSubnet(
            projectID: "proj-one",
            networkID: "net-int",
            cidr: "192.168.9.0/24",
            ipVersion: 4,
            gateway: nil,
            name: "no-gw-subnet",
            enableDHCP: true,
            allocationPools: [FakeState.FakeAllocationPool(start: "192.168.9.2", end: "192.168.9.254")]
        )
        guard let seeded else {
            Issue.record("Seeding the no-gateway subnet failed")
            return
        }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("router_interface"),
            "source": .string("router-1"),
            "source_type": .string("router"),
            "target": .string(seeded.id),
            "target_type": .string("subnet"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("no gateway IP") == true, "Error should mention the missing gateway, got: \(text ?? "nil")")
    }

    // MARK: - router_gateway

    @Test("router_gateway attach requires an external network", )
    func routerGatewayRequiresExternal() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("router_gateway"),
            "source": .string("router-1"),
            "source_type": .string("router"),
            "target": .string("net-int"),
            "target_type": .string("network"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("not an external network") == true, "Error should name the non-external net, got: \(text ?? "nil")")
    }

    @Test("router_gateway attach + detach round-trip on an external network", )
    func routerGatewayRoundTrip() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // router-1 already has a gateway; detach then re-attach.
        let detach = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("router_gateway"),
            "source": .string("router-1"),
            "source_type": .string("router"),
            "target": .string("net-ext"),
            "target_type": .string("network"),
        ])
        #expect(detach.isError != true)

        let attach = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("router_gateway"),
            "source": .string("router-1"),
            "source_type": .string("router"),
            "target": .string("net-ext"),
            "target_type": .string("network"),
        ])
        #expect(attach.isError != true)
        let text = firstText(attach.content)
        #expect(text?.contains("enable_snat") == true, "Result should report snat flag, got: \(text ?? "nil")")
    }

    // MARK: - image (rejected)

    @Test("image link attach is rejected with the create-pointer", )
    func imageLinkRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("image"),
            "source": .string("seed-vol"),
            "source_type": .string("volume"),
            "target": .string("img-1"),
            "target_type": .string("image"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("os_create") == true, "Error should point at os_create, got: \(text ?? "nil")")
        #expect(text?.contains("upload_to_image") == true, "Error should mention the reverse action")
    }

    @Test("image link detach is rejected", )
    func imageDetachRejected() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_detach", arguments: [
            "link": .string("image"),
            "source": .string("seed-vol"),
            "source_type": .string("volume"),
            "target": .string("img-1"),
            "target_type": .string("image"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("cannot be detached") == true, "Error should explain, got: \(text ?? "nil")")
    }

    // MARK: - read-only scope

    @Test("read-only token cannot call os_attach", )
    func readOnlyCannotAttach() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_attach", arguments: [
            "link": .string("volume"),
            "source": .string("srv-0001"),
            "source_type": .string("server"),
            "target": .string("seed-vol"),
            "target_type": .string("volume"),
            "params": .object(["device": .string("/dev/vdb")]),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("write scope") == true, "Error should mention write scope, got: \(text ?? "nil")")
    }
}
