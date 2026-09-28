# OpenStack MCP Server: Design Specification

| | |
|---|---|
| Status | Draft for review |
| Date | 2026-09-09 |
| Author | Kevin Carter, drafted with Claude |
| Language / runtime | Swift 6.2, Linux (Rocky 9) primary, macOS 14+ for development |
| HTTP framework | Hummingbird 2.26 |
| MCP SDK | modelcontextprotocol/swift-sdk 0.12.x (protocol revision 2025-11-25) |
| OpenStack target | 2026.1 Gazpacho and later; older clouds supported by negotiation |

## 1. Summary

Build a Model Context Protocol (MCP) server, written in Swift and hosted by Hummingbird, that lets an LLM client (Claude Code, Claude Desktop, or any MCP client) consume an OpenStack cloud conversationally. The server authenticates to OpenStack with Keystone application credentials, exposes create, read, update, and delete operations across the core OpenStack services, and models the connections between resources (volumes to servers, ports to networks, routers to subnets and external networks, floating IPs to ports, security groups to ports) as first-class operations and as a queryable topology.

The server is a fresh codebase. It does not depend on Substation. Substation's `OSClient` library is used as a source of inspiration for service coverage, microversion handling, cache tuning, and for a list of design choices we deliberately avoid in a multi-tenant server.

### Decisions at a glance

| Decision | Choice | Alternatives considered |
|---|---|---|
| OpenStack client | New `OpenStackClient` library on AsyncHTTPClient (SwiftNIO) | Depend on Substation `OSClient` (rejected by owner; URLSession based, process-global TLS toggle, single-user cache) |
| MCP hosting | Hummingbird routes wrap the SDK's `StatefulHTTPServerTransport` per session; stdio mode for local use | SDK's own NIO server (no middleware, metrics, or TLS story); stdio only (no remote multi-user use) |
| Client-to-server auth | Bearer token that carries an application credential (`id:secret`); server binds it to the MCP session | Static token to profile map (phase 2); OAuth 2.1 with external authorization server (phase 2) |
| Tool shape | Verb tools (`os_list`, `os_get`, `os_create`, ...) generic over a resource catalog, plus explicit `os_attach` / `os_detach` / `os_topology` | One tool per resource and verb (150+ tools, bloats context); one tool per resource with an `op` argument (loses per-tool safety annotations) |
| Service scope, phase 1 | Identity, Compute, Network, Block Storage, Image | All services at once (too large for one plan) |
| Config | swift-configuration: CLI flags, `OSMCP_*` env vars, YAML file; clouds from `clouds.yaml` | Custom parser |

## 2. Goals and non-goals

### Goals

1. A conversational interface to an OpenStack cloud: an operator can say "give me a server on the internal network with a floating IP and attach a 50 GB volume" and the client can do it with the tools provided.
2. Authentication with Keystone application credentials only. No passwords, no user tokens.
3. Full CRUD coverage for the resources of each supported service, driven by a declarative resource catalog so adding a resource is data plus a thin adapter.
4. Interconnectivity as a first-class concept: attach and detach operations, a topology query, connectivity diagnosis, and multi-cloud, multi-region addressing.
5. Safe by default: read-only mode, per-tool safety annotations, deny lists, dry runs, generated least-privilege Keystone access rules, no credentials on disk or in logs.
6. Production hosting: TLS, origin validation, session limits, health and readiness endpoints, Prometheus metrics, structured logs, static Linux binary and container image.
7. Testable without a cloud: an in-process fake OpenStack, in-process MCP client tests, and Hummingbird transport tests.

### Non-goals

1. Replacing the OpenStack CLI or Horizon for bulk administration.
2. Implementing an OAuth authorization server. OAuth resource-server support is phase 2 and relies on an external authorization server.
3. Cross-project scoping in one session. An application credential is bound to one project, so one session addresses one project per cloud.
4. Provisioning the OpenStack cloud itself, or any Keystone federation configuration.
5. Object storage data transfer of large objects through the model. Object tools handle metadata, listings, and small text objects only.

## 3. Definitions

- **Principal**: an authenticated OpenStack identity for the life of an MCP session: application credential ID, project, roles, cloud name, and the Keystone token derived from it.
- **Session**: one MCP session, identified by `Mcp-Session-Id`, bound to exactly one principal.
- **Resource**: a kind of OpenStack object the server manages (server, network, volume). Each resource belongs to a service and has a catalog entry.
- **Verb**: one of `list`, `get`, `create`, `update`, `delete`. Not every resource supports every verb.
- **Action**: a non-CRUD operation on a resource (`start`, `reboot`, `extend`, `set_visibility`).
- **Link**: a relationship between two resources that OpenStack models as an attachment or association. Links are created with `os_attach` and removed with `os_detach`.
- **Interconnectivity** (as used in this spec, since the term is ambiguous): three things. (a) Link operations between resources. (b) Topology reads that show what is connected to what, and a diagnosis workflow built on them. (c) Addressing more than one cloud and region from one server. The spec assumes this interpretation; see section 18.

## 4. Prior art and lessons

### Substation (github.com/cloudnull/substation)

A Swift 6 terminal UI for OpenStack by the same author, MIT licensed, with a dependency-free `OSClient` library covering Keystone, Nova, Neutron, Cinder, Glance, Swift, Barbican, and Magnum (about 9,000 lines, 230 public operations). We take from it:

- The operation inventory per service. Its Nova, Neutron, Cinder, and Glance coverage is the baseline for our resource matrix (section 8.5).
- A per-service microversion manager that negotiates once per service and caches the version headers.
- The cache TTL table in its configuration guide (authentication 3600 s, service endpoints 1800 s, servers, volumes, ports, floating IPs 120 s) as starting values.
- Its retry policy defaults (3 attempts, 1 s base delay, 60 s cap, retry on 429 and 5xx).
- The application credential auth body and its `RegionDetection` approach of reading regions from the catalog.
- `clouds.yaml` search order (`./clouds.yaml`, `~/.config/openstack/clouds.yaml`, `/etc/openstack/clouds.yaml`) and the `OS_CLOUD` and `OS_CLIENT_CONFIG_FILE` variables.

