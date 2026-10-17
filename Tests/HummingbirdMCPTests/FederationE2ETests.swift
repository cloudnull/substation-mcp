import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import Logging
import OpenStackClient
import OpenStackMCPServer
import FakeOpenStack

// MARK: - Federation E2E tests (Route A: WebSSO bounce)
//
// These drive the real `ServeApp` with federation enabled against a running
// `FakeApp`. They pin the router wiring for the WebSSO flow:
//   1. GET /oauth/federate → 502 "federation_not_configured" when no
//      clouds.yaml is visible (keystoneBaseURL returns nil). This pins that
//      the route IS mounted and reaches the handler.
//   2. POST /oauth/federation/callback missing relay_state → 502 error HTML
//      mentioning relay_state.
//   3. POST /oauth/federation/callback with a disallowed origin echo → 502
//      error HTML with the "different Substation instance" message.
//   4. POST /oauth/federation/pick-project with an unknown relay_state → 502
//      error HTML with the expired-session message.
//   5. GET /oauth/federate when federation is disabled → 404 (route not mounted).
//   6. GET /v1/login with federation on → page offers "Federated token".
//   7. GET /oauth/authorize with federation on → page offers "Federated token".
//
// The full 302 → callback → pick-project happy path (including the actual
// WebSSO redirect URL construction, token exchange, and code minting) requires
// a live Keystone that supports OS-FEDERATION; the fake does not implement
// those endpoints. The minter logic (listFedProjects, exchangeUnscopedForScoped)
// is covered by unit tests in TokenValidatorTests.

/// Build a `ServeApp` with federation enabled, pointing at the fake cloud.
private func makeFedServeApp(handle: FakeHandle, issuer: String) -> ServeApp {
    let cloud = CloudEntry(name: "fake", authURL: handle.url, regionName: nil)
    let cfg = OpenStackMCPConfig(
        serverPublicURL: issuer,
        authKeystoneURL: handle.keystoneURL.absoluteString,
        federationEnabled: true,
        federationIdP: "rackspace",
        federationProtocol: "saml2",
        oauthServerSecret: "test-server-secret",
        oauthIssuer: issuer + "/v1/oauth"
    )
    return ServeApp(config: cfg, cloud: cloud, logger: Logger(label: "fed-e2e"))
}

@Suite("Federation E2E (WebSSO bounce)", .timeLimit(.minutes(4)))
struct FederationE2ETests {

    // Test 1: /oauth/federate route is mounted and reaches the handler.
    // Without a clouds.yaml visible to keystoneBaseURL, the handler returns
    // 502 with "federation_not_configured" (keystone endpoint unresolvable).
    @Test("/oauth/federate returns 502 federation_not_configured without clouds.yaml")
    func federateWithoutCloudsReturns502() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/federate?client_id=test-client&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb&state=xyz&code_challenge=abc123&code_challenge_method=S256&scope=openstack%3Aread",
                method: .get
            )
            #expect(resp.status == .badGateway, "expected 502, got \(resp.status)")
            let body = bodyString(resp)
            #expect(body.contains("federation_not_configured") || body.contains("keystone_endpoint_unresolvable"),
                    "unexpected body: [\(body.prefix(300))]")
        }
    }

    // Test 2: /oauth/federation/callback rejects a missing relay_state
    @Test("/oauth/federation/callback rejects missing relay_state with 502 error page")
    func callbackMissingRelayStateShowsErrorPage() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/federation/callback",
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data("unscoped_token=fake-fed-tok-001".utf8)
            )
            #expect(resp.status == .badGateway, "expected 502 error page, got \(resp.status)")
            let body = bodyString(resp)
            #expect(body.contains("relay_state"), "error page should mention relay_state: [\(body.prefix(300))]")
        }
    }

    // Test 3: /oauth/federation/callback with a disallowed origin is rejected
    @Test("/oauth/federation/callback rejects disallowed origin echo with 502 error page")
    func callbackRejectsDisallowedOrigin() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let formBody =
                "origin=http%3A%2F%2Fevil.example.com"
                + "&relay_state=not-a-real-relay"
                + "&unscoped_token=fake-fed-tok-001"
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/federation/callback",
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(formBody.utf8)
            )
            #expect(resp.status == .badGateway, "expected 502 error page, got \(resp.status)")
            let body = bodyString(resp)
            #expect(
                body.contains("different Substation instance"),
                "disallowed-origin rejection expected: [\(body.prefix(300))]"
            )
        }
    }

    // Test 4: /oauth/federation/pick-project with an unknown relay_state returns
    // a 502 error page (the relay was never issued, or already consumed/expired).
    @Test("/oauth/federation/pick-project with unknown relay_state shows 502 expired session error")
    func pickProjectUnknownRelayShowsError() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let formBody = "relay_state=never-issued&project_id=proj-one"
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/federation/pick-project",
                method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(formBody.utf8)
            )
            #expect(resp.status == .badGateway, "expected 502 error page, got \(resp.status)")
            let body = bodyString(resp)
            #expect(
                body.contains("expired") || body.contains("Missing relay_state"),
                "unknown-relay error expected: [\(body.prefix(300))]"
            )
        }
    }

    // Test 5: federation route not mounted when federationEnabled is false
    @Test("/oauth/federate returns 404 when federation is disabled")
    func federateDisabledReturns404() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let cloud = CloudEntry(name: "fake", authURL: handle.url, regionName: nil)
        var cfg = OpenStackMCPConfig(
            serverPublicURL: issuer,
            authKeystoneURL: handle.keystoneURL.absoluteString,
            oauthServerSecret: "test-server-secret",
            oauthIssuer: issuer + "/v1/oauth"
        )
        cfg.federationEnabled = false
        let app = ServeApp(config: cfg, cloud: cloud, logger: Logger(label: "fed-off"))
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/federate?client_id=test-client&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb&state=xyz&code_challenge=abc123&code_challenge_method=S256&scope=openstack%3Aread",
                method: .get
            )
            #expect(resp.status == .notFound, "expected 404 when federation is disabled, got \(resp.status)")
        }
    }

    // Test 6: login page offers the federated option when federation is on
    @Test("login page shows Federated token option when federation is enabled")
    func loginPageShowsFederatedOption() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let resp = try await sendRequest(client, uri: "/v1/login", method: .get)
            #expect(resp.status == .ok, "login GET failed: \(resp.status)")
            let body = bodyString(resp)
            #expect(
                body.contains("Federated token") || body.contains("federated"),
                "login page should offer the federated method: [\(body.prefix(500))]"
            )
        }
    }

    // Test 7: /oauth/authorize page shows the federated option when federation is on
    @Test("OAuth authorize page shows Federated token option when federation is enabled")
    func authorizePageShowsFederatedOption() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let issuer = "http://127.0.0.1:8080"
        let app = makeFedServeApp(handle: handle, issuer: issuer)
        defer { app.shutdown() }

        try await app.app.test(.router) { client in
            _ = try await sendRequest(client, uri: "/healthz", method: .get)
            let resp = try await sendRequest(
                client,
                uri: "/v1/oauth/authorize?client_id=test-client&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb&state=xyz&code_challenge=abc123&code_challenge_method=S256&scope=openstack%3Aread",
                method: .get
            )
            #expect(resp.status == .ok, "authorize GET failed: \(resp.status)")
            let body = bodyString(resp)
            #expect(
                body.contains("Federated token") || body.contains("federated"),
                "authorize page should offer the federated method: [\(body.prefix(500))]"
            )
        }
    }
}
