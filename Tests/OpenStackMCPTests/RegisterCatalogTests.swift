import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
@testable import OpenStackMCPServer
import Logging

// MARK: - register-catalog idempotency (spec §6.5)

/// Drives `CatalogRegistrar.ensureCatalog()` against the fake Keystone with an
/// admin token. Run once → creates service (type=mcp) + 3 endpoints; run again
/// → idempotent (same ids, no duplicates).
@Suite("Register Catalog", .timeLimit(.minutes(2)))
struct RegisterCatalogTests {

    /// Mint an admin token and return its id (used as X-Auth-Token).
    private func adminToken(handle: FakeHandle) async throws -> String {
        guard let ft = await handle.state.mintToken(
            credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil
        ) else {
            throw OpenStackError(service: "test", status: 500, message: "mint failed")
        }
        return ft.id
    }

    private func makeRegistrar(handle: FakeHandle, token: String) -> (registrar: CatalogRegistrar, transport: Transport) {
        let cloud = CloudEntry(name: "fake", authURL: URL(string: handle.url.absoluteString)!, regionName: nil)
        let logger = Logger(label: "catalog-test")
        let transport = Transport(cloud: cloud, tokenSource: { token }, logger: logger)
        let registrar = CatalogRegistrar(
            transport: transport,
            region: "RegionOne",
            publicURL: "http://mcp.example:9000/v1",
            adminToken: token,
            logger: logger
        )
        return (registrar, transport)
    }

    @Test("register-catalog is idempotent: creates once, reuses on second run")
    func idempotent() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        let token = try await adminToken(handle: handle)
        let (registrar, transport) = makeRegistrar(handle: handle, token: token)
        defer { transport.syncShutdown() }

        // First run: creates the service + 3 endpoints.
        let first = try await registrar.ensureCatalog()
        #expect(!first.serviceID.isEmpty)
        #expect(first.endpointIDs.count == 3)
        #expect(first.reusedEndpointIDs.isEmpty, "first run should create all 3 endpoints")

        let svcAfterFirst = await handle.state.listServices().count
        let epAfterFirst = await handle.state.listEndpoints().count
        #expect(await handle.state.serviceByType("mcp") != nil)
        #expect(await handle.state.serviceByType("mcp")?.name == "mcp")

        // Second run: same service id, same endpoint ids, all reused.
        let second = try await registrar.ensureCatalog()
        #expect(second.serviceID == first.serviceID, "service id must be stable")
        #expect(second.endpointIDs == first.endpointIDs, "endpoint ids must be stable")
        #expect(second.reusedEndpointIDs.count == 3, "second run should reuse all 3 endpoints")

        let svcAfterSecond = await handle.state.listServices().count
        let epAfterSecond = await handle.state.listEndpoints().count
        #expect(svcAfterSecond == svcAfterFirst, "no duplicate service")
        #expect(epAfterSecond == epAfterFirst, "no duplicate endpoints")
    }

    @Test("register-catalog rejects a non-admin token (no X-Auth-Token match)")
    func rejectsBadToken() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // A token id that was never minted → the fake Keystone 401s.
        let (registrar, transport) = makeRegistrar(handle: handle, token: "fake-tok-0000")
        defer { transport.syncShutdown() }
        // The transport normalizes a 401 into an OpenStackError; either an
        // OpenStackError or a CatalogRegistrarError is an acceptable "rejected"
        // outcome — the key is that ensureCatalog() throws, not returns.
        await #expect(throws: (any Error).self) {
            _ = try await registrar.ensureCatalog()
        }
    }
}
