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

    @Test("write-scoped token sees the 17 verb tools + 3 task tools")
    func writeTokenSeesVerbAndTaskTools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        // 17 verb tools (the stable, additive-only set) + 3 task-lifecycle
        // tools (os_task_submit/status/cancel, the Path C shim).
        #expect(names.count == 20, "Expected 20 tools, got \(names.count): \(names.sorted())")
        #expect(names.contains("os_create"))
        #expect(names.contains("os_delete"))
        #expect(names.contains("os_list"))
        #expect(names.contains("os_task_submit"))
        #expect(names.contains("os_task_status"))
        #expect(names.contains("os_task_cancel"))
    }

    @Test("read-only token sees the 11 read verbs + 3 task tools")
    func readOnlyTokenSeesReadAndTaskTools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        // 11 read-only verb tools + 3 read-scoped task tools = 14.
        #expect(names.count == 14, "Expected 14 tools, got \(names.count): \(names.sorted())")
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

    @Test("os_list security_group_rule honors the security_group_id filter (ISSUE 13)")
    func listSecurityGroupRuleFilter() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Two fresh, distinct security groups.
        let sgA = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("security_group"),
            "spec": .object(["name": .string("e2e-sg-a"), "description": .string("a")]),
        ])
        #expect(sgA.isError != true, "create SG A failed: \(firstText(sgA.content) ?? "")")
        let sgB = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("security_group"),
            "spec": .object(["name": .string("e2e-sg-b"), "description": .string("b")]),
        ])
        #expect(sgB.isError != true, "create SG B failed: \(firstText(sgB.content) ?? "")")
        let dataA = try? parseResult(sgA)
        let dataB = try? parseResult(sgB)
        let idA = (dataA?["data"] as? [String: Any])?["id"] as? String
        let idB = (dataB?["data"] as? [String: Any])?["id"] as? String
        #expect(idA != nil && idB != nil && idA != idB, "Need two distinct new SG ids; A=\(firstText(sgA.content) ?? "") B=\(firstText(sgB.content) ?? "")")
        guard let idA = idA, let idB = idB, idA != idB else {
            throw OpenStackError(service: "test", status: 500, message: "could not parse created SG ids")
        }

        // One rule on each group; capture each rule's id from its create response.
        var ruleIDs: [String: String] = [:]   // sg id -> rule id
        for sid in [idA, idB] {
            let r = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
                "resource": .string("security_group_rule"),
                "spec": .object([
                    "security_group_id": .string(sid),
                    "direction": .string("ingress"),
                    "ethertype": .string("IPv4"),
                    "protocol": .string("tcp"),
                    "port_range_min": .int(80),
                    "port_range_max": .int(80),
                ]),
            ])
            #expect(r.isError != true, "create rule on \(sid) failed: \(firstText(r.content) ?? "")")
            let ruleID = ((try? parseResult(r))?["data"] as? [String: Any])?["id"] as? String
            #expect(ruleID != nil, "created rule should carry an id, got: \(firstText(r.content) ?? "")")
            ruleIDs[sid] = ruleID
        }

        // Unfiltered list must see BOTH rules (one per group).
        let allRes = try await bundle.mcpClient.callTool(name: "os_list", arguments: ["resource": .string("security_group_rule")])
        #expect(allRes.isError != true)
        #expect((try? parseResult(allRes))?["count"] as? Int == 2, "Unfiltered should list both rules, got: \(firstText(allRes.content) ?? "")")

        // The filtered list for A must contain ONLY A's rule — not B's. Before the fix,
        // NameResolver dropped the security_group_id filter, so this returned all rules
        // regardless of the requested group.
        let res = try await bundle.mcpClient.callTool(name: "os_list", arguments: [
            "resource": .string("security_group_rule"),
            "filters": .object(["security_group_id": .string(idA)]),
        ])
        #expect(res.isError != true, "filtered list failed: \(firstText(res.content) ?? "")")
        let data = try parseResult(res)
        let items = data["items"] as? [[String: Any]] ?? []
        let ids = Set(items.compactMap { $0["id"] as? String })
        #expect(data["count"] as? Int == 1, "Filtered list should return exactly A's rule, got count=\(String(describing: data["count"])): \(data)")
        #expect(ids.contains(ruleIDs[idA]!) == true, "List should include SG A's rule id \(ruleIDs[idA]!): \(items)")
        #expect(ids.contains(ruleIDs[idB]!) == false, "Filtered list leaked B's rule \(ruleIDs[idB]!): \(items)")
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

    @Test("ISSUE 20: os_find resolves network names (not just servers)")
    func findResolvesNetworkNames() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // The old handleFind was hardcoded to server-name + port-IP only, so a
        // network like int-net never resolved. The catalog-driven rewrite must
        // find it via its name field and report the resource type.
        let result = try await bundle.mcpClient.callTool(name: "os_find", arguments: ["value": .string("int-net")])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("int-net"), "os_find should return the seeded network, got: \(text)")
        #expect(text.contains("\"network\""), "match should be typed as network, got: \(text)")
    }

    @Test("ISSUE 20: os_find resolves flavor names")
    func findResolvesFlavorNames() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_find", arguments: ["value": .string("m1.small")])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("m1.small"), "os_find should return the seeded flavor, got: \(text)")
        #expect(text.contains("\"flavor\""), "match should be typed as flavor, got: \(text)")
    }

    @Test("ISSUE 19: os_get(load_balancer, id=<uuid>) resolves by id")
    func loadBalancerGetById() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Create an LB, then get it back BY ID. On live Rackspace octavia the
        // item endpoint 404s while list works; NameResolver now falls back to a
        // list-scan by idField so get-by-id succeeds whenever list can see the
        // resource. In the fake the direct get already works — this pins that
        // behavior and guards against regressing the by-id path.
        let created = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("load_balancer"),
            "spec": .object(["name": .string("test-lb")]),
        ])
        #expect(created.isError != true, "create load_balancer failed: \(firstText(created.content) ?? "nil")")
        let createdData = try parseResult(created)
        let lbID = ((createdData["data"] as? [String: Any])?["id"] as? String) ?? ""
        #expect(!lbID.isEmpty, "expected the created LB to carry an id, got: \(createdData)")

        let getResult = try await bundle.mcpClient.callTool(name: "os_get", arguments: [
            "resource": .string("load_balancer"),
            "id_or_name": .string(lbID),
        ])
        #expect(getResult.isError != true, "get-by-id failed: \(firstText(getResult.content) ?? "nil")")
        let getText = firstText(getResult.content) ?? ""
        #expect(getText.contains(lbID), "get-by-id should echo the id, got: \(getText)")
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

    // MARK: - Flavor recommendation (Task 5)

    @Test("recommend_flavor matches database workload to RAM-heavy flavor")
    func recommendFlavorDatabase() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_recommend_flavor", arguments: [
            "workload": .string("database"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        // The fake seeds m1.* flavors; the top pick must be the most RAM-heavy
        // one and the response must carry reasoning + a volume type pairing.
        #expect(text.contains("m1.xlarge"), "Expected the highest-RAM flavor first, got: \(text)")
        #expect(text.contains("RAM"))
        #expect(text.contains("\"volume_type_recommendation\":\"HA-Performance\""))
        #expect(text.contains("\"total_available\":3"))
    }

    @Test("recommend_flavor handles unknown workload gracefully")
    func recommendFlavorUnknown() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_recommend_flavor", arguments: [
            "workload": .string("quantum computing"),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        // Unknown workload falls back to general-purpose scoring; reasons must
        // say so rather than claim a family match.
        #expect(text.contains("general-purpose") || text.contains("Balanced"), "Expected general-purpose fallback, got: \(text)")
        #expect(text.contains("\"recommendations\""))
        #expect(text.contains("\"volume_type_recommendation\""))
    }

    @Test("recommend_flavor min_ram_gb filter excludes small flavors")
    func recommendFlavorMinRamFilter() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Seeded: m1.small (2 GB), m1.large (8 GB), m1.xlarge (16 GB).
        let result = try await bundle.mcpClient.callTool(name: "os_recommend_flavor", arguments: [
            "min_ram_gb": .int(8),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(!text.contains("m1.small"), "m1.small (2 GB) should be filtered out, got: \(text)")
        #expect(text.contains("m1.large"))
        #expect(text.contains("m1.xlarge"))
    }

    @Test("recommend_flavor returns empty recommendations when no flavor matches")
    func recommendFlavorNoMatch() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_recommend_flavor", arguments: [
            "min_vcpu": .int(99),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("\"recommendations\":[]"), "Expected empty recommendations, got: \(text)")
        #expect(text.contains("No flavors match the specified requirements"))
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

    // MARK: - Auto security group (Task 6)

    @Test("server create without security_groups auto-creates an SSH SG")
    func autoSGCreatedWhenOmitted() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("auto-sg-server"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
        ])
        #expect(result.isError != true, "create should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        let inner = data["data"] as? [String: Any] ?? [:]
        #expect(inner["security_group_created"] as? String == "auto-sg-server-sg",
               "expected security_group_created=auto-sg-server-sg, got: \(data)")

        // The created SG must exist and carry an SSH ingress rule (tcp/22).
        let rn = await bundle.client.network(region: nil)
        let vt = bundle.identity.vt
        let sgs = try await rn.listSecurityGroups(vt)
        guard let sg = sgs.first(where: { $0.name == "auto-sg-server-sg" }) else {
            Issue.record("auto-created SG missing from list: \(sgs.map(\.name))")
            return
        }
        let rules = try await rn.listSecurityGroupRules(vt, securityGroupID: sg.id)
        let sshRule = rules.first {
            $0.direction == "ingress" && $0.ipProtocol == "tcp"
                && $0.portRangeMin == 22 && $0.portRangeMax == 22
                && $0.remoteIPPrefix == "0.0.0.0/0"
        }
        #expect(sshRule != nil, "expected tcp/22 ingress rule on auto SG, got: \(rules)")
    }

    @Test("server create with explicit security_groups does not auto-create")
    func autoSGBypassedWhenExplicit() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Pre-create the SG the server will reference by name.
        let rn = await bundle.client.network(region: nil)
        let vt = bundle.identity.vt
        _ = try await rn.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "explicit-sg", description: "test"))

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("explicit-sg-server"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "security_groups": .array([.string("explicit-sg")]),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
        ])
        #expect(result.isError != true, "create should not error: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        let inner = data["data"] as? [String: Any] ?? [:]
        #expect(inner["security_group_created"] == nil,
               "no security_group_created expected when SGs are explicit, got: \(data)")

        // No auto-named SG may have been created.
        let sgs = try await rn.listSecurityGroups(vt)
        #expect(sgs.first { $0.name == "explicit-sg-server-sg" } == nil,
               "auto SG must not be created when explicit SGs are given: \(sgs.map(\.name))")
    }

    // MARK: - Auto security group: retry/collision safety (ISSUE #2)

    @Test("retrying a server create reuses an existing <name>-sg instead of duplicating (ISSUE 2)")
    func autoSGReusedOnRetry() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Simulate the leftover state from a first (partially-succeeded) create:
        // an SG named `<server>-sg` already exists. A retry must REUSE it, not
        // spawn a second SG with the same name.
        let rn = await bundle.client.network(region: nil)
        let vt = bundle.identity.vt
        let preExisting = try await rn.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "retry-server-sg", description: "from first attempt"))

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("retry-server"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
        ])
        #expect(result.isError != true, "create should succeed by reusing the SG: \(firstText(result.content) ?? "nil")")
        let data = try parseResult(result)
        let inner = data["data"] as? [String: Any] ?? [:]
        #expect(inner["security_group_created"] as? String == "retry-server-sg",
               "expected the reused SG name reported, got: \(inner)")

        // Exactly ONE SG may bear that name — no duplicate was spawned.
        let sgs = try await rn.listSecurityGroups(vt)
        let matches = sgs.filter { $0.name == "retry-server-sg" }
        #expect(matches.count == 1, "retry must not duplicate the SG; found \(matches.count): \(matches.map(\.id))")
        // And it's the SAME group the first attempt made (id stable, reused).
        #expect(matches.first?.id == preExisting.id, "reused SG should be the original, got ids: \(matches.map(\.id)) vs original \(preExisting.id)")
        // The reused group still carries the SSH ingress rule (idempotent ensure).
        let rules = try await rn.listSecurityGroupRules(vt, securityGroupID: preExisting.id)
        #expect(rules.contains { $0.ipProtocol == "tcp" && $0.portRangeMin == 22 && $0.portRangeMax == 22 },
               "reused SG must carry tcp/22 rule, got: \(rules)")
    }

    @Test("ambiguous duplicate <name>-sgs produce a clean error, not a Nova 409 (ISSUE 2)")
    func autoSGAmbiguityErrorsCleanly() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Two same-named groups already exist (the pathological state from older
        // runs). The create must fail with a clear, actionable message rather than
        // surfacing Nova's opaque "Multiple security_group matches" 409.
        let rn = await bundle.client.network(region: nil)
        let vt = bundle.identity.vt
        _ = try await rn.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "dup-server-sg", description: "a"))
        _ = try await rn.createSecurityGroup(vt, CreateSecurityGroupSpec(name: "dup-server-sg", description: "b"))

        let result = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object([
                "name": .string("dup-server"),
                "flavor": .string("m1.small"),
                "image": .string("ubuntu-24.04"),
                "networks": .array([.object(["network": .string("int-net")])]),
            ]),
        ])
        #expect(result.isError == true, "create should fail when two same-named SGs exist, got: \(firstText(result.content) ?? "nil")")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("dup-server-sg") == true, "error should name the colliding SG, got: \(text)")
        #expect(text.contains("security_groups") == true, "error should tell caller to pass security_groups explicitly, got: \(text)")
        #expect(text.contains("Multiple security_group matches") == false, "should NOT leak raw Nova ambiguous-name 409, got: \(text)")
        // No third duplicate was created.
        let sgs = try await rn.listSecurityGroups(vt)
        #expect(sgs.filter { $0.name == "dup-server-sg" }.count == 2, "no new SG may be added on ambiguity, got: \(sgs.filter { $0.name == "dup-server-sg" }.count)")
    }

    // MARK: - Delete dry-run dependency walk (ISSUE #1)

    @Test("delete dry-run on a router with an interface port reports it as a dependent (ISSUE 1)")
    func deleteDryRunRouterWithInterfaceBlocked() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // The fake seeds router-1 with an interface on subnet-int and we seed the
        // matching network:router_interface port (port-rif-router1), so a dry-run
        // delete of router-1 must report that port as blocking — NOT can_delete:true.
        let result = try await bundle.mcpClient.callTool(name: "os_delete", arguments: [
            "resource": .string("router"),
            "id_or_name": .string("router-1"),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true, "dry-run should not error: \(firstText(result.content) ?? "")")
        let data = try parseResult(result)
        #expect(data["can_delete"] as? Bool == false,
               "router with an interface port must not be deletable, got: \(data)")
        let deps = (data["dependents"] as? [Any]) ?? []
        #expect(deps.count >= 1, "expected at least one dependent (the interface port), got: \(data)")
        // Must carry a specific teardown hint, not just a bare bool.
        #expect((data["hint"] as? String)?.contains("router_interface") == true
                || ((data["hint"] as? String) ?? "").lowercased().contains("detach"),
               "blocked dry-run should include a router_interface/detach hint, got: \(data)")
    }

    @Test("delete dry-run on a clean router with no interfaces reports can_delete (ISSUE 1)")
    func deleteDryRunCleanRouterCanDelete() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // A brand-new gateway-only router has NO interface port, so it is deletable.
        let created = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("router"),
            "spec": .object(["name": .string("clean-dr-rtr"), "external_gateway_info": .object(["network_id": .string("net-ext")])]),
        ])
        #expect(created.isError != true, "create router failed: \(firstText(created.content) ?? "")")
        let id = ((try? parseResult(created))?["data"] as? [String: Any])?["id"] as? String
        #expect(id != nil, "expected created router id, got: \(created)")

        let result = try await bundle.mcpClient.callTool(name: "os_delete", arguments: [
            "resource": .string("router"),
            "id_or_name": .string(id!),
            "dry_run": .bool(true),
        ])
        #expect(result.isError != true)
        let data = try parseResult(result)
        #expect(data["can_delete"] as? Bool == true, "gateway-only router with no interfaces should be deletable, got: \(data)")
        #expect(((data["dependents"] as? [Any]) ?? []).isEmpty, "no dependents expected, got: \(data)")
    }
}
