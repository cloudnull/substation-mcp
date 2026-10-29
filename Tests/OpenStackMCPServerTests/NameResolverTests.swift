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
            // A failed LOOKUP is a distinct failure from a missing resource:
            // callers branch on this code to avoid reporting "does not exist"
            // for an identifier that was never resolved.
            #expect(error.code == "nameNotResolved", "Expected code nameNotResolved, got \(String(describing: error.code))")
            #expect(error.message.contains("id or name"), "Message should say what was searched, got: \(error.message)")
            // Attributed to the compute service, never to the MCP layer.
            #expect(error.service == "compute", "Should be attributed to compute, got \(error.service)")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("image NAME resolves to the same id as the UUID, with no properties or tags", .timeLimit(.minutes(2)))
    func imageMetadataPoorName() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let descriptor = ResourceCatalog.phase1().descriptor("image")!

        // `Debian-13`: active, public, owned by ANOTHER project, empty
        // `properties`, no `tags`. Metadata is descriptive — lacking it must
        // never make an image unresolvable.
        let byName = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "Debian-13", region: "RegionOne")
        #expect(byName.id == "img-public-other", "Name should resolve to the public image, got \(byName.id)")

        // The UUID form resolves to the same resource: name and id are aliases.
        let byID = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "img-public-other", region: "RegionOne")
        #expect(byID.id == byName.id, "NAME and UUID must resolve identically")
        #expect(byName.raw["status"]?.stringValue == "active")
        #expect(byName.raw["visibility"]?.stringValue == "public")
    }

    @Test("ambiguous image NAME lists every candidate id", .timeLimit(.minutes(2)))
    func imageAmbiguousName() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let descriptor = ResourceCatalog.phase1().descriptor("image")!

        do {
            _ = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "Debian-12", region: "RegionOne")
            Issue.record("Expected AmbiguousNameError for a name matching two images")
        } catch let error as AmbiguousNameError {
            let ids = Set(error.candidates.map { $0.id })
            #expect(ids == ["img-ambig-a", "img-ambig-b"], "Should list both candidates, got \(ids)")
        } catch {
            Issue.record("Expected AmbiguousNameError, got \(error)")
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

    @Test("server create: networks[] entry with neither network nor port fails fast", .timeLimit(.minutes(2)))
    func serverCreateNetworkEntryFailsFast() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Regression: an unresolvable networks[] entry used to be silently
        // dropped, so the request went out with no `networks` key and Nova
        // returned a cryptic "'networks' is a required property". It must now
        // throw a clear 400 before anything is sent.
        let descriptor = ResourceCatalog.phase1().descriptor("server")!
        do {
            _ = try await resolver.createPublic(
                vt,
                descriptor: descriptor,
                body: .object([
                    "name": .string("net-fail"),
                    "flavor": .string("m1.small"),
                    "image": .string("ubuntu-24.04"),
                    "networks": .array([.object(["net_id": .string("int-net")])]),
                ]),
                region: "RegionOne"
            )
            #expect(false, "Expected createPublic to throw for a bad networks[] entry")
        } catch let e as OpenStackError {
            #expect(e.status == 400, "Expected 400, got \(e.status)")
            #expect(e.message.contains("networks[0]"), "Error should name the offending entry, got: \(e.message)")
        }
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

    // Glance's `status` is read-only on PATCH and its status route is admin-only,
    // so the advertised actions report the gap instead of pretending to work.
    @Test("image actions deactivate/reactivate report feature_unavailable", .timeLimit(.minutes(2)))
    func imageStatusActionsUnsupported() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("image")!
        for action in ["deactivate", "reactivate"] {
            do {
                _ = try await resolver.actionPublic(vt, descriptor: descriptor, id: "img-1", action: action, params: [:], region: "RegionOne")
                Issue.record("\(action) must report feature_unavailable")
            } catch let error as OpenStackError {
                #expect(error.code == "feature_unavailable", "\(action): \(error.code ?? "nil") \(error.message)")
                #expect(error.status == 501)
                #expect(error.hint?.contains("glance image-\(action)") == true)
            }
        }
        // The image is untouched.
        let got = try await resolver.resolve(vt, descriptor: descriptor, idOrName: "img-1", region: "RegionOne")
        #expect(got.raw["status"]?.stringValue == "active")
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

    // MARK: - Hypervisor / compute_service admin actions

    @Test("hypervisor list supports the with_servers filter", .timeLimit(.minutes(2)))
    func hypervisorListWithServers() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("hypervisor")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: ["with_servers": "true"], limit: nil, marker: nil, region: "RegionOne")
        let items = result["items"]?.arrayValue ?? []
        #expect(items.count >= 1)
        let servers = items[0].objectValue?["servers"]?.arrayValue
        #expect(servers != nil, "with_servers=true must include the servers field")
    }

    @Test("hypervisor action statistics returns fleet totals", .timeLimit(.minutes(2)))
    func hypervisorStatisticsAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("hypervisor")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "1", action: "statistics", params: [:], region: "RegionOne")
        #expect(result["count"]?.intValue == 2)
        #expect(result["vcpus"]?.intValue == 64)
    }

    @Test("hypervisor action servers returns hosted instances", .timeLimit(.minutes(2)))
    func hypervisorServersAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("hypervisor")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "compute-01", action: "servers", params: [:], region: "RegionOne")
        #expect(result["action"]?.stringValue == "servers")
        let servers = result["servers"]?.arrayValue ?? []
        #expect(!servers.isEmpty)
        #expect(servers[0].objectValue?["uuid"] != nil)
    }

    @Test("compute_service disable then enable roundtrip via actions", .timeLimit(.minutes(2)))
    func computeServiceActionRoundtrip() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("compute_service")!
        let disabled = try await resolver.actionPublic(vt, descriptor: descriptor, id: "compute-01", action: "disable",
                                                       params: ["reason": .string("drain")], region: "RegionOne")
        #expect(disabled["status"]?.stringValue == "disabled")
        #expect(disabled["disabled_reason"]?.stringValue == "drain")

        let enabled = try await resolver.actionPublic(vt, descriptor: descriptor, id: "compute-01", action: "enable",
                                                      params: [:], region: "RegionOne")
        #expect(enabled["status"]?.stringValue == "enabled")
    }

    @Test("compute_service list filters by binary through the resolver", .timeLimit(.minutes(2)))
    func computeServiceListFilter() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("compute_service")!
        let result = try await resolver.listPublic(vt, descriptor: descriptor, filters: ["binary": "nova-conductor"], limit: nil, marker: nil, region: "RegionOne")
        let items = result["items"]?.arrayValue ?? []
        #expect(items.count == 1)
        #expect(items[0].objectValue?["host"]?.stringValue == "controller-01")
    }

    @Test("placement action candidates returns allocation requests", .timeLimit(.minutes(2)))
    func placementCandidatesAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("placement")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "rp-0001", action: "candidates",
                                                     params: ["resources": .string("VCPU:2,MEMORY_MB:1024")], region: "RegionOne")
        #expect(result["action"]?.stringValue == "candidates")
        let data = result["data"]?.objectValue
        let requests = data?["allocation_requests"]?.arrayValue ?? []
        #expect(requests.count == 2)
    }

    @Test("placement action candidates without resources returns 400", .timeLimit(.minutes(2)))
    func placementCandidatesMissingResources() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("placement")!
        do {
            _ = try await resolver.actionPublic(vt, descriptor: descriptor, id: "rp-0001", action: "candidates", params: [:], region: "RegionOne")
            Issue.record("Expected 400 for missing resources")
        } catch let error as OpenStackError {
            #expect(error.status == 400)
            #expect(error.message.contains("resources"))
        }
    }

    @Test("placement action allocations returns the consumer map", .timeLimit(.minutes(2)))
    func placementAllocationsAction() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let descriptor = ResourceCatalog.phase1().descriptor("placement")!
        let result = try await resolver.actionPublic(vt, descriptor: descriptor, id: "rp-0001", action: "allocations", params: [:], region: "RegionOne")
        #expect(result["action"]?.stringValue == "allocations")
        let data = result["data"]?.objectValue
        let allocations = data?["allocations"]?.objectValue
        #expect(allocations != nil && !allocations!.isEmpty)
    }

    // MARK: - Metric (Gnocchi) deepening

    @Test("metric list/get + archive_policy list route through the resolver", .timeLimit(.minutes(2)))
    func metricRoutes() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let catalog = ResourceCatalog.phase1()

        let list = try await resolver.listPublic(vt, descriptor: catalog.descriptor("metric")!, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        #expect(list["resource"]?.stringValue == "metric")
        #expect((list["items"]?.arrayValue ?? []).count == 2)

        let byResource = try await resolver.listPublic(vt, descriptor: catalog.descriptor("metric")!, filters: ["resource_id": "inst-1"], limit: 20, marker: nil, region: "RegionOne")
        #expect((byResource["items"]?.arrayValue ?? []).count == 2)
        let byPolicy = try await resolver.listPublic(vt, descriptor: catalog.descriptor("metric")!, filters: ["archive_policy": "low"], limit: 20, marker: nil, region: "RegionOne")
        let items = byPolicy["items"]?.arrayValue ?? []
        #expect(items.count == 1)
        #expect(items.first?.objectValue?["name"]?.stringValue == "cpu.utilization")

        let got = try await resolver.resolve(vt, descriptor: catalog.descriptor("metric")!, idOrName: "gnocchi-1", region: "RegionOne")
        #expect(got.raw["name"]?.stringValue == "cpu.utilization")

        let ap = try await resolver.listPublic(vt, descriptor: catalog.descriptor("archive_policy")!, filters: [:], limit: 20, marker: nil, region: "RegionOne")
        let policies = ap["items"]?.arrayValue ?? []
        #expect(policies.contains { $0.objectValue?["name"]?.stringValue == "ceilometer-low-rate" })

        let apGet = try await resolver.resolve(vt, descriptor: catalog.descriptor("archive_policy")!, idOrName: "low", region: "RegionOne")
        #expect(apGet.raw["aggregation_methods"]?.arrayValue?.contains(.string("mean")) == true)
    }

    @Test("metric measures/metrics actions + create/delete lifecycle through the resolver", .timeLimit(.minutes(2)))
    func metricActions() async throws {
        let (handle, vt, _, resolver, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let catalog = ResourceCatalog.phase1()
        let metric = catalog.descriptor("metric")!

        let raw = try await resolver.actionPublic(vt, descriptor: metric, id: "gnocchi-1", action: "measures", params: [:], region: "RegionOne")
        #expect(raw["action"]?.stringValue == "measures")
        #expect((raw["data"]?.arrayValue ?? []).count == 2)

        let agg = try await resolver.actionPublic(vt, descriptor: metric, id: "gnocchi-1", action: "measures",
            params: ["aggregation": .string("mean"), "granularity": .string("0:05:00")], region: "RegionOne")
        #expect((agg["data"]?.arrayValue ?? []).count == 1)

        // lone aggregation is rejected up front
        await #expect(throws: OpenStackError.self) {
            _ = try await resolver.actionPublic(vt, descriptor: metric, id: "gnocchi-1", action: "measures",
                params: ["aggregation": .string("mean")], region: "RegionOne")
        }

        let join = try await resolver.actionPublic(vt, descriptor: catalog.descriptor("resource_type")!, id: "instance", action: "metrics",
            params: ["resource_id": .string("inst-1")], region: "RegionOne")
        #expect(join["action"]?.stringValue == "metrics")
        #expect((join["data"]?.objectValue?["items"]?.arrayValue ?? []).count == 2)

        // create → delete
        let created = try await resolver.createPublic(vt, descriptor: metric, body: .object(["archive_policy": .string("medium"), "name": .string("resolver.metric")]), region: "RegionOne")
        let newID = created["id"]?.stringValue ?? ""
        #expect(!newID.isEmpty)
        _ = try await resolver.deletePublic(vt, descriptor: metric, id: newID, region: "RegionOne")
        await #expect(throws: OpenStackError.self) {
            _ = try await resolver.resolve(vt, descriptor: metric, idOrName: newID, region: "RegionOne")
        }

        // create without archive_policy → 400
        await #expect(throws: OpenStackError.self) {
            _ = try await resolver.createPublic(vt, descriptor: metric, body: .object(["name": .string("nope")]), region: "RegionOne")
        }
    }
}
