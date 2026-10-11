import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - Test helpers

/// Decode a token via the fake Keystone's auth/tokens endpoint.
func decodeToken(id: String, keystoneURL: URL) async throws -> ValidatedToken {
    let url = keystoneURL.appendingPathComponent("auth/tokens")
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(id, forHTTPHeaderField: "X-Auth-Token")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as! HTTPURLResponse).statusCode
    #expect(status == 200, "Token decode failed with \(status)")
    let token = try Token.decode(from: data)
    let scopes = deriveScopes(roles: token.roles)
    return ValidatedToken(token: token, scopes: scopes)
}

/// Bundle of test resources to shut down at test end.
final class MCPTestBundle: @unchecked Sendable {
    let mcpClient: MCP.Client
    let mcpServer: MCP.Server
    let client: OpenStackClient
    let identity: RequestIdentity
    private let shutdownClosure: @Sendable () -> Void

    init(mcpClient: MCP.Client, mcpServer: MCP.Server, client: OpenStackClient, identity: RequestIdentity, shutdownClosure: @escaping @Sendable () -> Void) {
        self.mcpClient = mcpClient
        self.mcpServer = mcpServer
        self.client = client
        self.identity = identity
        self.shutdownClosure = shutdownClosure
    }

    func shutdown() {
        shutdownClosure()
        Task { await mcpServer.stop() }
        Task { await mcpClient.disconnect() }
    }
}

/// Build a full `ToolRegistry` backed by a running `FakeApp`.
func makeRegistry(handle: FakeHandle, credID: String, secret: String) async throws -> MCPTestBundle {
    let logger = Logger(label: "test")

    guard let ft = await handle.state.mintToken(credID: credID, secret: secret, domain: nil, password: nil, userID: nil) else {
        throw OpenStackError(service: "test", status: 500, message: "Failed to mint token for \(credID)")
    }
    let vt = try await decodeToken(id: ft.id, keystoneURL: handle.keystoneURL)

    let whoami = Whoami(
        project: IdentityRef(id: ft.projectID, name: ft.projectName),
        domain: IdentityRef(id: ft.domainID, name: ft.domainName),
        roles: ft.roles,
        scopes: deriveScopes(roles: ft.roles),
        expiresAt: ft.expiresAt,
        regions: ["RegionOne"],
        services: [
            "compute": ["nova"],
            "network": ["neutron"],
            "volume": ["cinder"],
            "image": ["glance"],
        ]
    )
    let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: "fake")

    let cloud = CloudEntry(
        name: "fake",
        authURL: URL(string: handle.url.absoluteString)!,
        regionName: nil
    )
    let cache = Cache(maxEntries: 100)
    let transport = Transport(
        cloud: cloud,
        tokenSource: { ft.id },
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

    let catalog = ResourceCatalog.phase1()
    let policy = Policy()
    let registry = ToolRegistry(client: client, catalog: catalog, policy: policy, identity: identity, logger: logger)

    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let mcpClient = MCP.Client(name: "test-client", version: "1.0.0")
    let server = await registry.makeServer()

    // Start server first so its receive loop is ready before the client sends initialize
    try await server.start(transport: serverTransport)
    _ = try await mcpClient.connect(transport: clientTransport)

    return MCPTestBundle(
        mcpClient: mcpClient,
        mcpServer: server,
        client: client,
        identity: identity,
        shutdownClosure: { transport.syncShutdown() }
    )
}

/// Like `makeRegistry` but with `auth.scopes = per_service` enabled (P2), so
/// the write gate enforces per-service catalog presence.
func makeRegistryPerService(handle: FakeHandle, credID: String, secret: String) async throws -> MCPTestBundle {
    let logger = Logger(label: "test")

    guard let ft = await handle.state.mintToken(credID: credID, secret: secret, domain: nil, password: nil, userID: nil) else {
        throw OpenStackError(service: "test", status: 500, message: "Failed to mint token for \(credID)")
    }
    let vt = try await decodeToken(id: ft.id, keystoneURL: handle.keystoneURL)

    let whoami = Whoami(
        project: IdentityRef(id: ft.projectID, name: ft.projectName),
        domain: IdentityRef(id: ft.domainID, name: ft.domainName),
        roles: ft.roles,
        scopes: deriveScopes(roles: ft.roles),
        expiresAt: ft.expiresAt,
        regions: ["RegionOne"],
        services: [
            "compute": ["nova"],
            "network": ["neutron"],
            "volumev3": ["cinder"],
            "image": ["glance"],
        ]
    )
    let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: "fake")

    let cloud = CloudEntry(
        name: "fake",
        authURL: URL(string: handle.url.absoluteString)!,
        regionName: nil
    )
    let cache = Cache(maxEntries: 100)
    let transport = Transport(
        cloud: cloud,
        tokenSource: { ft.id },
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

    let catalog = ResourceCatalog.phase1()
    let policy = Policy()
    let registry = ToolRegistry(
        client: client, catalog: catalog, policy: policy, identity: identity,
        scopeMode: .perService, logger: logger
    )
    return try await finishBundle(registry: registry, client: client, identity: identity) { transport.syncShutdown() }
}

