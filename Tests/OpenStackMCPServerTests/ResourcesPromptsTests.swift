import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - Task 16: MCP resources and prompts

@Suite("Resources and Prompts Tests", .timeLimit(.minutes(3)))
struct ResourcesPromptsTests {

    private func promptText(_ prompt: (description: String?, messages: [Prompt.Message])) -> String {
        prompt.messages.compactMap { m in
            if case let .text(t) = m.content { return t }
            return nil
        }
        .joined(separator: "\n")
    }

    // MARK: Resources — listing

    @Test("resources/list returns catalog + catalog/{resource} + the live template")
    func listResources() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (resources, nextCursor) = try await bundle.mcpClient.listResources()
        #expect(nextCursor == nil)

        let uris = resources.map(\.uri)
        #expect(uris.contains("openstack://catalog"), "catalog URI missing: \(uris)")
        #expect(uris.contains("openstack://catalog/server"), "catalog/server URI missing")
        #expect(uris.contains("openstack://catalog/volume"), "catalog/volume URI missing")
        #expect(uris.contains("openstack://catalog/security_group_rule"), "catalog/security_group_rule URI missing")
        #expect(uris.contains("openstack://fake/RegionOne/{resource}/{id}"), "live template missing: \(uris)")

        // Catalog URIs are advertised with subscribe disabled (phase 1).
        let cat = resources.first { $0.uri == "openstack://catalog" }
        #expect(cat?.mimeType == "application/json")
        #expect(cat?.annotations?.audience != nil || cat?.description != nil)

