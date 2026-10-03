import Testing
import Foundation
import OpenStackClient
@testable import OpenStackMCPServer

// MARK: - tools subcommand (spec §11.3)

/// Tests the `tools` subcommand's output via `ToolListFormatter`:
/// `--json` machine output (18 tools for write = 15 verbs + 3 task tools,
/// 12 for read-only = 9 verbs + 3 task tools) and the human table.
@Suite("Tools Subcommand", .timeLimit(.minutes(2)))
struct SubcommandTests {

    private func decodeNames(_ json: String) throws -> [String] {
        let data = Data(json.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        return arr.compactMap { $0["name"] as? String }
    }

    @Test("tools --json (write) lists 18 tools")
    func toolsJSONWrite() throws {
        let tools = ToolListFormatter.tools(readOnly: false, catalog: ResourceCatalog.phase1())
        let json = try ToolListFormatter.json(tools)
        let names = try decodeNames(json)
        #expect(names.count == 18, "Expected 18 write-scoped tools, got \(names.count): \(names)")
        // Spot-check a few mutating + read + task tools.
        for n in ["os_list", "os_get", "os_create", "os_delete", "os_attach", "os_detach", "os_action", "os_task_submit", "os_task_status", "os_task_cancel"] {
            #expect(names.contains(n), "missing tool \(n)")
        }
        // Valid JSON with name/description/annotations/inputSchema keys.
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        for e in arr {
            #expect(e["name"] is String)
            #expect(e["description"] is String)
            #expect(e["readOnly"] is Bool)
            #expect(e["inputSchema"] is [String: Any])
        }
    }

    @Test("tools --read-only --json lists 12 tools")
    func toolsJSONReadOnly() throws {
        let tools = ToolListFormatter.tools(readOnly: true, catalog: ResourceCatalog.phase1())
        let json = try ToolListFormatter.json(tools)
        let names = try decodeNames(json)
        #expect(names.count == 12, "Expected 12 read-only tools, got \(names.count): \(names)")
        // Mutating tools must be absent; the 3 read-scoped task tools present.
        for n in ["os_create", "os_update", "os_delete", "os_action", "os_attach", "os_detach"] {
            #expect(!names.contains(n), "read-only should not include \(n)")
        }
        for n in ["os_task_submit", "os_task_status", "os_task_cancel"] {
            #expect(names.contains(n), "read-only should include task tool \(n)")
        }
    }

    @Test("human table has a header row and one row per tool")
    func humanTable() throws {
        let tools = ToolListFormatter.tools(readOnly: false, catalog: ResourceCatalog.phase1())
        let table = ToolListFormatter.table(tools)
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 2 + tools.count, "header + separator + one row per tool")
        #expect(lines[0].contains("TOOL"))
        #expect(table.contains("os_create"))
    }
}
