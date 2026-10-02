import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("KeyManagerService Tests", .timeLimit(.minutes(2)))
struct KeyManagerServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, KeyManagerService, Cache, Transport) {
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
        let svc = KeyManagerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Secrets

    @Test("list secrets returns the seeded secret")
    func listSecrets() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let secs = try await region.listSecrets(vt)
        #expect(secs.count == 1)
        #expect(secs.first?.id == "sec-1")
        #expect(secs.first?.status == "active")
    }

    @Test("get secret by id")
    func getSecret() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let s = try await region.getSecret(vt, id: "sec-1")
        #expect(s.id == "sec-1")
        #expect(s.type == "opaque")
    }

    @Test("get missing secret 404s")
    func getSecret404() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        do {
            _ = try await region.getSecret(vt, id: "nope")
            #expect(false, "should have thrown 404")
        } catch let e as OpenStackError {
            #expect(e.status == 404)
        }
    }

    @Test("create then delete a secret")
    func createDeleteSecret() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateSecretSpec(name: "new-secret", type: "opaque", secret: "c2VjcmV0", visibility: "private")
        let created = try await region.createSecret(vt, spec)
        #expect(!created.id.isEmpty)
        #expect(created.status == "active")
        #expect(created.name == "new-secret")

        let secs = try await region.listSecrets(vt)
        #expect(secs.contains { $0.id == created.id })

        try await region.deleteSecret(vt, id: created.id)
        let after = try await region.listSecrets(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    @Test("get secret payload returns the stored value")
    func getSecretPayload() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let payload = try await region.getSecretPayload(vt, id: "sec-1")
        #expect(payload.payload == "ZmFrZS1zZWNyZXQtbWF0ZXJpYWw=")
        #expect(payload.payloadContentType == "text/plain")
    }

    // MARK: - Containers

    @Test("list containers returns the seeded container")
    func listContainers() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let ctns = try await region.listContainers(vt)
        #expect(ctns.count == 1)
        #expect(ctns.first?.id == "sct-1")
    }

    @Test("get container by id")
    func getContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let c = try await region.getContainer(vt, id: "sct-1")
        #expect(c.id == "sct-1")
        #expect(c.secret_refs?.contains("sec-1") == true)
    }

    @Test("delete a container")
    func deleteContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        try await region.deleteContainer(vt, id: "sct-1")
        let after = try await region.listContainers(vt)
        #expect(after.isEmpty)
    }
}
