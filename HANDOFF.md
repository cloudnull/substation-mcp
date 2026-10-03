# Handoff: OpenStack MCP — Phase 1 + Phase 2/3 + Multi-Endpoint + Versioning COMPLETE

## Current State

- **Phase 1 complete** (22 tasks + `console_url`), **three sat0 real-cloud bugs fixed**, plus
  **Phase 2/3** (7 more services), **multi-endpoint routing**, **version negotiation**, and
  **P2 per-service scopes** — all validated against a real Rackspace sjc3 cloud.
- **Branch**: `main` (commits land directly on main; the worktree ff-merges).
- **Latest commits** (newest first):
  - `e6ed9a2` chore: gitignore `.openstack-credentials.md` (keep creds local-only)
  - `43b7b32` fix(octavia): use v2 (Rackspace) + pass token to version negotiator in stateless mode
  - `a43f08c` feat(versioning): negotiate API versions across service types (real cloud formats)
  - `2c74ac3` feat(auth): P2 per-service scopes (config-gated) + form-mode elicitation hardening
  - `6bde5b4` feat(routing): per-service multi-endpoint resolution (catalog = authoritative base)
- **Tests**: **451 tests, 0 failures** across the full suite (up from 373 at Phase 1 close).
- **15-tool invariant**: the 15 MCP verb tools are stable; new services are new *resources*.
- **Build**: `scripts/swift build` (Apple Container, `swift:6.4-rhel-ubi10`, native arm64).
- **Native image**: `scripts/build-image.sh` → `dist/substation-mcp-aarch64-ubi10-v*.tar.gz`
  (UBI10 rootfs, see `deploy/NATIVE-AARCH64.md`). Note: the current tarball predates the
  version-negotiation + octavia-v2 commits — rebuild if you need a deployable with them.
- **Conformance smoke**: `scripts/conformance.sh` (wraps the hidden `substation-mcp conformance`
  subcommand; 6-step handshake, `--read-only` for read-scoped tokens).
- **Real-cloud proof (Rackspace sjc3, 2026-10-03)**: `check` valid + versions
  (compute 2.100 / volumev3 3.70); conformance **6/6 PASS**; `os_list` for **all 5**
  services PASS (server/volume/image/secret/load_balancer); nova microversion header
  **confirmed sent** (`X-OpenStack-Nova-API-Version: 2.100`). See
  `.superpowers/sdd/version-negotiation-plan.md`.

## Backlog

- **License: MIT.** `substation-mcp` is to be licensed MIT. The `LICENSE` file has been
  added (Copyright (c) 2026 Kevin Carter). Still to do: add the license badge/section to the
  README and confirm the project rename from `substation-mcp` → `substation-mcp` is complete
  (target remote `cloudnull/substation-mcp`).

## Post-Phase-1 Work (Phase 2/3 → Versioning)

Added after Phase 1, each validated against real clouds and committed on main:

- **Phase 2/3 services** — 7 more OpenStack services wired as resources under the stable
  15 verbs: Swift (object-store), Barbican (key-manager), Octavia (load-balancer),
  Designate (dns), Magnum (container-infra), Heat (orchestration), Manila (share).
- **Multi-endpoint routing** (`6bde5b4`) — `EndpointResolver` routes each call to the
  service's real catalog endpoint (`Transport.overrideBase`). The catalog URL is the
  authoritative base; a per-service `serviceRoot` handles clouds that omit the version
  root in the catalog (Rackspace: glance→`v2`, barbican→`v1`, octavia→`v2`, cinder→`v3`,
  neutron→`v2.0`). Token-id backfill for Rackspace's whoami (which omits `token.id`).
- **Version negotiation** (`a43f08c`, `43b7b32`) — `VersionNegotiator` + per-service
  `ServiceVersionProfile`. Parses **both** the real `{"versions":[...]}` array form and the
  legacy `{"version":{...}}` object form; the `Transport` follows redirects (max 3) and
  accepts 200/300 for version-doc fetches (curl-verified Rackspace: nova `/v2.1/` → 200
  legacy-form max 2.100; cinder `/v3` → 302 → `/v3/` → 200 array-form max 3.71). Nova sends
  its negotiated microversion on every request; Cinder sends `OpenStack-API-Version: volume 3.70`.
  `check` resolves each service's endpoint before negotiating so versions print on
  multi-endpoint clouds. The `VersionNegotiator` takes a `tokenOverride` for stateless
  (serve/check) mode where the transport has no standing token source.
