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

    // MARK: - Catalog-gap resource lists (T2)

    @Test("address_group list returns 200 (items array)", .timeLimit(.minutes(2)))
    func addressGroupList() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("address_group")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "address_group")
        #expect(result["region"]?.stringValue == "RegionOne")
        #expect(result["items"]?.arrayValue != nil, "items should be an array")
        #expect(result["count"]?.intValue != nil)
    }

    @Test("volume_quota list returns the project quota wrapped in a 1-item list", .timeLimit(.minutes(2)))
    func volumeQuotaList() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("volume_quota")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "volume_quota")
        let items = result["items"]?.arrayValue ?? []
        #expect(items.count == 1, "volume_quota should be wrapped in a single-element list, got \(items.count)")
        let first = items.first?.objectValue ?? [:]
        #expect(first["volumes"]?.intValue == 10)
        #expect(first["gigabytes"]?.intValue == 1000)
        #expect(first["snapshots"]?.intValue == 10)
    }

    @Test("compute_quota list returns the project quota wrapped in a 1-item list", .timeLimit(.minutes(2)))
    func computeQuotaList() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("compute_quota")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "compute_quota")
        let items = result["items"]?.arrayValue ?? []
        #expect(items.count == 1, "compute_quota should be wrapped in a single-element list, got \(items.count)")
        let first = items.first?.objectValue ?? [:]
        #expect(first["instances"]?.intValue == 10)
        #expect(first["cores"]?.intValue == 20)
        #expect(first["ram"]?.intValue == 51200)
    }

    @Test("server_interface list flattens per-server interfaces", .timeLimit(.minutes(2)))
    func serverInterfaceList() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server_interface")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "server_interface")
        let items = result["items"]?.arrayValue ?? []
        // The fake seeds srv-0001 with port-002 attached to compute:nova,
        // so the flattened list carries at least that one interface.
        #expect(items.count >= 1, "Expected at least 1 interface, got \(items.count)")
        let first = items.first?.objectValue ?? [:]
        #expect(first["port"]?.stringValue != nil, "interface item should have a port id")
        #expect(first["net_id"]?.stringValue != nil, "interface item should have a net_id")
    }

    @Test("server_volume_attachment list flattens per-server volume attachments", .timeLimit(.minutes(2)))
    func serverVolumeAttachmentList() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("server_volume_attachment")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "server_volume_attachment")
        let items = result["items"]?.arrayValue ?? []
        // The fake seeds srv-0001 with one attachment (vol-001), so the
        // flattened list carries at least that one attachment.
        #expect(items.count >= 1, "Expected at least 1 volume attachment, got \(items.count)")
        let first = items.first?.objectValue ?? [:]
        #expect(first["volumeId"]?.stringValue != nil, "attachment item should have volumeId")
        #expect(first["serverId"]?.stringValue != nil, "attachment item should have serverId")
    }

    // MARK: - Catalog-gap resource gets (T2)

    @Test("volume_quota get returns the project quota", .timeLimit(.minutes(2)))
    func volumeQuotaGet() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Project id for the fake admin token.
        let descriptor = ResourceCatalog.phase1().descriptor("volume_quota")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "proj-one", region: "RegionOne")
        #expect(result.id == "proj-one")
        #expect(result.raw["volumes"]?.intValue == 10)
        #expect(result.raw["gigabytes"]?.intValue == 1000)
        #expect(result.raw["snapshots"]?.intValue == 10)
    }

    @Test("compute_quota get returns the project quota", .timeLimit(.minutes(2)))
    func computeQuotaGet() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("compute_quota")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "proj-one", region: "RegionOne")
        #expect(result.id == "proj-one")
        #expect(result.raw["instances"]?.intValue == 10)
        #expect(result.raw["cores"]?.intValue == 20)
        #expect(result.raw["ram"]?.intValue == 51200)
    }

    @Test("address_group get by id returns the group", .timeLimit(.minutes(2)))
    func addressGroupGet() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Create an address group through the resolver's create path so we
        // have a known id to resolve.
        let createDescriptor = ResourceCatalog.phase1().descriptor("address_group")!
        let created = try await resolver.createPublic(
            vt,
            descriptor: createDescriptor,
            body: .object([
                "name": .string("test-ag"),
                "description": .string("created in test"),
                "ip_addresses": .array([.string("10.0.0.0/24")]),
            ]),
            region: "RegionOne"
        )
        let agID = created["id"]?.stringValue
        #expect(agID != nil, "created address group should have an id")
        #expect(created["name"]?.stringValue == "test-ag")

        // Now resolve by id and verify we get the same group back.
        let descriptor = ResourceCatalog.phase1().descriptor("address_group")!
        let resolved = try await resolver.resolve(vt, descriptor: descriptor, idOrName: agID!, region: "RegionOne")
        #expect(resolved.id == agID)
        #expect(resolved.raw["name"]?.stringValue == "test-ag")
    }

    // MARK: - Placement (resource provider inventory)

    @Test("os_list placement returns the seeded providers via the resolver", .timeLimit(.minutes(2)))
    func listPlacement() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("placement")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: [:], limit: nil, marker: nil, region: "RegionOne")
        #expect(result["resource"]?.stringValue == "placement")
        #expect(result["region"]?.stringValue == "RegionOne")
        let items = result["items"]?.arrayValue
        #expect(items?.count == 2, "Expected 2 items, got \(String(describing: items?.count))")
        #expect(items?.contains(where: { $0.objectValue?["uuid"]?.stringValue == "rp-0001" }) == true)
    }

    @Test("os_get placement merges provider + inventory + usages", .timeLimit(.minutes(2)))
    func getPlacement() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("placement")!
        let result = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "rp-0002", region: "RegionOne")
        #expect(result.id == "rp-0002")
        #expect(result.raw["name"]?.stringValue == "compute://fake-gpu-host-1")
        // Merged inventory: open map keyed by resource class.
        let inventory = result.raw["inventory"]?.objectValue
        #expect(inventory?["VCPU"]?.objectValue?["total"]?.intValue == 8)
        #expect(inventory?["GPU"]?.objectValue?["total"]?.intValue == 2)
        // Merged usages.
        let usages = result.raw["usages"]?.objectValue
        #expect(usages?["VCPU"]?.intValue == 2)
        #expect(usages?["GPU"]?.intValue == 1)
    }

    // MARK: - Image actions (os_action wiring)

    @Test("image action set_visibility applies the new visibility", .timeLimit(.minutes(2)))
    func imageSetVisibilityAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "set_visibility", params: ["visibility": .string("public")], region: "RegionOne")
        #expect(result["id"]?.stringValue == "img-1")
        #expect(result["visibility"]?.stringValue == "public")
    }

    @Test("image action add_tag adds a single tag", .timeLimit(.minutes(2)))
    func imageAddTagAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "add_tag", params: ["tag": .string("env:staging")], region: "RegionOne")
        #expect(result["action"]?.stringValue == "add_tag")
        #expect(result["id"]?.stringValue == "img-1")
        #expect(result["tag"]?.stringValue == "env:staging")

        // Verify the tag was actually added.
        let got = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "img-1", region: "RegionOne")
        let tags = got.raw["tags"]?.arrayValue ?? []
        #expect(tags.contains(.string("env:staging")))
    }

    @Test("image action remove_tag removes a tag", .timeLimit(.minutes(2)))
    func imageRemoveTagAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        // Seed a tag, then remove it.
        _ = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "add_tag", params: ["tag": .string("os:ubuntu")], region: "RegionOne")
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "remove_tag", params: ["tag": .string("os:ubuntu")], region: "RegionOne")
        #expect(result["action"]?.stringValue == "remove_tag")
        #expect(result["tag"]?.stringValue == "os:ubuntu")

        let got = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "img-1", region: "RegionOne")
        let tags = got.raw["tags"]?.arrayValue ?? []
        #expect(!tags.contains(.string("os:ubuntu")))
    }

    @Test("image action reactivate restores an image to active", .timeLimit(.minutes(2)))
    func imageReactivateAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        _ = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "deactivate", params: [:], region: "RegionOne")
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "reactivate", params: [:], region: "RegionOne")
        #expect(result["id"]?.stringValue == "img-1")
        #expect(result["status"]?.stringValue == "active")
    }

    @Test("image action set_visibility without visibility param returns 400", .timeLimit(.minutes(2)))
    func imageSetVisibilityMissingParam() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        do {
            _ = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: "set_visibility", params: [:], region: "RegionOne")
            Issue.record("Expected 400 for missing visibility")
        } catch let error as OpenStackError {
            #expect(error.status == 400)
            #expect(error.message.contains("visibility"))
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }
}
