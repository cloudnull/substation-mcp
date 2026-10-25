import Foundation
import MCP
import OpenStackClient

// MARK: - AllTools (single source for the MCP tool definitions)

/// The full set of MCP tool definitions, shared by the live
/// `ToolRegistry.visibleTools()` (which filters by scope) and the
/// `tools` subcommand's dump (`ToolListFormatter`).
///
/// The `resource`/`link` enums are derived from the effective catalog so the
/// schemas always match what the deployment actually exposes.

/// One required argument of a tool, as the published schema describes it.
///
/// `order` is the argument's position in the schema's own `required` array, so
/// a hint renders arguments in the order a client reads them.
public struct ToolRequiredArgument: Sendable, Equatable {
    public let name: String
    public let order: Int
    /// The schema's `description` for this argument, when it has one. A hint
    /// renders it inside the placeholder so the caller is told what to supply
    /// (`target: <TARGET "Port ID or name">`) rather than guessing.
    public let description: String?

    public init(name: String, order: Int, description: String?) {
        self.name = name
        self.order = order
        self.description = description
    }
}

public enum AllTools {
    /// Every required argument of every tool, keyed by tool name, read straight
    /// off the `inputSchema` published through `tools/list`.
    ///
    /// `os_create`'s `next_steps` hints are rendered from this table so a hint
    /// can never advertise a call that omits a parameter the schema demands.
    /// That drift was live: the floating_ip hint said
    /// `os_attach(link:floating_ip, source:…, target:…)` while `os_attach`
    /// requires `source_type` and `target_type` as well, and an agent that
    /// copied the hint failed twice with `missingParam`.
    public static func requiredArguments(catalog: ResourceCatalog) -> [String: [ToolRequiredArgument]] {
        var out: [String: [ToolRequiredArgument]] = [:]
        for tool in tools(catalog: catalog) {
            guard case .object(let schema) = tool.inputSchema,
                  case .array(let req)? = schema["required"] else { continue }
            let properties = schema["properties"]?.objectValue ?? [:]
            var args: [ToolRequiredArgument] = []
            for (index, value) in req.enumerated() {
                guard let name = value.stringValue else { continue }
                args.append(.init(name: name, order: index,
                                  description: properties[name]?.objectValue?["description"]?.stringValue))
            }
            out[tool.name] = args
        }
        return out
    }

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
                        "id_or_name": .object(["type": .string("string"), "description": .string("Resource ID or name. Aliases id, name, uuid are accepted.")]),
                        "region": .object(["type": .string("string")]),
                        "fields": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_describe",
                description: "Describe a resource type: verbs, actions, links, list filters, terminal states, and the create_schema / update_schema (exact spec field names, types, required keys). Call this before os_create/os_update to learn the exact spec shape.",
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
                        "id_or_name": .object(["type": .string("string"), "description": .string("Resource ID or name. Aliases id, name, uuid are accepted.")]),
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
                name: "os_project_readiness",
                description: "Check what infrastructure exists in this project and what's needed before deploying servers. Returns: available networks (private/public), routers, volume quotas, flavors, keypairs, security groups, and a blockers list of missing prerequisites.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "region": .object(["type": .string("string")]),
                    ]),
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
                name: "os_recommend_flavor",
                description: "Recommend server flavors for a workload. Pass a plain-English workload (e.g. \"database\", \"web app\", \"batch compute\") and optional min_vcpu / min_ram_gb; returns the top 3 matching flavors with reasoning plus a volume type pairing.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "workload": .object(["type": .string("string")]),
                        "min_vcpu": .object(["type": .string("integer")]),
                        "min_ram_gb": .object(["type": .string("integer")]),
                        "region": .object(["type": .string("string")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_evacuation_plan",
                description: "Read-only evacuation plan for a hypervisor: lists every instance on the host with its disk shape (root local/volume, ephemeral GB, swap GB, attached volumes incl. bootable flag) and a per-instance recommended action — live_migrate (shared/BFOV, no local disks), migrate with block_migration=true (local/ephemeral disks, cold block migration), or evacuate (host is down/ERROR). Also returns target-capacity guidance (hypervisors with spare vcpu/ram/local disk, excluding the source) and the fencing step. This is the planning call for \"evacuate hypervisor X\": classify, choose actions, then execute os_action per instance and os_wait(until:[\"settled\"]) to confirm.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "host": .object(["type": .string("string"), "description": .string("Hypervisor hostname to evacuate (hypervisor_hostname).")]),
                        "region": .object(["type": .string("string")]),
                        "host_down": .object(["type": .string("boolean"), "description": .string("true: the host is down/unreachable — recommend evacuate (with block evacuation for local-disk instances) instead of migrate. Default false.")]),
                    ]),
                    "required": .array([.string("host")]),
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
                description: "Wait for a resource to reach a terminal state. Fast settles return synchronously with progress notifications. By default, if it does not settle within a short synchronous window, it HANDS OFF to a background task (returns {task_id, handed_off:true}) so slow operations outlive the client's HTTP request timeout — then poll os_task_status(task_id). Set async_on_timeout=false to force a fully synchronous wait instead.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "until": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "timeout_seconds": .object(["type": .string("integer"), "description": .string("Max seconds to wait (default 120). Alias: `timeout`.")]),
                        "timeout": .object(["type": .string("integer"), "description": .string("Alias for `timeout_seconds`.")]),
                        "async_on_timeout": .object(["type": .string("boolean"), "description": .string("Default true. When the wait outlives the synchronous window, hand off to a background task (returns task_id) rather than blocking; set false to stay fully synchronous.")]),
                    ]),
                    "required": .array([.string("resource"), .string("id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_task_submit",
                description: "Start a long-running wait as a task. Returns immediately with a task_id and the current status; the poll continues in the background. Use os_task_status to poll it and os_task_cancel to stop it. Prefer this over os_wait when the wait may outlive the client's request timeout.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id": .object(["type": .string("string")]),
                        "region": .object(["type": .string("string")]),
                        "until": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "timeout_seconds": .object(["type": .string("integer"), "description": .string("Max seconds to wait (default 120). Alias: `timeout`.")]),
                        "timeout": .object(["type": .string("integer"), "description": .string("Alias for `timeout_seconds`.")]),
                    ]),
                    "required": .array([.string("resource"), .string("id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_task_status",
                description: "Poll a task submitted by os_task_submit. Returns its state (submitted/running/succeeded/failed/timed_out/cancelled), last observed status, and — once terminal — the final result. Tasks are scoped to the presenting token.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("task_id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_task_cancel",
                description: "Cancel a running task submitted by os_task_submit. Stops the background poll and marks the task cancelled. No-op (error) if the task is unknown, foreign, or already terminal.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task_id": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("task_id")]),
                ]),
                annotations: .init(readOnlyHint: true, destructiveHint: false)
            ),
            Tool(
                name: "os_create",
                description: "Create an OpenStack resource. Call os_describe(resource:) first for the create schema (it returns the exact spec fields). dry_run validates without creating. For servers, pass a `provisioning` block (packages/services/users/firewall/extra_runcmd) to install software and configure the OS at boot via cloud-init — this is how you apply patches or install runtimes; verify the result later with os_action(server, provisioning_status).",
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
                        "id_or_name": .object(["type": .string("string"), "description": .string("Resource ID or name. Aliases id, name, uuid are accepted.")]),
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
                description: "Delete an OpenStack resource. dry_run:true returns dependent resources that block deletion. For a load balancer, cascade:true also deletes its children (listeners, pools, members, health monitors).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string"), "description": .string("Resource ID or name. Aliases id, name, uuid are accepted.")]),
                        "region": .object(["type": .string("string")]),
                        "dry_run": .object(["type": .string("boolean")]),
                        "cascade": .object(["type": .string("boolean"), "description": .string("Load balancer only: delete the load balancer and all its children (listeners, pools, members, health monitors) in one call. Without it an LB with children is rejected with 'it has children'.")]),
                    ]),
                    "required": .array([.string("resource"), .string("id_or_name")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            Tool(
                name: "os_action",
                description: "Perform a resource action (reboot, extend, set_bootable, etc). Per-action details in os_describe. For servers, `provisioning_status` reads the serial console to confirm a create-time `provisioning` block (cloud-init) succeeded; `console_output` returns raw boot logs.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "resource": .object(["type": .string("string"), "enum": .array(resourceEnum)]),
                        "id_or_name": .object(["type": .string("string"), "description": .string("Resource ID or name. Aliases id, name, uuid are accepted.")]),
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
                description: "Attach a link between two resources (volume, interface, security_group, floating_ip, router_interface, router_gateway). For a volume link, params.device is ADVISORY — on KVM hypervisors the driver often auto-assigns the next free slot instead of the exact target; the response returns the actual assigned device (field 'device') plus requested_device and a device_note, so always read those for the authoritative path.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum),
                                         "description": .string("Link kind: volume, interface, security_group, floating_ip, router_interface, router_gateway, qos_policy.")]),
                        "source": .object(["type": .string("string"),
                                           "description": .string("ID or name of the resource the link starts from: the floating IP (floating_ip), the router (router_interface / router_gateway), or the server (volume / interface / security_group).")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum),
                                                "description": .string("Resource type of `source` — floating_ip, router, or server. Required: os_attach rejects the call without it.")]),
                        "target": .object(["type": .string("string"),
                                           "description": .string("ID or name of the resource the link points at: a server or port (floating_ip), a subnet or port (router_interface), an EXTERNAL network (router_gateway), a volume (volume).")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum),
                                                "description": .string("Resource type of `target` — server, port, subnet, network, or volume. Required: os_attach rejects the call without it.")]),
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
                        "link": .object(["type": .string("string"), "enum": .array(linkEnum),
                                         "description": .string("Link kind to remove: volume, interface, security_group, floating_ip, router_interface, router_gateway, qos_policy.")]),
                        "source": .object(["type": .string("string"),
                                           "description": .string("ID or name of the resource the link starts from: the floating IP (floating_ip), the router (router_interface / router_gateway), or the server (volume / interface / security_group).")]),
                        "source_type": .object(["type": .string("string"), "enum": .array(resourceEnum),
                                                "description": .string("Resource type of `source` — floating_ip, router, or server. Required: os_detach rejects the call without it.")]),
                        "target": .object(["type": .string("string"),
                                           "description": .string("ID or name of the resource the link points at: a server or port (floating_ip), a subnet or port (router_interface), an EXTERNAL network (router_gateway), a volume (volume).")]),
                        "target_type": .object(["type": .string("string"), "enum": .array(resourceEnum),
                                                "description": .string("Resource type of `target` — server, port, subnet, network, or volume. Required: os_detach rejects the call without it.")]),
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