- **P2 per-service scopes** (`2c74ac3`) — config-gated `auth.scopes: per_service`
  (default `coarse`): a write token may mutate only services present in its own token catalog.
  Plus form-mode elicitation hardening (the login prompt advertises only URL-mode/client-mint).

### Real-cloud gotchas (Rackspace sjc3, curl-verified)
- **Token**: `.openstack-credentials.md` holds a literal user token (send as-is in
  `x-auth-token`; Keystone 3.14 also wants `x-subject-token` on whoami — the Transport sends
  both). It is **short-lived**; a fresh one + an app-cred are now in the (gitignored) file.
- **App-cred minting** must **omit the scope block** — Rackspace returns 401
  "Application credentials cannot request a scope" when one is present.
- **Octavia is v2** on Rackspace (catalog omits the version; `/v1/loadbalancers` 404s,
  `/v2/loadbalancers` 200s). MCP resource names: octavia = `load_balancer`, barbican = `secret`.
- **nova 500** was our decode bug (`listServers` needed `/servers/detail`, not `/servers`);
  **glance 300** was the version-root bug (catalog omits `/v2` → `serviceRoot: v2`).

## Real-cloud integration against sat0 (2026-10-01)

Goal: produce a native aarch64/UBI10 deployable and integrate against the local
cloud `https://keystone.api.sat0.cloudnull.dev` (read-only + conformance). No
docker on this host → the deployable is a UBI10 **filesystem-image tarball**
built with Apple `container` (aarch64, no QEMU).

Wiring to the live cloud surfaced **three latent bugs the unit suite never
caught** (tests exercise the library, not the process entry or live-wire
shapes). All three fixed TDD, all merged to main:

1. **`fix(transport): also send token as X-Subject-Token` (8961a73)** — Keystone
   3.14 on sat0 only honors the presented token on the whoami endpoint
   (`GET /v3/auth/tokens`) when it is also sent as `X-Subject-Token`;
   `X-Auth-Token` alone → 404 "No token in the request". The server-side
   `TokenValidator` relies on that endpoint, so without the header the serve
   path 401s. `Transport.request` now sends the token on **both** headers
   (standard, version-compatible).
2. **`fix(cli): wire the real entry point + correct subcommand names` (6036748)** —
   *the critical one.* The CLI types live in `main.swift` (a top-level-code
   file), so Swift does **not** synthesize `@main` for the `AsyncParsableCommand`
   root and there was no top-level `.main()` call. **Every subcommand exited 0
   with zero output for every invocation** (even a bad one) — the phase-1 CLI
   had never actually run through its real entry. Fix: `Entry.swift` (not
   `main.swift`) with an explicit `@main` wrapper. A second latent bug:
   subcommands without `commandName` fell back to `<Type>-command`
   (`serve-command`, etc.), so the documented names were unreachable — added
   `commandName` to all 7. New `CLIEntryTests` run the built binary and assert
   the entry produces output (self-skips if no binary; prefers the freshest).
3. **`fix(identity): decode real Keystone v3 token shapes` (17f09fc)** — live
   Keystone v3 whoami bodies differ from the test fixture: no top-level `id`,
   no top-level `domain` on project-scoped tokens, and `roles` as objects
   `{"id","name"}` (or a mix of strings/objects). `Token.decode` threw
   "Missing required fields in token" → serve-path 401/500. Now tolerant of all
   standard shapes (synthesizes id, falls back domain to `user.domain`, decodes
   roles via a single-value container).

Plus a conformance-smoke fix: **`fix(conformance)` (36330b8)** — the os_whoami
step wrongly required the literal tool name in the response body; a valid
`tools/call` result returns a JSON-RPC `result` envelope and never echoes the
name. Now asserts on the result envelope.

**Result — live sat0 conformance 6/6 PASS** (run in-container, read-only):
401 challenge, PRM, initialize (200 + MCP-Session-Id), tools/list (15),
tools/call os_whoami (returns real identity: project admin, region SAT0, all 9
services, roles reader/member/admin/manager/glance_admin), DELETE.

