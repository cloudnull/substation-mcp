import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenStackClient
import FakeOpenStack
import Logging

@Suite("KeyManagerService Tests", .timeLimit(.minutes(2)))
struct KeyManagerServiceTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, KeyManagerService, Cache, Transport) {
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
        let svc = KeyManagerService(cloud: cloud, transport: transport, cache: cache, logger: logger)
        return (handle, vt, svc, cache, transport)
    }

    // MARK: - Secrets

    @Test("list secrets returns the seeded secret")
    func listSecrets() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let secs = try await region.listSecrets(vt)
        #expect(secs.count == 1)
        #expect(secs.first?.id == "sec-1")
        #expect(secs.first?.status == "active")
    }

    @Test("get secret by id")
    func getSecret() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let s = try await region.getSecret(vt, id: "sec-1")
        #expect(s.id == "sec-1")
        #expect(s.type == "opaque")
    }

    @Test("get missing secret 404s")
    func getSecret404() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        do {
            _ = try await region.getSecret(vt, id: "nope")
            #expect(false, "should have thrown 404")
        } catch let e as OpenStackError {
            #expect(e.status == 404)
        }
    }

    @Test("create then delete a secret")
    func createDeleteSecret() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let spec = CreateSecretSpec(name: "new-secret", type: "opaque", secret: "c2VjcmV0", visibility: "private")
        let created = try await region.createSecret(vt, spec)
        #expect(!created.id.isEmpty)
        #expect(created.status == "active")
        #expect(created.name == "new-secret")

        let secs = try await region.listSecrets(vt)
        #expect(secs.contains { $0.id == created.id })

        try await region.deleteSecret(vt, id: created.id)
        let after = try await region.listSecrets(vt)
        #expect(!after.contains { $0.id == created.id })
    }

    @Test("get secret payload returns the stored value")
    func getSecretPayload() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let payload = try await region.getSecretPayload(vt, id: "sec-1")
        #expect(payload.payload == "ZmFrZS1zZWNyZXQtbWF0ZXJpYWw=")
        #expect(payload.payloadContentType == "text/plain")
    }

    @Test("ISSUE 3: decodes live Barbican secret items (uuid/secret_type/bit_length)")
    func decodeRealBarbicanSecret() throws {
        // Real Rackspace/barbican v1 returns items with `uuid` (no `id` key),
        // `secret_type` (not `type`) and `bit_length` (not `bit_size`). Before the
        // lenient decoder, this hard-threw on the missing `id` and surfaced as an
        // opaque MCP 500 ("The data is missing.") out of os_list(secret).
        let json = """
        {
          "uuid": "abc-123-def",
          "name": "live-secret",
          "secret_type": "symmetric_key",
          "algorithm": "AES",
          "mode": "CBC",
          "bit_length": 256,
          "status": "active",
          "content_types": ["application/octet-stream"],
          "created_at": "2026-01-01T00:00:00.000Z",
          "updated_at": "2026-01-02T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Secret.self, from: json)
        #expect(s.id == "abc-123-def")
        #expect(s.name == "live-secret")
        #expect(s.type == "symmetric_key")
        #expect(s.bit_size == 256)
        #expect(s.status == "active")
    }

    @Test("ISSUE 3: decodes the EXACT captured Rackspace IAD3 v1 /secrets item")
    func decodeCapturedLiveRackspaceSecret() throws {
        // Verbatim shape from GET https://barbican.api.iad3.rackspacecloud.com/v1/secrets
        // on 2026-10-12. Note the REAL production differences from the openstacksdk
        // docs: no id/uuid key (identifier lives in secret_ref's URL tail), and
        // timestamps are `created`/`updated` (not *_at). This is the ground-truth
        // regression for the opaque-500 os_list(secret) defect.
        let json = """
        {
          "created": "2026-10-12T03:39:21",
          "updated": "2026-10-12T03:39:21",
          "status": "ACTIVE",
          "name": null,
          "secret_type": "symmetric",
          "expiration": null,
          "algorithm": "aes",
          "bit_length": 256,
          "mode": null,
          "creator_id": "fdff75fff6ace79f499bd2275e96b1ba9fc5153ed8ba4570fbeca1fc67afab12",
          "content_types": {"default": "application/octet-stream"},
          "secret_ref": "http://barbican-api.openstack.svc.cluster.local:9311/v1/secrets/2e9ca375-aa56-4aa6-990b-313819b5cf72"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Secret.self, from: json)
        #expect(s.id == "2e9ca375-aa56-4aa6-990b-313819b5cf72", "id must come from secret_ref URL tail, got '\(s.id)'")
        #expect(s.type == "symmetric")
        #expect(s.bit_size == 256)
        #expect(s.status == "ACTIVE")
        #expect(s.algorithm == "aes")
        #expect(s.created_at == "2026-10-12T03:39:21", "live `created` maps to created_at")
        #expect(s.updated_at == "2026-10-12T03:39:21", "live `updated` maps to updated_at")
    }

    @Test("ISSUE 3: fake-shaped secret (id/type/bit_size) still decodes")
    func decodeFakeShapedSecret() throws {
        // The FakeOpenStack rig emits the canonical shape; decoding must keep
        // working alongside the real-Barbican aliases (dual-accept, not swap).
        let json = """
        {"id":"sec-1","name":"fake","type":"opaque","status":"active","bit_size":128}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Secret.self, from: json)
        #expect(s.id == "sec-1")
        #expect(s.type == "opaque")
        #expect(s.bit_size == 128)
    }

    @Test("ISSUE 3: decodes live Barbican container by uuid")
    func decodeRealBarbicanContainer() throws {
        let json = """
        {"uuid":"ctn-1","name":"live-ctn","secret_ref":"sec-x"}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(SecretContainer.self, from: json)
        #expect(c.id == "ctn-1")
        #expect(c.name == "live-ctn")
    }

    // MARK: - Containers

    @Test("list containers returns the seeded container")
    func listContainers() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let ctns = try await region.listContainers(vt)
        #expect(ctns.count == 1)
        #expect(ctns.first?.id == "sct-1")
    }

    @Test("get container by id")
    func getContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        let c = try await region.getContainer(vt, id: "sct-1")
        #expect(c.id == "sct-1")
        #expect(c.secret_refs?.contains("sec-1") == true)
    }

    @Test("delete a container")
    func deleteContainer() async throws {
        let (handle, vt, svc, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }

        let region = svc.region("RegionOne")
        try await region.deleteContainer(vt, id: "sct-1")
        let after = try await region.listContainers(vt)
        #expect(after.isEmpty)
    }
}