We deliberately avoid three of its choices, each fine for a single-user TUI and wrong for a server:

1. Disabling TLS verification by setting `CURL_SSL_VERIFYPEER` in the process environment. It affects every cloud in the process. We configure TLS per cloud with NIOSSL.
2. A three-level cache with an on-disk tier keyed by cloud name. Cached data would be shared across principals. Our cache is in memory and keyed by principal, region, and resource.
3. `clouds.yaml` parsing inside the executable target. Ours lives in the client library.

### Other references

- python-openstacksdk's proxy layer names resources and verbs consistently (`list_servers`, `create_network`); our catalog uses the same nouns so users who know the SDK or CLI recognize them.
- The MCP Swift SDK's conformance server (`Sources/MCPConformance/Server/HTTPApp.swift`) shows the session registry pattern the Hummingbird adapter mirrors.

## 5. Architecture

```
 MCP client (Claude Code, Desktop, Inspector)
        |  Streamable HTTP  (POST/GET/DELETE /mcp)        stdio
        v                                                  |
 +-------------------------------------------------------------+
 | Hummingbird Application                                      |
 |  middleware: request log, metrics, body limit, bearer auth   |
 |  routes: /mcp  /healthz  /readyz  /metrics                   |
 |          +--------------------------------------------+     |
 |          | HummingbirdMCP adapter                      |     |
 |          |  SessionRegistry (actor)                    |     |
 |          |   session -> StatefulHTTPServerTransport    |     |
 |          |              + MCP Server + Principal       |     |
 |          +--------------------------------------------+     |
 +-------------------------------------------------------------+
        |
        v
 +-------------------------------------------------------------+
 | OpenStackMCPServer                                           |
 |  ToolRegistry  (os_list, os_get, ... os_topology)            |
 |  ResourceCatalog (descriptors, schemas, links, actions)      |
 |  Policy (read-only, deny lists)   NameResolver   Waiter      |
 |  Resources (openstack:// URIs)    Prompts                     |
 +-------------------------------------------------------------+
        |
        v
 +-------------------------------------------------------------+
 | OpenStackClient                                              |
 |  CloudConfig (clouds.yaml)  Identity (app-cred auth, token)  |
 |  EndpointResolver (catalog, region, interface)               |
 |  VersionNegotiator (microversions, Neutron extensions)       |
 |  Transport (AsyncHTTPClient, retry, error mapping)           |
 |  Services: Identity Compute Network BlockStorage Image ...   |
 +-------------------------------------------------------------+
        |
        v
   Keystone, Nova, Neutron, Cinder, Glance, ... (per cloud, per region)
```

### 5.1 Components

Each component answers three questions: what it does, how it is used, what it depends on.

**OpenStackClient** (library target, no MCP knowledge)
- Does: authenticates with an application credential, resolves endpoints from the catalog, negotiates API versions, performs typed requests, maps errors, retries.
- Used as: `let cloud = try await OpenStackClient(config: cloudConfig, credential: appCred)`; then `cloud.compute(region:).listServers(filters:)`, `cloud.network(region:).createRouter(spec)`.
- Depends on: AsyncHTTPClient, swift-nio-ssl, swift-log, swift-metrics, Yams, swift-crypto.

**ResourceCatalog** (in OpenStackMCPServer)
- Does: declares every resource the server manages: service, verbs, actions, links, create and update JSON schemas, list filters, id and name fields, status field and terminal states, safety flags.
- Used as: tools look up a descriptor by resource name and dispatch through it; `os_describe` renders it; the access-rules generator walks it.
- Depends on: OpenStackClient service protocols.

**ToolRegistry**
- Does: builds the MCP `Tool` list from the catalog and policy, decodes arguments, runs handlers, formats results.
- Depends on: ResourceCatalog, Policy, NameResolver, Waiter, MCP SDK types.

**SessionRegistry and Principal** (in HummingbirdMCP plus OpenStackMCPServer)
- Does: creates one SDK `Server` and `StatefulHTTPServerTransport` per MCP session, binds the session to a principal, evicts idle sessions, zeroizes credentials.
- Depends on: MCP SDK, Hummingbird.

**HummingbirdMCP** (library target, reusable, no OpenStack knowledge)
- Does: converts Hummingbird requests to SDK `HTTPRequest`, SDK `HTTPResponse` to Hummingbird responses including SSE streaming, hosts the session registry, exposes a `MCPRoute` you mount on a router with a server factory closure.
- Depends on: Hummingbird, MCP SDK.

**Executable `openstack-mcp`**
- Subcommands: `serve` (HTTP), `stdio`, `check`, `access-rules`, `tools`. See section 11.3.

## 6. Authentication and authorization

Two independent layers. The MCP spec forbids passing a client's bearer token through to upstream APIs; the design honors that because the upstream credential is a Keystone token the server obtains itself.

### 6.1 Layer 1: MCP client to server

**HTTP mode (default, `auth.mode = application_credential`)**

- The client sends `Authorization: Bearer <application_credential_id>:<application_credential_secret>` on every request. Keystone credential IDs are 32 hex characters and never contain a colon, so the server splits on the first colon only; secrets may contain colons.
- The client may send `X-OpenStack-Cloud: <name>` to choose among configured clouds. If absent, the configured `default_cloud` is used. The client never supplies `auth_url`; only server configuration names clouds. This keeps the server from being an open proxy to arbitrary Keystones.
- On the `initialize` request the server authenticates the credential against the chosen cloud's Keystone. Failure returns HTTP 401 with `WWW-Authenticate: Bearer error="invalid_token"` and no session. Success creates the session and binds it to a SHA-256 fingerprint of `cloud + credential id + secret`.
- Every later request on that session must present a credential with the same fingerprint, otherwise 401. This prevents session hijacking with a stolen session ID alone.
- The secret is held in memory only, inside the principal, for re-authentication when the Keystone token nears expiry. It is never logged, never written to disk, and is overwritten with zeros when the session ends.
- Rate limiting: failed authentications per source IP are limited (default 10 per minute), then 429.

