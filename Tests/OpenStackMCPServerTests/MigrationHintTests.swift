import Testing
import Foundation
import OpenStackClient
import FakeOpenStack
import MCP
import OpenStackMCPServer
import Logging

// MARK: - Migration error hint mapping
//
// Nova's migration/evacuation failures ("No valid host was found", "Instance
// is busy", "block migration not supported", …) rarely name the fix. The error
// formatter (`migrationHint`, applied by `errorParagraph` on every os_action
// failure) translates the known shapes into the next concrete call. These tests
// pin the mapping table and prove the translation fires through the real
// dispatch error path — including the fake's Nova-accurate refusal of any
// migration while OS-EXT-STS:task_state is non-null.

@Suite("Migration error hint mapping", .timeLimit(.minutes(3)))
struct MigrationHintTests {

    private func hint(_ service: String, _ message: String) -> String? {
        // `migrationHint` is internal; the public surface is `errorParagraph`,
        // which applies it whenever the error carries no explicit hint.
        let text = errorParagraph(OpenStackError(service: service, status: 400, code: nil,
                                                 message: message, requestID: nil, retriable: false),
                                  what: "os_action")
        guard let r = text.range(of: "Hint: ") else { return nil }
        return String(text[r.upperBound...])
    }

    @Test("table maps the Nova failure shapes")
    func table() {
        // Scheduler capacity failure → block-migration/capacity guidance.
        #expect(hint("compute", "No valid host was found. There are not enough hosts available.")?
            .contains("block_migration") == true)
        // In-flight async task → settled wait.
        #expect(hint("compute", "Instance is busy, cannot complete the action")?
            .contains("settled") == true)
        // Local disks without block migration → cold block migrate.
        #expect(hint("compute", "cannot migrate instance: block migration is not supported by the hosts")?
            .contains("block_migration: true") == true)
        // Target == source host.
        #expect(hint("compute", "source and destination cannot be the same host")?
            .contains("different target") == true)
        // Action key rejected by a pinned microversion.
        #expect(hint("compute", "Unknown action: no such action: os-migrateLive")?
            .contains("os-migrateLive") == true)
        // Nova policy denial (distinct from the MCP role gate).
        #expect(hint("compute", "Policy doesn't allow os_compute_api:action:evacuate to be performed.")?
            .contains("admin") == true)
        // CPU-pinned instance.
        #expect(hint("compute", "Instance is pinned to a host CPU set")?
            .contains("cold migrate") == true)

        // Non-compute services and unrelated messages pass through unmapped.
        #expect(hint("network", "No valid host was found.") == nil)
        #expect(hint("compute", "Some unrelated nova failure.") == nil)
    }

    /// End-to-end: a migration against a server whose `task_state` is set must
    /// surface the settled-wait hint through `os_action`'s error text, not just
    /// Nova's raw message.
    @Test("os_action surfaces the hint on a task_state-blocked migrate", .timeLimit(.minutes(2)))
    func dispatchSurfacesHint() async throws {
        let handle = try await FakeApp.start()
        defer { handle.stop() }
        let bundle = try await makeRegistry(handle: handle, credID: "fake-cred-admin", secret: "secret-admin")
        defer { bundle.shutdown() }

        // Nova refuses migration while an async task is in flight; block the
        // seeded server and the fake mirrors the refusal.
        #expect(await handle.state.setServerTaskState(serverID: "srv-0001", taskState: "migrating"))

        let result = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "action": .string("migrate"),
            "params": .object(["block_migration": .bool(true)]),
        ])
        let text = firstText(result.content) ?? ""
        #expect(result.isError == true, "blocked migrate must surface as a tool error: \(text)")
        #expect(text.lowercased().contains("task_state"),
                "raw Nova refusal should survive in the text: \(text)")
        #expect(text.contains("Hint:") && text.contains("settled"),
                "dispatch must attach the settled-wait hint: \(text)")

        // Clearing the task lets the same call succeed (202 accepted).
        #expect(await handle.state.setServerTaskState(serverID: "srv-0001", taskState: nil))
        let retry = try await bundle.mcpClient.callTool(name: "os_action", arguments: [
            "resource": .string("server"),
            "id_or_name": .string("srv-0001"),
            "action": .string("migrate"),
            "params": .object(["block_migration": .bool(true)]),
        ])
        #expect(retry.isError != true, "retry after settle should succeed: \(firstText(retry.content) ?? "nil")")
    }
}
