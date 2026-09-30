import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack
import Logging

@Suite("NameResolver Tests")
struct NameResolverTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, OpenStackClient, NameResolver, Cache, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state

        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }

        let url = handle.keystoneURL.appendingPathComponent("auth/tokens")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(fakeToken.id, forHTTPHeaderField: "X-Auth-Token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let token = try Token.decode(from: data)
        let vt = ValidatedToken(token: token, scopes: [.read, .write])

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

        return (handle, vt, client, resolver, cache, transport)
    }

    @Test("ID resolution: exact ID hit", .timeLimit(.minutes(2)))
    func idHit() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "srv-0001", region: "RegionOne")
        #expect(result.id == "srv-0001")
        #expect(result.raw["id"]?.stringValue == "srv-0001")
    }

    @Test("Name resolution: exact name hit", .timeLimit(.minutes(2)))
    func nameHit() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "server-1", region: "RegionOne")
        #expect(result.id == "srv-0001", "Expected srv-0001, got \(result.id)")
    }

    @Test("Name resolution: case-insensitive hit", .timeLimit(.minutes(2)))
    func caseInsensitiveHit() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        // "Server-1" should match "server-1"
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "Server-1", region: "RegionOne")
        #expect(result.id == "srv-0001", "Expected srv-0001, got \(result.id)")
    }

    @Test("Ambiguous name: two servers with same name", .timeLimit(.minutes(2)))
    func ambiguousName() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Create a second server with the same name "server-1"
        let state = handle.state
        _ = await state.createServer(name: "server-1", projectID: "proj-one", flavorID: "flavor-1")

        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        do {
            _ = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "server-1", region: "RegionOne")
            Issue.record("Expected AmbiguousNameError")
        } catch let error as AmbiguousNameError {
            #expect(error.candidates.count >= 2, "Expected at least 2 candidates, got \(error.candidates.count)")
            #expect(error.description.contains("Ambiguous"), "Description should mention ambiguity")
            for candidate in error.candidates {
                #expect(!candidate.id.isEmpty, "Candidate should have an ID")
                #expect(candidate.name == "server-1", "Candidate name should be server-1")
            }
        } catch {
            Issue.record("Expected AmbiguousNameError, got \(error)")
        }
    }

    @Test("Not found: ID 404s and name 404s", .timeLimit(.minutes(2)))
    func notFound() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        do {
            _ = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "nonexistent-server-xyz", region: "RegionOne")
            Issue.record("Expected OpenStackError for not found")
        } catch let error as OpenStackError {
            #expect(error.status == 404, "Expected 404, got \(error.status)")
            #expect(error.message.contains("nonexistent-server-xyz"), "Message should mention the name")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("Network name resolution: exact name hit", .timeLimit(.minutes(2)))
    func networkNameHit() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("network")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "ext-net", region: "RegionOne")
        #expect(result.id == "net-ext", "Expected net-ext, got \(result.id)")
    }
}