**stdio mode**

- Per the MCP spec, stdio servers read credentials from the environment. The server accepts `OS_CLOUD` with a `clouds.yaml` entry that uses `auth_type: v3applicationcredential`, or the trio `OS_AUTH_URL`, `OS_APPLICATION_CREDENTIAL_ID`, `OS_APPLICATION_CREDENTIAL_SECRET` (plus optional `OS_REGION_NAME`, `OS_INTERFACE`, `OS_CACERT`).
- One principal for the process lifetime. Logs go to stderr only; stdout carries MCP messages only.

**Phase 2 options (designed for, not built in phase 1)**

- `auth.mode = static_tokens`: a server-side map from opaque bearer tokens to `clouds.yaml` profiles, for clients that cannot carry a two-part credential.
- `auth.mode = oauth`: the server acts as an OAuth 2.1 resource server. The SDK already ships `BearerTokenValidator` and `ProtectedResourceMetadataValidator`; the server would serve `/.well-known/oauth-protected-resource`, validate audience-bound tokens from an external authorization server (Keycloak or similar), and map the token subject to a stored application credential in a secret store. Requires a secret store, so it is out of phase 1.

### 6.2 Layer 2: server to OpenStack

- `POST /v3/auth/tokens` with `methods: ["application_credential"]` and `application_credential: {id, secret}`. Application credentials are always project scoped, so the response carries the project, roles, and service catalog.
- Token lifetime comes from `expires_at`. The principal refreshes at 80 percent of lifetime or on the first 401 from any service, at most once per request. A second 401 fails the tool call with an authentication error and marks the session for re-initialization.
- One Keystone token serves all regions of a cloud; region only selects endpoints from the catalog.
- The principal exposes `whoami`: application credential name and ID, project, domain, roles, `expires_at`, `unrestricted`, `access_rules`, and the regions and services present in the catalog. Application credentials can read their own definition through `GET /v3/users/{user_id}/application_credentials/{id}`.

### 6.3 Least privilege with Keystone access rules

Application credentials support access rules (`service`, `method`, `path`, with `*` for one segment and `**` for many). The resource catalog knows every path and method each tool uses, so the server can emit rules:

```
openstack-mcp access-rules --mode read-only            # GET rules only
openstack-mcp access-rules --mode operator             # everything phase 1 uses
openstack-mcp access-rules --services compute,network  # subset
```

Output is the JSON list Keystone expects for `openstack application credential create --access-rules`. The `check` subcommand compares the rules on the presented credential against what the enabled tools need and reports the gaps. Note that services must set `service_type` in their keystonemiddleware config for rules to be enforced; the report says so when a cloud does not enforce them.

### 6.4 Server-side policy

Configuration, evaluated before any tool runs and reflected in `tools/list`:

- `policy.read_only: true` registers only read-only tools (`os_list`, `os_get`, `os_describe`, `os_topology`, `os_find`, `os_whoami`, `os_quota`, `os_clouds`, `os_wait`).
- `policy.deny_resources: [user, project, domain]` removes resources from the catalog for this deployment. Identity administration resources are denied by default.
- `policy.deny_verbs: {server: [delete]}` removes verbs per resource.
- `policy.deny_actions: {server: [evacuate]}`.
- `policy.max_list_limit` (default 200) caps `limit` on list tools.

Policy is defense in depth on top of Keystone roles and access rules, not a substitute.

## 7. Sessions and transport hosting

### 7.1 Streamable HTTP on Hummingbird

The MCP endpoint is one path (default `/mcp`) handling POST, GET, and DELETE per the 2025-11-25 transport rules.

Request flow inside the `HummingbirdMCP` adapter:

1. Middleware collects the body (limit `server.max_body_bytes`, default 1 MiB), runs the bearer authenticator, and attaches the principal candidate to the request context.
2. The route builds an SDK `HTTPRequest(method:headers:body:path:)`.
3. `SessionRegistry` (an actor) looks up `Mcp-Session-Id`.
   - Present and known: verify the credential fingerprint, touch `lastAccessedAt`, forward to that session's `transport.handleRequest`.
   - Absent and the body is a JSON-RPC `initialize`: authenticate the principal against Keystone, create `StatefulHTTPServerTransport` with the configured validation pipeline, create an SDK `Server` via the factory (which registers tools bound to the principal), `server.start(transport:initializeHook:)`, then forward the request. The transport assigns the session ID and returns it in the response header.
   - Absent otherwise: 400 with a JSON-RPC error.
   - Present but unknown or expired: 404, so the client re-initializes.
4. The SDK `HTTPResponse` maps to Hummingbird: `.accepted` to 202, `.ok` to 200, `.data` to 200 with `application/json`, `.stream` to 200 with `text/event-stream`, `Cache-Control: no-cache`, `X-Accel-Buffering: no`, body `ResponseBody(asyncSequence:)` over the stream's `Data` chunks, `.error` to its status with the JSON-RPC error body.
5. DELETE terminates the session: `server.stop()`, transport disconnect, principal zeroized, 200.

Validation pipeline (SDK validators, in order): `OriginValidator` with configured `server.allowed_origins` (default: localhost only, a present invalid `Origin` is 403), `AcceptHeaderValidator(.sseRequired)`, `ContentTypeValidator`, `ProtocolVersionValidator`, `SessionValidator`.

Session limits: `session.idle_ttl` (default 30 min), `session.max_lifetime` (default 12 h), `session.max_sessions` (default 500), `session.max_streams_per_session` (default 4). A cleanup task runs every minute. Eviction behaves like DELETE.

The `initializeHook` records the client's name, version, and capabilities on the session, in particular whether it supports elicitation, which changes how `os_delete` confirms (section 8.3).

### 7.2 stdio

`openstack-mcp stdio` builds one principal from the environment, one `Server`, and the SDK `StdioTransport`. Identical tool surface. Used by Claude Desktop and by Claude Code with `claude mcp add --transport stdio`.

