import Testing
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MCP
import Logging
import NIOConcurrencyHelpers
import HummingbirdMCP

// MARK: - Shared test helpers (Task 17)

/// Trivial in-memory token validator (spec §7.1 Review Focus 1/2/3).
/// `tok-admin` → [read,write] p1; `tok-ro` → [read] p1; `tok-p2` → [read,write] p2; else throw.
/// A `cacheEnabled` flag makes the validator cache by token id so the "validate twice →
/// underlying called once" behavior is observable.
struct StubValidator: TokenValidating, Sendable {
    var cacheEnabled = true
    private let cache = NIOLockedValueBox([String: ValidatedIdentity]())
    private let validationCount = NIOLockedValueBox(Int(0))

    func validate(tokenID: String) async throws -> ValidatedIdentity {
        let hit = cache.withLockedValue { $0[tokenID] }
        if let hit { return hit }
        validationCount.withLockedValue { $0 += 1 }
        let identity: ValidatedIdentity
        switch tokenID {
        case "tok-admin":
            identity = ValidatedIdentity(tokenID: tokenID, projectID: "p1", scopes: ["openstack:read", "openstack:write"], raw: nil)
        case "tok-ro":
            identity = ValidatedIdentity(tokenID: tokenID, projectID: "p1", scopes: ["openstack:read"], raw: nil)
        case "tok-p2":
            identity = ValidatedIdentity(tokenID: tokenID, projectID: "p2", scopes: ["openstack:read", "openstack:write"], raw: nil)
        default:
            throw MCPError.invalidRequest("invalid token")
        }
        if cacheEnabled {
            cache.withLockedValue { $0[tokenID] = identity }
        }
        return identity
    }

    var validationCountValue: Int { validationCount.withLockedValue { $0 } }
}

/// A recorder for which identity the `serverFactory` received, in order.
final class IdentityRecorder: @unchecked Sendable {
    private let identities = NIOLockedValueBox([ValidatedIdentity]())
    func record(_ id: ValidatedIdentity) {
        identities.withLockedValue { $0.append(id) }
    }
    var recorded: [ValidatedIdentity] {
        identities.withLockedValue { $0 }
    }
}

/// A minimal MCP server whose `tools/list` returns a tool set that encodes the
/// validated identity, so tests can assert scope-awareness end to end.
func makeStubServer(identity: ValidatedIdentity) async -> Server {
    let scope = identity.scopes.contains("openstack:write") ? "write" : "read"
    let project = identity.projectID
    let toolName = "stub_\(project)_\(scope)"
    let tool = Tool(
        name: toolName,
        description: "Stub tool",
        inputSchema: .object(["type": .string("object")])
    )
    let server = Server(
        name: "stub-server",
        version: "1.0.0",
        capabilities: .init(tools: .init())
    )
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [tool])
    }
    return server
}

/// Build a `Router` with the MCP routes installed.
@discardableResult
func makeRouter(
    config: MCPConfig,
    validator: any TokenValidating,
    recorder: IdentityRecorder? = nil,
    prm: (@Sendable () -> Data)? = nil,
    login: (@Sendable (LoginRequest) async -> LoginResponse)? = nil,
    terminated: (@Sendable (String) -> Void)? = nil,
    logger: Logger = Logger(label: "test")
) -> Router<BasicRequestContext> {
    let factory: @Sendable (ValidatedIdentity) async -> Server = { identity in
        if let recorder { recorder.record(identity) }
        return await makeStubServer(identity: identity)
    }
    let route = MCPRoute(
        config: config,
        validator: validator,
        serverFactory: factory,
        gate: WriteToolGate(toolNames: ["stub_write"]),
        terminated: terminated ?? { _ in },
        logger: logger
    )
    let router = Router<BasicRequestContext>()
    route.install(on: router, prm: prm, login: login)
    return router
}

/// Extract a `TestResponse` body as a string.
func bodyString(_ response: TestResponse) -> String {
    String(buffer: response.body)
}

