import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - Waiter tests
//
// Covers: success on terminal state, `until` targeting, invalid `until`
// state, unknown resource, timeout, and (directly on the `Waiter`) the
// progress-notification path via the fake's `transitionDelay` knob with an
// intermediate REBOOT status before the final ACTIVE.

@Suite("Waiter Tests", .timeLimit(.minutes(3)))
struct WaiterTests {

    @Test("os_wait returns terminal state for an ACTIVE server", )
    func waitActiveServer() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_wait", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "timeout_seconds": .int(10),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("ACTIVE") == true, "Should reach ACTIVE, got: \(text ?? "nil")")
        #expect(text?.contains("polls") == true, "Should report poll count")
    }

    @Test("os_wait with until reaches SHUTOFF after a stop action", )
    func waitSHUTOFF() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let stop = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0002"),
            "action": .string("stop"),
        ])
        #expect(stop.isError != true)

        let result = try await bundle.mcpClient.callTool(name: "os_wait", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0002"),
            "until": .array([.string("SHUTOFF"), .string("ERROR")]),
            "timeout_seconds": .int(10),
        ])
        #expect(result.isError != true)
        let text = firstText(result.content)
        #expect(text?.contains("SHUTOFF") == true, "Should reach SHUTOFF, got: \(text ?? "nil")")
    }

    @Test("os_wait rejects unknown until state", )
    func waitInvalidUntilState() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_wait", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "until": .array([.string("BOGUS_STATE")]),
            "timeout_seconds": .int(5),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("BOGUS_STATE") == true, "Error should name the bad state, got: \(text ?? "nil")")
        #expect(text?.contains("ACTIVE") == true, "Error should list valid states")
    }

    @Test("os_wait rejects resources without a status to poll", )
    func waitUnknownResource() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_wait", arguments: [
            "resource": .string("flavor"),
            "id": .string("1"),
            "timeout_seconds": .int(5),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("not supported") == true, "Should say waiting on flavor is unsupported, got: \(text ?? "nil")")
    }

    @Test("os_wait times out when the state never changes", )
    func waitTimeout() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // srv-0001 is ACTIVE; asking for SHUTOFF without an action means the
        // state never changes and we should time out.
        let result = try await bundle.mcpClient.callTool(name: "os_wait", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "until": .array([.string("SHUTOFF")]),
            "timeout_seconds": .int(2),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content)
        #expect(text?.contains("Timed out") == true, "Should be a timeout error, got: \(text ?? "nil")")
        #expect(text?.contains("ACTIVE") == true, "Should report last observed status")
    }

    @Test("Waiter reports intermediate status via progress notifications", )
    func waiterProgressDirect() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }

        // Slow the fake's action settle so an intermediate REBOOT is observable
        // past the waiter's 1s initial backoff (first poll sees REBOOT, the
        // ~2s second poll sees ACTIVE).
        let state = handle.state
        await state.setTransitionDelay(.milliseconds(4000))

        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Capture progress notifications emitted for our token.
        let recorder = ProgressRecorder()
        await bundle.mcpClient.onNotification(ProgressNotification.self) { msg in
            let params = msg.params
            await recorder.record(token: params.progressToken, message: params.message)
        }

        // Reboot: immediately REBOOT, ACTIVE after the 4s delay.
        let reboot = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "action": .string("reboot"),
        ])
        #expect(reboot.isError != true)

        // Build the waiter directly so we can pass the token + server without
        // relying on the client to plumb _meta.
        let vt = bundle.identity.vt
        let waiter = Waiter(client: bundle.client, catalog: ResourceCatalog.phase1(), logger: Logger(label: "test-waiter"))
        let outcome = try await waiter.wait(
            vt,
            resource: "server",
            id: "srv-0001",
            region: "RegionOne",
            until: nil,
            timeout: 20,
            progressToken: .string("tok-progress"),
            server: bundle.mcpServer
        )
        #expect(outcome["status"]?.stringValue == "ACTIVE", "Should settle on ACTIVE, got \(String(describing: outcome["status"]))")

        // At least one progress notification for our token mentioning the
        // intermediate status (REBOOT) must have been observed.
        let entries = await recorder.entries
        let tokenMatches = entries.filter { $0.token == "tok-progress" }
        #expect(!tokenMatches.isEmpty, "Expected >=1 progress notification for the token, got \(entries.count) total")
        #expect(tokenMatches.contains { $0.message?.contains("REBOOT") == true },
                "Expected a progress notification mentioning REBOOT, got: \(entries.map { $0.message ?? "?" }.joined(separator: " | "))")
    }

    // MARK: - Transient fetch failure (one-shot fake 500 injection)
    //
    // These guard the tri-state fetchStatus contract: a non-404 fetch error is
    // transient (keep polling), a true 404 is gone, and only a confirmed 404
    // may ever be reported as "resource no longer exists" / deleted.

    @Test("wait survives a transient fetch error and then succeeds", )
    func waitSurvivesTransientFetchError() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Arm the fake Nova server GET to fail once with a 500. The first poll
        // of the wait hits it; the knob is consumed, the rest of the polls see
        // ACTIVE and the wait succeeds.
        await handle.state.setServerGetFailNext(("srv-0001", 500))

        let vt = bundle.identity.vt
        let waiter = Waiter(client: bundle.client, catalog: ResourceCatalog.phase1(), logger: Logger(label: "test-waiter"))
        let outcome = try await waiter.wait(
            vt,
            resource: "server",
            id: "srv-0001",
            region: "RegionOne",
            until: nil,
            timeout: 30
        )
        #expect(outcome["status"]?.stringValue == "ACTIVE",
                "Should settle on ACTIVE after one transient failure, got \(String(describing: outcome["status"]))")
        // At least two polls: the failed one plus the successful one.
        #expect(outcome["polls"]?.intValue == 2, "Expected exactly 2 polls, got \(String(describing: outcome["polls"]))")
    }

    @Test("wait times out on persistent transient fetch errors, never reports deletion", )
    func waitTimesOutOnPersistentTransientErrors() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Keep re-arming the one-shot 500 for the whole wait so every poll
        // fails transiently. Old code reported this as "no longer exists"
        // (404 itemNotFound) on the very first poll; the fix must instead
        // burn the timeout and return the timeout error. The re-arm loop runs
        // in its own unstructured task so it doesn't block the wait; the
        // helper is nonisolated and captures only the Sendable `FakeState`.
        let rearm = rearmTransientFailures(state: handle.state)
        defer { rearm.cancel() }

        let vt = bundle.identity.vt
        let waiter = Waiter(client: bundle.client, catalog: ResourceCatalog.phase1(), logger: Logger(label: "test-waiter"))
        do {
            _ = try await waiter.wait(
                vt,
                resource: "server",
                id: "srv-0001",
                region: "RegionOne",
                until: ["SHUTOFF"],
                timeout: 3
            )
            #expect(Bool(false), "Expected a timeout error for persistent transient fetch failures")
        } catch let e as OpenStackError {
            #expect(e.status == 408, "Persistent transient errors must time out (408), not 404; got status \(e.status)")
            #expect(e.code == "timeout", "Expected code 'timeout', got \(String(describing: e.code))")
        }
    }

    @Test("wait still reports a true 404 as gone (not transient)", )
    func waitTrue404ReportsGone() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Genuinely delete srv-0003 so the fake GET returns a real 404.
        let del = try await bundle.mcpClient.callTool(name: "os_delete", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0003"),
        ])
        #expect(del.isError != true, "os_delete of srv-0003 should succeed, got: \(firstText(del.content) ?? "nil")")

        // Waiting for a state on the deleted server must surface the confirmed
        // 404 as itemNotFound — the tri-state fix must not demote real 404s
        // to transient errors and hide the deletion behind a timeout.
        let vt = bundle.identity.vt
        let waiter = Waiter(client: bundle.client, catalog: ResourceCatalog.phase1(), logger: Logger(label: "test-waiter"))
        do {
            _ = try await waiter.wait(
                vt,
                resource: "server",
                id: "srv-0003",
                region: "RegionOne",
                until: ["SHUTOFF"],
                timeout: 10
            )
            #expect(Bool(false), "Expected itemNotFound for a deleted server, but the wait returned")
        } catch let e as OpenStackError {
            #expect(e.status == 404, "True 404 must still be 'gone' (404), got status \(e.status)")
            #expect(e.code == "itemNotFound", "Expected code 'itemNotFound', got \(String(describing: e.code))")
        }
    }
}

/// Sendable collector for progress notification messages.
actor ProgressRecorder {
    struct Entry: Sendable {
        let token: String?
        let message: String?
    }
    private var _entries: [Entry] = []

    func record(token: ProgressToken, message: String?) {
        let tokenString: String?
        switch token {
        case .string(let s): tokenString = s
        case .integer(let i): tokenString = String(i)
        }
        _entries.append(Entry(token: tokenString, message: message))
    }

    var entries: [Entry] { _entries }
}

/// Re-arm a one-shot fake server GET failure on a cadence until the returned
/// task is cancelled. A free (nonisolated) function capturing only the
/// Sendable `FakeState`, so the closure is safe to hand to a background
/// `Task` under strict concurrency.
func rearmTransientFailures(
    state: FakeState,
    serverID: String = "srv-0001",
    status: Int = 500,
    every: Duration = .milliseconds(100)
) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            await state.setServerGetFailNext((serverID, status))
            try? await Task.sleep(for: every)
        }
    }
}
