import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - Service scope names (P2 per-service scopes)

@Suite("ServiceScopeNames")
struct ServiceScopeNamesTests {
    @Test func serviceTypeName_mapsEnumToCatalogType() {
        // The per-service scope name is the catalog service type the token
        // catalog carries, so a presence check lines up with the resolved
        // service. Block storage resolves to the Cinder v3 type `volumev3`.
        #expect(Service.compute.serviceTypeName == "compute")
        #expect(Service.network.serviceTypeName == "network")
        #expect(Service.blockStorage.serviceTypeName == "volumev3")
        #expect(Service.image.serviceTypeName == "image")
        #expect(Service.identity.serviceTypeName == "identity")
    }

    @Test func allServiceScopeNames_coversEveryService() {
        let all = Service.allServiceScopeNames
        #expect(all.count == Service.allCases.count)
        #expect(Set(all).count == all.count, "service scope names must be unique: \(all)")
        #expect(all.allSatisfy { $0.hasSuffix(":write") }, "each must be a write scope: \(all)")
        #expect(all.contains("compute:write"), "expected compute:write: \(all)")
        #expect(all.contains("volumev3:write"), "expected volumev3:write: \(all)")
    }
}

// MARK: - P2 per-service scope enforcement (dispatch-level)
//
// A token whose roles derive `openstack:write` may mutate only services present
// in its own token catalog when `auth.scopes = per_service`. We drive the real
// `ToolRegistry.dispatch` with a FORGED identity (write scope + a partial
// catalog) so the catalog-presence rule is exercised directly. The forged token
// reuses the real client's catalog shape (service types like `compute` /
// `volumev3`) minus the services we want to deny. The scope gate runs before
// any OpenStack call, so a denial never touches the fake and an allow proceeds
// to a real (succeeding) create.

@Suite("P2 per-service scope enforcement", .timeLimit(.minutes(3)))
struct ServiceScopeTests {

    /// Build a registry bundle on the real client from `base`, but with a forged
    /// identity: write scope + a catalog that lists only `catalogTypes`.
    private static func forgedBundle(
        base: MCPTestBundle,
        catalogTypes: [String],
        scopeMode: ToolRegistry.ScopeMode
    ) async throws -> MCPTestBundle {
        let logger = Logger(label: "svc-scope-forged")
        let realToken = base.identity.vt.token
        let forged = Token(
            id: realToken.id,
            expiresAt: realToken.expiresAt,
            project: realToken.project,
            domain: realToken.domain,
            user: realToken.user,
            roles: ["admin"],
            catalog: catalogTypes.map { t in
                realToken.catalog.first(where: { $0.type == t })
                    ?? CatalogEntry(type: t, name: t, endpoints: [
                        CatalogEndpoint(region: "RegionOne", interface: "public", url: URL(string: "http://fake.local/\(t)")!)
                    ])
            }
        )
        let vt = ValidatedToken(token: forged, scopes: [.read, .write])
        let whoami = Whoami(
            project: realToken.project,
            domain: realToken.domain,
            roles: ["admin"],
            scopes: [.read, .write],
            expiresAt: realToken.expiresAt,
            regions: ["RegionOne"],
            services: catalogTypes.reduce(into: [String: [String]]()) { $0[$1] = [$1] }
        )
        let identity = RequestIdentity(vt: vt, whoami: whoami, cloudName: "fake")
        let registry = ToolRegistry(
            client: base.client,
            catalog: ResourceCatalog.phase1(),
            policy: Policy(),
            identity: identity,
            scopeMode: scopeMode,
            logger: logger
        )
        // The forged registry reuses the real client (and its transport); the
        // base bundle's shutdown already tears the shared transport down.
        return try await finishBundle(registry: registry, client: base.client, identity: identity) { }
    }

    @Test("per_service: a write token whose catalog lacks 'compute' is denied os_create(server)")
    func deniedWhenCatalogLacksService() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Baseline: the real (full-catalog, coarse) registry allows the create,
        // so the denial below is attributable to the per-service gate.
        let baseline = try await bundle.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object(["name": .string("baseline-server"), "flavor": .string("m1.small"), "image": .string("ubuntu-24.04")]),
        ])
        #expect(baseline.isError != true, "baseline (full catalog, coarse) should allow: \(firstText(baseline.content) ?? "")")

        // Forged identity: write scope but a catalog that lacks compute.
        let forged = try await Self.forgedBundle(base: bundle, catalogTypes: ["volumev3", "image"], scopeMode: .perService)
        defer { forged.shutdown() }

        let result = try await forged.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object(["name": .string("denied-server"), "flavor": .string("m1.small"), "image": .string("ubuntu-24.04")]),
        ])
        let text = firstText(result.content) ?? ""
        #expect(result.isError == true, "server should be denied (not in forged catalog): \(text)")
        #expect(text.contains("compute:write") || text.lowercased().contains("insufficient"),
                "error should name the missing per-service scope: \(text)")
    }

    @Test("per_service: the same write token is allowed for a service its catalog includes")
    func allowedWhenCatalogHasService() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Forged identity whose catalog includes volumev3 (the fake's volume
        // service type) but not compute. A volume create must clear the scope
        // gate and succeed; a server create would be denied.
        let forged = try await Self.forgedBundle(base: bundle, catalogTypes: ["volumev3", "image"], scopeMode: .perService)
        defer { forged.shutdown() }

        let result = try await forged.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("volume"),
            "spec": .object(["size": .int(5), "name": .string("scope-vol")]),
        ])
        let text = firstText(result.content) ?? ""
        #expect(!text.contains("insufficient_scope") && !text.contains("volumev3:write"),
                "in-catalog service must not be scope-denied: \(text)")
        #expect(result.isError != true, "in-catalog volume create should succeed: \(text)")
    }

    @Test("coarse (default): the per-service gate is off, so a catalog-lacking write is not scope-denied")
    func coarseDoesNotScopeDeny() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Forged identity: write scope + a catalog lacking compute, coarse mode.
        // The create must NOT be scope-denied (it should succeed, since the
        // scope gate is off and the real client has a full catalog to route to).
        let forged = try await Self.forgedBundle(base: bundle, catalogTypes: ["image"], scopeMode: .coarse)
        defer { forged.shutdown() }

        let result = try await forged.mcpClient.callTool(name: "os_create", arguments: [
            "resource": .string("server"),
            "spec": .object(["name": .string("coarse-server"), "flavor": .string("m1.small"), "image": .string("ubuntu-24.04")]),
        ])
        let text = firstText(result.content) ?? ""
        #expect(!text.contains("insufficient_scope") && !text.contains("compute:write"),
                "coarse mode must not apply the per-service gate: \(text)")
    }
}
