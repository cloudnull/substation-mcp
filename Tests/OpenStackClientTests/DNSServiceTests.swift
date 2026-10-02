import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("DNSService Tests", .timeLimit(.minutes(2)))
struct DNSServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, DNSService, Cache, Transport) {
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
        let svc = DNSService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Zones

    @Test("list zones returns the seeded zone")
    func listZones() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let zones = try await region.listZones(vt)
        #expect(zones.count == 1)
        #expect(zones.first?.id == "zone-1")
        #expect(zones.first?.status == "active")
        #expect(zones.first?.name == "example.com.")
    }

    @Test("get zone by id")
    func getZone() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let z = try await region.getZone(vt, id: "zone-1")
        #expect(z.id == "zone-1")
        #expect(z.email == "admin@example.com")
    }

    @Test("create then delete a zone")
    func createDeleteZone() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateZoneSpec(name: "new.example.org.", email: "a@b.c", ttl: 600)
        let created = try await region.createZone(vt, spec)
        #expect(created.id.hasPrefix("zone-"))
        #expect(created.status == "active")

        let zones = try await region.listZones(vt)
        #expect(zones.contains { $0.id == created.id })

        try await region.deleteZone(vt, id: created.id)
        let after = try await region.listZones(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    // MARK: - Record sets

    @Test("list record sets returns the seeded record set")
    func listRecordSets() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let rses = try await region.listRecordSets(vt)
        #expect(rses.count == 1)
        #expect(rses.first?.id == "rs-1")
        #expect(rses.first?.type == "A")
        #expect(rses.first?.records == ["10.0.0.1"])
    }

    @Test("create a record set")
    func createRecordSet() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateRecordSetSpec(zone_id: "zone-1", name: "api.example.com.", type: "A", ttl: 300, records: ["10.0.0.2"])
        let rs = try await region.createRecordSet(vt, spec)
        #expect(rs.id.hasPrefix("rs-"))
        #expect(rs.type == "A")
        #expect(rs.records == ["10.0.0.2"])
        #expect(rs.zone_id == "zone-1")
    }

    @Test("get record set by id")
    func getRecordSet() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let rs = try await region.getRecordSet(vt, id: "rs-1")
        #expect(rs.id == "rs-1")
        #expect(rs.name == "www.example.com.")
    }
}