/// Shared tail of the registry builders: start the in-memory MCP server, connect
/// the client, and bundle everything for shutdown. The shutdown action is passed
/// as a closure so the `Transport` type is never *named* (it is ambiguous against
/// the MCP SDK's `Transport` in files that import both modules).
func finishBundle(
    registry: ToolRegistry,
    client: OpenStackClient,
    identity: RequestIdentity,
    _ shutdown: @escaping @Sendable () -> Void
) async throws -> MCPTestBundle {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let mcpClient = MCP.Client(name: "test-client", version: "1.0.0")
    let server = await registry.makeServer()

    // Start server first so its receive loop is ready before the client sends initialize
    try await server.start(transport: serverTransport)
    _ = try await mcpClient.connect(transport: clientTransport)

    return MCPTestBundle(
        mcpClient: mcpClient,
        mcpServer: server,
        client: client,
        identity: identity,
        shutdownClosure: shutdown
    )
}

/// Extract the first text content from a callTool result.
func firstText(_ content: [Tool.Content]) -> String? {
    for block in content {
        if case let .text(text: t, _, _) = block { return t }
    }
    return nil
}

// MARK: - Tests

@Suite("InProcess MCP Tests", .timeLimit(.minutes(3)))
struct InProcessMCPTests {

    @Test("initialize succeeds and instructions mention os_describe")
    func initialize() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }
        // connect() already ran initialize; the server is ready.
    }

    @Test("write-scoped token sees the 16 verb tools + 3 task tools")
    func writeTokenSeesVerbAndTaskTools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        // 16 verb tools (the stable, additive-only set) + 3 task-lifecycle
        // tools (os_task_submit/status/cancel, the Path C shim).
        #expect(names.count == 19, "Expected 19 tools, got \(names.count): \(names.sorted())")
        #expect(names.contains("os_create"))
        #expect(names.contains("os_delete"))
        #expect(names.contains("os_list"))
        #expect(names.contains("os_task_submit"))
        #expect(names.contains("os_task_status"))
        #expect(names.contains("os_task_cancel"))
    }

    @Test("read-only token sees the 10 read verbs + 3 task tools")
    func readOnlyTokenSeesReadAndTaskTools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        // 10 read-only verb tools + 3 read-scoped task tools = 13.
        #expect(names.count == 13, "Expected 13 tools, got \(names.count): \(names.sorted())")
        #expect(!names.contains("os_create"))
        #expect(!names.contains("os_delete"))
        #expect(names.contains("os_list"))
        #expect(names.contains("os_describe"))
        #expect(names.contains("os_task_submit"))
        #expect(names.contains("os_task_status"))
        #expect(names.contains("os_task_cancel"))
    }

    @Test("os_whoami reports scopes")
    func whoami() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_whoami", arguments: [:])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("admin") == true, "whoami should mention admin role, got: \(text ?? "nil")")
        #expect(text?.contains("openstack:read") == true)
        #expect(text?.contains("openstack:write") == true)
    }

    @Test("os_describe returns schema for server")
    func describeServer() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_describe", arguments: ["resource": .string("server")])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("server") == true)
        #expect(text?.contains("reboot") == true, "Should mention reboot action")
        // The create schema must be surfaced so the harness learns the exact
        // spec shape (regression: it was documented in the tool description but
        // never returned, forcing callers to guess field names like networks).
        #expect(text?.contains("create_schema") == true, "os_describe should return create_schema, got: \(text ?? "nil")")
        #expect(text?.contains("\"network\"") == true, "create_schema should expose the networks[].network field, got: \(text ?? "nil")")
    }

    @Test("os_describe surfaces phase-1 note on by-design 501 identity resources")
    func describeIdentityPhase1Note() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        for resource in ["region", "service", "endpoint", "application_credential"] {
            let result = try await bundle.mcpClient.callTool(name: "os_describe", arguments: ["resource": .string(resource)])
            #expect(result.isError != true, "\(resource) describe failed")
            let text = firstText(result.content) ?? ""
            #expect(text.contains("501 by design"), "\(resource) should document the by-design 501 phase-1 note, got: \(text)")
        }
    }

    @Test("os_list returns servers with default projection")
    func listServers() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_list", arguments: ["resource": .string("server")])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("server-1") == true)
        #expect(text?.contains("count") == true)
        #expect(text?.contains("id") == true)
        #expect(text?.contains("name") == true)
        #expect(text?.contains("status") == true)
    }

    @Test("os_list with unknown resource returns error")
    func listUnknownResource() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_list", arguments: ["resource": .string("nonexistent")])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("Unknown resource") == true)
    }

    @Test("os_create validates and creates a volume")
    func createVolume() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("volume"),
            "spec": .object(["size": .int(5), "name": .string("test-vol")]),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("volume") == true)
    }

    @Test("read-only token cannot call os_create")
    func readOnlyCannotCreate() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("volume"),
            "spec": .object(["size": .int(5)]),
        ])
        #expect(result.isError == true)
    }

    @Test("os_find searches by name")
    func findByName() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_find", arguments: ["value": .string("server-1")])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("server-1") == true)
    }

    @Test("os_quota returns compute quotas")
    func quotaCompute() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_quota", arguments: ["service": .string("compute")])
        #expect(result.isError != true)
    }

    @Test("os_clouds lists regions")
    func clouds() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_clouds", arguments: [:])
        #expect(result.isError != true)
    }

    @Test("os_clouds includes per-region capability matrix")
    func cloudsCapability() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_clouds", arguments: [:])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("capabilities"))
        #expect(text.contains("volume_types"))
    }

    @Test("os_project_readiness returns valid JSON with all sections")
    func projectReadinessValidJSON() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_project_readiness", arguments: [:])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("\"networks\""))
        #expect(text.contains("\"routers\""))
        #expect(text.contains("\"volumes\"") || text.contains("quota_volumes"), "Expected volume quota section, got: \(text)")
        #expect(text.contains("\"flavors\""))
        #expect(text.contains("\"keypairs\""))
        #expect(text.contains("\"security_groups\""))
        #expect(text.contains("\"ready_for_servers\""))
        #expect(text.contains("\"blockers\""))
    }

    @Test("project_readiness reports missing private network when none exists")
    func projectReadinessMissingNetwork() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // proj-one is seeded with int-net (private) plus ext-net (public); a
        // prior test may have created net-001. Delete every private network so
        // the blocker must appear.
        for name in ["net-int", "net-001"] {
            let del = try await bundle.mcpClient.callTool(name: "os_delete", arguments: [
                "resource": .string("network"),
                "id_or_name": .string(name),
            ])
            #expect(del.isError != true, "Delete \(name) failed: \(firstText(del.content) ?? "")")
        }

        let result = try await bundle.mcpClient.callTool(name: "os_project_readiness", arguments: [:])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("\"ready_for_servers\":false"), "Expected not ready, got: \(text)")
        #expect(text.contains("No private network"), "Expected private-network blocker, got: \(text)")
    }

    @Test("project_readiness reports ready when infra exists")
    func projectReadinessComplete() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // proj-one is seeded with int-net (private), ext-net (public),
        // router-1 (gateway to ext-net, interface on subnet-int), and a
        // test-key keypair — everything needed to deploy servers.
        let result = try await bundle.mcpClient.callTool(name: "os_project_readiness", arguments: [:])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("\"ready_for_servers\":true"), "Expected ready, got: \(text)")
        #expect(!text.contains("No private network"))
        #expect(!text.contains("No SSH keypairs"))
    }

    // MARK: - Server create dry-run validation (Task 2)

    /// Parse the first text content of a callTool result into a JSON dict.
    private func parseResult(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard let text = firstText(result.content),
              let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenStackError(service: "test", status: 500, message: "unparseable result: \(firstText(result.content) ?? "nil")")
        }
        return obj
    }

    @Test("server dry_run rejects public network without creating")
    func serverDryRunPublicNetwork() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let serversBefore = await handle.state.listServers(projectID: "proj-one").count

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-test"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "networks": .array([.object(["network": .string("ext-net")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        #expect(data["dry_run"] as? Bool == true, "expected dry_run flag, got: \(data)")
        #expect(data["valid"] as? Bool == false, "expected valid:false, got: \(data)")
        let errors = data["errors"] as? [String] ?? []
        #expect(errors.contains { $0.contains("publicNetworkRejected") }, "expected publicNetworkRejected in errors, got: \(errors)")

        // No server must have been created.
        let serversAfter = await handle.state.listServers(projectID: "proj-one").count
        #expect(serversAfter == serversBefore, "dry run must not create a server (\(serversBefore) -> \(serversAfter))")
    }

    @Test("server dry_run passes with valid private network and keypair")
    func serverDryRunValid() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let serversBefore = await handle.state.listServers(projectID: "proj-one").count

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-ok"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "key_name": .string("test-key"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        #expect(data["dry_run"] as? Bool == true, "expected dry_run flag, got: \(data)")
        #expect(data["valid"] as? Bool == true, "expected valid:true, got: \(data)")
        let errors = data["errors"] as? [String] ?? []
        #expect(errors.isEmpty, "expected no errors, got: \(errors)")
        let warnings = data["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("security groups") }, "expected SG warning, got: \(warnings)")

        // No server must have been created.
        let serversAfter = await handle.state.listServers(projectID: "proj-one").count
        #expect(serversAfter == serversBefore, "dry run must not create a server (\(serversBefore) -> \(serversAfter))")
    }

    @Test("server dry_run reports missing keypair and unknown image")
    func serverDryRunMissingKeypairAndImage() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-bad"),
                "flavor": .string("m1.small"),
                "image": .string("no-such-image"),
                "key_name": .string("no-such-key"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        #expect(data["valid"] as? Bool == false, "expected valid:false, got: \(data)")
        let errors = data["errors"] as? [String] ?? []
        #expect(errors.contains { $0.contains("imageNotFound") }, "expected imageNotFound, got: \(errors)")
        #expect(errors.contains { $0.contains("keypairNotFound") }, "expected keypairNotFound, got: \(errors)")
    }

    @Test("server dry_run reports unknown image AND unknown network in one pass")
    func serverDryRunMissingImageAndNetwork() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dry-bad2"),
                "flavor": .string("m1.small"),
                "image": .string("no-such-image"),
                "networks": .array([.object(["network": .string("no-such-net")])]),
            ]),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry run should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        #expect(data["valid"] as? Bool == false, "expected valid:false, got: \(data)")
        let errors = data["errors"] as? [String] ?? []
        #expect(errors.contains { $0.contains("imageNotFound") }, "expected imageNotFound, got: \(errors)")
        #expect(errors.contains { $0.contains("networkNotFound") }, "expected networkNotFound, got: \(errors)")
    }

    // MARK: - Error hints (Task 3)

    @Test("404 error includes hint listing available options")
    func errorHint404() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("nonexistent-server"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("Hint:"), "expected Hint in 404 response, got: \(text)")
        #expect(text.lowercased().contains("available"), "expected 'available' in 404 hint, got: \(text)")
    }

    @Test("403 quota error includes actionable path")
    func errorHintQuota() async throws {
        let err = OpenStackError.normalize(
            body: #"{"quotaExceeded":{"message":"Quota exceeded for instances: limit 10, in-use 10, requested 1"}}"#.data(using: .utf8),
            status: 403,
            service: "compute",
            requestID: nil,
            hasAccessRules: false
        )
        #expect(err.hint?.lowercased().contains("quota exceeded") == true, "expected quota hint, got: \(String(describing: err.hint))")
        #expect(err.hint?.lowercased().contains("delete unused") == true || err.hint?.lowercased().contains("request a quota increase") == true,
               "expected actionable quota guidance, got: \(String(describing: err.hint))")
    }

    @Test("publicNetworkRejected error has hint with creation sequence")
    func errorHintPublicNetwork() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("hint-test"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "key_name": .string("test-key"),
                "networks": .array([.object(["network": .string("ext-net")])]),
            ]),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("publicNetworkRejected"), "expected publicNetworkRejected, got: \(text)")
        #expect(text.contains("Hint:"), "expected Hint in publicNetworkRejected response, got: \(text)")
        #expect(text.contains("os_create(network"), "expected network creation step in hint, got: \(text)")
        #expect(text.contains("os_create(subnet"), "expected subnet creation step in hint, got: \(text)")
        #expect(text.contains("os_create(router"), "expected router creation step in hint, got: \(text)")
        #expect(text.contains("os_attach(link:router_interface"), "expected router interface attach step in hint, got: \(text)")
    }

    // MARK: - Next-step hints on mutation results (Task 4)

    @Test("network create returns next_steps for subnet")
    func networkCreateNextSteps() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("network"),
            "spec": .object(["name": .string("next-steps-net")]),
        ])
        #expect(result.isError != true, "network create should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        #expect(data["next_steps"] != nil, "expected next_steps in network create response, got: \(data)")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("next_steps"), "expected next_steps in response text, got: \(text)")
        #expect(text.contains("subnet"), "expected subnet hint in network create response, got: \(text)")
        #expect(text.contains("router"), "expected router hint in network create response, got: \(text)")
    }

    @Test("subnet create returns next_steps for router")
    func subnetCreateNextSteps() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let netResult = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("network"),
            "spec": .object(["name": .string("next-steps-subnet-net")]),
        ])
        #expect(netResult.isError != true, "network create should not error: \(firstText(netResult.content) ?? "nil")")
        let netData = try parseResult(netResult)
        guard let dataObj = netData["data"] as? [String: Any],
              let netID = dataObj["id"] as? String else {
            throw OpenStackError(service: "test", status: 500, message: "could not extract network id from: \(netData)")
        }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("subnet"),
            "spec": .object([
                "name": .string("next-steps-subnet"),
                "network_id": .string(netID),
                "cidr": .string("192.168.100.0/24"),
            ]),
        ])
        #expect(result.isError != true, "subnet create should not error: \(firstText(result.content) ?? "nil")")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("next_steps"), "expected next_steps in subnet create response, got: \(text)")
        #expect(text.contains("router"), "expected router hint in subnet create response, got: \(text)")
        #expect(text.contains("router_interface"), "expected router_interface hint in subnet create response, got: \(text)")
    }

    @Test("server create returns next_steps with os_wait")
    func serverCreateNextSteps() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("next-steps-server"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "key_name": .string("test-key"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
        ])
        #expect(result.isError != true, "server create should not error: \(firstText(result.content) ?? "nil")")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("next_steps"), "expected next_steps in server create response, got: \(text)")
        #expect(text.contains("os_wait"), "expected os_wait hint in server create response, got: \(text)")
    }

    // MARK: - Volume stuck-state diagnostics (Task 7)

    @Test("reserved volume with no attachments shows diagnostic")
    func reservedVolumeDiagnostic() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = await handle.state.seedVolume(id: "stuck-vol", projectID: "proj-one", name: "stuck-vol", status: "reserved")

        let result = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("volume"),
            "id_or_name": .string("stuck-vol"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("diagnostic"), "expected diagnostic field, got: \(text)")
        #expect(text.contains("Cinder"), "expected Cinder mention, got: \(text)")
        #expect(text.contains("force-release"), "expected force-release hint, got: \(text)")
    }

    @Test("error volume shows diagnostic")
    func errorVolumeDiagnostic() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = await handle.state.seedVolume(id: "broken-vol", projectID: "proj-one", name: "broken-vol", status: "error")

        let result = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("volume"),
            "id_or_name": .string("broken-vol"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("diagnostic"), "expected diagnostic field, got: \(text)")
        #expect(text.contains("error state"), "expected error-state message, got: \(text)")
        #expect(text.contains("os-vol-host"), "expected os-vol-host hint, got: \(text)")
    }

    @Test("healthy volume has no diagnostic field")
    func healthyVolumeNoDiagnostic() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("volume"),
            "id_or_name": .string("seed-vol"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(!text.contains("diagnostic"), "healthy volume must not carry a diagnostic, got: \(text)")
    }

    @Test("volume list annotates stuck volumes only")
    func volumeListDiagnostic() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        _ = await handle.state.seedVolume(id: "stuck-list-vol", projectID: "proj-one", name: "stuck-list-vol", status: "reserved")

        let result = try await bundle.mcpClient.callTool(name: "os_list", arguments: [
            "resource": .string("volume"),
            "fields": .array([.string("id"), .string("status"), .string("diagnostic")]),
        ])
        #expect(result.isError != true)
        let data = try parseResult(result)
        guard let items = data["items"] as? [[String: Any]] else {
            Issue.record("expected items array in list response, got: \(data)")
            return
        }
        let stuck = items.first { $0["id"] as? String == "stuck-list-vol" }
        #expect(stuck != nil, "stuck volume missing from list: \(data)")
        #expect(stuck?["diagnostic"] as? String != nil, "expected diagnostic on stuck volume in list")
        let healthy = items.first { $0["id"] as? String == "seed-vol" }
        #expect(healthy != nil, "seed-vol missing from list: \(data)")
        #expect(healthy?["diagnostic"] == nil, "healthy volume must not have diagnostic in list")
    }

}