        // No per-instance URIs are enumerated for other projects.
        #expect(!uris.contains { $0.hasPrefix("openstack://fake/RegionOne/server/srv-") })
    }

    @Test("read-only token sees the same resource surface")
    func readOnlyResources() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let (resources, _) = try await bundle.mcpClient.listResources()
        let uris = Set(resources.map(\.uri))
        #expect(uris.contains("openstack://catalog"))
        #expect(uris.contains("openstack://catalog/server"))
        #expect(uris.contains("openstack://fake/RegionOne/{resource}/{id}"))
    }

    // MARK: Resources — reading

    @Test("openstack://catalog reads the full catalog index")
    func readCatalog() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let contents = try await bundle.mcpClient.readResource(uri: "openstack://catalog")
        #expect(contents.count == 1)
        let text = contents.first?.text ?? ""
        #expect(text.contains("server"), "catalog should list server")
        #expect(text.contains("floating_ip"), "catalog should list floating_ip")
        #expect(text.contains("security_group_rule"), "catalog should list security_group_rule")
    }

    @Test("openstack://catalog/{resource} reads one descriptor")
    func readCatalogEntry() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let contents = try await bundle.mcpClient.readResource(uri: "openstack://catalog/server")
        let text = contents.first?.text ?? ""
        #expect(text.contains("\"server\""))
        #expect(text.contains("reboot"), "server descriptor should mention reboot")
        #expect(text.contains("ACTIVE"), "server descriptor should mention terminal state")
    }

    @Test("openstack://{cloud}/{region}/{resource}/{id} reads live state")
    func readLiveResource() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let contents = try await bundle.mcpClient.readResource(uri: "openstack://fake/RegionOne/server/srv-0001")
        #expect(contents.count == 1)
        let text = contents.first?.text ?? ""
        #expect(text.contains("srv-0001"), "live resource should carry the id, got: \(text)")
        #expect(text.contains("ACTIVE"), "live server should be ACTIVE, got: \(text)")
    }

    @Test("reading an unknown resource id yields a tool-style error, not a crash")
    func readUnknownID() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let contents = try await bundle.mcpClient.readResource(uri: "openstack://fake/RegionOne/server/does-not-exist")
        #expect(contents.count == 1)
        let text = contents.first?.text ?? ""
        #expect(text.contains("not found"), "expected a not-found error, got: \(text)")
    }

    @Test("cross-project resource read is refused")
    func readOtherProjectRefused() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // srv-0004 belongs to proj-two; our token is proj-one.
        let contents = try await bundle.mcpClient.readResource(uri: "openstack://fake/RegionOne/server/srv-0004")
        #expect(contents.count == 1)
        let text = contents.first?.text ?? ""
        #expect(text.contains("not found"), "cross-project read should 404, got: \(text)")
    }

    // MARK: Prompts — listing

    @Test("prompts/list returns the four phase 1 prompts with their arguments")
    func listPrompts() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (prompts, nextCursor) = try await bundle.mcpClient.listPrompts()
        #expect(nextCursor == nil)
        let names = Set(prompts.map(\.name))
        #expect(names == ["login", "provision_server", "diagnose_connectivity", "audit_security_groups"],
                 "got: \(names.sorted())")

        let provision = prompts.first { $0.name == "provision_server" }
        let argNames = Set(provision?.arguments?.map(\.name) ?? [])
        #expect(argNames == ["name", "flavor", "image", "network", "public", "volume_gb", "provision"],
                "got: \(argNames.sorted())")

        let diag = prompts.first { $0.name == "diagnose_connectivity" }
        let diagArgs = Set(diag?.arguments?.map(\.name) ?? [])
        #expect(diagArgs == ["from", "to", "port", "protocol"], "got: \(diagArgs.sorted())")

        let audit = prompts.first { $0.name == "audit_security_groups" }
        #expect((audit?.arguments ?? []).isEmpty)
    }

    @Test("read-only token sees the same prompt surface")
    func readOnlyPrompts() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let (prompts, _) = try await bundle.mcpClient.listPrompts()
        #expect(Set(prompts.map(\.name)) == ["login", "provision_server", "diagnose_connectivity", "audit_security_groups"])
    }

    // MARK: Prompts — getting

    @Test("provision_server expands to the ordered plan with argument substitution")
    func provisionServerPrompt() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let prompt = try await bundle.mcpClient.getPrompt(name: "provision_server", arguments: [
            "name": "web-1",
            "flavor": "m1.small",
            "image": "ubuntu-24.04",
            "network": "ext-net",
            "public": "true",
            "volume_gb": "100",
        ])
        #expect(prompt.messages.count == 1)
        #expect(prompt.messages.first?.role == .user)
        let text = promptText(prompt)
        // Substitution of every argument.
        #expect(text.contains("web-1"))
        #expect(text.contains("m1.small"))
        #expect(text.contains("ubuntu-24.04"))
        #expect(text.contains("ext-net"))
        #expect(text.contains("100"))
        // The ordered plan.
        #expect(text.contains("os_find"), "plan should start with find, got: \(text)")
        #expect(text.contains("os_create"), "plan should create the server")
        #expect(text.contains("os_wait"), "plan should wait")
        #expect(text.contains("floating"), "public=true plan should add a floating IP")
        #expect(text.contains("os_attach"), "plan should attach the floating IP / volume")
        // Ordering: find before create before wait before attach.
        let offsets: [String: Int] = {
            var out: [String: Int] = [:]
            for step in ["os_find", "os_create", "os_wait", "os_attach"] {
                if let r = text.range(of: step) { out[step] = text.distance(from: text.startIndex, to: r.lowerBound) }
            }
            return out
        }()
        #expect(["os_find", "os_create", "os_wait", "os_attach"].allSatisfy { offsets[$0] != nil },
                "missing plan steps: \(text)")
        #expect((offsets["os_find"] ?? 0) < (offsets["os_create"] ?? -1)
                && (offsets["os_create"] ?? 0) < (offsets["os_wait"] ?? -1)
                && (offsets["os_wait"] ?? 0) < (offsets["os_attach"] ?? -1),
                "plan out of order: \(text)")
    }

    @Test("diagnose_connectivity directs os_topology with diagnosis on both ends")
    func diagnoseConnectivityPrompt() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let prompt = try await bundle.mcpClient.getPrompt(name: "diagnose_connectivity", arguments: [
            "from": "server-a",
            "to": "server-b",
            "port": "5432",
            "protocol": "tcp",
        ])
        let text = promptText(prompt)
        #expect(text.contains("server-a"))
        #expect(text.contains("server-b"))
        #expect(text.contains("5432"))
        #expect(text.contains("tcp"))
        #expect(text.contains("os_topology"), "should direct to os_topology, got: \(text)")
        #expect(text.contains("diagnosis"), "should request diagnosis")
        #expect(text.contains("both"), "should cover both ends")
        #expect(text.contains("first blocking"), "should explain the first blocking finding")
    }

    @Test("audit_security_groups directs a security group audit")
    func auditSecurityGroupsPrompt() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let prompt = try await bundle.mcpClient.getPrompt(name: "audit_security_groups")
        let text = promptText(prompt)
        #expect(text.contains("security_group_rule"), "should list security_group_rule, got: \(text)")
        #expect(text.contains("0.0.0.0/0"), "should flag world-open ingress")
        #expect(text.contains("unused"), "should flag unused groups")
    }

    @Test("login prompt with no arguments returns client-side mint instructions")
    func loginPrompt() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let prompt = try await bundle.mcpClient.getPrompt(name: "login")
        #expect(prompt.messages.count == 1)
        let text = promptText(prompt)
        #expect(text.contains("~/.config/openstack/mcp-tokens"), "should name the token store path, got: \(text)")
        #expect(text.contains("0600"), "should mention file mode")
        #expect(text.contains("401"), "should mention re-running on 401")
    }

    @Test("login prompt only ever offers URL-mode / client-mint (never form-mode credential collection)")
    func loginPromptIsURLModeOnly() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let prompt = try await bundle.mcpClient.getPrompt(name: "login")
        let text = promptText(prompt)
        // The two sanctioned paths: client-side mint, or the server's URL-mode login page.
        #expect(text.contains("Client-side mint"), "should offer client-side mint: \(text)")
        #expect(text.contains("/v1/login"), "should offer the URL-mode login page: \(text)")
        #expect(text.lowercased().contains("out-of-band"), "credentials enter out-of-band (never via the MCP client): \(text)")
        // Spec §6.1b: credentials MUST NOT be collected via form-mode elicitation.
        #expect(!text.lowercased().contains("form mode"), "must not instruct form-mode credential entry: \(text)")
        #expect(!text.lowercased().contains("form-mode"), "must not instruct form-mode credential entry: \(text)")
    }
}
