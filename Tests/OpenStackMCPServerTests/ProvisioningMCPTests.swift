import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Provisioning

/// In-process round-trip tests for distro-aware provisioning:
/// `os_create(server, provisioning: ...)` → rendered cloud-init → fake console
/// → `os_action(server, provisioning_status)` → parsed status.
@Suite("Provisioning MCP round-trips", .timeLimit(.minutes(3)))
struct ProvisioningMCPTests {

    // MARK: - Helpers

    /// Parse a tool result's text content (JSON) into a nested dictionary.
    private func resultDict(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard let text = firstText(result.content),
              let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("unparseable result: \(String(describing: firstText(result.content)))")
            return [:]
        }
        return obj
    }

    /// Create a provisioned server and return its id + provisioning sha.
    private func createProvisioned(
        _ bundle: MCPTestBundle
    ) async throws -> (id: String, sha: String) {
        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("prov-test"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "provisioning": .object([
                    "packages": .array([.string("curl")]),
                    "services": .array([.string("curl")]),
                    "firewall": .array([
                        .object(["proto": .string("tcp"), "port": .int(8080)]),
                    ]),
                    "final_message": .string("provisioned by osmcp"),
                ]),
            ]),
        ])
        #expect(result.isError != true, "os_create failed: \(String(describing: firstText(result.content)))")
        let data = try resultDict(result)
        let inner = (data["data"] as? [String: Any]) ?? data
        let id = inner["id"] as? String ?? ""
        let sha = inner["provisioning_sha"] as? String ?? ""
        #expect(!id.isEmpty, "no server id in result: \(data)")
        #expect(sha.count == 8, "no 8-hex sha in result: \(data)")
        return (id, sha)
    }

    /// Run `os_action(server, provisioning_status)` and return the decoded result.
    private func provisioningStatus(_ bundle: MCPTestBundle, _ id: String) async throws -> [String: Any] {
        let result = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string(id),
            "action": .string("provisioning_status"),
        ])
        #expect(result.isError != true, "status failed: \(String(describing: firstText(result.content)))")
        let data = try resultDict(result)
        return (data["data"] as? [String: Any]) ?? data
    }

    // MARK: - Tests

    @Test("os_create with provisioning renders cloud-init and reports succeeded")
    func createWithProvisioning() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (id, sha) = try await createProvisioned(bundle)
        _ = await handle.state.setServerStatus(serverID: id, status: "ACTIVE")

        let status = try await provisioningStatus(bundle, id)
        #expect(status["status"] as? String == "succeeded", "expected succeeded, got: \(status)")
        #expect(status["sha"] as? String == sha, "sha mismatch in status: \(status)")
        #expect(status["started"] as? Bool == true)
        #expect(status["finished"] as? Bool == true)
    }

    @Test("os_create with provisioning + dry_run returns rendered cloud-init")
    func dryRunProvisioning() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-test"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "provisioning": .object(["packages": .array([.string("curl")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run failed: \(String(describing: firstText(result.content)))")
        let data = try resultDict(result)
        #expect(data["dry_run"] as? Bool == true, "no dry_run flag")
        #expect((data["rendered_user_data"] as? String)?.hasPrefix("#cloud-config") == true, "no rendered yaml")
        #expect(data["provisioning_distro"] as? String == "ubuntu/apt", "distro not detected: \(data)")
        #expect((data["provisioning_sha"] as? String)?.count == 8, "no sha")
        #expect(data["rendered_user_data_base64"] as? String != nil, "no base64")
    }

    @Test("os_create with both user_data and provisioning is rejected")
    func userDataConflict() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("conflict"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "user_data": .string("aGVsbG8="),
                "provisioning": .object(["packages": .array([.string("curl")])]),
            ]),
        ])
        #expect(result.isError == true, "expected conflict error")
        let text = firstText(result.content) ?? ""
        #expect(text.lowercased().contains("mutually exclusive"), "expected XOR message, got: \(text)")
    }

    @Test("os_create with empty provisioning is rejected")
    func emptyProvisioning() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("empty"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "provisioning": .object([:]),
            ]),
        ])
        #expect(result.isError == true, "expected empty provisioning error")
        let text = firstText(result.content) ?? ""
        #expect(text.lowercased().contains("empty"), "expected empty message, got: \(text)")
    }

    @Test("os_create with oversized provisioning is rejected")
    func oversizedProvisioning() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Build a spec that will exceed the 12 KiB render cap.
        var pkgs: [Value] = []
        for i in 0..<400 { pkgs.append(.string("pkg-\(String(repeating: "x", count: 20))-\(i)")) }
        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("big"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "provisioning": .object(["packages": .array(pkgs)]),
            ]),
        ])
        #expect(result.isError == true, "expected oversized error")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("12288") || text.lowercased().contains("exceeding"), "expected size message, got: \(text)")
    }
    @Test("provisioning_status for a failed boot")
    func statusFailed() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (id, sha) = try await createProvisioned(bundle)
        _ = await handle.state.setServerStatus(serverID: id, status: "ACTIVE")
        _ = await handle.state.setServerProvisioningOutcome(serverID: id, outcome: "failed")

        let status = try await provisioningStatus(bundle, id)
        #expect(status["status"] as? String == "failed", "expected failed, got: \(status)")
        #expect(status["sha"] as? String == sha)
        let errLines = status["error_lines"] as? [String] ?? []
        #expect(!errLines.isEmpty, "expected error_lines")
        #expect(errLines.first?.contains("rc=1") == true)
    }

    @Test("provisioning_status for a pending boot")
    func statusPending() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (id, sha) = try await createProvisioned(bundle)
        _ = await handle.state.setServerStatus(serverID: id, status: "ACTIVE")
        _ = await handle.state.setServerProvisioningOutcome(serverID: id, outcome: "pending")

        let status = try await provisioningStatus(bundle, id)
        #expect(status["status"] as? String == "pending", "expected pending, got: \(status)")
        #expect(status["sha"] as? String == sha)
        #expect(status["started"] as? Bool == true)
        #expect(status["finished"] as? Bool == false)
    }

    @Test("provisioning_status on a server never provisioned -> unknown")
    func statusUnknown() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Seeded server srv-0001 (from FakeState.seed) was not created via
        // osmcp, so the console has no markers and the parser reports unknown.
        let status = try await provisioningStatus(bundle, "srv-0001")
        #expect(status["status"] as? String == "unknown", "expected unknown, got: \(status)")
    }

    @Test("dry_run with provisioning on an unknown image renders for unknown distro")
    func dryRunUnknownDistro() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-unknown"),
                "flavor": .string("m1.small"),
                "image": .string("does-not-exist"),
                "provisioning": .object(["packages": .array([.string("curl")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run failed: \(String(describing: firstText(result.content)))")
        let data = try resultDict(result)
        #expect(data["provisioning_distro"] as? String == "unknown/unknown", "expected unknown distro, got: \(data)")
    }
}