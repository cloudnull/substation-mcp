[← Documentation home](index.md)
# Tools reference

The server exposes **20 tools** — 14 read-only + 6 write. The verb tools are
**stable (additive-only invariant):** new OpenStack services are exposed as new
*resources* under the existing verbs, never as new tools. That means a client
that learns `os_list` / `os_get` / `os_create` keeps working forever as the
catalog grows (currently **63 resource descriptors** across ~19 types).

Read-only mode (`--read-only` / `policy.read_only: true`) restricts the server
to the 14 read tools. Write tools are additionally gated by the token's derived
scopes: a token without the `openstack:write` scope gets
`403 insufficient_scope` on mutating calls.

## Read-only tools (14)

| Tool | Description |
|------|-------------|
| `os_list` | List a resource type with filters, `fields`, `limit`, `marker`. Call `os_describe(resource:)` first to see available filters. |
| `os_get` | Get one resource by ID or name (project-scoped). Ambiguous names return an error listing candidates. |
| `os_describe` | Get + resolved name + attached resources (volumes, ports, SGs), plus verbs/actions/links and the `create_schema`/`update_schema` field shapes. Call before `os_create`/`os_update`. |
| `os_topology` | Graph of connected resources from an anchor (depth 1–3, optional diagnosis findings). |
| `os_find` | Search across resource types by name/ID/IP. |
| `os_whoami` | Token identity: project, domain, roles, scopes, regions, services. |
| `os_project_readiness` | What infrastructure exists in this project and what's needed before deploying servers (networks, routers, quotas, flavors, keypairs, SGs). |
| `os_quota` | Quota usage for a resource type. |
| `os_clouds` | Cloud catalog: regions, services, endpoints. |
| `os_wait` | Poll a resource until it reaches a target state (with progress notifications). |
| `os_recommend_flavor` | Recommend server flavors for a plain-English workload; returns top matches with reasoning. |
| `os_task_submit` | Start a long-running wait as a background task; returns a `task_id` immediately and polls in the background. |
| `os_task_status` | Poll a task submitted by `os_task_submit`; returns state, last observed status, and final result once terminal. |
| `os_task_cancel` | Cancel a running task. No-op if unknown, foreign, or already terminal. |

## Write tools (6)

| Tool | Description |
|------|-------------|
| `os_create` | Create a resource (schema-validated against `create_schema`). Supports `dry_run` and distro-aware cloud-init provisioning for servers. |
| `os_update` | Update a resource (PATCH). |
| `os_delete` | Delete a resource. `dry_run:true` returns dependent resources that block deletion. |
| `os_action` | Run a server action (start, stop, reboot, resize, …). |
| `os_attach` | Attach a link between two resources (volume, interface, SG, floating IP, router interface, router gateway). |
| `os_detach` | Detach a link (reverse of `os_attach`). Floating IP detach = disassociate, never delete. |

## Argument & result conventions

- **Resource enums are live.** The `resource` argument enum is derived from the
  effective catalog at runtime, so the schema always matches what your
  deployment actually exposes.
- **Call `os_describe` first.** It returns the exact spec field names, types,
  and required keys for create/update. Never guess the body shape.
- **Result shaping.** Outputs are normalized to a consistent JSON envelope so a
  client can reason about them uniformly across services. See spec §8.3.
- **Hints.** Every tool carries MCP annotations (`readOnlyHint`,
  `destructiveHint`). Mutating tools surface a human-readable `hint` alongside
  errors where useful.

## Related surfaces (not tools)

- **MCP resources:** `openstack://catalog`, `openstack://catalog/{resource}`,
  and a lazily-resolved live-resource URI template. A client can read state via
  `resources/read` without a tool call. See spec §9.
- **Prompts:** curated prompt templates over the same data. See spec §9.

For the full matrix of resource × verbs × actions × links, see spec
§8.5–§8.8 in [`specs/substation-mcp-spec.md`](../specs/substation-mcp-spec.md).

## Related

- [Architecture](architecture.md) — how a tool call flows through the server.
- [Configuration](configuration.md) — read-only mode and per-resource cache TTLs.

