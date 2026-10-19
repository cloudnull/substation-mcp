import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack
import Logging

/// Regression coverage for the two defects that made `os_list` fail on
/// per-server compute resources, and for the `os_get` identifier aliases.
///
/// Both per-server resources advertise `server_id`, but the old implementation
/// forwarded the whole filter map into `GET /servers/detail`, where Nova rejects
/// unknown query keys with 400 "'server_id' does not match any of the regexes:
/// '^_'" — so the advertised filter could never work. The fan-out was also
/// serial (one round-trip per server).
@Suite("Per-Server List Scoping Tests")
struct PerServerListScopingTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, NameResolver, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state
        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        // The whoami body is the real decode path (mirrors NameResolverTests):
        // the fake's FakeToken is not an OpenStackClient.Token.
        let url = handle.keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(fakeToken.id, forHTTPHeaderField: "X-Auth-Token")
        let (data, _) = try await URLSession.shared.data(for: req)
        let token = try Token.decode(from: data)

        let cloud = CloudEntry(
            name: "fake",
            authURL: URL(string: handle.url.absoluteString)!,
            regionName: "RegionOne"
        )
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { fakeToken.id }, logger: logger)
        let validator = TokenValidator(transport: transport, cache: cache, servedProjects: [])
        let client = OpenStackClient(cloud: cloud, transport: transport, cache: cache, validator: validator, logger: logger)
        let resolver = NameResolver(catalog: ResourceCatalog.phase1(), client: client)
        return (handle, ValidatedToken(token: token, scopes: [.read, .write]), resolver, transport)
    }

    /// Seeds: srv-0001..srv-0003 in proj-one; vol-001 attached to srv-0001;
    /// port-002 owned by srv-0001.
    private func list(_ resolver: NameResolver, _ vt: ValidatedToken, _ resource: String, _ filters: [String: String]) async throws -> [[String: JSONValue]] {
        let d = ResourceCatalog.phase1().descriptor(resource)!
        let raw = try await resolver.listPublic(vt, descriptor: d, filters: filters, limit: nil, marker: nil, region: "RegionOne")
        return (raw["items"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    @Test("server_volume_attachment: server_id scopes without leaking to Nova", .timeLimit(.minutes(2)))
    func volumeAttachmentScopedByServer() async throws {
        let (handle, vt, resolver, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let scoped = try await list(resolver, vt, "server_volume_attachment", ["server_id": "srv-0001"])
        #expect(scoped.count == 1, "srv-0001 has exactly one seeded attachment, got \(scoped.count)")
        #expect(scoped.first?["volumeId"]?.stringValue == "vol-001")

        // A server with no attachments must yield an empty list, not a 400.
        let empty = try await list(resolver, vt, "server_volume_attachment", ["server_id": "srv-0002"])
        #expect(empty.isEmpty, "srv-0002 has no attachments")
    }

    @Test("server_volume_attachment: volume_id filters the fan-out results", .timeLimit(.minutes(2)))
    func volumeAttachmentScopedByVolume() async throws {
        let (handle, vt, resolver, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let hit = try await list(resolver, vt, "server_volume_attachment", ["volume_id": "vol-001"])
        #expect(hit.count == 1, "vol-001 is attached to exactly one seeded server")
        let miss = try await list(resolver, vt, "server_volume_attachment", ["volume_id": "vol-nope"])
        #expect(miss.isEmpty)
    }

    @Test("server_interface: server_id scopes without leaking to Nova", .timeLimit(.minutes(2)))
    func interfaceScopedByServer() async throws {
        let (handle, vt, resolver, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let scoped = try await list(resolver, vt, "server_interface", ["server_id": "srv-0001"])
        let ports = scoped.compactMap { $0["port"]?.stringValue }
        #expect(ports.contains("port-002"), "srv-0001 owns port-002; got \(ports)")
        #expect(!ports.contains("port-001"), "port-001 is not a compute port of srv-0001")

        let empty = try await list(resolver, vt, "server_interface", ["server_id": "srv-0002"])
        #expect(empty.isEmpty, "srv-0002 has no compute ports")
    }

    @Test("server_interface: port_id filters the fan-out results", .timeLimit(.minutes(2)))
    func interfaceScopedByPort() async throws {
        let (handle, vt, resolver, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let hit = try await list(resolver, vt, "server_interface", ["port_id": "port-002"])
        #expect(hit.count == 1)
        let miss = try await list(resolver, vt, "server_interface", ["port_id": "port-nope"])
        #expect(miss.isEmpty)
    }

    @Test("unscoped fan-out still returns attachments from every server", .timeLimit(.minutes(2)))
    func unscopedFanOut() async throws {
        let (handle, vt, resolver, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let all = try await list(resolver, vt, "server_volume_attachment", [:])
        #expect(all.count == 1, "one seeded attachment across three servers, got \(all.count)")
    }
}
