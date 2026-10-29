import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("ImageService Tests")
struct ImageServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, ImageService, CloudEntry, Cache, Transport) {
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

        let images = ImageService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, images, cloud, cache, transport)
    }

    // MARK: - Images

    @Test("list images returns seeded images", .timeLimit(.minutes(2)))
    func listImages() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let imgs = try await region.listImages(vt)
        // Seed: img-1 (own project) + Debian-13 + two img-ambig-* rows (other
        // project, public). The list is visibility-filtered, not project-filtered.
        #expect(imgs.count == 4)
        #expect(imgs.contains { $0.name == "ubuntu-24.04" && $0.status == "active" })
    }

    @Test("create image and upload via web-download", .timeLimit(.minutes(2)))
    func createImageWebDownload() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(
            name: "imported-image",
            diskFormat: "qcow2",
            containerFormat: "bare",
            visibility: "private"
        )
        let img = try await region.createImage(vt, spec)
        #expect(img.name == "imported-image")
        #expect(img.status == "queued")

        // Upload via web-download from the fake's static file route
        let importURL = handle.url.appendingPathComponent("static/image.qcow2")
        try await region.importImage(vt, id: img.id, mechanism: "web-download", uri: importURL.absoluteString)

        let active = try await region.getImage(vt, id: img.id)
        #expect(active.status == "active")
        #expect(active.size > 0)
    }

    @Test("create image and upload via base64 payload", .timeLimit(.minutes(2)))
    func createImageBase64() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(
            name: "small-image",
            diskFormat: "raw",
            containerFormat: "bare",
            visibility: "private"
        )
        let img = try await region.createImage(vt, spec)

        // Small base64 payload: "hello image data"
        let payload = Data("hello image data".utf8)
        let base64 = payload.base64EncodedString()
        try await region.uploadImage(vt, id: img.id, data: base64, diskFormat: "raw")

        let active = try await region.getImage(vt, id: img.id)
        #expect(active.status == "active")
        #expect(active.size == payload.count)
    }

    @Test("a failed web-download import leaves the image queued, not killed", .timeLimit(.minutes(2)))
    func failedImportLeavesImageQueued() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(
            name: "bad-import",
            diskFormat: "qcow2",
            containerFormat: "bare",
            visibility: "private"
        )
        let img = try await region.createImage(vt, spec)

        // Point at a URL that doesn't exist on the fake
        let badURL = handle.url.appendingPathComponent("static/nonexistent.qcow2")
        try await region.importImage(vt, id: img.id, mechanism: "web-download", uri: badURL.absoluteString)

        // Live-verified on Genestack 2024.1: a failed web-download records the
        // failure and leaves the image `queued` — it never becomes `killed`.
        let stuck = try await region.getImage(vt, id: img.id)
        #expect(stuck.status == "queued")
        #expect(stuck.statusReason?.contains("Unable to retrieve") == true)
    }

    @Test("get image by id", .timeLimit(.minutes(2)))
    func getImage() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let img = try await region.getImage(vt, id: "img-1")
        #expect(img.id == "img-1")
        #expect(img.name == "ubuntu-24.04")
    }

    @Test("get nonexistent image throws 404", .timeLimit(.minutes(2)))
    func getImageNotFound() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        do {
            _ = try await region.getImage(vt, id: "no-such-img")
            Issue.record("Expected 404 error")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("update image name and visibility", .timeLimit(.minutes(2)))
    func updateImage() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(name: "updatable", diskFormat: "raw", containerFormat: "bare")
        let img = try await region.createImage(vt, spec)

        let updated = try await region.updateImage(vt, id: img.id, name: "renamed", visibility: "shared")
        #expect(updated.name == "renamed")
        #expect(updated.visibility == "shared")
    }

    @Test("tags round-trip", .timeLimit(.minutes(2)))
    func tagsRoundTrip() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(name: "tagged", diskFormat: "raw", containerFormat: "bare")
        let img = try await region.createImage(vt, spec)

        try await region.addTags(vt, id: img.id, tags: ["os:ubuntu", "env:dev"])
        let withTags = try await region.getImage(vt, id: img.id)
        #expect(withTags.tags.contains("os:ubuntu"))
        #expect(withTags.tags.contains("env:dev"))

        try await region.removeTag(vt, id: img.id, tag: "os:ubuntu")
        let withoutTag = try await region.getImage(vt, id: img.id)
        #expect(!withoutTag.tags.contains("os:ubuntu"))
        #expect(withoutTag.tags.contains("env:dev"))
    }

    /// A tag is caller data: an unescaped `"` in one corrupts the PUT body, so
    /// Glance stores a mangled tag or rejects the request outright.
    @Test("a tag containing quotes and backslashes round-trips", .timeLimit(.minutes(2)))
    func tagWithJSONMetacharacters() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let img = try await region.createImage(
            vt, CreateImageSpec(name: "tricky-tags", diskFormat: "raw", containerFormat: "bare"))

        let nasty = "quote\"back\\slash"
        try await region.addTags(vt, id: img.id, tags: [nasty, "plain"])
        let withTags = try await region.getImage(vt, id: img.id)
        #expect(withTags.tags.contains(nasty),
                "an unescaped tag body corrupts the tag: \(withTags.tags)")

        try await region.removeTag(vt, id: img.id, tag: "plain")
        let withoutTag = try await region.getImage(vt, id: img.id)
        #expect(!withoutTag.tags.contains("plain"))
        #expect(withoutTag.tags.contains(nasty))
    }

    @Test("protect and unprotect", .timeLimit(.minutes(2)))
    func protectUnprotect() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(name: "protect-me", diskFormat: "raw", containerFormat: "bare")
        let img = try await region.createImage(vt, spec)

        try await region.protect(vt, id: img.id)
        let protected = try await region.getImage(vt, id: img.id)
        #expect(protected.protected == true)

        try await region.unprotect(vt, id: img.id)
        let unprotected = try await region.getImage(vt, id: img.id)
        #expect(unprotected.protected == false)
    }

    @Test("delete image", .timeLimit(.minutes(2)))
    func deleteImage() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(name: "doomed-img", diskFormat: "raw", containerFormat: "bare")
        let img = try await region.createImage(vt, spec)

        try await region.deleteImage(vt, id: img.id)
        do {
            _ = try await region.getImage(vt, id: img.id)
            Issue.record("Expected 404 after delete")
        } catch let error as OpenStackError {
            #expect(error.status == 404)
        } catch {
            Issue.record("Expected OpenStackError, got \(error)")
        }
    }

    @Test("image pagination via limit and marker", .timeLimit(.minutes(2)))
    func imagePagination() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        _ = try await region.createImage(vt, CreateImageSpec(name: "page-img-2", diskFormat: "raw", containerFormat: "bare"))
        _ = try await region.createImage(vt, CreateImageSpec(name: "page-img-3", diskFormat: "raw", containerFormat: "bare"))

        let page1 = try await region.listImages(vt, limit: 2)
        #expect(page1.count == 2)
        guard let last = page1.last else {
            Issue.record("No last item in page 1")
            return
        }

        let page2 = try await region.listImages(vt, limit: 2, marker: last.id)
        #expect(page2.count >= 1)
        let page1IDs = Set(page1.map { $0.id })
        for item in page2 {
            #expect(!page1IDs.contains(item.id))
        }
    }

    // Regression test for the live-Glance 415: updateImage's PATCH must carry
    // application/openstack-images-v2.1-json-patch, not the Transport default of
    // application/json. Live Glance (Genestack 2024.1) 415s anything else, so a
    // successful update whose response reflects the change proves the media type
    // was right.
    @Test("updateImage PATCH carries the json-patch media type", .timeLimit(.minutes(2)))
    func updateImageGlanceMediaType() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let updated = try await region.updateImage(vt, id: "img-1", name: "renamed-glance")
        #expect(updated.name == "renamed-glance")

        let fetched = try await region.getImage(vt, id: "img-1")
        #expect(fetched.name == "renamed-glance")
    }

    // MARK: - Issue #4: Glance's flat request/response schema
    //
    // Glance v2 is the only service here with FLAT bodies: Nova and Cinder wrap in
    // {"server": …}/{"volume": …}, Glance takes attributes at the top level and
    // carries custom properties as top-level string keys (its schema's
    // additionalProperties is {"type": "string"}). A wrapped body is therefore a
    // hard 400, and a wrapped REPLY cannot be decoded. These tests pin both
    // directions plus the attribute round-trip, because the fake previously
    // accepted either envelope and could not see the difference.

    /// Raw request to the fake Glance, bypassing the client. The transport
    /// normalises a non-2xx into a thrown error, so asserting on a *rejection*
    /// needs the status code and body directly.
    private func rawGlance(
        _ handle: FakeHandle, tokenID: String, method: String, path: String, body: String,
        contentType: String = "application/json"
    ) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: handle.url.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(tokenID, forHTTPHeaderField: "X-Auth-Token")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, String(decoding: data, as: UTF8.self))
    }

    @Test("create sends a FLAT body and decodes a FLAT reply", .timeLimit(.minutes(2)))
    func createUsesFlatSchema() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // The client's own create must be accepted by a schema-strict Glance and
        // must round-trip the non-default attributes, not just the name.
        let spec = CreateImageSpec(
            name: "cirros-0.6.2", diskFormat: "qcow2", containerFormat: "bare",
            visibility: "shared", minRAM: 256, properties: ["os_distro": "cirros"]
        )
        let img = try await images.region("RegionOne").createImage(vt, spec)
        #expect(img.diskFormat == "qcow2")
        #expect(img.containerFormat == "bare")
        #expect(img.visibility == "shared")
        #expect(img.minRAM == 256)
        #expect(img.properties["os_distro"] == "cirros")
    }

    @Test("a wrapped create body is rejected, exactly like live Glance", .timeLimit(.minutes(2)))
    func wrappedCreateBodyRejected() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let tokenID = vt.token.id

        let wrapped = try await rawGlance(handle, tokenID: tokenID, method: "POST", path: "glance/v2/images",
                                          body: #"{"image":{"name":"wrapped","disk_format":"raw","container_format":"bare"}}"#)
        #expect(wrapped.status == 400, "A {\"image\": {...}} body must be a 400, got \(wrapped.status): \(wrapped.body)")
        #expect(wrapped.body.contains("is not of type 'string'"),
                "The rejection must be the schema error live Glance produces, got: \(wrapped.body)")

        // The same body, flat, is accepted — proving the 400 came from the
        // envelope and not from the attributes.
        let flat = try await rawGlance(handle, tokenID: tokenID, method: "POST", path: "glance/v2/images",
                                       body: #"{"name":"flat","disk_format":"qcow2","container_format":"bare"}"#)
        #expect(flat.status == 201, "A flat create body must be accepted: \(flat.status) \(flat.body)")
        // And the reply is the bare image object: no "image" key to unwrap.
        let decoded = try JSONSerialization.jsonObject(with: Data(flat.body.utf8)) as? [String: Any]
        #expect(decoded?["image"] == nil, "Glance replies with the image unwrapped")
        #expect(decoded?["id"] != nil)
    }

    @Test("custom properties travel as top-level string keys on create", .timeLimit(.minutes(2)))
    func customPropertiesAreTopLevelStrings() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let tokenID = vt.token.id

        // Nesting them under `properties` is illegal on POST /images: `properties`
        // would itself be a non-string custom property.
        let nested = try await rawGlance(handle, tokenID: tokenID, method: "POST", path: "glance/v2/images",
                                         body: #"{"name":"nested","disk_format":"raw","container_format":"bare","properties":{"os_distro":"cirros"}}"#)
        #expect(nested.status == 400, "A nested properties object must be rejected on create, got \(nested.status): \(nested.body)")

        let flat = try await rawGlance(handle, tokenID: tokenID, method: "POST", path: "glance/v2/images",
                                       body: #"{"name":"flatprops","disk_format":"raw","container_format":"bare","os_distro":"cirros"}"#)
        #expect(flat.status == 201, "A top-level custom property must be accepted: \(flat.status) \(flat.body)")
        let decoded = try JSONSerialization.jsonObject(with: Data(flat.body.utf8)) as? [String: Any]
        // Glance replies with the property as a TOP-LEVEL string key and no
        // `properties` object at all — that is the shape the client decoder has
        // to fold, and the shape the fake has to send.
        #expect(decoded?["os_distro"] as? String == "cirros",
                "the reply must carry the property at the top level: \(flat.body)")
        #expect(decoded?["properties"] == nil,
                "Glance never echoes a nested properties object: \(flat.body)")
    }

    @Test("a non-string custom property is rejected", .timeLimit(.minutes(2)))
    func nonStringCustomPropertyRejected() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let bad = try await rawGlance(handle, tokenID: vt.token.id, method: "POST", path: "glance/v2/images",
                                      body: #"{"name":"badprop","disk_format":"raw","container_format":"bare","os_distro":{"nested":"object"}}"#)
        #expect(bad.status == 400, "additionalProperties is string-typed; an object value must fail: \(bad.status) \(bad.body)")
    }

    // PATCH is the one place Glance is NOT a flat attribute map: the body is an
    // RFC 6902 operation array under the v2.1 json-patch media type. Live Glance
    // 415s any other media type and 400s a flat map even with the right one, so
    // the fake enforces both, and `status` is a read-only attribute (403).
    @Test("update sends a JSON-PATCH body and decodes a FLAT reply", .timeLimit(.minutes(2)))
    func updateUsesPatchDocument() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")
        let img = try await region.createImage(vt, CreateImageSpec(name: "patch-me", diskFormat: "raw", containerFormat: "bare"))

        // Every advertised attribute must reach Glance through ONE PATCH and come
        // back in the (unwrapped) reply.
        let updated = try await region.updateImage(
            vt, id: img.id, name: "patched", visibility: "public",
            protected: true, properties: ["os_distro": "fedora"], minRAM: 512,
            tags: ["env:prod", "os:fedora"]
        )
        #expect(updated.name == "patched")
        #expect(updated.visibility == "public")
        #expect(updated.protected == true)
        #expect(updated.minRAM == 512)
        #expect(updated.properties["os_distro"] == "fedora")
        #expect(updated.tags.contains("env:prod"))

        let fetched = try await region.getImage(vt, id: img.id)
        #expect(fetched.visibility == "public")
        #expect(fetched.minRAM == 512)
        #expect(fetched.properties["os_distro"] == "fedora")
        #expect(fetched.tags.sorted() == ["env:prod", "os:fedora"])
    }

    @Test("PATCH with the wrong media type is a 415", .timeLimit(.minutes(2)))
    func patchWithWrongMediaTypeRejected() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // Plain application/json — the shape the client used to send.
        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"[{"op":"replace","path":"/name","value":"renamed-415"}]"#
        )
        #expect(rejected.status == 415, "Glance refuses a non-json-patch media type, got \(rejected.status): \(rejected.body)")
        let fetched = try await images.region("RegionOne").getImage(vt, id: "img-1")
        #expect(fetched.name != "renamed-415", "a rejected PATCH must not change the image")
    }

    @Test("a flat PATCH body is rejected even with the json-patch media type", .timeLimit(.minutes(2)))
    func flatPatchBodyRejected() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"{"name":"flat-patch"}"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(rejected.status == 400, "A flat attribute map is not an operation array, got \(rejected.status): \(rejected.body)")
        let fetched = try await images.region("RegionOne").getImage(vt, id: "img-1")
        #expect(fetched.name != "flat-patch")
    }

    @Test("patching status is refused as read-only", .timeLimit(.minutes(2)))
    func patchStatusRejected() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"[{"op":"replace","path":"/status","value":"deactivated"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(rejected.status == 403, "status is read-only on PATCH, got \(rejected.status): \(rejected.body)")
        #expect(rejected.body.contains("read-only"))
        let fetched = try await images.region("RegionOne").getImage(vt, id: "img-1")
        #expect(fetched.status == "active", "a refused status patch must leave the image active")
    }

    // Glance's PATCH path does more than check the media type and the array
    // shape: it validates the operation name and the pointer, refuses
    // read-only/reserved attributes, requires `value` on add/replace, and looks
    // the property up on the image (`replace`/`remove` of an absent custom
    // property is 409; `remove` of a base attribute is 403). All of that is
    // `glance/api/v2/images.py`; the fake holds it so a live cloud is not needed
    // to catch a client that gets it wrong.
    @Test("a PATCH operation Glance does not implement is refused", .timeLimit(.minutes(2)))
    func unsupportedPatchOperationRejected() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"[{"op":"move","from":"/name","path":"/visibility"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(rejected.status == 400, "only add/remove/replace exist in Glance's PATCH, got \(rejected.status): \(rejected.body)")
        #expect(rejected.body.contains("Invalid operation"), "got: \(rejected.body)")
        let fetched = try await images.region("RegionOne").getImage(vt, id: "img-1")
        #expect(fetched.visibility == "public", "a refused operation must change nothing")
    }

    @Test("a malformed JSON pointer is refused", .timeLimit(.minutes(2)))
    func malformedPointerRejected() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        // No leading slash, a trailing slash, and a bad ~ escape: all three are
        // Glance's `_validate_json_pointer` 400s.
        for body in [
            #"[{"op":"add","path":"os_distro","value":"cirros"}]"#,
            #"[{"op":"add","path":"/os_distro/","value":"cirros"}]"#,
            #"[{"op":"add","path":"/os~2distro","value":"cirros"}]"#
        ] {
            let rejected = try await rawGlance(
                handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
                body: body, contentType: "application/openstack-images-v2.1-json-patch"
            )
            #expect(rejected.status == 400, "pointer \(body) must be refused, got \(rejected.status): \(rejected.body)")
        }
    }

    @Test("an add/replace operation without a value member is refused", .timeLimit(.minutes(2)))
    func patchValueMemberRequired() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"[{"op":"add","path":"/os_distro"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(rejected.status == 400, "RFC 6902 puts no value on `remove` but does on `add`, got \(rejected.status): \(rejected.body)")
        #expect(rejected.body.contains("value"), "got: \(rejected.body)")
    }

    @Test("replacing or removing a property the image does not carry is 409", .timeLimit(.minutes(2)))
    func patchAbsentPropertyConflicts() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")
        let img = try await region.createImage(vt, CreateImageSpec(name: "no-props", diskFormat: "raw", containerFormat: "bare"))

        let badReplace = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/\(img.id)",
            body: #"[{"op":"replace","path":"/os_distro","value":"cirros"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(badReplace.status == 409, "replace will not invent a property, got \(badReplace.status)")
        #expect(badReplace.body.contains("does not exist"))

        let badRemove = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/\(img.id)",
            body: #"[{"op":"remove","path":"/os_distro"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(badRemove.status == 409, "removing an absent property is a conflict, got \(badRemove.status)")
    }

    @Test("removing a base image attribute is refused", .timeLimit(.minutes(2)))
    func removeBaseAttributeRejected() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let rejected = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: #"[{"op":"remove","path":"/min_ram"}]"#,
            contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(rejected.status == 403, "a base attribute may not be removed, got \(rejected.status): \(rejected.body)")
        #expect(rejected.body.contains("may not be removed"), "got: \(rejected.body)")
    }

    @Test("a reserved PATCH attribute is refused", .timeLimit(.minutes(2)))
    func reservedPatchAttributeRejected() async throws {
        let (handle, vt, _, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        for path in ["/deleted", "/os_glance_managed"] {
            let rejected = try await rawGlance(
                handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
                body: #"[{"op":"add","path":"\#(path)","value":"x"}]"#,
                contentType: "application/openstack-images-v2.1-json-patch"
            )
            #expect(rejected.status == 403, "\(path) is reserved, got \(rejected.status): \(rejected.body)")
        }
    }

    @Test("an empty PATCH document is a no-op", .timeLimit(.minutes(2)))
    func emptyPatchDocumentIsNoOp() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")
        let before = try await region.getImage(vt, id: "img-1")

        let ok = try await rawGlance(
            handle, tokenID: vt.token.id, method: "PATCH", path: "glance/v2/images/img-1",
            body: "[]", contentType: "application/openstack-images-v2.1-json-patch"
        )
        #expect(ok.status == 200, "Glance accepts an empty document, got \(ok.status): \(ok.body)")
        let after = try await region.getImage(vt, id: "img-1")
        #expect(after.name == before.name && after.updated == before.updated,
                "an empty document must not touch the image")
    }

    /// `min_disk` is what gates scheduling onto a store with room for the image,
    /// and Glance lets it be patched (`_readonly_properties` does not list it).
    /// It was neither forwarded nor decoded, so every image was created with a
    /// 0 GB floor.
    @Test("min_disk round-trips through create and update", .timeLimit(.minutes(2)))
    func minDiskRoundTrips() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")

        let created = try await region.createImage(
            vt, CreateImageSpec(name: "needs-disk", diskFormat: "qcow2", containerFormat: "bare", minDisk: 20)
        )
        #expect(created.minDisk == 20, "create must forward min_disk, got \(created.minDisk)")

        let updated = try await region.updateImage(vt, id: created.id, minDisk: 40)
        #expect(updated.minDisk == 40, "PATCH must carry min_disk, got \(updated.minDisk)")
        let fetched = try await region.getImage(vt, id: created.id)
        #expect(fetched.minDisk == 40, "min_disk must survive the reply, got \(fetched.minDisk)")
        #expect(fetched.minRAM == created.minRAM, "patching min_disk must not disturb min_ram")
    }

    /// A custom property can only be cleared with a `remove` operation, so
    /// `properties[key] == nil` has to produce one. Without it a caller can add
    /// a property but never take it away, and Glance 409s a `replace` of an
    /// absent key, so `add` cannot stand in for it either.
    @Test("a nil property value removes the custom property", .timeLimit(.minutes(2)))
    func nilPropertyValueRemovesIt() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")
        let img = try await region.createImage(
            vt, CreateImageSpec(name: "removable", diskFormat: "raw", containerFormat: "bare",
                                properties: ["os_distro": "cirros", "hw_rng": "on"])
        )
        #expect(img.properties["os_distro"] == "cirros")

        let after = try await region.updateImage(vt, id: img.id, properties: ["os_distro": nil])
        #expect(after.properties["os_distro"] == nil, "the property must be gone: \(after.properties)")
        #expect(after.properties["hw_rng"] == "on", "removing one property must not disturb another")
        let fetched = try await region.getImage(vt, id: img.id)
        #expect(fetched.properties == ["hw_rng": "on"], "removal must persist: \(fetched.properties)")
    }

    @Test("an image name containing quotes and backslashes creates successfully", .timeLimit(.minutes(2)))
    func escapingInImageName() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let tricky = "he said \"hi\" \\ back\nnewline"
        let img = try await images.region("RegionOne").createImage(
            vt, CreateImageSpec(name: tricky, diskFormat: "raw", containerFormat: "bare",
                                properties: ["note.key": "a\"b"])
        )
        #expect(img.name == tricky, "An unescaped name would corrupt the body; got \(img.name.debugDescription)")
        #expect(img.properties["note.key"] == "a\"b")
    }

    @Test("import sends the {method:{name,uri}} body Glance actually parses", .timeLimit(.minutes(2)))
    func importUsesMethodObjectBody() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        let region = images.region("RegionOne")
        let img = try await region.createImage(vt, CreateImageSpec(name: "import-flat", diskFormat: "qcow2", containerFormat: "bare"))

        let importURL = handle.url.appendingPathComponent("static/image.qcow2")
        try await region.importImage(vt, id: img.id, mechanism: "web-download", uri: importURL.absoluteString)
        let active = try await region.getImage(vt, id: img.id)
        #expect(active.status == "active")

        // The FLAT {"method":"web-download","uri":…} form must be rejected: it
        // is what we shipped, and live Glance crashes on it with a 500
        // (_validate_import_body does method['name'] on a String). The fake now
        // refuses it so the wrong client body can never pass the suite again.
        let flat = try await rawGlance(handle, tokenID: vt.token.id, method: "POST", path: "glance/v2/images/\(img.id)/import",
                                       body: #"{"method":"web-download","uri":"\#(importURL.absoluteString)"}"#)
        #expect(flat.status == 400, "a flat method string must be rejected, got \(flat.status): \(flat.body)")

        // A wrapped import body must not be honoured either.
        let rejected = try await rawGlance(handle, tokenID: vt.token.id, method: "POST", path: "glance/v2/images/\(img.id)/import",
                                           body: #"{"import":{"method":"web-download","uri":"\#(importURL.absoluteString)"}}"#)
        #expect(rejected.status == 400, "A wrapped import body must be rejected, got \(rejected.status): \(rejected.body)")
    }
}
