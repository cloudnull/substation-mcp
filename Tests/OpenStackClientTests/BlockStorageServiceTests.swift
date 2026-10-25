import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("BlockStorageService Tests")
struct BlockStorageServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, BlockStorageService, CloudEntry, Cache, Transport) {
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
        let transport = Transport(
            cloud: cloud,
            tokenSource: { tokenID },
            logger: logger
        )

        let blockStorage = BlockStorageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, blockStorage, cloud, cache, transport)
    }

    // MARK: - Volume decode (Rackspace lenient-decode regressions)

    @Test("Volume decodes minimal Rackspace Cinder index row (id/name/links only)", .timeLimit(.minutes(2)))
    func volumeDecodesMinimalIndexRow() throws {
        // Rackspace Cinder's volume LIST (index) rows carry only id/name/links —
        // no status/size. The strict decoder 500'd os_list volume on IAD3
        // (DecodingError at volumes[0]). Decode must fall back to ""/0.
        let json = """
        {"volumes":[{"id":"84879da4-d18e-4462-9398-dd489b987639","name":"vtest1","links":[{"rel":"self","href":"https://cinder/v3/p/volumes/84879da4"}]}]}
        """
        struct VolumeList: Decodable { let volumes: [Volume] }
        let decoded = try JSONDecoder().decode(VolumeList.self, from: json.data(using: .utf8)!)
        let v = decoded.volumes[0]
        #expect(v.id == "84879da4-d18e-4462-9398-dd489b987639")
        #expect(v.name == "vtest1")
        #expect(v.status == "")
        #expect(v.size == 0)
    }

    @Test("Volume decodes string bootable/multiattach (Rackspace Cinder)", .timeLimit(.minutes(2)))
    func volumeDecodesStringBools() throws {
        // Rackspace Cinder shows detail volume bootable as the string "true"
        // (bool in stock Cinder); the Bool-only decode 500'd with
        // DecodingError.typeMismatch (Expected Bool, found String) at
        // volumes[0].bootable.
        let json = """
        {"volume":{"id":"84879da4-d18e-4462-9398-dd489b987639","name":"vtest1","status":"in-use","size":20,"bootable":"true","multiattach":"false"}}
        """
        struct VolumeDetail: Decodable { let volume: Volume }
        let decoded = try JSONDecoder().decode(VolumeDetail.self, from: json.data(using: .utf8)!)
        let v = decoded.volume
        #expect(v.bootable == true)
        #expect(v.multiattach == false)
        #expect(v.status == "in-use")
        #expect(v.size == 20)
    }

    @Test("Volume still decodes standard bool bootable (stock Cinder)", .timeLimit(.minutes(2)))
    func volumeDecodesBoolBootable() throws {
        let json = """
        {"volume":{"id":"abc","name":"v","status":"available","size":1,"bootable":true,"multiattach":true}}
        """
        struct VolumeDetail: Decodable { let volume: Volume }
        let decoded = try JSONDecoder().decode(VolumeDetail.self, from: json.data(using: .utf8)!)
        let v = decoded.volume
        #expect(v.bootable == true)
        #expect(v.multiattach == true)
    }

    // MARK: - Volumes

    @Test("list volumes returns seeded volumes", .timeLimit(.minutes(2)))
    func listVolumes() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let volumes = try await region.listVolumes(vt)
        // 2 seeded proj-one volumes: seed-vol and the client-test vol-001.
        #expect(volumes.count == 2)
        let seed = volumes.first { $0.id == "seed-vol" }
        #expect(seed?.name == "seed-vol")
        #expect(seed?.status == "available")
        #expect(seed?.size == 10)
        #expect(volumes.contains { $0.id == "vol-001" && $0.status == "in-use" })
    }

    @Test("create volume from image", .timeLimit(.minutes(2)))
    func createVolumeFromImage() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(
            name: "from-image",
            size: 5,
            imageID: "img-1"
        )
        let vol = try await region.createVolume(vt, spec)
        #expect(vol.name == "from-image")
        #expect(vol.status == "creating")
        #expect(vol.size == 5)
        #expect(vol.imageID == "img-1")
    }

    @Test("create volume from source volume", .timeLimit(.minutes(2)))
    func createVolumeFromSource() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(
            name: "clone-vol",
            size: 10,
            sourceVolumeID: "seed-vol"
        )
        let vol = try await region.createVolume(vt, spec)
        #expect(vol.name == "clone-vol")
        #expect(vol.sourceVolumeID == "seed-vol")
    }

    @Test("get volume by id", .timeLimit(.minutes(2)))
    func getVolume() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let vol = try await region.getVolume(vt, id: "seed-vol")
        #expect(vol.id == "seed-vol")
        #expect(vol.name == "seed-vol")
    }

    @Test("get nonexistent volume throws 404", .timeLimit(.minutes(2)))
    func getVolumeNotFound() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        do {
            _ = try await region.getVolume(vt, id: "no-such-vol")
            Issue.record("Expected 404 error")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
            #expect(error.code == "itemNotFound")
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("delete volume", .timeLimit(.minutes(2)))
    func deleteVolume() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(name: "doomed", size: 1)
        let vol = try await region.createVolume(vt, spec)

        try await region.deleteVolume(vt, id: vol.id)
        do {
            _ = try await region.getVolume(vt, id: vol.id)
            Issue.record("Expected 404 after delete")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("extend volume grows size", .timeLimit(.minutes(2)))
    func extendVolume() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(name: "extend-me", size: 10)
        let vol = try await region.createVolume(vt, spec)

        let extended = try await region.extendVolume(vt, id: vol.id, size: 20)
        #expect(extended.size == 20)
        #expect(extended.id == vol.id)
    }

    @Test("retype volume changes volume type", .timeLimit(.minutes(2)))
    func retypeVolume() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(name: "retype-me", size: 10, volumeType: "lvmdriver-1")
        let vol = try await region.createVolume(vt, spec)
        #expect(vol.volumeType == "lvmdriver-1")

        let retyped = try await region.retypeVolume(vt, id: vol.id, volumeType: "lvmdriver-2")
        #expect(retyped.volumeType == "lvmdriver-2")
        #expect(retyped.id == vol.id)
    }

    @Test("set bootable", .timeLimit(.minutes(2)))
    func setBootable() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(name: "boot-me", size: 5)
        let vol = try await region.createVolume(vt, spec)

        let bootable = try await region.setBootable(vt, id: vol.id, bootable: true)
        #expect(bootable.bootable == true)
    }

    @Test("upload to image returns image id", .timeLimit(.minutes(2)))
    func uploadToImage() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateVolumeSpec(name: "to-image", size: 5)
        let vol = try await region.createVolume(vt, spec)

        let imageID = try await region.uploadToImage(vt, id: vol.id)
        #expect(!imageID.isEmpty)
        #expect(imageID.hasPrefix("img-"))
    }

    @Test("volume pagination via limit and marker", .timeLimit(.minutes(2)))
    func volumePagination() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        _ = try await region.createVolume(vt, CreateVolumeSpec(name: "page-vol-2", size: 1))
        _ = try await region.createVolume(vt, CreateVolumeSpec(name: "page-vol-3", size: 1))

        let page1 = try await region.listVolumes(vt, limit: 2)
        #expect(page1.count == 2)
        guard let last = page1.last else {
            Issue.record("No last item in page 1")
            return
        }

        let page2 = try await region.listVolumes(vt, limit: 2, marker: last.id)
        #expect(page2.count >= 1)
        let page1IDs = Set(page1.map { $0.id })
        for item in page2 {
            #expect(!page1IDs.contains(item.id))
        }
    }

    // MARK: - Volume Types

    @Test("list volume types", .timeLimit(.minutes(2)))
    func listVolumeTypes() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let types = try await region.listVolumeTypes(vt)
        #expect(types.count >= 1)
        #expect(types.contains(where: { $0.name == "lvmdriver-1" }))
    }

    @Test("volume types are listed from /{project_id}/types, not /volume-types", .timeLimit(.minutes(2)))
    func volumeTypesPathIsProjectScoped() async throws {
        // Cinder v3's collection is `types` under the project, NOT
        // `volume-types` (cinder/api/v3/router.py registers
        // `mapper.resource("type", "types", ...)`; api-ref
        // volumes-v3-types.inc `GET /v3/{project_id}/types`). The old path
        // matched no Cinder route, so `os_list volume_type` returned
        // `404 The resource could not be found.` on Rackspace IAD3 even though
        // the list is member-readable (policy
        // `volume_extension:type_get_all` = system_reader_or_project_reader).
        //
        // The fake now serves only the real routes, so each assertion below
        // fails if the path regresses: a wrong collection name or a dropped
        // project segment 404s, and a wrong project id is refused.
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let base = handle.url
        let tokenID = vt.token.id
        let projectID = vt.token.project.id
        #expect(!projectID.isEmpty, "token must carry a project id")

        func get(_ path: String) async -> Int {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "GET"
            req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
            req.setValue("volume 3.70", forHTTPHeaderField: "OpenStack-API-Version")
            // A transport failure is reported as a status the assertions will
            // reject, rather than thrown: this helper exists to compare status
            // codes, and a 0 makes the failing path obvious in the message.
            guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return 0 }
            return (resp as? HTTPURLResponse)?.statusCode ?? 0
        }

        // The correct, project-scoped collection route serves the list.
        #expect(await get("cinder/v3/\(projectID)/types") == 200)
        // The old client path is not a Cinder route at all.
        #expect(await get("cinder/v3/\(projectID)/volume-types") == 404)
        // Nor is the same collection without the project segment.
        #expect(await get("cinder/v3/types") == 404)
        #expect(await get("cinder/v3/volume-types") == 404)
        // A foreign project id in the path is refused even with a valid token.
        #expect(await get("cinder/v3/proj-two/types") == 403)

        // And the client itself goes through the working route.
        let region = blockStorage.region("RegionOne")
        do {
            let types = try await region.listVolumeTypes(vt)
            #expect(types.contains(where: { $0.name == "lvmdriver-1" }))
        } catch {
            Issue.record("Project-scoped /types list should succeed, got: \(error)")
        }
    }

    @Test("volume type decodes Cinder's brief list view", .timeLimit(.minutes(2)))
    func volumeTypeDecodesCinderListView() throws {
        // Verbatim shape of Cinder's `GET /v3/{project_id}/types` response
        // (api-ref samples/volume_type/volume-types-list-response.json). The
        // envelope key is `volume_types` (snake_case) — the client used to
        // decode `volumeTypes`, which would have thrown even on a 200.
        let json = """
        {"volume_types":[{"description":"Default Volume Type","extra_specs":{},"id":"7a56b996-b73f-4233-9f00-dd6a68b49b27","is_public":true,"name":"__DEFAULT__","os-volume-type-access:is_public":true,"qos_specs_id":null}]}
        """
        struct List: Decodable { let volume_types: [VolumeType] }
        let decoded = try JSONDecoder().decode(List.self, from: json.data(using: .utf8)!)
        let vt = decoded.volume_types[0]
        #expect(vt.id == "7a56b996-b73f-4233-9f00-dd6a68b49b27")
        #expect(vt.name == "__DEFAULT__")
        #expect(vt.description == "Default Volume Type")
        #expect(vt.isPublic == true)
        #expect(vt.extraSpecs == [:])
    }

    @Test("volume type create posts the snake_case volume_type envelope", .timeLimit(.minutes(2)))
    func createVolumeTypeBodyShape() throws {
        // Cinder's create-type body is `{"volume_type": {...}}`
        // (api-ref volumes-v3-types.inc). The camelCase `volumeType` envelope
        // fails Cinder's body validation.
        let spec = CreateVolumeTypeSpec(name: "fast-ssd", extra_specs: ["volume_backend_name": "ssd"])
        #expect(spec.body() == "{\"volume_type\":{\"name\":\"fast-ssd\",\"extra_specs\":{\"volume_backend_name\":\"ssd\"}}}")
    }

    @Test("create, get and delete volume type through /types", .timeLimit(.minutes(2)))
    func createDeleteVolumeType() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let type = try await region.createVolumeType(vt, CreateVolumeTypeSpec(name: "fast-ssd"))
        #expect(type.name == "fast-ssd")

        let fetched = try await region.getVolumeType(vt, id: type.id)
        #expect(fetched.id == type.id)

        try await region.deleteVolumeType(vt, id: type.id)
        do {
            _ = try await region.getVolumeType(vt, id: type.id)
            Issue.record("Expected 404 after delete")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Snapshots

    @Test("create and list snapshots", .timeLimit(.minutes(2)))
    func createListSnapshots() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateSnapshotSpec(volumeID: "seed-vol", name: "snap-1")
        let snap = try await region.createSnapshot(vt, spec)
        #expect(snap.name == "snap-1")
        #expect(snap.volumeID == "seed-vol")

        let snaps = try await region.listSnapshots(vt)
        #expect(snaps.contains(where: { $0.id == snap.id }))
    }

    @Test("delete snapshot", .timeLimit(.minutes(2)))
    func deleteSnapshot() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateSnapshotSpec(volumeID: "seed-vol", name: "snap-doomed")
        let snap = try await region.createSnapshot(vt, spec)

        try await region.deleteSnapshot(vt, id: snap.id)
        do {
            _ = try await region.getSnapshot(vt, id: snap.id)
            Issue.record("Expected 404 after delete")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Backups

    @Test("create and list backups", .timeLimit(.minutes(2)))
    func createListBackups() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateBackupSpec(volumeID: "seed-vol", name: "backup-1")
        let backup = try await region.createBackup(vt, spec)
        #expect(backup.name == "backup-1")
        #expect(backup.volumeID == "seed-vol")

        let backups = try await region.listBackups(vt)
        #expect(backups.contains(where: { $0.id == backup.id }))
    }

    @Test("backup restore creates new volume with backup marker", .timeLimit(.minutes(2)))
    func backupRestore() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateBackupSpec(volumeID: "seed-vol", name: "backup-for-restore")
        let backup = try await region.createBackup(vt, spec)

        let restored = try await region.restoreBackup(vt, id: backup.id)
        #expect(restored.id != backup.volumeID)
        #expect(restored.metadata?["os-extended-vol-backup:backup_id"] == backup.id)
    }

    @Test("delete backup", .timeLimit(.minutes(2)))
    func deleteBackup() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let spec = CreateBackupSpec(volumeID: "seed-vol", name: "backup-doomed")
        let backup = try await region.createBackup(vt, spec)

        try await region.deleteBackup(vt, id: backup.id)
        do {
            _ = try await region.getBackup(vt, id: backup.id)
            Issue.record("Expected 404 after delete")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    // MARK: - Quotas

    @Test("get volume quotas", .timeLimit(.minutes(2)))
    func getQuotas() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        let quota = try await region.getQuota(vt)
        #expect(quota.volumes == 10)
        #expect(quota.gigabytes == 1000)
        #expect(quota.snapshots == 10)
    }

    // MARK: - API Version Header

    @Test("OpenStack-API-Version header is sent", .timeLimit(.minutes(2)))
    func apiVersionHeader() async throws {
        let (handle, vt, blockStorage, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = blockStorage.region("RegionOne")
        // The fake rejects requests without the header; if this passes, the header is present
        let volumes = try await region.listVolumes(vt)
        #expect(volumes.count >= 1)
    }
}
