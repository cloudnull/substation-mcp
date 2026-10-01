import Foundation
import MCP
import OpenStackClient

// MARK: - tools (spec §11.3)

/// Renders the tool list (name, description, annotations, inputSchema) for the
/// effective policy. `--json` produces machine output; the default is a human
/// table. This is the documentation/diff artifact.
public enum ToolListFormatter {
    /// The tool names a session of the given scope would see.
    public static func toolNames(readOnly: Bool) -> [String] {
        if readOnly {
            return [
                "os_list", "os_get", "os_describe", "os_topology",
                "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait",
            ]
        }
        return [
            "os_list", "os_get", "os_describe", "os_topology",
            "os_find", "os_whoami", "os_quota", "os_clouds", "os_wait",
            "os_create", "os_update", "os_delete", "os_action",
            "os_attach", "os_detach",
        ]
    }

    /// Build the full `[Tool]` list (name/description/schema/annotations) for
    /// the effective policy, matching `ToolRegistry.visibleTools()` filtered by
    /// scope. This is the single source the `tools` subcommand dumps.
    public static func tools(readOnly: Bool, catalog: ResourceCatalog) -> [Tool] {
        let names = Set(toolNames(readOnly: readOnly))
        let all = AllTools.tools(catalog: catalog)
        return all.filter { names.contains($0.name) }
    }

    /// Bare JSON (`--json`): an array of `{name, description, annotations, inputSchema}`.
    public static func json(_ tools: [Tool]) throws -> String {
        struct Entry: Encodable {
            let name: String
            let description: String?
            let readOnly: Bool
            let destructive: Bool
            let inputSchema: [String: String]
        }
        var entries: [Entry] = []
        for t in tools {
            entries.append(Entry(
                name: t.name,
                description: t.description,
                readOnly: t.annotations.readOnlyHint ?? false,
                destructive: t.annotations.destructiveHint ?? false,
                inputSchema: schemaStrings(t.inputSchema)
            ))
        }
        let data = try JSONEncoder().encode(entries)
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ToolFormatError.encoding
        }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: out, encoding: .utf8) ?? "[]"
    }

    /// Human table.
    public static func table(_ tools: [Tool]) -> String {
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        var lines: [String] = []
        lines.append(pad("TOOL", 14) + " " + pad("KIND", 10) + " " + "DESCRIPTION")
        lines.append(pad(String(repeating: "-", count: 14), 14) + " " + pad(String(repeating: "-", count: 10), 10) + " " + String(repeating: "-", count: 40))
        for t in tools.sorted(by: { $0.name < $1.name }) {
            let kind = (t.annotations.readOnlyHint ?? false) ? "read" : "mutate"
            lines.append(pad(t.name, 14) + " " + pad(kind, 10) + " " + (t.description ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private static func schemaStrings(_ schema: Value) -> [String: String] {
        if case .object(let obj) = schema {
            return obj.mapValues { stringifyValue($0) }
        }
        return ["type": "object"]
    }

    private static func stringifyValue(_ v: Value) -> String {
        switch v {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .data: return "data"
        case .array: return "[array]"
        case .object(let dict): return "{\(dict.keys.sorted().joined(separator: ","))}"
        }
    }
}

public enum ToolFormatError: Error { case encoding }
