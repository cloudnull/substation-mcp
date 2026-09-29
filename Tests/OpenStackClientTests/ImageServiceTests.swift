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
        #expect(imgs.count == 1)
        #expect(imgs.first?.name == "ubuntu-24.04")
        #expect(imgs.first?.status == "active")
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

    @Test("failed web-download import sets image to killed", .timeLimit(.minutes(2)))
    func failedImportKillsImage() async throws {
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

        let killed = try await region.getImage(vt, id: img.id)
        #expect(killed.status == "killed")
        #expect(killed.statusReason?.contains("not found") == true)
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

    @Test("deactivate and reactivate", .timeLimit(.minutes(2)))
    func deactivateReactivate() async throws {
        let (handle, vt, images, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = images.region("RegionOne")
        let spec = CreateImageSpec(name: "deact-me", diskFormat: "raw", containerFormat: "bare")
        let img = try await region.createImage(vt, spec)

        try await region.deactivate(vt, id: img.id)
        let deactivated = try await region.getImage(vt, id: img.id)
        #expect(deactivated.status == "deactivated")

        try await region.reactivate(vt, id: img.id)
        let reactivated = try await region.getImage(vt, id: img.id)
        #expect(reactivated.status == "active")
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
}
