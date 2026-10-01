# Handoff: OpenStack MCP Phase 1 — Task 19 onwards

## Current State

- **Branch**: `openstack-mcp` in worktree `/Users/cloudnull/Projects/openstack-mcp/.worktrees/openstack-mcp/`
- **Main**: up through Task 18. All tasks through 18 merged.
- **Latest commit**: Task 18: OpenStack serve app (login page, token store, PRM, wiring, CLI)
- **Tests**: 313 tests, all green (134 MCP server / 149 client / 30 HummingbirdMCP incl. 15 session + 1 soak)
- **Build**: `scripts/swift build` (Apple Container, `swift:6.4-rhel-ubi10`, native arm64, `--cpus 8 --memory 16g`)

## Immediate Next Step

**Start Task 19: Logging, redaction, audit, metrics completeness** — see plan.

## Task 18 Implementation Notes (new)

### Composition layer (`Sources/OpenStackMCPServer/`)
- `ServeApp`: builds the full Hummingbird app — `MCPRoute` (from Task-17 `HummingbirdMCP`) + `healthz`/`readyz`, `/.well-known/oauth-protected-resource` (PRM), optional bearer-gated `/metrics` (Prometheus body deferred to Task 19), `/<endpoint>/login` (GET form + POST mint).
- `CloudWiring`: shared `Transport`/`Cache`/`TokenValidator`/`OpenStackClient` assembly, used by serve, stdio, and tests. `shutdown()` calls `transport.syncShutdown()`.
- `AppTokenValidator: TokenValidating`: validates a presented token id via `TokenValidator.validate` (real Keystone GET, cached).
- `TokenStore` (actor): per-session token binding — `bind(sessionID:elicitationID:token:expiry:)`, `token(for:sessionID:)`, `zeroize(sessionID:)`. Expired tokens are evicted on read.
- `ProtectedResourceMetadata`: PRM document (RFC 9728). `resource` = `config.serverPublicURL ?? "http://\(host):\(port)"` (the server's own URL, not Keystone).
- `OpenStackMCPConfig` + `ConfigLoader`: YAML/env/CLI precedence.
- `main.swift` CLI: `serve` / `stdio` / `healthz`.

### Adapter changes (`Sources/HummingbirdMCP/`)
- `FailedAuthLimiter`: **record-on-failure** sliding-window (1-min) per-source-IP counter. First `limit` failed validations → 401; the next failure in the same window → 429. (An earlier pre-validation 429 design rate-limited *successful* concurrent sessions from the same IP and broke the soak test.)
- `clientIP`: first hop of `X-Forwarded-For` if present, else `"local"` (Hummingbird `Request` has no public peer address here).
- Login POST: on mint success → 200 HTML with the token id; on failure → **400** HTML with a *generic* error (never echoes the credential). `LoginPage` logs only non-sensitive metadata (`keystone-<status>`, `missing-app-cred-fields`).

### Transport / TokenValidator (`Sources/OpenStackClient/`)
- **`tokenOverride` semantics:** `nil` → standing token source; `""` → send **no** `X-Auth-Token` header (minting); non-empty → send that token. Minting must use `tokenOverride: ""` + explicit `Content-Type: application/json` in `extraHeaders`.
- `Transport.request` THROWS on non-2xx (it does not return the status for error codes) — `mint` handles the throw; a 2xx path returns `(status, body, requestID)`.

### Gotchas learned in Task 18
- **Fake Keystone snake_case decode:** real Keystone uses `application_credential` (snake_case) in the auth body, but Swift's *synthesized* `Decodable` expects the camelCase key `applicationCredential`. The fake's mint decode silently produced `applicationCredential = nil` → 401 `forbidden`. Fixed with an explicit `CodingKeys` mapping `case applicationCredential = "application_credential"`. **This is a durable gotcha:** any fake/test that decodes a real-service JSON body must map snake_case keys explicitly; a synthesized `Decodable` with a camelCase property name will *not* read a snake_case key (it decodes to `nil` when optional, or `keyNotFound` when not).
- **`FakeSmokeTests` malformed mint bodies (pre-existing):** two `mintBody` literals were `"methods":[...],"applicationCredential":{...}` — the `]` after `methods` closed the `identity` object, so `applicationCredential` landed in `auth`, not `identity`. The old fake's `try? decode` swallowed it (401); a stricter unknown-methods check surfaced it. Fixed the bodies to use `application_credential` inside `identity`.
- **Test-router quirk:** the first request in a fresh `app.test(.router)` context is dropped/mishandled (400 on initialize). Work around by sending a warm-up request (e.g. `GET /healthz`) in the same `test` closure before real requests.
- **50-session soak (no cross-project leak):** 50 interleaved sessions init concurrently, then each calls `os_whoami`; assert each response's `project.id` matches its own seeded project. Phase 1 serial init + phase 2 concurrent whoami avoids init-order flakiness.
- `os_whoami` tool output includes `project.id` (used by the soak leak check: `"id":"proj-one"`).

## Task 17 Implementation Notes (new)

### `HummingbirdMCP` target (OpenStack-free: imports only `MCP`, `Hummingbird`, `HTTPTypes`, `Logging`)
- `MCPRoute.install(on:prm:login:)` mounts `/v1` + legacy `/mcp` (POST/GET/DELETE), `/.well-known/oauth-protected-resource[/v1]` (GET, from the injected `prm` closure), and `/<endpoint>/login` (GET renders form, POST decodes `LoginRequest` → injected `login` minter → completion page).
- `MCPConfig` (endpoint, legacyEndpoint, allowedOrigins, maxBodyBytes, maxSessions, maxStreamsPerSession, idleTTL, maxLifetime, cleanupInterval, publicURL).
- **Token-per-request auth (spec §7.1.1/3):** Bearer parsed + validated on EVERY request via the `TokenValidating` seam (cache lives in the validator). Missing/invalid → `401 WWW-Authenticate: Bearer error="invalid_token", resource_metadata=...`. `resourceMetadataURL` is always present: `config.publicURL ?? ""` + `/.well-known/oauth-protected-resource`.
- **Scope gate:** `WriteToolGate(toolNames:)` (default empty) + `ScopeAuthorizer(servedProjects:)`. Write-gated `tools/call` → `403 error="insufficient_scope", scope="openstack:write"`; audience mismatch → `403 invalid_target`. Task 18 supplies real tool names + served projects.
- **Per-request identity:** `serverFactory: @Sendable (ValidatedIdentity) async -> Server` builds one `MCP.Server` per token; `MCP-Session-Id` per session; `SessionRegistry` actor holds server+transport+timing only (no principal). `DELETE` → `registry.terminate` (fires `terminated` callback for token zeroize) + `MCPSession.disconnect()`; subsequent requests 404.
- `Authenticator.swift`: `ValidatedIdentity`, `AnyTokenPayload`, `TokenValidating`, `ScopeAuthorizer`, `WriteToolGate`. `SessionRegistry.swift`: `MCPSession` (+ `disconnect()`), `SessionRegistry` actor. `HummingbirdMCP.swift`: `MCPRoute`, `MCPConfig`, `LoginRequest/Response`, `ConfiguredOriginValidator`, response builders.

### Gotchas learned in Task 17
- **`Server` is an actor** → `withMethodHandler` is actor-isolated; any closure building a `Server` must be `async` and `await` the handler registration. Hence `serverFactory` is `async`.
- **Name collision:** MCP SDK `HTTPRequest`/`HTTPResponse`/`HTTPValidationContext`/`HTTPRequestValidator` collide with `HTTPTypes` equivalents (the target imports both). Qualify the SDK ones as `MCP.HTTPRequest` etc. `MCPError`, `StatefulHTTPServerTransport`, validators, `SessionIDGenerator` are MCP-unique.
- **Raw-string interpolation bug (cost a test cycle):** `#"Bearer ... scope="\(required)""#` does NOT expand `\(...)` — raw `#""#` strings treat interpolation literally, so the challenge leaked the text `\(required)`. Use a normal interpolated string (`"Bearer ... scope=\"\(required)\""`). `unauthorized`/`forbiddenAudience` build their interpolation in a non-raw part.
- **DELETE must terminate the registry session, not just the transport's:** routing DELETE through the SDK transport's `handleDelete` terminates the *transport's* session and does NOT fire our `terminated` callback. Add an explicit `DELETE` branch in `handle` → `registry.terminate(id)` + `removed.disconnect()`; return a plain `200`.
- **`MCPSession.disconnect()` = `server.stop()`** (idempotent — `Server.stop` and the transport's `terminate()` are both idempotent, so double-teardown on DELETE + idle eviction is safe).
- **Hummingbird 2.26 API:** `Router<BasicRequestContext>`; `Application<RouterResponder<BasicRequestContext>>(router:)`; dynamic paths need `RouterPath("...")`; `Request.uri: URI` (has `.path`), NOT `.url`; `RequestBody` is an `AsyncSequence` of `ByteBuffer` (no public `.collect` — drain manually); 413 status is `.contentTooLarge`; `HTTPField.Name` is a **failable** `init?(_:)` (not `ExpressibleByStringLiteral`); static names `.contentType`/`.wwwAuthenticate` exist.
- **SDK transport:** `StatefulHTTPServerTransport(sessionIDGenerator:validationPipeline:retryInterval:logger:)` + `handleRequest(MCP.HTTPRequest) async -> MCP.HTTPResponse`; `.stream`/`.data`/`.ok`/`.error(statusCode:error:sessionID:extraHeaders:)`; `FixedSessionIDGenerator` pins the UUID we hand back to the client.
- **Test client:** `app.test(.router) { client in ... }`, `client.execute(uri:method:headers:body:)` with `headers: HTTPFields`, `body: ByteBuffer?`, `method: HTTPRequest.Method` (`.get`/`.post`/`.delete`).
- 15 tests: `AuthTests` (missingAuth, bogusToken, perRequestIdentity, tokenCache, insufficientScope, scopeAwareToolList, sessionRequired, deleteTerminates) + `TransportTests` (413, PRM, Origin, legacy /mcp, SSE content-type, login).

## Remaining Tasks After 17

| Task | Description |
|------|-------------|
| 19 | Logging, redaction, audit, metrics completeness |
| 20 | CLI — check, access-rules, tools, register-catalog |
| 21 | Deployment assets + README |
| 22 | Integration test (opt-in) + conformance pass + final hardening sweep |

## Services Completed (Tasks 1-12)

| Service | File | Region Type | Key Details |
|---------|------|-------------|-------------|
| Identity (Keystone) | `KeystoneService.swift` | — | Token decode, catalog, scopes |
| Compute (Nova) | `ComputeService.swift` | `ComputeRegion` | Microversion gating (2.90/2.96), actions, attachments |
| Network (Neutron) | `NetworkService.swift` | `NetworkRegion` | Extension gating, auto-assign IPs, IP conflict 409 |
| Block Storage (Cinder) | `BlockStorageService.swift` | `BlockStorageRegion` | `OpenStack-API-Version: volume 3.x` header required, actions |
| Image (Glance) | `ImageService.swift` | `ImageRegion` | `Link: rel=next` pagination, web-download import, base64 upload |
| **Facade** | **`OpenStackClient.swift`** | — | **Stateless-per-identity actor, shared Transport/Cache/TokenValidator** |
| **Catalog** | **`Catalog/*.swift`** (9 files) | — | **35 resources, 25 server actions, 7 links, JSONSchema validate(), 37 tests** |

## Task 16 Implementation Notes (new)

### Resources (`Sources/OpenStackMCPServer/Resources/MCPResources.swift`)
- URIs: `openstack://catalog` (index of all resource names), `openstack://catalog/{resource}` (one descriptor: service, verbs, id/name field, terminal states, action names, link kinds), and the live template `openstack://{cloud}/{region}/{resource}/{id}`.
- `resources/list` returns the two static catalog URIs (one per resource) + the URI **template** only (region baked from `whoami.regions.first ?? "RegionOne"`). Live instances are NOT enumerated.
- `resources/read` parses the URI into parts. `catalog` branch is static JSON; everything else is the live path: validates the cloud matches the session (`identity.cloudName`), looks up the descriptor, and calls `NameResolver.resolve` (which is project-scoped by the token). Unknown id / unknown resource / cross-cloud → a `text/plain` error content (`resourceErrorText`), never a thrown error.
- Reuses `ToolRegistry.toValue` (now internal) for JSON serialization.

### Prompts (`Sources/OpenStackMCPServer/Prompts/MCPPrompts.swift`)
- `login` (optional `cloud`): client-side mint instructions — store token at `~/.config/openstack/mcp-tokens/<cloud>.token` mode `0600`, re-run on 401; mentions the URL-mode elicitation fallback.
- `provision_server(name, flavor, image, network, public, volume_gb)`: ordered plan — find (os_find/os_get) → create server (os_create) → wait ACTIVE (os_wait) → [public: floating IP create+attach] → [volume_gb: volume create+attach]. Steps renumbered based on which options are set.
- `diagnose_connectivity(from, to, port, protocol)`: os_topology with `diagnosis: true` on both ends, then explain the first blocking finding (port-security ingress, no router interface, no gateway, ERROR/SHUTOFF).
- `audit_security_groups` (no args): list security_group + security_group_rule, flag `0.0.0.0/0` on sensitive ports and unused groups.
- Each returns a single `Prompt.Message.user(.text(text:))`. `Prompt.Message.Content.text` takes a single labeled associated value `text:` (unlike `Tool.Content.text` which is 3-ary).

### Wiring
- `ToolRegistry.makeServer()` registers `ListResources`/`ReadResource`/`ListPrompts`/`GetPrompt` via `withMethodHandler`, alongside `ListTools`/`CallTool`.
- `RequestIdentity` gained `cloudName: String`; `ToolRegistry.defaultRegion` computed property.
- The 15 tool registrations/schemas are unchanged.

### Test notes
- `ResourcesPromptsTests` (13 tests). For prompt text, match `.text(t)` (single associated value). For the provision-plan ordering check, compare `text.distance(from:to:)` offsets — `#expect(a != nil)` does NOT narrow optionals for a following line.

## Task 15 Implementation Notes (new)

### Waiter (`Sources/OpenStackMCPServer/Waiter.swift`)
- `Waiter.wait(vt, resource:id:region:until:timeout:waitingForDelete:progressToken:server:)` — polls with 1s→10s doubling backoff.
- `validStates(descriptor)` = terminal states + `ERROR` + `killed`; `until` entries must be in that set (else 400 `invalidState` listing valid states).
- **`supportsWaiting(descriptor)` guard runs before any fetch** — flavor/keypair/server_group/identity → 501 `notPollable` "not supported". Without this, a bad id on a non-pollable resource 404s and `fetchStatus` reports `exists: false` → "no longer exists" (misleading).
- Fault states (`ERROR`/`killed`) short-circuit with `fault: true`. 404 during poll → `itemNotFound` error (or success if `waitingForDelete`).
- Progress: `sendProgress(server:token:status:elapsed:)` → `Message<ProgressNotification>` (method `notifications/progress`) via `server.notify`; message = `"status: <X>, elapsed: <n>s"`.
- Pollable set: server (compute), network/subnet/port/router/floating_ip (network), volume (blockStorage), image (image). Subnet polls as hardcoded `ACTIVE` (Neutron subnets have no status field).

### Links (`Sources/OpenStackMCPServer/Links/Links.swift`)
- `LinkExecutor.attach/detach(vt, link:sourceType:source:targetType:target:params:region:wait:)`.
- 7 links: `volume`, `interface`, `security_group`, `floating_ip`, `router_interface`, `router_gateway`, `image` (rejected both directions with explanatory pointer).
- `wait: true` → after the mutation, `Waiter.wait` to the post-state (volume→in-use / available; fip→ACTIVE / DOWN; interface→ACTIVE) and embeds the wait outcome under `wait`.
- `security_group` attach/detach resolves the port (server→first port with `device_id` filter, or port directly), checks `portSecurityEnabled`, reads `port.securityGroups`, calls `updatePort(securityGroups:)`, and **verifies the response echoes the group** (500 `portUpdateIgnored` otherwise) — the fake had a real bug where the PUT parsed `security_groups` but discarded them.
- `router_interface` uses the raw `client.routerInterface(vt:method:routerID:subnetID:region:)` escape hatch (PUT/DELETE `routers/:id/add_router_interface|remove_router_interface`); rejects subnets without a gateway IP.
- `router_gateway` requires the target network to be `router:external` (400 otherwise).
- `volume` attach requires `params.device`; precondition: server not BUILD/REBUILD, volume available (or multiattach).

### Topology (`Sources/OpenStackMCPServer/Links/Topology.swift`)
- `TopologyBuilder.build(vt, anchorResource:anchorID:depth:diagnosis:diagnose:region:)` — depth clamped 1–3.
- Anchors: `server`, `network`, `router`, `floating_ip`, `subnet`, `port`. Each builds nodes (`{resource,id,name,status,...}`) and edges (`{kind, source:{resource,id}, target:{resource,id}}`).
- `routersOnSubnet` approximates router interfaces: a router "has an interface" on a subnet when it has an external gateway on a *different* network than the subnet's network. (The fake tracks the exact mapping in `state.routerInterfaces` but topology derives it from the public API.)
- Diagnosis findings: SHUTOFF/ERROR server; subnet with no router interface; router without external gateway; floating IP on an unrouted subnet; **port-rule ingress diagnosis** (`diagnosePortRule(port:rules:proto:dport:portID:)`) — when `diagnose: {protocol, port}` is given, flags a port-security-enabled port whose security groups have no matching ingress rule (proto + port range + ethertype).
- Server anchor also shows attached volumes (depth ≥ 1).

### ToolRegistry wiring
- `dispatch(params:server:)` — the `server:` param is needed for `os_wait` progress notifications.
- `handleWait` reads `_meta.progressToken` from the MCP request metadata; `handleTopology` parses the `diagnose` object (`protocol` string, `port` int).
- `os_topology` schema gained the `diagnose` property (the only Task-15 schema change).
- `NameResolver.createPublic` gained a `security_group_rule` case (field names: `security_group_id`, `direction`, `ethertype`, `protocol`, `port_range_min`, `port_range_max`, `remote_ip_prefix`).
- `public typealias NetPort = OSPort` in `Tools/ToolRegistry.swift` — used in Links/Topology. **Do not redeclare it elsewhere** (duplicate = compile error).

### Fake changes (Task 15)
- `NovaFake` action route: `noStateActions` no longer includes `os-start`/`os-stop` (they now transition state); `serverActionWithSettle` handles `os-stop`/`os-start` keys (the client sends `{"os-stop":null}`, not `{"stop":null}`).
- Two-phase settle: with `transitionDelay` set, start/reboot apply the intermediate status (REBOOT/REBUILD) immediately and settle to ACTIVE after the delay in a background task — this lets the progress test observe an intermediate status. `suppressTransitionDelay` forces instant settle.
- `setTransitionDelay(_:)` public helper (actor-isolated var can't be set from a nonisolated test context).
- `NeutronFake` PUT `/ports/:id`: parses `security_groups` as **string arrays and/or id-object arrays** (the client sends plain strings; the old compactMap dropped them) and **persists via `state.setPortSecurityGroups`** (the old code built a local copy and discarded it).
- `NeutronFake` PUT `/floatingips/:id` + `updateFloatingIP`: `port_id: null` now disassociates (the client now sends explicit nulls — see below).
- `CinderFake.volumeJSON` now emits `attachments: [{id, server_id, volume_id, device}]` — required by `os_detach volume` (the client reads `volume.attachments`).
- `SharedState` seeds (proj-one): `vol-001` (in-use, attached to srv-0001 via `att-001`), `net-001` + `subnet-001` (172.16.1.0/24), `port-002` (on net-int, device srv-0001, sg-default). `subnetIDCounter=1`, `portIDCounter=2`, `routerIDCounter=1` (createRouter → router-2).
- `FakeAllocationPool` got a `public init(start:end:)`.
- New `FakeState` members: `routerInterfaces` (+ add/remove/list), `volumeAttachments` (+ attach/detach), `attachInterface`/`detachInterface`, `setPortSecurityGroups`, `portsWithFixedIP`, `usedIPs`.
- Seed `routerInterfaces = ["router-1": ["subnet-int"]]`.

### Client changes (Task 15)
- **`Port` → `OSPort`** in `NetworkModels.swift` + all `NetworkService` signatures. Bare `Port` resolves to `NIOPosix.VsockAddress.Port` (NIOCore is publicly imported by Hummingbird). The actor `OpenStackClient` also shadows the module name, so `OpenStackClient.Port` can never work.
- `UpdatePortSpec` + `updatePort` gained `securityGroups: [String]?`.
- `OpenStackClient.routerInterface(_ vt:method:routerID:subnetID:region:)` raw escape hatch.
- `updateFloatingIP` sends explicit `"port_id":null` / `"fixed_ip_address":null` (previously omitted the keys → the fake couldn't distinguish "not provided" from "clear it").

### Test-harness changes
- `MCPTestBundle` (InProcessMCPTests.swift) now also exposes `client: OpenStackClient`, `identity: RequestIdentity`, and `mcpServer: MCP.Server` — used by the waiter progress test (direct `Waiter.wait` + `client.onNotification(ProgressNotification.self)`) and the direct-wait tests.
- New suites: `WaiterTests` (6), `LinkToolsTests` (20), `TopologyTests` (11).
- Client-test seed counts updated: networks 3, subnets 3, ports 2, volumes 2; `detachInterface` test now detaches `port-002` (the seeded srv-0001 port) instead of `port-001` (unattached).

### Gotchas learned in Task 15
- **Fake action-route matching**: `actions.first(where: { body.contains("\"" + $0 + "\"") })` — order matters. `stop` is a substring of `os-stop`, so `os-stop` must not be in `noStateActions` or the real action falls through to `default` → 400 "unknown action: os-stop".
- **`JSONValue`** has `stringValue`/`intValue`/`boolValue`/`objectValue`/`arrayValue` (no `integerValue`/`floatValue`).
- **MCP SDK `Value`** cases: `.null`, `.bool`, `.int`, `.double`, `.string`, `.array`, `.object` (NOT `.integer`/`.float`).
- **Testing `.timeLimit`** is minutes-only (`.seconds` unavailable).
- **`#expect(false, ...)`** warns — use `Issue.record`.
- **Avoid giant inline closures** in tests (type-check timeout).
- **`@Test`/`@Suite`** run in the same process — fake state is per-`FakeApp.start()`, so tests are isolated.
- **Progress test timing**: `transitionDelay(.milliseconds(4000))` so the waiter's 1s first backoff still sees the intermediate REBOOT before the 4s settle; the progress test takes ~7s.
- **Schema field names**: subnet create → `network_id`/`gateway_ip`; security_group_rule create → `security_group_id` (NOT `network`/`gateway`/`security_group`). Phase-1 subnet create does not expose `gateway_ip` — seed a no-gateway subnet via `state.createSubnet(gateway: nil, ...)` and use the **returned id** (the counter id, e.g. `subnet-2`), not the name.

## Fakes

| Fake | File | Base Path | Error Shape |
|------|------|-----------|-------------|
| Keystone | `KeystoneFake.swift` | `/keystone/v3` | `{"error":{"code","message"}}` |
| Nova | `NovaFake.swift` | `/nova` | `{"itemNotFound":{"message"}}` |
| Neutron | `NeutronFake.swift` | `/neutron/v2.0` | `{"NeutronError":{"type","message"}}` |
| Cinder | `CinderFake.swift` | `/cinder/v3` | `{"badRequest":{"message"}}` / `{"itemNotFound":{"message"}}` |
| Glance | `GlanceFake.swift` | `/glance/v2` | Plain text (`404 Not Found`) |

## Seeded Fixture Facts

- `proj-one`: `net-ext`/`net-int`/`net-001`, `subnet-ext` (10.0.0.0/24)/`subnet-int` (192.168.1.0/24)/`subnet-001` (172.16.1.0/24),
  `port-001` (10.0.0.5, unattached), `port-002` (192.168.1.77, device srv-0001, sg-default),
  `fip-001` (203.0.113.10 DOWN), `sg-default`, `router-1` (gateway net-ext, interface subnet-int),
  3 servers (srv-0001..0003, ACTIVE), `seed-vol` (available, 10GB, lvmdriver-1),
  `vol-001` (in-use, attached to srv-0001 as att-001 /dev/vdb), `img-1` (ubuntu-24.04, active, public, qcow2)
- `proj-two`: minimal — `net-two`, 1 server (srv-0004, ACTIVE)
- Volume types: `vt-1` (lvmdriver-1), `vt-2` (lvmdriver-2)
- Quotas: volume=10, gigabytes=1000, snapshots=10; network=10, subnet=10, port=50
- Service catalog: `RegionOne` has all 5 services; `RegionTwo` lacks `cinder` (volumev3)
- Cinder service type: `volumev3` (fall back to `volume`)
- Glance service type: `image`

## Key Implementation Patterns (learned from Tasks 1-11)

### Transport
- `Transport` is an **actor**, base URL = `cloud.authURL` (the host root)
- `transport.request(method:service:path:query:body:tokenOverride:extraHeaders:timeoutOverride:)`
- Path includes the service prefix: `"nova/servers"`, `"neutron/v2.0/networks"`, `"cinder/v3/volumes"`, `"glance/v2/images"`
- `basePath` parameter on each service controls the URL prefix
- `tokenOverride` = the validated token ID (presented as `X-Auth-Token`)
- `extraHeaders` for service-specific headers (e.g. `OpenStack-API-Version`)
- `syncShutdown()` is `nonisolated public` for use in `defer` blocks
- **Content-Type: application/json** is set on every request

### Cache
- `Cache` is an actor. Methods: `get(_:ttl:as:)`, `put(_:ttl:value:)`, `invalidate(resource:tokenID:region:)`
- `CacheKey(tokenID:region:resource:suffix:)`
- **Use `put` not `set`**
- List methods include `limit` and `marker` in the suffix to avoid cross-page cache hits
- TTLs: volumes 60s, images 300s, servers 60s, networks 300s

### Service Pattern
```swift
public struct XService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger

    public func region(_ region: String? = nil) -> XRegion { ... }
}

public struct XRegion: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String
    let serviceType: String
    let defaultRegion: String?

    // Every operation takes `_ vt: ValidatedToken` as first arg
    public func listXs(_ vt: ValidatedToken, filters:..., limit:..., marker:...) async throws -> [X]
    public func createX(_ vt: ValidatedToken, _ spec: CreateXSpec) async throws -> X
    // ...
    // resolveRegion(vt) is the single chokepoint: resolves region name AND
    // calls guardEndpoint(serviceType:region:vt:) to enforce no-endpoint (RF3)
}
```

### Facade Pattern (Task 11)
- `actor OpenStackClient` holds: `cloud`, `transport`, `cache`, `validator` (TokenValidator), `logger`
- **Stateless w.r.t. identity**: every op takes `ValidatedToken`
- `compute(region:)`, `network(region:)`, `blockStorage(region:)`, `image(region:)` → region structs
- `regions(vt)` → distinct regions from token catalog (ordered)
- `whoami(vt)` → `Whoami` with project/domain/roles/scopes/regions/services map
- `defaultRegion(vt)` → cloud.regionName ?? first catalog region ?? "RegionOne"
- `EndpointGuard.swift`: `guardEndpoint(serviceType:region:vt:)` throws no-endpoint if catalog lacks the service endpoint
- Each Region's `resolveRegion(vt)` is `throws` and calls `guardEndpoint` after resolving the region string
- `serviceType` per region: compute→"compute", network→"network", blockStorage→"volumev3", image→"image"
- **Fixed bug**: BlockStorageRegion/ImageRegion ignored the `region` param — now plumbed as `defaultRegion`

### Catalog Pattern (Task 12)
- `JSONValue`: Sendable enum (string/integer/float/bool/null/array/object), ExpressibleBy* literals
- `JSONSchema`: **class** (not struct) because recursive (properties/items nest schemas), `@unchecked Sendable`
- `JSONSchema.validate(_ value: JSONValue) -> [ValidationIssue]` — checks type, enum, required, nested props, array items
- `ValidationIssue`: path, expected, found, fragment (for self-correctable errors per §8.2)
- `ResourceDescriptor`: **class** (not struct) because contains `ServiceDispatch` (closures) + `JSONSchema` (recursive)
- `ServiceDispatch`: closure bundle (list/get/create/update/delete/action/link), all `@Sendable`
- `DispatchRequest`: region, filters, limit, marker, id, body, fresh
- `ResourceCatalog.phase1()` → 35 resources (10+10+9+5+1), `byName` lookup dict
- Entry files: `IdentityEntries`, `ComputeEntries`, `NetworkEntries`, `BlockStorageEntries`, `ImageEntries` — each a `static let all: [ResourceDescriptor]`
- 37 completeness tests in `CatalogCompletenessTests.swift`

### Policy + Name Resolution + Output Shaping (Task 13)
- `Policy` struct: `readOnly`, `denyResources` (default: 6 identity-admin names), `denyVerbs`, `denyActions`, `maxListLimit` (200), `maxCallsPerMinute` (120)
- `Policy.effective(catalog:)` → filtered `ResourceCatalog` (removes denied resources, subtracts denied verbs, filters denied actions)
- `Policy.toolsEnabled()` → 9 read-only tool names
- `NameResolver` actor: `resolve(vt:descriptor:idOrName:region:)` → `(id, raw)`. Resolution: exact ID → exact name filter (limit 2) → case-insensitive scan. ≥2 → `AmbiguousNameError`. 0 → 404 `OpenStackError`.
- `NameResolver` dispatches via `OpenStackClient` region methods (compute/network/blockStorage/image). Identity → 501.
- `ResultFormatting`: `project()` (field projection), `checkFilters()` (validate against descriptor), `errorParagraph()` (what/status/message/requestID/hint), `redact()` (regex-based secret/token redaction)
- `ListResult` / `MutationResult` types for result shaping
- 30 tests: PolicyTests (8), NameResolverTests (6), SchemaValidationTests (16)

### ToolRegistry (Task 14)
- `RequestIdentity` struct: Sendable — holds `vt: ValidatedToken` + `whoami: Whoami`, built at session init
- `ToolRegistry: Sendable` — holds `client`, `catalog` (policy-filtered), `policy`, `identity`, `logger`
- `ToolRegistry.makeServer()` → `MCP.Server` with `ListTools` and `CallTool` handlers
- 15 tools: os_list, os_get, os_describe, os_topology, os_find, os_whoami, os_quota, os_clouds, os_wait, os_create, os_update, os_delete, os_action, os_attach, os_detach
- Scope-aware: `visibleToolNames` → 9 read-only or 15 (with write). `dispatch()` returns 403 error for mutating tools without write scope
- `dispatch(params:server:)` routes to per-tool handlers (`handleList`, `handleGet`, `handleDescribe`, etc.)
- `handleLink`, `handleTopology`, `handleWait` implemented in Task 15 (see above)
- `NameResolver` public methods: `listPublic`, `createPublic`, `updatePublic`, `deletePublic`, `actionPublic`
- JSONValue ↔ MCP Value conversion via `convertValue`/`toValue`
- `resultText(_ obj: [String: JSONValue])` → `(String, Value)` — JSON-encodes for text, converts for structuredContent
- MCP SDK `Value` cases: `.string`, `.int`, `.double`, `.bool`, `.null`, `.array`, `.object` (NOT `.integer`)
- MCP SDK `Tool.Content.text` is a case: `.text(text:annotations:_meta:)` — the static `.text(_:)` is deprecated
- `CallTool.Result.isError` is `Bool?` (nil = success, true = error) — test with `!= true` not `== false`
- `MCP.Client.callTool(name:arguments:meta:)` → `(content: [Tool.Content], isError: Bool?)`
- `MCP.Client.listTools()` → `(tools: [Tool], nextCursor: String?)`
- **Start server before client**: `server.start(transport:)` then `client.connect(transport:)` to avoid deadlock
- **Transport shutdown**: `Transport.syncShutdown()` must be called before test ends (HTTPClient crash otherwise)
- 12 InProcessMCPTests using `InMemoryTransport.createConnectedPair()`

### Model Pattern
- `Sendable, Codable, Identifiable` for resource models
- Custom `init(from:)` + `func encode(to:)` when CodingKeys differ from property names
- **`init(from:)` must be `public`** (protocol requirement)
- **CodingKeys case names must NOT collide with stored property names** when the raw value differs (use `createdAt = "created_at"` not `created = "created_at"`)
- `CreateXSpec` structs: `Sendable` only, with `func body() -> String` for JSON construction
- JSON body: use array-of-parts + `joined(separator:)` pattern, not multi-line string interpolation

### Fake Pattern
- Manual JSON string construction (no `JSONSerialization` in hot paths)
- `arrayForValue` uses depth-tracking bracket matching (NOT `range(of: "]", options: .backwards)`)
- `extractInt` must handle unquoted numeric values (not delegate to `extractString` which only handles quoted strings)
- `extractBool` checks `hasPrefix("true")` / `hasPrefix("false")` after trimming
- `objectForKey` uses depth-tracking for nested objects
- `queryParam` uses `req.uri.queryParameters[Substring(name)]` (Hummingbird URI API)
- Custom headers: use `HTTPField.Name("...")!` constants in `FakeHeaders`
- `HTTPFields` is a struct: use `var headers = HTTPFields()` + subscript, not dictionary literal
- `Response(status:headers:body:)` takes `HTTPFields`, not `[String: String]`
- Routes: register more specific paths BEFORE less specific ones (e.g. `/images/:id/tags` before `/images/:id`)
- Seed data in `FakeState.seed()`; counters start at appropriate values to avoid collisions with seeded IDs
- **JSON array elements**: parse string-array elements explicitly (`hasPrefix("\"")`) before trying id-object extraction — `compactMap` silently drops elements that match neither form.

### Test Pattern
```swift
@Suite("X Tests") struct XTests {
    let logger = Logger(label: "test")

    private func makeSetup() async throws -> (FakeHandle, ValidatedToken, Service, CloudEntry, Cache, Transport) {
        let handle = try await FakeApp.start()
        let state = handle.state
        guard let fakeToken = await state.mintToken(credID: "fake-cred-admin", secret: "secret-admin", domain: nil, password: nil, userID: nil) else { ... }
        let tokenID = fakeToken.id
        // GET keystone auth/tokens with X-Auth-Token header → Token.decode(from:)
        // Build CloudEntry, Cache, Transport, Service
        return (handle, vt, service, cloud, cache, transport)
    }

    @Test("...", .timeLimit(.minutes(2)))
    func test() async throws {
        let (handle, vt, service, _, _, transport) = try await makeSetup()
        defer { handle.stop(); transport.syncShutdown() }
        // ...
    }
}
```

### Linux/Swift Gotchas
- `import FoundationNetworking` in tests that use `URLRequest`/`URLSession`
- `.timeLimit(.minutes(n))` not `.seconds(n)`
- `Token.decode(from: Data)` is the public decoder for Keystone token responses
- `FakeHandle.stop()` is **synchronous** (not async) — safe in `defer`
- `Transport.syncShutdown()` is `nonisolated public` — safe in `defer`
- Swift 6.4 compiler bug: avoid `if case`/`guard case` on enums with `[Int8]` payloads in actor contexts
- `String(bytes:encoding:)` expects `[UInt8]` not `[Int8]`
- JSON body construction: use explicit string concatenation or array-of-parts, not multi-line string interpolation
- **Swift string interpolation `\(array)` wraps in `[...]`** — for JSON arrays, build the string manually and use literal brackets, not `\[...\]`
- `protocol` is a Swift reserved word — use `ipProtocol` in model properties (JSON key stays `"protocol"` via CodingKeys)
- `NeutronExtensions` made `Codable` for cache storage
- `OpenStackError.normalize` checks `NeutronError` key **first** (before generic firstKey branch)
- `ipInCidr` uses numerical prefix match (string `hasPrefix` fails for CIDR comparison)
- `FakeState.extensions` is a public mutable `Set<String>`; `removeExtension(_:)` for tests
- `#expect(false, ...)` triggers a compiler warning — use `Issue.record("...")` instead in do/catch test patterns
- `getVolume` and similar single-ID methods require the `id:` argument label
- **`Substring` has no `droppingLast()`** — use `String(part.dropFirst()).dropLast()`

### Package.swift
- `OpenStackClientTests` depends on: `OpenStackClient`, `FakeOpenStack`, `HummingbirdTesting`, `Hummingbird`
- `OpenStackMCPServerTests` depends on: `OpenStackClient`, `FakeOpenStack`, `Hummingbird`, `MCP`

### Git / SDD Discipline
- Commit per task with descriptive message
- Merge to main after each task, sync worktree
- SDD ledger at `.superpowers/sdd/2026-09-28-openstack-mcp-phase-1/progress.md` (gitignored, local-only)
- Plan at `docs/superpowers/plans/2026-09-28-openstack-mcp-phase-1.md`
- Spec at `specs/openstack-mcp-spec.md`
