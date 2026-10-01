import Foundation
import MCP
import OpenStackClient

// MARK: - AllTools (single source for the 15 MCP tool definitions)

/// The full set of 15 MCP tool definitions, shared by the live
/// `ToolRegistry.visibleTools()` (which filters by scope) and the
/// `tools` subcommand's dump (`ToolListFormatter`).
///
/// The `resource`/`link` enums are derived from the effective catalog so the
/// schemas always match what the deployment actually exposes.
public enum AllTools {
    public static func tools(catalog: ResourceCatalog) -> [Tool] {
        let resourceEnum = catalog.names.sorted().map { Value.string($0) }
        let linkEnum = catalog.allLinks.keys.sorted().map { Value.string($0) }

        return [
            Tool(
                name: "os_list",
                description: "List OpenStack resources. Use filters to narrow results. Call os_describe(resource:) first to see available filters.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "region": .object(["type": .string("string")]),
                        "filters": .object(["type": .string("object")]),
                        "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "limit": .object(["type": .string("integer")]),
                        "marker": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("resource")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_get",
                description: "Get a single OpenStack resource by ID or name. Ambiguous names return an error listing candidates.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_describe",
                description: "Describe a resource type: verbs, actions, links, create/update schemas, list filters, terminal states.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                    ]),
                    "required": .array([.string("resource")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_topology",
                description: "Show the topology around an anchor resource with optional diagnosis findings.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "depth": .object(["type": .string("integer")]),
                        "diagnosis": .object(["type": .string("boolean")]),
                        "diagnose": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "protocol": .object(["type": .string("string")]),
                                "port": .object(["type": .string("integer")]),
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_find",
                description: "Search across resources for a value (IP address, name, etc.).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")]),
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("value")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_whoami",
                description: "Show the current identity: project, domain, roles, scopes, regions, services.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_quota",
                description: "Show resource quotas for the current project.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "service": .object(["type": .string("string"), "enum": .array([.string("compute"), .string("network"), .string("volume"), .string("image")])]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("service")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_clouds",
                description: "Show the cloud's regions and available services per region.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_wait",
                description: "Wait for a resource to reach a terminal state. Sends progress notifications.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "until": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "timeout_seconds": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("resource"), .string("id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_create",
                description: "Create an OpenStack resource. Call os_describe(resource:) first for the create schema. dry_run validates without creating.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "spec": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("spec")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_update",
                description: "Update an OpenStack resource (PATCH). Call os_describe(resource:) first for the update schema.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string")]),
                        "patch": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name"), .string("patch")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_delete",
                description: "Delete an OpenStack resource. dry_run:true returns dependent resources that block deletion.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "os_action",
                description: "Perform a resource action (reboot, extend, set_bootable, etc). Per-action details in os_describe.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string")]),
                        "action": .object(["type": .string("string")]),
                        "params": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name"), .string("action")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "os_attach",
                description: "Attach a link between two resources (volume, interface, security_group, floating_ip, router_interface, router_gateway).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum)]),
                        "source": .object(["type": .string("string")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "target": .object(["type": .string("string")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "params": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("link"), .string("source"), .string("source_type"), .string("target"), .string("target_type")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
            Tool(
                name: "os_detach",
                description: "Detach a link (reverse of os_attach). Floating IP detach = disassociate, never delete.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum)]),
                        "source": .object(["type": .string("string")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "target": .object(["type": .string("string")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "params": .object(["type": .string("object")]),
                        "region": .object(["type": .string("string")]),
                        "wait": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("link"), .string("source"), .string("source_type"), .string("target"), .string("target_type")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false)
            ),
        ]
    }
}