### Native aarch64 image
`scripts/build-image.sh TAG=v0.1.0` → `dist/substation-mcp-aarch64-ubi10-v0.1.0.tar.gz`
(27 MB UBI10 rootfs: binary at `/usr/local/bin/substation-mcp`, `substation-mcp`
uid 10001, `/etc/openstack*` mount points) + `.manifest.json`. See
`deploy/NATIVE-AARCH64.md`. `dist/sat0/{clouds.yaml,config.yaml,clouds-it.yaml}`
are working config templates (app-cred secret scrubbed).

### Known remaining issue (opt-in IT suite only, not in scope)
`OSMCP_IT_CLOUD=... swift test --filter IntegrationTests` read-only pass crashes
the runner at teardown: `AsyncHTTPClient … Client not shut down before the
deinit` (SIGTRAP). The read-only client calls themselves work (proven by the
`check`/whoami probes returning real data), but an `HTTPClient` created inside
the client/transport is not drained before the test process exits. CI self-skips
(this is opt-in), and the conformance smoke is the authoritative real-cloud
proof. Fixing the HTTPClient lifecycle in the IT rig is a follow-up.

## Post-completion gap closure: `console_url` (b723462)

The single spec §12 hardening item that had been explicitly dropped — *"console URLs returned only to the requesting session"* — is now implemented end-to-end (it was the only in-scope phase-1 gap; everything else is phase 2+).