### 7.3 Other routes

- `GET /healthz`: process liveness, 200.
- `GET /readyz`: for each configured cloud, Keystone version discovery reachable within 2 s; 503 with details otherwise. Never authenticates.
- `GET /metrics`: Prometheus text format via swift-prometheus. Not authenticated by default; bind or firewall accordingly, or set `server.metrics_token`.
- `GET /.well-known/oauth-protected-resource`: phase 2.

TLS: either terminate at a reverse proxy (recommended, documented for Caddy and nginx with SSE buffering disabled) or use `HummingbirdTLS` with `server.tls.cert` and `server.tls.key`.

## 8. Tool surface

### 8.1 Tools

Every tool takes optional `cloud` and `region` arguments. `cloud` defaults to the session's cloud; a session may only address the cloud its credential authenticated against, so `cloud` is accepted for forward compatibility and must match. `region` defaults to `clouds.yaml` `region_name`, else the first region in the catalog.

| Tool | Purpose | Annotations |
|---|---|---|
| `os_describe` | Return the resource catalog: resources, verbs, actions, links, and the JSON schema for `create` and `update` of one resource or all. The model's discovery entry point. | readOnly |
| `os_clouds` | List configured clouds and their regions, interfaces, and which one the session is bound to. | readOnly |
| `os_whoami` | Principal details: credential, project, roles, expiry, access rules, catalog summary. | readOnly |
| `os_list` | List a resource with filters, `limit`, `marker`, `fields`, `fresh`. Returns items plus `next_marker`. | readOnly |
| `os_get` | Fetch one resource by `id` or `name`. Name resolution errors on ambiguity with candidates. | readOnly |
| `os_find` | Resolve a free-form identifier (name, ID, IPv4/IPv6, MAC, hostname) to matching resources across services in a region. | readOnly |
| `os_create` | Create a resource from `spec`, validated against the catalog schema. `wait: true` blocks until the resource reaches a terminal state (bounded by `timeout`). `dry_run: true` validates and returns the request body without sending. | destructive: false, idempotent: false |
| `os_update` | Patch mutable fields of a resource. `dry_run` supported. | destructive: false, idempotent: true |
| `os_delete` | Delete a resource. `dry_run: true` returns dependents that block or cascade (ports on a network, attachments on a volume). `force` maps to service-specific force flags. | destructive: true |
| `os_action` | Run a resource action: `server.start`, `server.stop`, `server.reboot`, `server.resize`, `volume.extend`, `image.set_visibility`. Parameters validated per action. | destructive per action (table 8.6) |
| `os_attach` | Create a link between two resources (section 8.7). | destructive: false |
| `os_detach` | Remove a link. | destructive: true |
| `os_topology` | Connectivity graph around an anchor: server, network, router, subnet, port, or floating IP. Includes security group rules applied at each port and the external gateway path. | readOnly |
| `os_wait` | Poll a resource until `status` is in `until` (defaults to the catalog's terminal states) or `timeout` (default 300 s). Emits MCP progress notifications when the client sent a progress token. | readOnly |
| `os_quota` | Quota and usage for compute, network, block storage. `update` requires admin and is gated by policy. | readOnly for read |

Phase 1 registers 15 tools. Read-only mode registers 9.

### 8.2 Argument conventions

- `resource` is a string enum generated from the catalog (`server`, `flavor`, `keypair`, `network`, ...). The `inputSchema` lists the enum so the model sees valid values without a round trip.
- `id_or_name` accepts either. Resolution: exact ID match first, then an exact name filter through the service API, then case-insensitive match on the listed names. Two or more matches return an error listing them with IDs.
- `spec` and `patch` are objects. The tool description says to call `os_describe` for the schema. The server validates against the catalog JSON schema before sending and returns the failing path, the expected type, and the relevant schema fragment on error so the model can self-correct in one turn.
- `filters` is an object of service filter names passed through (`status`, `name`, `network_id`, `device_id`). Unknown filters are rejected with the list of known ones.
- `fields` projects the output to the named top-level fields to save context. Default projections per resource are defined in the catalog (a server lists `id, name, status, flavor, addresses, created`).

### 8.3 Result conventions

- Every result sets `structuredContent` to a JSON object matching the tool's `outputSchema`, and mirrors compact JSON in a text content block for clients that ignore structured content.
- List results: `{ "resource": "server", "region": "RegionOne", "count": 12, "items": [...], "next_marker": "..." }`.
- Mutations return the resulting resource plus `{ "request_id": "req-..." }` from `X-OpenStack-Request-Id` so an operator can correlate with cloud logs.
- Errors are tool execution errors (`isError: true`), not protocol errors, unless the request itself is malformed. The text is one paragraph: what failed, the HTTP status and OpenStack message, the request ID, and a hint (missing access rule, quota exceeded, dependent resources). Secrets and tokens are never included.
- `os_delete` confirmation: if the client declared the elicitation capability, the server calls `requestElicitation` with a yes/no schema describing the resource and its dependents before deleting; declining returns a non-error result stating nothing was deleted. Without elicitation, the tool relies on the client's own approval for `destructiveHint` tools and on policy. `dry_run` is always available.

### 8.4 Server instructions

The `Server` `instructions` string tells the model the workflow: start with `os_describe` or `os_find`, prefer `os_get` before mutating, use `dry_run` for anything destructive, use `os_wait` after creates and actions that return transitional states, and use `os_topology` before answering connectivity questions.

### 8.5 Resource matrix, phase 1

Verbs: L list, G get, C create, U update, D delete. Resource names are singular and match python-openstacksdk nouns.

**Identity (Keystone v3)**

| Resource | L | G | C | U | D | Notes |
|---|---|---|---|---|---|---|
| region | x | x | | | | Read from catalog; no admin CRUD in phase 1 |
| project | x | x | x | x | x | Denied by default (policy) |
| user | x | x | x | x | x | Denied by default |
| group | x | x | x | x | x | Denied by default |
| role | x | x | x | x | x | Denied by default |
| role_assignment | x | | x | | x | Grant and revoke on project; denied by default |
| domain | x | x | x | x | x | Denied by default |
| service | x | x | | | | Catalog read |
| endpoint | x | x | | | | Catalog read |
| application_credential | x | x | | | | Own credentials only; creation is impossible for a restricted credential by design |

**Compute (Nova, microversion negotiated, floor 2.79)**

| Resource | L | G | C | U | D | Notes |
|---|---|---|---|---|---|---|
| server | x | x | x | x | x | Update: name, description, metadata, tags |
| flavor | x | x | x | | x | Create and delete need admin |
| keypair | x | x | x | | x | Import public key or generate |
| server_group | x | x | x | | x | |
| availability_zone | x | | | | | |
| hypervisor | x | x | | | | Admin only |
| compute_service | x | | | x | | Update: enable, disable with reason |
| server_interface | x | | | | | Attach and detach through links |
| server_volume_attachment | x | | | | | Attach and detach through links |
| quota (compute) | | x | | x | | |

**Network (Neutron, extensions discovered)**

| Resource | L | G | C | U | D | Notes |
|---|---|---|---|---|---|---|
| network | x | x | x | x | x | Provider attributes when the extension exists |
| subnet | x | x | x | x | x | |
| port | x | x | x | x | x | Fixed IPs, security groups, port security |
| router | x | x | x | x | x | External gateway through links |
| floating_ip | x | x | x | x | x | Association through links |
| security_group | x | x | x | x | x | |
| security_group_rule | x | x | x | | x | Immutable in Neutron |
| address_group | x | x | x | x | x | When extension `address-group` exists |
| quota (network) | | x | | x | | |

**Block storage (Cinder v3, floor 3.44)**

| Resource | L | G | C | U | D | Notes |
|---|---|---|---|---|---|---|
| volume | x | x | x | x | x | Create from image, snapshot, or another volume |
| volume_type | x | x | x | x | x | Admin |
| volume_snapshot | x | x | x | x | x | |
| volume_backup | x | x | x | | x | Restore is an action |
| quota (volume) | | x | | x | | |

**Image (Glance v2)**

| Resource | L | G | C | U | D | Notes |
|---|---|---|---|---|---|---|
| image | x | x | x | x | x | Create registers metadata; upload from a URL the cloud can reach (`web-download` import) or from a small base64 payload; visibility, protection, and tags through actions and update |

Phase 2 adds object storage (container, object metadata), key manager (secret, secret container), load balancer (Octavia: load_balancer, listener, pool, member, health_monitor), and DNS (Designate: zone, recordset). Phase 3 adds container infrastructure (Magnum), orchestration (Heat stacks), and shared file systems (Manila). The catalog and verb tools do not change when services are added.

### 8.6 Actions, phase 1

| Resource | Action | Destructive | Notes |
|---|---|---|---|
| server | start, stop, reboot (soft, hard), pause, unpause, suspend, resume, lock, unlock, shelve, unshelve, rescue, unrescue | stop, reboot, shelve, rescue are marked destructive | |
| server | resize, confirm_resize, revert_resize | resize destructive | |
| server | rebuild | yes | Image and optional new admin password never echoed |
| server | snapshot | no | Creates an image; returns image ID |
| server | console_output (`lines`), console_url (`type`) | no | |
| server | add_security_group, remove_security_group | no | Also reachable as links |
| server | evacuate, live_migrate, migrate | yes | Admin; denied by default policy |
| volume | extend, retype, reset_status, upload_to_image, set_bootable | extend and retype no, reset_status yes | |
| volume_backup | restore | yes | Into a new or existing volume |
| image | set_visibility, protect, unprotect, add_tag, remove_tag, deactivate, reactivate | deactivate yes | |
| router | set_gateway, clear_gateway | clear_gateway yes | Also reachable as links |
| floating_ip | associate, disassociate | disassociate yes | Also reachable as links |
| compute_service | enable, disable | disable yes | Admin |

### 8.7 Links (interconnectivity)

`os_attach` and `os_detach` take `link`, `source`, `target`, and link-specific parameters. Each link names the API used, the precondition checks the server performs, and the states it waits for when `wait: true`.

| Link | Source | Target | API | Parameters | Preconditions checked |
|---|---|---|---|---|---|
| `volume` | server | volume | Nova `os-volume_attachments` (2.79 adds `delete_on_termination`) | `device`, `delete_on_termination` | volume `available` or multiattach type; server not `building` |
| `interface` | server | network, subnet, or port | Nova `os-interface` | `fixed_ip`, `port_id`, `net_id` | port unattached; network reachable in region |
| `security_group` | server or port | security_group | Nova `addSecurityGroup` or Neutron port update | | port security enabled |
| `floating_ip` | floating_ip | port (or server, resolved to its first port on a router-reachable subnet) | Neutron floating IP update `port_id`, `fixed_ip_address` | `fixed_ip` | port's subnet is reachable from the floating IP's external network through a router |
| `router_interface` | router | subnet or port | Neutron `add_router_interface` | | subnet has a gateway IP or port is free |
| `router_gateway` | router | external network | Neutron router update `external_gateway_info` | `enable_snat`, `external_fixed_ips` | network is `router:external` |
| `image` | volume | image | Cinder create from `imageRef` is a create-time link; `upload_to_image` is the reverse action | | |

`os_detach` reverses each link with the matching API. Detaching a `floating_ip` disassociates without deleting the floating IP; `os_delete` on the floating IP releases it.

### 8.8 Topology

`os_topology(anchor: {resource, id_or_name}, depth: 1..3)` returns a graph: `nodes` (resource, id, name, status, key attributes) and `edges` (link kind, source, target). Traversal rules per anchor:

- server: ports; each port's fixed IPs, subnet, network, security groups with rules; floating IPs on the ports; routers with interfaces on those subnets; each router's external gateway network; attached volumes.
- network: subnets, ports grouped by device owner, routers attached, floating IPs whose port is on the network.
- router: interfaces with subnets and networks, gateway network and external IPs, floating IPs routed through it, static routes.
- floating_ip: port, its server or device, subnet, router path to the external network.

A `diagnosis` flag adds findings: port security enabled with no ingress rule for the asked protocol, subnet without a router interface, router without gateway, floating IP associated with a port on an unrouted subnet, server in `SHUTOFF` or `ERROR`, DHCP disabled with no fixed IP. This is the substance of the `diagnose_connectivity` prompt.

### 8.9 Waiting and progress

Terminal states per resource live in the catalog (server: `ACTIVE`, `SHUTOFF`, `ERROR`, `SHELVED_OFFLOADED`; volume: `available`, `in-use`, `error`; image: `active`, `killed`; router and floating IP: `ACTIVE`, `DOWN`). `os_wait` polls with backoff from 1 s to 10 s, stops on a terminal state, an `ERROR` state (returned with the fault message), a deleted resource when waiting for deletion, or `timeout`. Progress notifications carry the current status and elapsed seconds. The MCP Tasks extension (2026-07-28 revision) is the eventual home for this; the SDK does not implement it yet, so `os_wait` is the phase 1 mechanism and the catalog's terminal-state data will carry over.

## 9. MCP resources and prompts

### Resources

- `openstack://catalog` and `openstack://catalog/{resource}`: JSON of the catalog entry, so clients can pin schema context without a tool call.
- `openstack://{cloud}/{region}/{resource}/{id}`: current JSON of one resource. Listed lazily: `resources/list` returns only the catalog resources; `resources/read` on a resource URI fetches live. Subscriptions are not supported in phase 1 (`subscribe: false`).

### Prompts

- `provision_server`: arguments `name`, `flavor`, `image`, `network`, `public` (bool), `volume_gb`. Produces the ordered plan (find, create server, wait, create floating IP, attach, attach volume) as a user message the model executes.
- `diagnose_connectivity`: arguments `from` (server), `to` (address or server), `port`, `protocol`. Directs the model to `os_topology` with `diagnosis: true` on both ends and to explain the first blocking finding.
- `audit_security_groups`: lists groups with `0.0.0.0/0` ingress on sensitive ports and unused groups.

## 10. OpenStack API handling

### 10.1 Endpoints and versions

- The service catalog from the token response provides endpoints by `service_type`, `interface`, and `region`. The resolver prefers the cloud's configured `interface` (default `public`) and reports a clear error when a region lacks a service.
- Version discovery runs once per session, region, and service on first use and is cached: Keystone `GET /v3`, Nova `GET /` version document, Cinder `GET /` (v3), Glance `GET /versions`, Neutron `GET /v2.0/extensions`.
- Microversions: the negotiator picks `min(server max, client max)` and refuses to go below the floor. A feature table (`feature -> minimum microversion`) gates optional behavior at call time, for example `delete_on_termination` at 2.79, hostname at 2.90, pinned availability zone in server bodies at 2.96, scheduler hints echo at 2.100, asynchronous volume attach returning 202 at 2.101. Nova's maximum in 2026.1 Gazpacho is 2.104; the client max tracks what the models decode. Cinder uses `OpenStack-API-Version: volume 3.x` the same way.
- Neutron features are gated by extension alias (`router`, `external-net`, `port-security`, `address-group`, `qos`, `trunk`, `dns-integration`).

### 10.2 Transport

- One `HTTPClient` per cloud with that cloud's `TLSConfiguration`: `cacert` sets trust roots, `verify: false` sets `certificateVerification = .none` for that cloud only. HTTP/2 when offered. Connection pool sized by `client.max_connections_per_host` (default 16).
- Headers: `X-Auth-Token`, `OpenStack-API-Version` or `X-OpenStack-Nova-API-Version` as negotiated, `Accept: application/json`, `User-Agent: openstack-mcp/<version>`, and a generated `X-OpenStack-Request-Id` (client side, for correlation) on every request.
- Timeouts: connect 10 s, request 60 s default, per-call override for long operations (image upload).
- Retries: GET, HEAD, and idempotent deletes retry up to 3 times with exponential backoff (1 s base, 60 s cap, jitter) on connection errors, 429 (honoring `Retry-After`), 502, 503, 504. POST is not retried except after a single re-authentication on 401.
- Pagination: Nova and Cinder `limit` and `marker`; Neutron `limit`, `marker`, and `_links`; Glance `next`; Keystone `links.next`. `os_list` exposes one shape regardless.

### 10.3 Errors

`OpenStackError { service, status, code, message, requestID, retriable, hint }`. Service error bodies differ (Nova `{"itemNotFound": {"message"}}`, Neutron `{"NeutronError": {"type", "message"}}`, Cinder `{"badRequest": {"message"}}`, Keystone `{"error": {"code", "message"}}`, Glance plain text) and are normalized. 403 on a credential with access rules adds the hint "the application credential's access rules do not allow METHOD PATH; regenerate with `openstack-mcp access-rules`".

### 10.4 Caching

In-memory, per principal, per region, per resource, actor-isolated. TTLs from configuration with defaults taken from Substation's guide: catalog and version documents 1800 s, flavors, images, networks, subnets, security groups 300 s, servers, ports, volumes, floating IPs 60 s, and no caching for `get` after a mutation on the same resource within the session. Any mutation invalidates the list cache for its resource and for linked resources (attaching a volume invalidates server and volume lists). `fresh: true` bypasses. Memory bound: `cache.max_entries_per_session` (default 2000), least recently used eviction.

## 11. Configuration and CLI

### 11.1 Sources

swift-configuration with providers in priority order: command line flags, environment (`OSMCP_` prefix, `__` as separator), YAML file (`--config`, default `/etc/openstack-mcp/config.yaml`), then defaults. Clouds come from `clouds.yaml` (standard search order, or `OS_CLIENT_CONFIG_FILE`) and are referenced by name; `secure.yaml` merging is supported for `cacert` and `verify` only, since the server never stores credentials in HTTP mode.

### 11.2 Keys

| Key | Default | Meaning |
|---|---|---|
| `server.host` | `127.0.0.1` | Bind address; the spec's DNS-rebinding guidance |
| `server.port` | `8080` | |
| `server.endpoint` | `/mcp` | |
| `server.allowed_origins` | localhost origins | `Origin` allow list; `*` disables the check (not recommended) |
| `server.max_body_bytes` | `1048576` | |
| `server.tls.cert`, `server.tls.key` | unset | Enable HummingbirdTLS |
| `server.metrics_token` | unset | Bearer token required for `/metrics` when set |
| `auth.mode` | `application_credential` | `static_tokens`, `oauth` in phase 2 |
| `auth.failed_auth_per_minute` | `10` | Per source IP |
| `clouds.default` | first in `clouds.yaml` | Cloud used when `X-OpenStack-Cloud` is absent |
| `clouds.allowed` | all | Names a session may select |
| `clouds.file` | search order | Path to `clouds.yaml` |
| `session.idle_ttl` | `30m` | |
| `session.max_lifetime` | `12h` | |
| `session.max_sessions` | `500` | |
| `policy.read_only` | `false` | |
| `policy.deny_resources` | `[project, user, group, role, role_assignment, domain]` | |
| `policy.deny_verbs`, `policy.deny_actions` | `{}` | |
| `policy.max_list_limit` | `200` | |
| `client.request_timeout` | `60s` | |
| `client.max_connections_per_host` | `16` | |
| `cache.ttl.<resource>` | per section 10.4 | |
| `log.level` | `info` | |
| `log.format` | `json` | `json` or `text` |
| `log.audit` | `true` | Audit records for every mutating tool call |

### 11.3 Subcommands

- `openstack-mcp serve [--config path] [--host] [--port] [--read-only]`
- `openstack-mcp stdio [--cloud name] [--read-only]`
- `openstack-mcp check --cloud name`: authenticate with the environment's application credential, print project, roles, regions, services, negotiated versions, extensions, and access-rule gaps. Exit non-zero on failure. Used by `readyz` logic and by operators.
- `openstack-mcp access-rules --mode read-only|operator [--services a,b] [--resources x,y]`
- `openstack-mcp tools [--read-only] [--json]`: dump the tool list and schemas for documentation and for diffing across versions.

## 12. Observability and security hardening

- Logging: swift-log, JSON by default, to stdout in `serve`, stderr in `stdio`. Every log line carries `session`, `cloud`, `region`, `tool`, and `request_id` when known. A redaction layer drops `Authorization`, `X-Auth-Token`, `X-Subject-Token`, any field named `secret`, `password`, `adminPass`, or `user_data`.
- Audit: one record per mutating tool call: time, session fingerprint (not the credential), application credential ID, project ID, tool, resource, ID, outcome, OpenStack request ID.
- Metrics: `osmcp_tool_calls_total{tool,outcome}`, `osmcp_tool_duration_seconds{tool}`, `osmcp_openstack_requests_total{service,method,status}`, `osmcp_openstack_request_duration_seconds{service}`, `osmcp_sessions_active`, `osmcp_auth_failures_total{reason}`, `osmcp_cache_hits_total{resource}`.
- Hardening checklist: bind localhost unless behind TLS; origin validation on; body limit; per-IP auth rate limit; per-session tool call rate limit (`policy.max_calls_per_minute`, default 120); no `auth_url` from clients; per-cloud TLS; credential memory only, zeroized; identity admin resources denied by default; `user_data` accepted on server create but never echoed back; console URLs returned only to the requesting session.

## 13. Deployment

- Build: `swift build -c release --static-swift-stdlib` on Rocky 9 with the Swift 6.2 toolchain from swiftly. Output is a single binary plus the system TLS trust store.
- Container: multi-stage `Dockerfile` (swift:6.2 builder, `rockylinux:9-minimal` runtime with `ca-certificates`), non-root user, `clouds.yaml` mounted read-only at `/etc/openstack/clouds.yaml`, config at `/etc/openstack-mcp/config.yaml`, port 8080.
- systemd unit with `DynamicUser=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, environment file for `OSMCP_*`.
- Client setup examples in the README: Claude Code `claude mcp add --transport http openstack https://host/mcp --header "Authorization: Bearer ID:SECRET" --header "X-OpenStack-Cloud: prod"`; Claude Desktop stdio entry with `OS_CLOUD`.

## 14. Testing strategy

1. Unit tests (Swift Testing): catalog completeness (every resource has schemas, terminal states, and at least one verb), schema validation error messages, name resolution including ambiguity, error normalization per service, microversion selection and feature gating, credential parsing, redaction.
2. Fake OpenStack: a Hummingbird application in the test target that serves Keystone (`/v3/auth/tokens` with application credential validation, catalog with two regions), Nova, Neutron, Cinder, and Glance from in-memory state with microversion checks and realistic error bodies. Every catalog operation has a test against it. The fake is also runnable as `openstack-mcp-fake` for manual client testing.
3. MCP in-process tests: the SDK `Client` connected through `InMemoryTransport` to a server bound to the fake; exercises `initialize`, `tools/list` under each policy, every tool's happy path and one error path, elicitation on delete, progress on wait, resources and prompts.
4. Transport tests with `HummingbirdTesting`: session creation and fingerprint binding, missing and unknown session IDs, origin rejection, SSE stream framing, DELETE, idle eviction, body limit, auth rate limit.
5. Conformance: run the MCP Inspector and the SDK conformance client against `serve` in CI.
6. Integration (opt-in, `OSMCP_IT_CLOUD` set): a read-only pass and a create-attach-detach-delete pass on a scratch project of a real cloud, tagged resources cleaned up in `defer`.
7. Concurrency: strict concurrency enabled; a soak test with 50 concurrent sessions against the fake, checking no cross-session cache or credential leakage by asserting each session sees only its own project's resources.

## 15. Repository layout and dependencies

```
openstack-mcp/
  Package.swift
  Sources/
    OpenStackClient/        # library: no MCP dependency
      CloudConfig/          # clouds.yaml, secure.yaml, env
      Identity/             # app-cred auth, token, whoami, regions
      Transport/            # HTTPClient wrapper, retry, errors, request id
      Versioning/           # microversions, extensions, feature table
      Services/Identity Compute Network BlockStorage Image
      Models/               # Codable models per service
    OpenStackMCPServer/     # library: catalog, tools, policy, sessions, resources, prompts
      Catalog/
      Tools/
      Links/                # attach, detach, topology, diagnosis
      Policy/
      Session/
    HummingbirdMCP/         # library: reusable Hummingbird <-> MCP SDK adapter
    OpenStackMCP/           # executable: subcommands, config wiring
  Tests/
    OpenStackClientTests/
    OpenStackMCPServerTests/
    HummingbirdMCPTests/
    FakeOpenStack/          # test support target
  docs/
  deploy/                   # Dockerfile, systemd unit, Caddy and nginx snippets
```

| Dependency | Version | Purpose |
|---|---|---|
| hummingbird | 2.26.x | HTTP server, router, middleware, TLS, testing |
| modelcontextprotocol/swift-sdk | 0.12.x | MCP types, server, transports, validators |
| async-http-client | 1.36.x | OpenStack HTTP client |
| swift-nio-ssl | via async-http-client | Per-cloud TLS |
| swift-log, swift-metrics | 1.x, 2.x | Logging, metrics |
| swift-prometheus | 2.x | `/metrics` |
| swift-configuration | 1.2.x | Configuration providers |
| swift-argument-parser | 1.x | CLI |
| Yams | 5.x | `clouds.yaml` |
| swift-crypto | 3.x | SHA-256 fingerprints |

`OpenStackClient` and `HummingbirdMCP` have no dependency on each other and may be split into their own packages later without API change.

## 16. Delivery phases

**Phase 1 (this spec's implementation plan)**
1. `OpenStackClient` core: cloud config, application credential auth, catalog, version negotiation, transport, errors, fake Keystone.
2. Services and models: Identity read, Compute, Network, Block Storage, Image, with the fake for each.
3. Catalog and verb tools with policy, name resolution, validation, output shaping.
4. Links, topology, diagnosis, wait with progress.
5. `HummingbirdMCP` adapter, sessions, auth, routes, metrics; stdio mode.
6. CLI subcommands, access-rules generator, deployment assets, docs.

**Phase 2**: object storage, key manager, load balancer, DNS; `static_tokens` and `oauth` auth modes; resource subscriptions.

**Phase 3**: container infrastructure, orchestration, shared file systems; MCP Tasks once the SDK supports the 2026-07-28 revision.

## 17. Risks

| Risk | Mitigation |
|---|---|
| The SDK's HTTP transports are young (0.12) and the spec revision it implements (2025-11-25) lags the latest (2026-07-28) | Adapter isolates the SDK; version negotiation is the SDK's; conformance tests in CI catch regressions on upgrade |
| Tool count versus schema precision: verb tools push field knowledge into `os_describe` | Descriptions carry the most common fields inline; validation errors quote the schema; a phase 2 flag can generate per-resource typed tools from the same catalog if clients want them |
| Cloud diversity: extensions missing, old microversions, vendor quirks | Feature gating with clear errors; `check` reports the negotiated surface; fake covers minimum and maximum versions |
| A leaked bearer header equals a leaked application credential | Documented: use short-lived credentials with access rules and expiry; TLS required off-host; rate limits; session fingerprint binding |
| Long operations exceed client tool timeouts | `wait` bounded and resumable through `os_wait`; progress notifications |
| Context bloat from large lists | Default `limit` 50, projections, `count` and `next_marker` |

## 18. Open questions and assumptions

Assumptions made to keep moving; each can be changed before the implementation plan.

1. **Interconnectivity** is interpreted per section 3. If it was meant to include load balancers and DNS in phase 1, Octavia and Designate move up from phase 2.
2. **Bearer format** `id:secret` is acceptable for the clients in use. If a client cannot set custom headers, `static_tokens` moves to phase 1.
3. **Phase 1 service scope** is identity, compute, network, block storage, and image.
4. **Identity administration** (users, projects, roles) ships in the catalog but is denied by default.
5. **Name**: the package and executable are `openstack-mcp` until a name is chosen.
6. **Spec location**: this file lives in the home folder as requested; it is not in a git repository, so it has not been committed.
7. **Substation upstreaming**: nothing from this project is expected to flow back into Substation, though `OpenStackClient` could later replace `OSClient` if wanted.

## 19. References

- MCP specification, revision 2025-11-25: transports (https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), authorization (https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization), tools (https://modelcontextprotocol.io/specification/2025-11-25/server/tools). Latest revision 2026-07-28 (https://modelcontextprotocol.io/specification/latest).
- MCP Swift SDK: https://github.com/modelcontextprotocol/swift-sdk (tags 0.12.0, 0.12.1; server transports in `Sources/MCP/Base/Transports/HTTPServer/`; conformance server in `Sources/MCPConformance/Server/HTTPApp.swift`).
- Hummingbird 2: https://github.com/hummingbird-project/hummingbird (2.26.0), https://docs.hummingbird.codes.
- Keystone application credentials and access rules: https://docs.openstack.org/keystone/latest/user/application_credentials.html.
- OpenStack API references: https://docs.openstack.org/api-ref/identity/v3/, https://docs.openstack.org/api-ref/compute/, https://docs.openstack.org/api-ref/network/v2/, https://docs.openstack.org/api-ref/block-storage/v3/, https://docs.openstack.org/api-ref/image/v2/.
- Nova microversion history (2.104 maximum in 2026.1 Gazpacho): https://docs.openstack.org/nova/latest/reference/api-microversion-history.html.
- OpenStack releases: 2026.1 Gazpacho (https://releases.openstack.org/gazpacho/index.html), 2026.2 Hibiscus schedule.
- Substation: https://github.com/cloudnull/substation and its configuration guide https://substation.cloud/configuration/.
