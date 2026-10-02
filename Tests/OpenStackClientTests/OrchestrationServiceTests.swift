import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("OrchestrationService Tests", .timeLimit(.minutes(2)))
struct OrchestrationServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, OrchestrationService, Cache, Transport) {
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
        let svc = OrchestrationService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    @Test("list stacks returns the seeded stack")
    func listStacks() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let stacks = try await region.listStacks(vt)
        #expect(stacks.count == 1)
        #expect(stacks.first?.id == "stack-1")
        #expect(stacks.first?.status == "CREATE_COMPLETE")
    }

    @Test("get stack by id")
    func getStack() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let s = try await region.getStack(vt, id: "stack-1")
        #expect(s.id == "stack-1")
        #expect(s.name == "fake-stack")
        #expect(s.parameters?["environment"] == "dev")
    }

    @Test("get stack outputs returns the seeded output")
    func getStackOutputs() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let outputs = try await region.getStackOutputs(vt, id: "stack-1")
        #expect(outputs.count == 1)
        #expect(outputs.first?.output_key == "endpoint")
        #expect(outputs.first?.output_value == "http://10.0.0.50:8080")
    }

    @Test("create then delete a stack")
    func createDeleteStack() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateStackSpec(
            name: "new-stack",
            template: "heat_template_version: '2016-10-14'\nresources: {}",
            parameters: ["environment": "prod"]
        )
        let created = try await region.createStack(vt, spec)
        #expect(created.id.hasPrefix("stack-"))
        #expect(created.status == "CREATE_COMPLETE")
        #expect(created.parameters?["environment"] == "prod")

        let stacks = try await region.listStacks(vt)
        #expect(stacks.contains { $0.id == created.id })

        try await region.deleteStack(vt, id: created.id)
        let after = try await region.listStacks(vt)
        #expect(!after.contains { $0.id == created.id })
    }
}