/// Case-insensitive header lookup on a `TestResponse`.
func header(_ response: TestResponse, _ name: String) -> String? {
    response.headers[HTTPField.Name(name)!]
}

/// A thread-safe `Bool` box for capturing a flag across an `@Sendable` closure.
final class FlagBox: @unchecked Sendable {
    private let value = NIOLockedValueBox(Bool(false))
    func set(_ value: Bool) { self.value.withLockedValue { $0 = value } }
    var isSet: Bool { value.withLockedValue { $0 } }
}

/// Build `HTTPFields` from a string dictionary (for the Hummingbird test client).
func httpFields(_ pairs: [String: String]) -> HTTPFields {
    var fields = HTTPFields()
    for (key, value) in pairs {
        if let name = HTTPField.Name(key) {
            fields[name] = value
        }
    }
    return fields
}

/// Send a request via the Hummingbird test client and return the `TestResponse`.
func sendRequest(
    _ client: any TestClientProtocol,
    uri: String,
    method: HTTPRequest.Method,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> TestResponse {
    try await client.execute(
        uri: uri,
        method: method,
        headers: httpFields(headers),
        body: body.map { ByteBuffer(data: $0) }
    )
}

// MARK: - Auth tests (Review Focus 1/2/3/4 pinned here)

@Suite("HummingbirdMCP Auth Tests", .timeLimit(.minutes(3)))
struct AuthTests {

    private func makeApp(_ validator: any TokenValidating,
                         recorder: IdentityRecorder? = nil,
                         terminated: (@Sendable (String) -> Void)? = nil,
                         config: MCPConfig = MCPConfig(allowedOrigins: ["*"])) -> Application<RouterResponder<BasicRequestContext>> {
        Application(router: makeRouter(config: config, validator: validator, recorder: recorder, terminated: terminated))
    }

    @Test("missing Authorization header -> 401 with WWW-Authenticate invalid_token + resource_metadata")
    func missingAuth() async throws {
        let app = makeApp(StubValidator())
        try await app.test(.router) { client in
            let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data("{}".utf8))
            #expect(response.status == .unauthorized, "expected 401, got \(response.status)")
            let www = header(response, "WWW-Authenticate") ?? ""
            #expect(www.contains("error=\"invalid_token\""), "missing invalid_token: \(www)")
            #expect(www.contains("resource_metadata"), "missing resource_metadata: \(www)")
        }
    }

    @Test("bogus token -> 401 and no session created")
    func bogusToken() async throws {
        let recorder = IdentityRecorder()
        let app = makeApp(StubValidator(cacheEnabled: false), recorder: recorder)
        try await app.test(.router) { client in
            let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer bogus-token",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data("{}".utf8))
            #expect(response.status == .unauthorized, "expected 401, got \(response.status)")
            #expect(recorder.recorded.isEmpty, "factory must not run for invalid token")
        }
    }

    @Test("per-request identity: serverFactory receives the matching project per request")
    func perRequestIdentity() async throws {
        let recorder = IdentityRecorder()
        let app = makeApp(StubValidator(), recorder: recorder)
        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            for token in ["tok-admin", "tok-p2"] {
                let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                ], body: Data(initBody.utf8))
                #expect(response.status == .ok, "initialize with \(token) failed: \(response.status) \(bodyString(response))")
            }
        }
        // Each token's validated project must reach the serverFactory.
        let projects = recorder.recorded.map(\.projectID)
        #expect(projects.contains("p1"), "should include p1: \(projects)")
        #expect(projects.contains("p2"), "should include p2: \(projects)")
    }

    @Test("token cache keyed by token id: validate twice -> underlying validator called once")
    func tokenCache() async throws {
        let validator = StubValidator(cacheEnabled: true)
        let app = makeApp(validator)
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        try await app.test(.router) { client in
            for _ in 0..<2 {
                let response = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                    "Authorization": "Bearer tok-admin",
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                ], body: Data(initBody.utf8))
                #expect(response.status == .ok, "init failed: \(response.status)")
            }
            _ = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-p2",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
        }
        // tok-admin validated once (cached), tok-p2 validated once = 2 total.
        #expect(validator.validationCountValue == 2, "expected 2 validations, got \(validator.validationCountValue)")
    }

    @Test("read-only token + write tool -> 403 insufficient_scope with openstack:write")
    func insufficientScope() async throws {
        let app = makeApp(StubValidator())
        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            let initResp = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-ro",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(initResp.status == .ok)
            let sessionID = header(initResp, "MCP-Session-Id")
            #expect(sessionID != nil, "no session id returned")

            // A write-gated tool call by a read-only token.
            let callBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stub_write","arguments":{}}}"#
            let callResp = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-ro",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": sessionID ?? "",
            ], body: Data(callBody.utf8))
            #expect(callResp.status == .forbidden, "expected 403, got \(callResp.status)")
            let www = header(callResp, "WWW-Authenticate") ?? ""
            #expect(www.contains("error=\"insufficient_scope\""), "missing insufficient_scope: \(www)")
            #expect(www.contains("openstack:write"), "missing required scope: \(www)")
        }
    }

    @Test("tools/list with tok-admin exposes the write tool; with tok-ro exposes the read tool")
    func scopeAwareToolList() async throws {
        let app = makeApp(StubValidator())
        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

            let adminResp = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(adminResp.status == .ok)
            let adminSession = header(adminResp, "MCP-Session-Id") ?? ""
            let listAdmin = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": adminSession,
            ], body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8))
            #expect(bodyString(listAdmin).contains("stub_p1_write"), "admin should see write tool: \(bodyString(listAdmin))")
            #expect(!bodyString(listAdmin).contains("stub_p1_read"), "admin should not see read-only tool")

            let roResp = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-ro",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(roResp.status == .ok)
            let roSession = header(roResp, "MCP-Session-Id") ?? ""
            let listRO = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-ro",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": roSession,
            ], body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8))
            #expect(bodyString(listRO).contains("stub_p1_read"), "ro should see read tool: \(bodyString(listRO))")
            #expect(!bodyString(listRO).contains("stub_p1_write"), "ro should not see write tool")
        }
    }

    @Test("tools/call without session id -> 400; with bogus session id -> 404")
    func sessionRequired() async throws {
        let app = makeApp(StubValidator())
        try await app.test(.router) { client in
            let callBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stub","arguments":{}}}"#
            let noSession = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(callBody.utf8))
            #expect(noSession.status == .badRequest, "expected 400, got \(noSession.status)")

            let bogus = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": "does-not-exist",
            ], body: Data(callBody.utf8))
            #expect(bogus.status == .notFound, "expected 404, got \(bogus.status)")
        }
    }

    @Test("DELETE terminates the session: 200, terminated callback fired, subsequent request 404")
    func deleteTerminates() async throws {
        let flag = FlagBox()
        let onTerminated: @Sendable (String) -> Void = { _ in flag.set(true) }
        let app = makeApp(StubValidator(), terminated: onTerminated)
        try await app.test(.router) { client in
            let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
            let initResp = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ], body: Data(initBody.utf8))
            #expect(initResp.status == .ok)
            let sessionID = header(initResp, "MCP-Session-Id") ?? ""

            let delResp = try await sendRequest(client,uri: "/v1", method: .delete, headers: [
                "Authorization": "Bearer tok-admin",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": sessionID,
            ])
            #expect(delResp.status == .ok, "DELETE should 200, got \(delResp.status)")

            let callBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
            let after = try await sendRequest(client,uri: "/v1", method: .post, headers: [
                "Authorization": "Bearer tok-admin",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Session-Id": sessionID,
            ], body: Data(callBody.utf8))
            #expect(after.status == .notFound, "after DELETE, request should 404, got \(after.status)")
        }
        #expect(flag.isSet, "terminated callback should have fired")
    }
}