- **Client** (`OpenStackClient`): new `Console` model (`{type,url}`) + `ComputeService.getConsole` / `getConsoleOutput`. These decode the `{"console":{...}}` / `{"output":...}` bodies; the generic `action()` decoded a `Server` and previously dropped the console payload.
- **Dispatch** (`NameResolver.actionPublic`): `console_url` / `console_output` route through the dedicated client paths and return the console object / output string; every other action is unchanged.
- **Fake** (`FakeOpenStack`): `NovaFake` action route handles `getVNCConsole` (200 `{"console":{...}}`) and `getConsoleOutput`; `FakeState.consoles` is a per-token map so the url is derived from the token's project + server + UUID. Each MCP session sees only the url it requested (stable on re-read, distinct across sessions) — the §12 property.
- **Tests** (+3 → 367): `ComputeServiceTests` (client-level: type+url present, token-scoped, distinct across projects) + `HardeningTests` (MCP-level `os_action` §12 assertion: two sessions' console urls differ, each references its own server).

## Task 22 Implementation Notes (new — FINAL TASK)

### Hardening sweep (`Tests/HummingbirdMCPTests/HardeningTests.swift`, 12 tests)
Pins spec §12 checklist:
- **default bind 127.0.0.1** (config default), **body limit 413**, **per-IP auth-failure 429**
- **per-token tool-call rate limit**: new `ToolCallLimiter` actor (`Sources/OpenStackMCPServer/Policy/ToolCallLimiter.swift`), sliding 60s window keyed by token id, wired into `ToolRegistry.dispatch` (returns a self-correctable `isError` tool error, not HTTP 429); `CloudWiring.makeServerFactory` shares one limiter sized to `policy.maxCallsPerMinute`
- **user_data never echoed**: stripped at the result formatter in `ToolRegistry.handleGet` (servers), in addition to the redaction layer which already covers log lines
- **metrics_token gating** (401 without / 200 with), **session.max_lifetime eviction** (`SessionRegistry.evictExpired` now drops sessions past `maxLifetime` even when within idle TTL; `MCPRoute` passes `config.maxLifetime`)
- **token-per-request**: an expired token on a live session → 401 `invalid_token` (identity is per-token, not per-session). Fake gained `expireToken(_:)` test hook; the test also invalidates the validator's token cache
- **tenant isolation** (proj-one/two never see each other's servers), **read-only mutating call → 403 `insufficient_scope`**, **login secret never stored** (TokenStore round-trip + completion page), **PRM at both canonical and endpoint-scoped URLs**
- **Origin/CORS pinned as NOT required** (MCP 2025-11-25; the bearer token is the boundary) — no Origin assertion.

### Test-infra fix (important)
The shared-transport design could not reach the fake's services: the fake served Keystone only at `<base>/keystone/v3`, so a base-URL transport couldn't validate tokens and a `/keystone`-URL transport couldn't reach `<base>/nova`. Fixed by making the fake **also serve Keystone at the root** (`/v3/auth/tokens` GET/POST as aliases of the `/keystone/v3` routes). Added `makeServeAppReachable` (base-URL cloud) to `SessionTests.swift` for full-serve tests that make real OpenStack calls. `makeServeApp` (auth-surface only) is unchanged.

### Opt-in integration target (`IntegrationTests/IntegrationTests.swift`, spec §14.6)
New SwiftPM test target `OpenStackMCPIntegrationTests` (path `IntegrationTests`). Self-skips unless `OSMCP_IT_CLOUD` is set. Pass 1 read-only (whoami, clouds, list servers/networks/volumes/images, describe). Pass 2 network-only mutation (network→subnet→port, reverse cleanup, best-effort) gated by `OSMCP_IT_MUTATE=1` so CI never mutates. Drives `OpenStackClient` directly against a real cloud.

### Conformance (spec §14.5)
- Hidden `substation-mcp conformance` subcommand (`main.swift`, `shouldDisplay: false`) drives the full Streamable-HTTP handshake with the binary as the HTTP client (`URLSession`/FoundationNetworking — no curl, which is absent from ubi10-minimal): 401 challenge, PRM shape, initialize→200+MCP-Session-Id, tools/list (15/9), os_whoami, DELETE. Exit 0/1.
- `scripts/conformance.sh` (executable) is a thin wrapper: locates the built binary and `exec`s `conformance` with the caller's args (`--url ... --token ...` or `--auth-url ... --app-cred-id ... --app-cred-secret ...`, `--read-only` for the 9-tool surface).
- README documents the conformance flow + MCP Inspector manual steps.

### Gotchas learned in Task 22
- **`OpenStackClient` is an actor** — its service accessors (`compute`/`network`/`blockStorage`/`image`) and `whoami`/`regions` need `await`.
- **`exit(Int)` in the binary**: use `Foundation.exit(code:)` (the bare `exit` resolves to the wrong overload on Linux); `await` cannot appear to the right of `??` (autoclosure) — assign to a var first.
- **SSE-framed test responses**: `tools/call` over the full-serve path returns `id: N` / `event: message` / `data: {jsonrpc...}` — extract the last `data:` line for assertions.
- The existing full-serve tests only ever exercised `os_whoami` (no real service call), which is why the transport/fake mismatch was never caught before Task 22.

## Task 21 Implementation Notes (new)

### Deployment assets (`deploy/`)
- **`Dockerfile`**: multi-stage — builder `swift:6.4-rhel-ubi10`, runtime `almalinux:10` (public RHEL10-compatible; UBI10 needs a RH subscription login CI doesn't have) + `ca-certificates` + the dynamic Swift runtime + its dnf runtime libs. Non-root user uid 10001. `EXPOSE 8080`. `ENTRYPOINT substation-mcp serve --host 0.0.0.0 --port 8080`. Dynamic release build (static not achievable — ICU symbols).
- **`substation-mcp.service`**: hardened systemd unit — `DynamicUser=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, `EnvironmentFile=-/etc/substation-mcp/env`.
- **`register-catalog.sh`**: idempotent wrapper. Mints admin token from app-cred or password if `OS_AUTH_TOKEN` unset. Required env: `OS_CLOUD`, `REGION`, `PUBLIC_URL`.
- **`caddy/Caddyfile`**: reverse proxy, `flush_interval -1` for SSE on `/v1` and `/mcp`.
- **`nginx/substation-mcp.conf`**: `proxy_buffering off; proxy_cache off;` on `/v1/` and `/mcp/`.

### README (full rewrite)
Tools table, architecture diagram, quickstart (check → register-catalog → serve → client setup), config reference (spec §11.2), all 7 subcommands, security model, observability, deployment (docker/systemd/proxy), development (fake, integration test, repo layout).

### `scripts/build.sh` fix
Attempts `--static-swift-stdlib` first, falls back to dynamic release (ICU symbols not in static link path on Swift 6.4/UBI10).

### Gotchas
- **Apple Container stdout forwarding**: child process stdout NOT forwarded to host file redirects — verify CLI output via unit tests.
- **Static build failure**: `--static-swift-stdlib` fails with undefined ICU references (`swift_ucasemap_open`, `swift_ures_open`, etc.).

## Task 20 Implementation Notes (new)

### Testable cores in `OpenStackMCPServer` + thin CLI shims in `substation-mcp`
- `CheckReport.swift`: `CheckReport.build(config:)` — connectivity (per region), `region_required` warn, `catalog_mismatch` warn (only if `server.enableCatalogChecks`).
- `AccessRule.swift`: `AccessRulesGenerator.rules(mode:project:region:services:resources:)` — read-only = 15 tools, operator = 14 non-write. `AccessRulePaths` = single source for tool → `service/resource` mapping.
- `CatalogRegistrar.swift`: idempotent per region — find-or-create `type=mcp` service, then public/internal/admin endpoints.
- `Tools/AllTools.swift`: `AllTools.tools(catalog:)` — 15 tool definitions, shared by `ToolRegistry.visibleTools()` and the `tools` dump.
- `main.swift`: 7 subcommands (serve, stdio, healthz, check, access-rules, tools, register-catalog). Exit codes: auth=1, config=2.

## Task 19 Implementation Notes (new)

### Observability (`Sources/OpenStackMCPServer/Observability/`, `Sources/OpenStackClient/Observability/`)
- **Redaction**: `Redactor.redact(_ json:) -> String` — pure JSON->JSON mask (case-insensitive keys: Authorization, X-Auth-Token, X-Subject-Token, secret, password, adminpass, user_data, token, application_credential, appcredsecret -> `[REDACTED]`; recurses; non-JSON passes through). `RedactingJSONLogHandler` writes one redacted JSON object per record to stdout/stderr (no LoggingSystem.bootstrap). `makeLogger(level:format:sink:label:)` lives in the server lib; main.swift's old local `makeLogger` deleted.
- **Audit**: one `.info` `category=audit` line per **mutating** tool call in `ToolRegistry.dispatch` (token id, project id, tool, outcome, request id, app_credential). Gated by `ToolRegistry.auditEnabled` (from `config.logAudit`). Read-only tools are not audited.
- **Metrics** (`OSMetrics` in `OpenStackClient/Observability/Metrics.swift` — placed in the client so Transport/Cache and the server both emit without an import cycle): `bootstrapMetrics()` (swift-prometheus, call once at process start) + `MetricsCollector.render()` for `/metrics`. All 7 spec §12 metric names emitted: tool_calls_total + tool_duration_seconds (ToolRegistry), openstack_requests_total + openstack_request_duration_seconds (Transport), sessions_active (MCPRoute `onSessionStart`/`onSessionEnd`), auth_failures_total{reason} (`FailedAuthLimiter.onFailure` — `"rejected"`/`"rate_limited"`), cache_hits_total (Cache.get).
- **/metrics** route (ServeApp) now returns `MetricsCollector.render()`.
- **Config**: `ConfigLoader.resolve(cli:env:yaml:)` is a pure, unit-testable precedence resolver; key mapping fixed to section-aware + acronym-aware (`port`->`server__port`, `logLevel`->`log__level`, `readOnly`->`policy__read_only`, `publicURL`->`server__public_url`); env `OSMCP_` keys lowercased on strip.

## Task 18 Implementation Notes

### Composition layer (`Sources/OpenStackMCPServer/`)
- `ServeApp`: builds the full Hummingbird app — `MCPRoute` (from Task-17 `HummingbirdMCP`) + `healthz`/`readyz`, `/.well-known/oauth-protected-resource` (PRM), optional bearer-gated `/metrics` (Prometheus body completed in Task 19), `/<endpoint>/login` (GET form + POST mint).
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
| 19 | Logging, redaction, audit, metrics completeness | done @ c6ccd74 |
| 20 | CLI — check, access-rules, tools, register-catalog | done @ 8fe26b1 |
| 21 | Deployment assets + README | done @ 1c07dd1 |
| 22 | Integration test (opt-in) + conformance pass + final hardening sweep | done @ b9f5340 |

**Phase 1 complete.** No remaining tasks.

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
- SDD ledger at `.superpowers/sdd/2026-09-28-substation-mcp-phase-1/progress.md` (gitignored, local-only)
- Plan at `docs/superpowers/plans/2026-09-28-substation-mcp-phase-1.md`
- Spec at `specs/substation-mcp-spec.md`
