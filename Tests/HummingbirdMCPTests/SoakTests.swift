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
import NIOConcurrencyHelpers

// MARK: - Concurrency soak test (spec §14.7 #7)
//
// 50 concurrent sessions present interleaved tokens from multiple projects
// (proj-one and proj-two). We assert no cross-session token/project leakage:
// each `os_whoami` must report the project of the token that made the request,
// never another session's project.

@Suite("Concurrency soak tests", .timeLimit(.minutes(6)))
struct SoakTests {

    @Test("50 interleaved multi-project sessions never leak another session's project")
    func noCrossSessionLeakage() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let store = TokenStore()
        let logger = Logger(label: "soak")
        let app = makeServeApp(handle: handle, config: defaultConfig, tokenStore: store, logger: logger)
        defer { app.shutdown() }

        // Mint 50 tokens, interleaving the two projects.
        let creds = [
            ("fake-cred-admin", "secret-admin", "proj-one"),
            ("fake-cred-two", "secret-two", "proj-two"),
        ]
        struct Session: Sendable { let tokenID: String; let project: String }
        var built: [Session] = []
        for i in 0..<50 {
            let (credID, secret, project) = creds[i % creds.count]
            guard let ft = await handle.state.mintToken(
                credID: credID, secret: secret, domain: nil, password: nil, userID: nil
            ) else {
                throw OpenStackError(service: "test", status: 500, message: "mint failed \(credID)")
            }
            built.append(Session(tokenID: ft.id, project: project))
        }
        let sessions: [Session] = built

        // Phase 1: create all 50 sessions (initialize only), then phase 2:
        // run os_whoami concurrently on each. The session-creation phase is
        // serialized because each initialize is a session-scoped write; the
        // per-session isolation is what phase 2 verifies.
        struct SessionID: Sendable { let id: String }
        final class CreatedBox: @unchecked Sendable {
            private let value = NIOLockedValueBox([(session: Session, sid: SessionID)]())
            private let failure = NIOLockedValueBox("none")
            func append(_ session: Session, _ sid: String) {
                value.withLockedValue { $0.append((session, SessionID(id: sid))) }
            }
            func recordFailure(_ message: String) {
                failure.withLockedValue { $0 = message }
            }
            func lastFailure() -> String { failure.withLockedValue { $0 } }
            func all() -> [(session: Session, sid: SessionID)] {
                value.withLockedValue { $0 }
            }
        }
        let createdBox = CreatedBox()

        // Phase 1: create all 50 sessions.
        try await app.app.test(.router) { client in
            for (idx, session) in sessions.enumerated() {
                let sc = SessionClient(client: client, tokenID: session.tokenID)
                let resp = try await sc.initialize()
                if resp.status == .ok, let sid = header(resp, "MCP-Session-Id") {
                    createdBox.append(session, sid)
                } else {
                    createdBox.recordFailure("idx=\(idx) status=\(resp.status) body=\(bodyString(resp).prefix(200))")
                }
            }
        }
        let created = createdBox.all()
        guard created.count == 50 else {
            throw OpenStackError(service: "test", status: 500, message: "only \(created.count) sessions initialized; last failure: \(createdBox.lastFailure())")
        }

        // Phase 2: concurrent os_whoami across all sessions.
        try await app.app.test(.router) { client in
            let results = await withTaskGroup(of: (String, String?).self) { group in
                for (idx, entry) in created.enumerated() {
                    group.addTask { () -> (String, String?) in
                        let session = entry.session
                        let sid = entry.sid.id
                        do {
                            let headers = [
                                "Authorization": "Bearer \(session.tokenID)",
                                "Content-Type": "application/json",
                                "Accept": "application/json, text/event-stream",
                                "MCP-Session-Id": sid,
                            ]
                            let whoamiBody = "{" + "\"jsonrpc\":\"2.0\",\"id\":\(idx + 1000),"
                                + "\"method\":\"tools/call\",\"params\":{\"name\":\"os_whoami\",\"arguments\":{}}}"
                            let whoamiResp = try await sendRequest(client, uri: "/v1", method: .post, headers: headers, body: Data(whoamiBody.utf8))
                            guard whoamiResp.status == .ok else {
                                return (session.project, "whoami:\(whoamiResp.status):\(bodyString(whoamiResp).prefix(120))")
                            }
                            let body = bodyString(whoamiResp)
                            // The response must contain THIS session's project id.
                            if body.contains(#""id":"\#(session.project)""#) {
                                return (session.project, session.project)
                            }
                            // It must NOT contain the other project.
                            let other = session.project == "proj-one" ? "proj-two" : "proj-one"
                            if body.contains(other) {
                                return (session.project, "LEAK:\(other)")
                            }
                            return (session.project, "whoami-no-project")
                        } catch {
                            return (session.project, "throw:\(error)")
                        }
                    }
                }
                var out: [(String, String?)] = []
                for await r in group { out.append(r) }
                return out
            }

            // Every session must have seen exactly its own project.
            for (expected, actual) in results {
                #expect(actual == expected, "session expected project \(expected) but saw \(actual ?? "<nil>")")
            }
            #expect(results.count == 50)
        }
    }
}
