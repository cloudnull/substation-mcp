import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("ShareService Tests", .timeLimit(.minutes(2)))
struct ShareServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ShareService, Cache, Transport) {
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
        let svc = ShareService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Shares

    @Test("list shares returns the seeded share")
    func listShares() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let shares = try await region.listShares(vt)
        #expect(shares.count == 1)
        #expect(shares.first?.id == "share-1")
        #expect(shares.first?.status == "available")
        #expect(shares.first?.share_size == 10)
    }

    @Test("get share by id")
    func getShare() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let s = try await region.getShare(vt, id: "share-1")
        #expect(s.id == "share-1")
        #expect(s.name == "fake-share")
        #expect(s.share_type == "generic")
    }

    @Test("create then delete a share")
    func createDeleteShare() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateShareSpec(name: "new-share", share_size: 5, share_type: "generic", is_public: false)
        let created = try await region.createShare(vt, spec)
        #expect(created.id.hasPrefix("share-"))
        #expect(created.status == "available")
        #expect(created.share_size == 5)

        let shares = try await region.listShares(vt)
        #expect(shares.contains { $0.id == created.id })

        try await region.deleteShare(vt, id: created.id)
        let after = try await region.listShares(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    // MARK: - Share access

    @Test("list share access for a share returns the seeded access")
    func listShareAccess() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let accesses = try await region.listShareAccess(vt, shareID: "share-1")
        #expect(accesses.count == 1)
        #expect(accesses.first?.id == "sa-1")
        #expect(accesses.first?.access_to == "10.0.0.0/24")
        #expect(accesses.first?.access_type == "ip")
    }

    @Test("create a share access")
    func createShareAccess() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateShareAccessSpec(share_id: "share-1", access_to: "10.0.1.0/24", access_type: "ip", access_protocol: "nfs")
        let a = try await region.createShareAccess(vt, spec)
        #expect(a.id.hasPrefix("sa-"))
        #expect(a.share_id == "share-1")
        #expect(a.access_to == "10.0.1.0/24")
        #expect(a.state == "accessible")
    }

    @Test("delete a share access")
    func deleteShareAccess() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        try await region.deleteShareAccess(vt, shareID: "share-1", id: "sa-1")
        let after = try await region.listShareAccess(vt, shareID: "share-1")
        #expect(after.isEmpty)
    }
}
