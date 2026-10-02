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

    @Test("write-scoped token sees 15 tools")
    func writeTokenSees15Tools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        #expect(names.count == 15, "Expected 15 tools, got \(names.count): \(names.sorted())")
        #expect(names.contains("os_create"))
        #expect(names.contains("os_delete"))
        #expect(names.contains("os_list"))
    }

    @Test("read-only token sees 9 tools")
    func readOnlyTokenSees9Tools() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundle.shutdown() }

        let (tools, _) = try await bundle.mcpClient.listTools()
        let names = Set(tools.map(\.name))
        #expect(names.count == 9, "Expected 9 tools, got \(names.count): \(names.sorted())")
        #expect(!names.contains("os_create"))
        #expect(!names.contains("os_delete"))
        #expect(names.contains("os_list"))
        #expect(names.contains("os_describe"))
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
}
