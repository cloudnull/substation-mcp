import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - MCP Tasks shim (Path C) tests
//
// A non-conformant task-handle surface built over the 0.12.1 SDK + the existing
// `Waiter`. Long-running waits are submitted as tasks that return a `task_id`
// immediately; the poll runs in a background task; `os_task_status` polls the
// task state; `os_task_cancel` cancels the background poll.
//
// The task store is a shared, server-scoped actor (`TaskRegistry`) keyed by
// token id, so a task submitted in one request is visible to later requests
// presenting the same token (and NOT to a different token — project isolation).
//
// TDD note: these tests are written FIRST, before the implementation exists.

@Suite("MCP Tasks shim", .timeLimit(.minutes(3)))
struct TaskShimTests {

    // MARK: submit

    @Test("os_task_submit returns a task_id immediately (does not block on settle)")
    func submitReturnsImmediately() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // Slow the settle so a blocking wait would take >1s; a submit must
        // still return in well under that.
        await handle.state.setTransitionDelay(.seconds(5))
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let start = Date()
        let result = try await bundle.mcpClient.callTool(name: "os_task_submit", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "timeout_seconds": .int(30),
        ])
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.isError != true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("task_id"), "submit should return a task_id, got: \(text)")
        #expect(elapsed < 2.0, "submit must not block on the settle (took \(elapsed)s)")
    }

    @Test("os_task_status reports the task as succeeded once the wait settles")
    func statusReachesSucceeded() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let submit = try await bundle.mcpClient.callTool(name: "os_task_submit", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "timeout_seconds": .int(10),
        ])
        #expect(submit.isError != true)
        let taskID = try extractTaskID(firstText(submit.content) ?? "")
        #expect(!taskID.isEmpty, "could not parse task_id from submit result")

        // srv-0001 is already ACTIVE in the fake, so the wait succeeds on the
        // first poll. Poll the task status until it reports succeeded.
        let final = try await pollTaskStatus(bundle: bundle, taskID: taskID, maxSeconds: 10)
        #expect(final.contains("succeeded"), "task should reach succeeded, got: \(final)")
        #expect(final.contains("ACTIVE"), "task result should carry the final status, got: \(final)")
    }

    @Test("os_task_status rejects an unknown task_id")
    func statusUnknownTask() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_task_status", arguments: [
            "task_id": .string("no-such-task"),
        ])
        #expect(result.isError == true)
        let text = firstText(result.content) ?? ""
        #expect(text.contains("Unknown task"), "should name the missing task, got: \(text)")
    }

    // MARK: cancel

    @Test("os_task_cancel cancels a running task; status then reports cancelled")
    func cancelRunningTask() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        // Keep the resource from settling so the task is still running when we
        // cancel it: srv-0001 is ACTIVE, ask for SHUTOFF (never happens).
        await handle.state.setTransitionDelay(.seconds(1))
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let submit = try await bundle.mcpClient.callTool(name: "os_task_submit", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "until": .array([.string("SHUTOFF")]),
            "timeout_seconds": .int(60),
        ])
        #expect(submit.isError != true)
        let taskID = try extractTaskID(firstText(submit.content) ?? "")
        #expect(!taskID.isEmpty)

        // Give the background poll a moment to start, then cancel.
        try await Task.sleep(for: .milliseconds(300))
        let cancel = try await bundle.mcpClient.callTool(name: "os_task_cancel", arguments: [
            "task_id": .string(taskID),
        ])
        #expect(cancel.isError != true)
        let cancelText = firstText(cancel.content) ?? ""
        #expect(cancelText.contains("cancelled"), "cancel should report cancelled, got: \(cancelText)")

        let final = try await pollTaskStatus(bundle: bundle, taskID: taskID, maxSeconds: 5, expect: "cancelled")
        #expect(final.contains("cancelled"), "task status should be cancelled, got: \(final)")
    }

    @Test("os_task_cancel of an unknown task_id is an error")
    func cancelUnknownTask() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        let result = try await bundle.mcpClient.callTool(name: "os_task_cancel", arguments: [
            "task_id": .string("no-such-task"),
        ])
        #expect(result.isError == true)
    }

    // MARK: isolation

    @Test("a task submitted by one token is not visible to another token")
    func taskIsolationAcrossTokens() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundleA = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundleA.shutdown() }

        let submit = try await bundleA.mcpClient.callTool(name: "os_task_submit", arguments: [
            "resource": .string("server"),
            "id": .string("srv-0001"),
            "timeout_seconds": .int(10),
        ])
        #expect(submit.isError != true)
        let taskID = try extractTaskID(firstText(submit.content) ?? "")
        #expect(!taskID.isEmpty)

        // A different token (read-only, different id) must NOT be able to read
        // token A's task. Task tools are read-scoped, so a read token can use
        // them on its OWN tasks but not on a foreign token's tasks.
        let bundleB = try await makeRegistry(handle: handle, credID: "fake-cred-ro", secret: "secret-ro")
        defer { bundleB.shutdown() }
        let result = try await bundleB.mcpClient.callTool(name: "os_task_status", arguments: [
            "task_id": .string(taskID),
        ])
        #expect(result.isError == true, "another token must not read token A's task")
        let text = firstText(result.content) ?? ""
        #expect(text.contains("Unknown task"), "foreign token should see it as unknown, got: \(text)")
    }

    // MARK: helpers

    /// Parse the `task_id` out of a JSON-ish submit result. The submit handler
    /// returns a structured object; we grab the value following `"task_id"`.
    private func extractTaskID(_ text: String) throws -> String {
        // The resultText serialization is JSON, so the id appears as
        // "task_id":"<value>". Strip a possible single-quote variant too.
        for (open, close) in [("\"task_id\":\"", "\""), ("\"task_id\": \"", "\"")] {
            if let i = text.range(of: open) {
                let rest = text[i.upperBound...]
                if let j = rest.firstIndex(of: close[...].first!) {
                    return String(rest[..<j])
                }
            }
        }
        // Fallback: decode as JSON.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["task_id"] as? String {
            return id
        }
        throw OpenStackError(service: "test", status: 500, message: "no task_id in: \(text)")
    }

    /// Poll `os_task_status` until the text contains `expect` (default
    /// "succeeded") or `maxSeconds` elapses; return the last status text.
    private func pollTaskStatus(
        bundle: MCPTestBundle,
        taskID: String,
        maxSeconds: Int,
        expect: String = "succeeded"
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(maxSeconds))
        var last = ""
        while Date() < deadline {
            let r = try await bundle.mcpClient.callTool(name: "os_task_status", arguments: [
                "task_id": .string(taskID),
            ])
            last = firstText(r.content) ?? ""
            if r.isError != true, last.contains(expect) { return last }
            try await Task.sleep(for: .milliseconds(150))
        }
        return last
    }
}
