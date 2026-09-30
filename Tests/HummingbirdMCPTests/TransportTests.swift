import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import Logging
import NIOConcurrencyHelpers
import HummingbirdMCP

// MARK: - Transport tests (spec §7.1)

@Suite("HummingbirdMCP Transport Tests", .timeLimit(.minutes(3)))
struct TransportTests {

    private let logger = Logger(label: "test")

    @Test("POST with Accept: text/event-stream -> response content-type is text/event-stream")
    func sseContentType() async throws {
        let validator = StubValidator()
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["*"], publicURL: "http://localhost:8080"),
            validator: validator,
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(response.status == .ok, "init failed: \(response.status)")
            let contentType = header(response, "Content-Type") ?? ""
            #expect(contentType.hasPrefix("text/event-stream"), "expected SSE content-type, got: \(contentType)")
            #expect(bodyString(response).contains("data:"), "SSE body should have data: framing: \(bodyString(response))")
        }
    }

    @Test("POST with only application/json accepted -> 406")
    func jsonOnly406() async throws {
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["*"], publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ], body: Data(initBody.utf8))
            #expect(response.status == .notAcceptable, "expected 406, got \(response.status)")
        }
    }

    @Test("non-localhost Origin -> 403; localhost origin proceeds")
    func originValidation() async throws {
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["http://localhost:8080"], publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

            let evil = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Origin": "https://evil.example",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(evil.status == .forbidden, "evil origin should 403, got \(evil.status)")

            let local = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Origin": "http://localhost:8080",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(local.status == .ok, "allowed origin should proceed, got \(local.status)")
        }
    }

    @Test("body larger than maxBodyBytes -> 413")
    func bodyTooLarge() async throws {
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["*"], maxBodyBytes: 16, publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let big = Data(String(repeating: "x", count: 4096).utf8)
            let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: big)
            #expect(response.status == .contentTooLarge, "expected 413, got \(response.status)")
        }
    }

    @Test("legacy /mcp endpoint is a working alias of /v1")
    func legacyEndpoint() async throws {
        let route = MCPRoute(
            config: MCPConfig(endpoint: "/v1", legacyEndpoint: "/mcp", allowedOrigins: ["*"], publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            let response = try await sendRequest(client,uri: "/mcp", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(response.status == .ok, "legacy /mcp should work, got \(response.status)")
        }
    }

    @Test("GET /.well-known/oauth-protected-resource -> 200 JSON from the injected PRM closure")
    func prmRoute() async throws {
        let prmData: @Sendable () -> Data = {
            #"{"resource":"http://localhost:8080","authorization_servers":["http://keystone.example"],"scopes_supported":["openstack:read","openstack:write"]}"#.data(using: .utf8)!
        }
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["*"], publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: prmData, login: nil)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let response = try await sendRequest(client,uri: "/.well-known/oauth-protected-resource", method: .get)
            #expect(response.status == .ok, "PRM should 200, got \(response.status)")
            let body = bodyString(response)
            #expect(body.contains("authorization_servers"), "PRM missing authorization_servers: \(body)")
            #expect(body.contains("keystone.example"), "PRM missing keystone: \(body)")
            #expect(body.contains("openstack:write"), "PRM missing scopes_supported: \(body)")
        }
    }

    @Test("GET /v1/login -> 200 HTML form; POST /v1/login calls the injected minter and hides the secret")
    func loginRoute() async throws {
        final class MinterRecorder: @unchecked Sendable {
            private let called = NIOLockedValueBox(Bool(false))
            private let secret = NIOLockedValueBox(String?.none as String?)
            func record(secret: String?) {
                called.withLockedValue { $0 = true }
                self.secret.withLockedValue { $0 = secret }
            }
            var calledValue: Bool { called.withLockedValue { $0 } }
            var secretValue: String? { secret.withLockedValue { $0 } }
        }
        let recorder = MinterRecorder()
        let minter: @Sendable (LoginRequest) async -> LoginResponse = { req in
            recorder.record(secret: req.secret)
            return LoginResponse(tokenID: "minted-token", storePath: "/tmp/minted.token", completion: true)
        }
        let route = MCPRoute(
            config: MCPConfig(allowedOrigins: ["*"], publicURL: "http://localhost:8080"),
            validator: StubValidator(),
            serverFactory: { identity in await makeStubServer(identity: identity) },
            terminated: { _ in },
            logger: logger
        )
        let router = Router<BasicRequestContext>()
        route.install(on: router, prm: nil, login: minter)
        let app = Application<RouterResponder<BasicRequestContext>>(router: router)

        try await app.test(.router) { client in
            let get = try await sendRequest(client, uri: "/v1/login", method: .get)
            #expect(get.status == .ok, "login GET should 200, got \(get.status)")
            #expect(bodyString(get).lowercased().contains("form"), "login should render a form: \(bodyString(get))")

            let postBody = #"{"elicitationId":"E1","method":"app-cred","appCredId":"cred-1","secret":"hunter2-supersecret"}"#
            let post = try await sendRequest(client, uri: "/v1/login", method: .post, headers: [
                "Content-Type": "application/json",
            ], body: Data(postBody.utf8))
            #expect(post.status == .ok, "login POST should 200, got \(post.status)")
            #expect(!bodyString(post).contains("hunter2-supersecret"), "secret must not appear in response: \(bodyString(post))")
        }
        #expect(recorder.calledValue, "minter should have been called")
        #expect(recorder.secretValue == "hunter2-supersecret", "minter should receive the secret")
    }
}
