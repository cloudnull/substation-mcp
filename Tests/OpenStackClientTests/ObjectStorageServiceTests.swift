import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("ObjectStorageService Tests", .timeLimit(.minutes(2)))
struct ObjectStorageServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ObjectStorageService, Cache, Transport) {
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
        let svc = ObjectStorageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Containers

    @Test("list containers returns the seeded container")
    func listContainers() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let ctns = try await region.listContainers(vt)
        #expect(ctns.count == 1)
        #expect(ctns.first?.name == "fake-bucket")
    }

    @Test("get container by name")
    func getContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let ctn = try await region.getContainer(vt, name: "fake-bucket")
        #expect(ctn.name == "fake-bucket")
    }

    @Test("get missing container 404s")
    func getContainer404() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        do {
            _ = try await region.getContainer(vt, name: "nope")
            #expect(false, "should have thrown 404")
        } catch let e as OpenStackError {
            #expect(e.status == 404)
        }
    }

    @Test("create then delete a container")
    func createDeleteContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let created = try await region.createContainer(vt, CreateContainerSpec(name: "new-bucket", quotaBytes: 1024))
        #expect(created.name == "new-bucket")

        let ctns = try await region.listContainers(vt)
        #expect(ctns.contains { $0.name == "new-bucket" })

        try await region.deleteContainer(vt, name: "new-bucket")
        let after = try await region.listContainers(vt)
        #expect(!after.contains { $0.name == "new-bucket" })
    }

    // MARK: - Objects

    @Test("list objects in the seeded container")
    func listObjects() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let objs = try await region.listObjects(vt, container: "fake-bucket")
        #expect(objs.count == 1)
        #expect(objs.first?.name == "hello.txt")
        #expect(objs.first?.size == 11)
    }

    @Test("create, get, then delete an object")
    func objectRoundTrip() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateObjectSpec(container: "fake-bucket", name: "greeting.bin", content: "hello", contentType: "text/plain")
        let created = try await region.createObject(vt, spec)
        #expect(created.name == "greeting.bin")
        #expect(created.size == 5)

        let got = try await region.getObject(vt, container: "fake-bucket", name: "greeting.bin")
        #expect(got.name == "greeting.bin")
        #expect(got.contentType == "text/plain")

        try await region.deleteObject(vt, container: "fake-bucket", name: "greeting.bin")
        let after = try await region.listObjects(vt, container: "fake-bucket")
        #expect(!after.contains { $0.name == "greeting.bin" })
    }

    @Test("put object into a missing container 404s")
    func objectMissingContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateObjectSpec(container: "does-not-exist", name: "x", content: "y")
        do {
            _ = try await region.createObject(vt, spec)
            #expect(false, "should have thrown 404")
        } catch let e as OpenStackError {
            #expect(e.status == 404)
        }
    }
}
