import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("PlacementService Tests", .timeLimit(.minutes(2)))
struct PlacementServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, PlacementService, Cache, Transport) {
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
        let transport = Transport(cloud: cloud, tokenSource: { tokenID }, logger: logger)
        let svc = PlacementService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Resource providers

    @Test("list resource providers returns the 2 seeded providers")
    func listProviders() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let rps = try await region.listResourceProviders(vt)
        #expect(rps.count == 2)
        #expect(rps.contains { $0.uuid == "rp-0001" })
        #expect(rps.contains { $0.uuid == "rp-0002" })
        let gpu = rps.first { $0.uuid == "rp-0002" }
        #expect(gpu?.name == "compute://fake-gpu-host-1")
        #expect(gpu?.traits == ["GPU", "NVIDIA:A100"])
    }

    @Test("list resource providers supports the name filter")
    func listProvidersByName() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let rps = try await region.listResourceProviders(vt, name: "compute://fake-host-1")
        #expect(rps.count == 1)
        #expect(rps.first?.uuid == "rp-0001")
    }

    @Test("get resource provider by uuid")
    func getProvider() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let rp = try await region.getResourceProvider(vt, uuid: "rp-0001")
        #expect(rp.uuid == "rp-0001")
        #expect(rp.name == "compute://fake-host-1")
        #expect(rp.generation == 3)
        #expect(rp.links?.contains(where: { $0.rel == "inventories" }) == true)
    }

    @Test("get resource provider inventories returns per-class totals")
    func getInventories() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let inv = try await region.getInventories(vt, uuid: "rp-0002")
        #expect(inv.resources["VCPU"]?.total == 8)
        #expect(inv.resources["MEMORY_MB"]?.total == 32768)
        #expect(inv.resources["DISK_GB"]?.total == 256)
        // GPU-class resources pass through the open-ended map verbatim.
        #expect(inv.resources["GPU"]?.total == 2)
    }

    @Test("get resource provider usages returns allocated amounts")
    func getUsages() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let usages = try await region.getUsages(vt, uuid: "rp-0001")
        #expect(usages.resources["VCPU"] == 4)
        #expect(usages.resources["MEMORY_MB"] == 8192)
        #expect(usages.resources["DISK_GB"] == 61)
    }

    @Test("get resource provider for an unknown uuid throws 404")
    func getProviderNotFound() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        do {
            _ = try await region.getResourceProvider(vt, uuid: "rp-missing")
            Issue.record("Expected 404 for unknown resource provider")
        } catch let error as OpenStackError {
            #expect(error.status == 404, "Expected 404, got \(error.status): \(error.message)")
        }
    }
}
