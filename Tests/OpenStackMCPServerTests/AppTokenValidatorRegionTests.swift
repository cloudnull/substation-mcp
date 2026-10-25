import Testing
import Foundation
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack
import Logging

/// The `region:<REGION>:<token>` bearer form (URL-mode login on multi-region
/// clouds): parsing, regional validation, and the session region preference.
@Suite("AppTokenValidator Region Bearer")
struct AppTokenValidatorRegionTests {
    private func makeValidator() async throws -> (FakeHandle, AppTokenValidator, Transport, String) {
        let handle = try await FakeApp.start()
        let state = handle.state
        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else {
            throw OpenStackError(service: "keystone", status: 500, message: "Failed to mint token")
        }
        let cloud = CloudEntry(name: "fake", authURL: handle.url, regionName: "RegionOne")
        let cache = Cache(maxEntries: 100)
        let transport = Transport(cloud: cloud, tokenSource: { fakeToken.id }, logger: Logger(label: "test"))
        let validator = TokenValidator(transport: transport, cache: cache, servedProjects: [])
        return (handle, AppTokenValidator(validator: validator), transport, fakeToken.id)
    }

    @Test("splitRegion parses the prefix and leaves plain tokens untouched")
    func parsing() {
        #expect(AppTokenValidator.splitRegion("region:IAD3:abc123") == ("IAD3", "abc123"))
        #expect(AppTokenValidator.splitRegion("abc123") == (nil, "abc123"))
        // malformed prefixes fall back to treating the whole string as the token
        #expect(AppTokenValidator.splitRegion("region::abc") == (nil, "region::abc"))
        #expect(AppTokenValidator.splitRegion("region:IAD3:") == (nil, "region:IAD3:"))
        // a token containing colons after the region keeps its payload intact
        #expect(AppTokenValidator.splitRegion("region:DFW3:a:b:c") == ("DFW3", "a:b:c"))
    }

    @Test("region-prefixed bearer validates and carries the region preference")
    func regionBearerValidates() async throws {
        let (handle, validator, transport, tokenID) = try await makeValidator()
        defer { handle.stop(); transport.syncShutdown() }

        let identity = try await validator.validate(tokenID: "region:RegionOne:" + tokenID)
        #expect(identity.region == "RegionOne")
        #expect(identity.tokenID == tokenID)
        #expect(!identity.projectID.isEmpty)

        // plain bearer still works, with no region preference
        let plain = try await validator.validate(tokenID: tokenID)
        #expect(plain.region == nil)
        #expect(plain.tokenID == tokenID)
    }

    @Test("region-prefixed bearer with a bad token still 401s")
    func regionBearerRejectsBadToken() async throws {
        let (handle, validator, transport, _) = try await makeValidator()
        defer { handle.stop(); transport.syncShutdown() }
        await #expect(throws: (any Error).self) {
            _ = try await validator.validate(tokenID: "region:RegionOne:not-a-real-token")
        }
    }

    @Test("splitBearer parses region + scope prefixes in either order")
    func scopeParsing() {
        typealias S = AppTokenValidator.BearerScope
        #expect(AppTokenValidator.splitBearer("abc123") == (nil, nil, "abc123"))
        #expect(AppTokenValidator.splitBearer("scope:ro:abc123") == (nil, .readOnly, "abc123"))
        #expect(AppTokenValidator.splitBearer("scope:rw:abc123") == (nil, .readWrite, "abc123"))
        #expect(AppTokenValidator.splitBearer("region:IAD3:scope:ro:abc123") == ("IAD3", .readOnly, "abc123"))
        #expect(AppTokenValidator.splitBearer("scope:ro:region:IAD3:abc123") == ("IAD3", .readOnly, "abc123"))
        // A token that merely starts with `scope:` (no valid marker) is left whole.
        #expect(AppTokenValidator.splitBearer("scope:maybe:abc") == (nil, nil, "scope:maybe:abc"))
        #expect(AppTokenValidator.splitBearer("scope:ro:") == (nil, nil, "scope:ro:"))
        // The token payload keeps its own colons.
        #expect(AppTokenValidator.splitBearer("region:DFW3:scope:ro:a:b:c") == ("DFW3", .readOnly, "a:b:c"))
    }

    @Test("scope:ro: narrows the session to read; scope:rw: leaves roles alone")
    func scopeBearerNarrowsScopes() async throws {
        let (handle, validator, transport, tokenID) = try await makeValidator()
        defer { handle.stop(); transport.syncShutdown() }

        let full = try await validator.validate(tokenID: tokenID)
        #expect(full.scopes.contains("openstack:write"), "the admin token's roles grant write: \(full.scopes)")

        let narrowed = try await validator.validate(tokenID: "scope:ro:" + tokenID)
        #expect(narrowed.scopes == ["openstack:read"], "scope:ro: must drop write: \(narrowed.scopes)")
        #expect(narrowed.tokenID == tokenID, "the marker must not reach Keystone: \(narrowed.tokenID)")

        let widened = try await validator.validate(tokenID: "scope:rw:" + tokenID)
        #expect(widened.scopes == full.scopes, "scope:rw: must not change anything: \(widened.scopes)")
    }

    @Test("region + scope bearer carries both preferences and narrows scopes")
    func regionAndScopeBearer() async throws {
        let (handle, validator, transport, tokenID) = try await makeValidator()
        defer { handle.stop(); transport.syncShutdown() }

        let identity = try await validator.validate(tokenID: "region:RegionOne:scope:ro:" + tokenID)
        #expect(identity.region == "RegionOne")
        #expect(identity.scopes == ["openstack:read"], "combined bearer: \(identity.scopes)")
    }
}
