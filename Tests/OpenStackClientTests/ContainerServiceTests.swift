import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("ContainerService Tests", .timeLimit(.minutes(2)))
struct ContainerServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ContainerService, Cache, Transport) {
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
        let svc = ContainerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Clusters

    @Test("list clusters returns the seeded cluster")
    func listClusters() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let clusters = try await region.listContainers(vt)
        #expect(clusters.count == 1)
        #expect(clusters.first?.id == "cluster-1")
        #expect(clusters.first?.status == "ACTIVE")
    }

    @Test("get cluster by id")
    func getCluster() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let c = try await region.getContainer(vt, id: "cluster-1")
        #expect(c.id == "cluster-1")
        #expect(c.name == "fake-k8s-cluster")
        #expect(c.cluster_template_id == "ct-1")
    }

    @Test("create then delete a cluster")
    func createDeleteCluster() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateMagnumClusterSpec(name: "new-cluster", cluster_template_id: "ct-1", master_count: 1, node_count: 2)
        let created = try await region.createContainer(vt, spec)
        #expect(created.id.hasPrefix("cluster-"))
        #expect(created.status == "ACTIVE")
        #expect(created.node_count == 2)

        let clusters = try await region.listContainers(vt)
        #expect(clusters.contains { $0.id == created.id })

        try await region.deleteContainer(vt, id: created.id)
        let after = try await region.listContainers(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    // MARK: - Cluster templates

    @Test("list cluster templates returns the seeded template")
    func listClusterTemplates() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let templates = try await region.listClusterTemplates(vt)
        #expect(templates.count == 1)
        #expect(templates.first?.id == "ct-1")
        #expect(templates.first?.master_count == 1)
    }

    @Test("create a cluster template")
    func createClusterTemplate() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateMagnumClusterTemplateSpec(name: "new-template", master_count: 1, node_count: 4)
        let t = try await region.createClusterTemplate(vt, spec)
        #expect(t.id.hasPrefix("ct-"))
        #expect(t.name == "new-template")
        #expect(t.node_count == 4)
    }
}
