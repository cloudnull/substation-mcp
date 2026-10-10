# Handoff: OpenStack MCP — v0.2.0 PRODUCTION ROLLOUT COMPLETE

## Current State

- **v0.2.0 PRODUCTION ROLLOUT COMPLETE** (2026-10-10). Deployed to sat0 Genestack
  cluster (172.16.27.67), namespace `openstack`, image
  `ghcr.io/cloudnull/substation-mcp:0.2.0`, helm release revision 22 (chart 0.2.0).
  Auth profile: **oauth** (P3 stateless OAuth 2.1 AS — HS256 JWT codes/tokens,
  deterministic DCR, memcached replay store). `keystone_token` remains as an
  explicit opt-out. Full MCP wire E2E validated live against sat0: 401 challenge,
  PRM, initialize (200 + session), tools/list (18 tools), os_whoami (admin/SAT0/
  10 services), os_list servers (5 real ACTIVE servers). External FQDN
  `https://substation.api.sat0.cloudnull.dev/v1` → 401 (auth enforced through
  TLS→Gateway→Service→pod). 607 unit tests green. IAD3 local E2E: 15 PASS /
  3 DENIED(expected) / 0 FAIL.
- **Phase 1 complete** (22 tasks + `console_url`), **three sat0 real-cloud bugs fixed**, plus
  **Phase 2/3** (7 more services), **multi-endpoint routing**, **version negotiation**,
  **P2 per-service scopes**, and the **full IAD3 gap-fill** (Trove, Gnocchi, ZaQar, Blazar,
  Freezer, Heat-CFN — 11 new catalog resources, 52 → 63) — validated against live
  Rackspace IAD3 via the local dev server.
- **Branch**: `main` (commits land directly on main; the worktree ff-merges).
- **WIP separation note**: the primary tree (`/Users/cloudnull/Projects/openstack-mcp`)
  carries in-flight Provisioning WIP (untracked `wip/` dir, modified
  `ComputeServiceTests.swift`) that is unrelated to this branch. The memcached
  replay-store work was done in an isolated worktree
  (`openstack-mcp-p3-memcached`) on `p3-memcached-replay`, based on `main` at
  `cf53ed8`, and ff-merged back. The primary tree's Provisioning WIP is
  untouched by this merge.
- **Latest commits** (newest first):
  - `deea2e5` chore(release): bump to 0.2.0 + chart default auth=oauth
  - `9c76180` fix(blockstorage): lenient Volume decode for Rackspace Cinder (IAD3)
  - `9f3d5a4` feat(oauth): memcached-backed shared authorization-code replay store (G4)
  - `de6036b` feat(provisioning): distro-aware cloud-init provisioning for os_create
  - `cf53ed8` feat(oauth): land stateless OAuth 2.1 AS as default auth profile (P3)
- **P3 OAuth re-land (this branch `p3-oauth-reland`)**: the stateless OAuth 2.1
  authorization server is restored from the P3 checkpoint (`c36a635`, `7490bed`)
  and lands on `main` as the **default** `auth.profile = "oauth"`. The server
  fronts Keystone as its own RFC 8414 AS: deterministic DCR (RFC 7591),
  authorization-code + PKCE S256, HS256-signed JWT code and `stst.at.` access
  tokens, browser consent page, loopback-redirect enforcement, and a
  DEBUG-only headless `dev-mint` endpoint. The MCP gate is a **composite
  validator**: `stst.at.` JWTs are verified in-process (issuer + expiry +
  constant-time signature compare) and their embedded Keystone token id is
  delegated to the P1 `TokenValidator`; **any other bearer token is handled
  exactly as P1** — existing `keystone_token` clients work unchanged. When
  `oauth.server_secret` is unset, the AS derives a deterministic **dev** secret
  (`"dev-" + sha256_hex("substation-oauth-dev" + issuer)`) so OAuth is
  zero-config; **production must set `oauth.server_secret` explicitly** (full
  details: `deploy/OAUTH.md`). Gaps closed during the port: G1 default profile
  flipped to `oauth`, G2 zero-config secret bootstrap (`oauthSecretResolved`),
  G3 constant-time JWT signature comparison (`constantTimeEquals`), G5 `jti`
  extraction verified (`jtiOf` in `OAuthRoutes.swift`), G6 build + full test
  suite green — the checkpoint test file had **never compiled or passed**
  against `main`, so these were required: (a) Swift-6 `init`-identifier,
  argument-order, and `headers[.location]` API fixes in `OAuthServerTests.swift`;
  (b) every E2E test URL had a double `/v1/oauth` prefix (the helper `issuer`
  already includes it); (c) `parseLocation` — the fragment branch
  (`split("#").last`) was taken even for success redirects, so no test could
  read `code` from the query string; (d) the P1 PRM test pinned to
  `auth.profile = "keystone_token"` (the PRM names the AS under the new
  `oauth` default); (e) **production fix**: RFC 8414 §2 requires absolute
  endpoint URIs in the metadata, but `metadata()` emitted relative
  `path`-based URIs — now derived from the issuer; (f) the non-loopback
  `redirect_uri` test now expects the 400 JSON error the code actually
  returns (an error redirect to an untrusted URI would leak state off-origin,
  so 400 is correct). **G4 is now CLOSED**: `CodeReplayStore` was the last
  instance-local bit of server state (single-use authorization codes). It is
  now pluggable — `oauth.replay_store: local` (default; the original in-memory
  store, single-replica) or `oauth.replay_store: memcached` (shared across
  replicas). With `memcached`, a redeemed code `jti` is recorded with
  memcached NO_OVERWRITE (`add`) so the *first* replica to redeem a code wins
  and a replay is rejected cluster-wide. The cache endpoint is resolved the
  **normal OpenStack way**: from each token's Keystone **service catalog**
  (service type `memcached`, interface preference public → internal → admin),
  exactly like Nova/Neutron — so it reaches the cloud's memcached over the
  internal network with no extra credential; `oauth.replay_store_endpoint`
  (`host:port`) overrides the catalog for non-catalog deployments. The shared
  backend is **fail-open**: any discovery/cache error degrades that one
  exchange to the instance-local store (warning log), so a memcached outage
  never breaks the OAuth flow. Implementation is a minimal in-repo text-
  protocol memcached client (`Auth/MemcachedClient.swift`, NIO, no new
  dependency). Remaining documented limitations: G8 no per-service scope
  enforcement beyond the existing coarse scopes, G9 dev-mint is `#if
  DEBUG`-gated (not compiled into release builds).
  Docs updated: spec §6.0 + config table, README auth section + config table,
  `deploy/OAUTH.md` (new + "Multi-replica deployments" section), this file.
- **Tests**: **562 tests, 0 failures** across all targets — OpenStackClientTests 242,
  OpenStackMCPServerTests 231 (was 217; +14 replay-store: local store, catalog
  endpoint discovery + override + interface preference, memcached wire
  protocol STORED/EXISTS/timeout, cross-replica single-use over one shared
  cache, fail-open on unreachable cache / missing catalog entry, config
  parse), HummingbirdMCPTests 47, OpenStackMCPTests 42,
  OpenStackMCPIntegrationTests 2. (Up from 550 pre-replay-store: +14 (3 wire-protocol tests consolidated into 1 round-trip via FakeMemcached transport seam).)
- **Catalog**: **63 resources** (52 pre-gap-fill + 11: `database_instance`,
  `database_flavor`, `database_datastore`, `metric`, `resource_type`, `queue`,
  `reservation`, `allocation`, `backup`, `schedule`, `cfn_stack`). `cfn_stack` is
  501-by-design (SigV4, not Keystone tokens).
- **Live IAD3 gap-fill status** (2026-10-08): Trove + Gnocchi fully live with real
  data; ZaQar (525 edge TLS healed 2026-10-08 ~19:00 UTC to a clean 401 unauthed,
  but origin now returns a stable 503 "service temporarily unavailable" for all
  paths incl. the authenticated `/v1/{proj}/queues` — still upstream), Blazar
  (503 backend down), Freezer (catalog points
  at a dfw3 dev host, 401) are upstream-broken — clients are wired and fake-verified,
  zero code change needed when the endpoints heal. Details in the
  "IAD3 gap-fill: six remaining services (2026-10-08)" section below.
- **os_wait transient-fetch fix deployed to sat0 and live-E2E verified 2026-10-08** —
  see the `Genestack deployment` section below (digest `ea3ae61e`, real
  ACTIVE→SHUTOFF wait observed). The E2E exposed a `timeout` vs `timeout_seconds`
  gotcha, fixed in `8749860` (`timeout` now honored as an alias).
- **Clean live compute E2E COMPLETE on Rackspace IAD3 (2026-10-08)** — the alias rollout
  is now live-verified against a full-catalog real cloud: `os_get` by UUID, `os_wait` with
  `timeout: 2` and `timeout_seconds: 2` (both → immediate on an ACTIVE server; both →
  `408 code:timeout` after 2s on a never-occurring SHUTOFF), and precedence
  (`timeout_seconds` wins over `timeout`). This surfaced + fixed a second latent bug:
  `ImageRef` didn't decode Rackspace's bare-string `image` field (500 on `os_list`/`os_get`).
  Full record + container-ops gotchas in the "2026-10-08 (cont): Clean live IAD3 compute
  E2E" section below. **sat0** clean compute E2E remains blocked on sat0 Keystone infra
  (NULL endpoint service links) — unrelated to MCP code.
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
- **`Dockerfile`**: multi-stage — builder `swift:6.4-rhel-ubi10`, runtime `registry.access.redhat.com/ubi10-minimal` (genuine Red Hat UBI10, freely pullable with no login) + EPEL (repo file written directly, no epel-release RPM in UBI repos) + the dynamic Swift runtime. Package manager is **microdnf** (no full dnf in -minimal); the base already ships libcurl/libstdc++/libssl/libnghttp2/krb5/glibc, so only `libicu` + `glibc-langpack-en` are installed. Non-root user uid 10001. `EXPOSE 8080`. `ENTRYPOINT substation-mcp serve --host 0.0.0.0 --port 8080`. Dynamic release build (static not achievable — ICU symbols).
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

## Genestack deployment (LIVE, 2026-10-03)

Deployed to the Genestack cluster at **172.16.27.67**, namespace `openstack`, image
`ghcr.io/cloudnull/substation-mcp:latest`. Auth is **token-per-request** (the server
holds no credentials; it validates each client Bearer token against the in-cluster
Keystone `keystone-api.openstack.svc.cluster.local:5000`, region `SAT0`).

External exposure (full Gateway API): FQDN **`substation.api.sat0.cloudnull.dev`** →
`substation-https` listener patched onto the shared `flex-gateway` (envoy-gateway ns) →
HTTPRoute `substation-mcp-route` → Service `substation-mcp:8080`. TLS via cert-manager
`Certificate substation-gw-tls-secret` (issuer `letsencrypt-prod`, HTTP-01 through
flex-gateway). Verified: pod 1/1 Ready, `/healthz`+`/readyz` 200, and
`https://substation.api.sat0.cloudnull.dev/v1` → `HTTP/2 401 {"error":"unauthorized"}`
(full TLS→Gateway→Service→pod→MCP-auth chain works; 401 = auth correctly enforced).

**Root cause of the long `readyz`/`connectTimeout` blocker** (pod stuck 0/1 for 2h while
curl reached Keystone in ~8ms): the helm chart default
`client.max_connections_per_host: 0`. AsyncHTTPClient treats `0` as "open ZERO HTTP/1.1
connections to the host", so every request waited forever for a connection that was never
created (`/proc/nent/tcp` showed no SYN ever sent, ELG threads idle). Fixed: chart default
0→16 + `Transport` clamps the soft limit to `>= 1` (commit `209df54`). The nsswitch.conf,
30s connect timeout, and explicit `MultiThreadedEventLoopGroup` changes (commit `b300c14`)
were correct hardening but NOT the cause.

**LIVE E2E — os_wait transient-fetch fix: PASS (2026-10-08).** After the fix landed
(`1700132` — the waiter treats only a *confirmed* `404` as "gone"; every other fetch
error is transient and retried until `timeout_seconds`), the sat0 deployment was
restarted and confirmed running final image digest **`ea3ae61e`** on pod
`substation-mcp-6cfc8cfd99-46mdp`. A real authenticated Streamable-HTTP session
(Keystone admin token minted in-cluster, client run from the sat0 host against the
pod IP) exercised `os_wait` live:
- **`WAIT-ACTIVE`** on an already-ACTIVE server returned **immediately** (no-op case).
- **`WAIT-SHUTOFF`** tracked a real **ACTIVE → SHUTOFF** transition across **5 polls**
  and returned `SHUTOFF` (a genuine state change, not a timeout artifact).

Contract validated end-to-end: confirmed `404` = gone; non-`404` fetch errors =
transient retry; persistent transient errors = **timeout**, never a spurious
`itemNotFound`. **Gotcha pinned:** `os_wait`'s timeout param is **`timeout_seconds`**
(default 120) — a `timeout` key was **silently ignored**; `8749860` added `timeout`
as an honored alias (when both are sent, `timeout_seconds` wins). Second gotcha:
`os_wait`'s `id` is passed **raw to the service API — no name resolution** (unlike
`os_get`/`os_list`), so a server *name* gets a confirmed 404 → `itemNotFound`;
resolve the UUID first.

**REMAINING / BLOCKED**: volume-lifecycle E2E is blocked on sat0 Cinder — no usable
`cinder-volume` backend (`lvmdriver-1` / LVM) is configured, so real volume create/attach
cannot be exercised. The in-process data-plane is covered by the full suite
(461 tests, 0 failures). The `timeout` alias (`8749860`) is merged but not yet on the
sat0 image — the next CI build + `kubectl rollout restart` picks it up; no behavior
change for correct callers.

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

## IAD3 gap-fill: six remaining services (2026-10-08)

Goal: cover **all** remaining IAD3-available services. Before: 52 catalog resources
(compute/network/volume/image/object/identity/key-manager/load-balancer/placement/
container-infra/orchestration + fake). After: **63** (+11).

### What was added (new files unless noted)

- **Clients** (`Sources/OpenStackClient/Services/` + `Models/`):
  - `DatabaseService` / `DatabaseModels` (Trove, service type `database`) — instances
    (full lifecycle L/G/C/D + actions resize/reboot/rebuild), flavors, datastores.
  - `MetricService` / `MetricModels` (Gnocchi, `metric`) — metrics (list/get/create),
    resource types.
  - `MessagingService` / `MessagingModels` (ZaQar, `messaging`) — queues, name-keyed
    (get/list/create/delete); read-only otherwise (no message-body API).
  - `ReservationService` / `ReservationModels` (Blazar, `reservation`) — reservations
    (L/G/C/D) + allocations.
  - `BackupService` / `BackupModels` (Freezer, `backup`) — backups + schedules.
- **Catalog entries** (`Sources/OpenStackMCPServer/Catalog/`): `DatabaseEntries`,
  `MetricEntries`, `MessagingEntries`, `ReservationEntries`, `BackupEntries`,
  `CloudFormationEntries` (+ 11 `ResourceDescriptor`s, `Service` enum cases +
  raw-string mappings in `ResourceDescriptor.swift`).
- **Dispatch**: `NameResolver` — get/list/create/update/delete/actions for all six
  (CFN = 501). **Waiter**: `database_instance` + `reservation` pollable by `status`;
  metric/messaging/backup/cfn = honest 501.
- **Fakes** (`Sources/FakeOpenStack/`): `DatabaseFake`, `MetricFake`, `MessagingFake`,
  `ReservationFake`, `BackupFake` + `SharedState` storage + `FakeApp`/`KeystoneFake`
  routes and catalog endpoints, so every path is unit-tested offline.
- **Tests**: `Tests/OpenStackClientTests/Iad3GapFillServiceTests.swift` (5 client
  lifecycle tests against the fake cloud) + `CatalogCompletenessTests` updated
  (63 total / 11 new).

### Endpoint strategies (the per-service gotchas)

- **Trove** (`database`): catalog URL already carries `/v1.0/<project>` →
  `serviceRoot = ""`, `basePath = ""`. Project already injected by Keystone.
- **Gnocchi** (`metric`): catalog URL is the host root (no `/v1`) →
  `serviceRoot = "v1"`. (Same trap as Neutron: Rackspace's Gnocchi catalog entry has
  no version path; the client must supply `/v1`.)
- **ZaQar** (`messaging`): catalog URL is the host root → `serviceRoot = "v1"`, and
  the path is built from scratch as `<project>/queues` — the token's project id is
  injected by the resolver.
- **Blazar** (`reservation`): catalog URL carries `/v1` → `serviceRoot = ""`,
  `basePath = ""` (catalog is authoritative, like Heat).
- **Freezer** (`backup`): catalog URL is the host root → `serviceRoot = "v1"`.
- **Heat-CFN** (`cloudformation`): **501 by design.** IAD3's heat-cfn endpoint
  (`https://cloudformation.api.iad3.rackspacecloud.com/v1`) authenticates with
  **AWS SigV4** request signing, not Keystone bearer tokens — the existing token
  transport cannot speak it. `cfn_stack` is registered in the catalog so it shows
  up in `os_describe`/enums, but dispatch returns an honest
  `501 "CloudFormation uses AWS SigV4 signing, not Keystone tokens; not supported
  in phase 1"`. (Same pattern as the phase-1 identity resources.)

### New IAD3 quirk handled (lenient decode, same family as Nova/Cinder/Barbican)

- **Trove flavor lists return `id: null`.** The real UUID lives in `str_id` (or the
  `links[self].href` last path segment). `DatabaseFlavor.init(from:)` now derives
  `id` in order: `str_id` → self-link href → `id` → `""`. Without this, `os_list
  database_flavor` 500s with `keyNotFound: id`. (Verified: 17 flavors return after
  the fix.)

### Live IAD3 validation (2026-10-08, via the local dev server + curl MCP wire)

| Resource | Live result | Layer |
|---|---|---|
| `database_instance` | `count: 0` (none in project) | ✅ reachable |
| `database_flavor` | `count: 17` (after str_id fix) | ✅ reachable |
| `database_datastore` | `count: 1` (mysql) | ✅ reachable |
| `metric` | `count: 200` (real metrics) | ✅ reachable |
| `resource_type` | `count: 24` | ✅ reachable |
| `queue` | `525` at edge healed (now `401` unauthed, correct edge auth behavior); origin returns stable `503` for all paths incl. authed `/v1/{proj}/queues` (verified 5× with fresh subject tokens, 2026-10-08 ~19:25 UTC) | ⚠️ upstream origin down |
| `reservation` | `503` (backend down; flapped 404 earlier) | ⚠️ upstream |
| `allocation` | `503` | ⚠️ upstream |
| `backup` | `401` (catalog → dfw3 dev host) | ⚠️ wrong endpoint |
| `schedule` | `401` | ⚠️ wrong endpoint |
| `cfn_stack` | `501` (SigV4) | by design |

**ZaQar 525 / Blazar 503 are NOT our bug.** Direct `curl` to the catalog endpoints
with the subject token (no substation in the loop) reproduces them identically:
- ZaQar: `GET https://zaqar.api.iad3.rackspacecloud.com/` with **no token** returns
  525 — it fails independent of auth/path/project. 525 = the Rackspace edge failed
  the TLS session with the ZaQar origin pod. **Update (2026-10-08 ~19:00 UTC):** the
  525 edge-TLS failure healed — the unauthed probe now returns a clean `401`
  (correct edge auth behavior) and the authenticated request reaches the origin
  (`x-openstack-request-id` present, `server: cloudflare`, no more TLS handshake
  failure) — but the origin itself answers a stable `503 "The server is currently
  unavailable ... temporarily unavailable"` for every path, verified 5× over
  ~25 min with freshly minted subject tokens (list **and** create, exact client
  path `/v1/{proj}/queues`). So the ZaQar origin pod is still down/redeploying;
  the edge↔origin link is fixed, the app behind it is not.
- Blazar: `https://blazar.api.iad3.rackspacecloud.com/v1/reservations` returns a
  stable 503 whose error page says "The **Keystone** service is temporarily
  unavailable" — a mislabeled generic stack page meaning the Blazar API isn't up
  behind that hostname. Earlier it 404'd (web server, no routes) — i.e. it's
  flapping/redeploying.

**When those endpoints heal, zero client code changes are needed** — the request
shapes are standard (verified against the fakes) and the catalog URLs are already
correct. The clients are fully wired and fake-tested today.

### Rebuild + restart (Apple container gotchas re-confirmed)

- `container rm` refuses a running container → `container stop` first. Note this
  container was previously created `--rm`, so `stop` **destroys** it; recreate with
  `container run --name substation-mcp -c 4 -m 4g -p 8080:8080 -v <worktree>:/work
  swift:6.4-rhel-ubi10 /work/.build/debug/substation-mcp serve --config
  /work/dist/rackspace-iad3/config.yaml`.
- `dist/` is gitignored (clouds.yaml + config.yaml are local-only, bind-mounted at
  `/work/dist/rackspace-iad3/`).
- **The MCP client (Cline) session expires on server restart** — re-init or the
  `substation__` tools 401 with "session not found or expired". Curl-based MCP
  handshake (initialize → `mcp-session-id` → `tools/call`) works without touching the
  client and is how the live validation above was done.

## 2026-10-08: Clean live sat0 compute E2E — blocked by sat0 Keystone endpoint-table corruption (infra, not MCP code)

The alias rollout is functionally complete and live-verified. The "clean live compute E2E" (os_get / os_wait against real Nova) is **blocked at the sat0 Keystone**, not in substation-mcp. Full investigation record:

### What was tried and found (sat0 host `172.16.27.67`, pod `substation-mcp-5745b679-f7vdl`, digest `7849feacc`)
1. **The `no compute endpoint in region SAT0` error is correct server behavior, caused by an empty token catalog.** `EndpointResolver.endpoint` (Sources/OpenStackClient/EndpointResolver.swift:129) filters the *client token's* catalog by `type == "compute"` and `region == "SAT0"` (case-sensitive) and throws `code: no-endpoint` when nothing matches. With `catalog=0` it must throw.
2. **Every credential minted from the sat0 host now returns a degraded token.** Probed via public Keystone (`https://keystone.api.sat0.cloudnull.dev`):
   - admin password, unscoped → token body has `user`, `audit_ids`, `expires_at`, `issued_at`, `methods` only — **no `id`, no `catalog`, no project/domain**.
   - admin password, project-scoped → 201, **project silently dropped, catalog=0**.
   - admin password, domain-scoped → 201, `domain=Default`, `roles=[admin, reader, member, manager]`, but catalog flickered: one probe returned `catalog=10`, then 4× and 15× repeats returned `catalog=0`. Non-deterministic → suggests either an active migration on the endpoints table or an LB with mixed backends.
   - provisioned app-cred `fdd0967e…` (substation/service, the pod's own identity, from k8s secret `substation-mcp-service-identity`) → scope-less mint 201, `roles=[]`, **catalog=0**. Even the pod's own identity has no catalog now.
3. **`/v3/endpoints` (admin) shows the smoking gun**: 30 endpoint rows, all `region=SAT0`, all **`service_type=None`** (NULL service links). Catalog construction joins endpoints to services by type; with NULL types, zero endpoints can attach to any service → empty catalog for every scoped token.
4. **Pod-level confirmation**: minting via the in-cluster `keystone-api.openstack.svc.cluster.local:5000` (same path the pod's TokenValidator uses) gives the identical degraded token. A Bearer client token passes validation, then `os_get` fails with `no-endpoint` and `os_wait` reports `Last status: unknown` (transient no-endpoint retries) — exactly the observed symptoms.
5. **`os_whoami` does NOT prove the client token is healthy.** `handleWhoami` (Sources/OpenStackMCPServer/Tools/ToolRegistry.swift:520) reads `identity.whoami` — the **server's own app-cred identity** (`identity.vt`), not the request's Bearer token. Same for `os_clouds` (:534). During this investigation a live sat0 `os_whoami` returned `project:"unscoped"`, `services:{}`, `regions:[]` — the pod's identity token itself is now degraded. Do not use `os_whoami` output as evidence of client-token health.
6. The earlier handoff note ("Cline MCP showed `compute: [SAT0]`") was **stale**: the currently connected `substation__` MCP in this Cline environment points at a **Rackspace cloud (region IAD3)**, not sat0. It cannot serve as a sat0 E2E client.

### Conclusion
- No client-credential choice can fix this: the Keystone backends currently serve catalogs with **no endpoints bound to service types**, so no token (password any scope, app-cred) carries `compute@SAT0`.
- **Fix is on the sat0 platform side**: repair the Keystone endpoints table (re-register endpoints against services — e.g. `openstack endpoint list`/re-create, or fix the `endpoint.service_id` links / service catalog in the RDO/Genestack deployment) and verify with a domain-scoped admin mint that `catalog` ≥ 10 with `compute` region `SAT0`. Possibly a recent cloud migration/tooling left endpoints orphaned from services.
- Until then, keep: alias verified live (both `timeout: 2` and `timeout_seconds: 2` → ~2s, HTTP 408 `code: timeout`), `os_wait` transient-fetch behavior verified, 461 local tests green.

### Diagnostic gotchas worth remembering
- Keystone v3: app-creds carry a **fixed scope**; sending `"scope"` in the mint body → 400/401. Mint scope-less.
- App-cred mints may need `id` (+`user_id` for name/secret forms) — name+secret+domain alone → 400 "Expecting to find user in application credential".
- sat0 in-cluster keystone svc rejects some scoped password mints (spurious 400 "invalid JSON" per deploy README); public endpoint accepts them — but currently BOTH return empty catalogs.
- `kubectl exec POD -- curl -d <json>` works when the JSON has no shell-special chars beyond quotes; avoid embedding secrets in heredoc'd shell scripts (quoting through ssh+heredoc mangles backslashes). Host-side Python + `subprocess` kubectl is the reliable pattern.
- `os_wait.id` is not name-resolved — pass a server UUID.

### Status
- Alias rollout: **DONE** (commit `8749860`, sat0 pod verified; **clean live IAD3 E2E now done** — see next section).
- Clean live compute E2E on sat0: **STILL BLOCKED — sat0 Keystone endpoints table has NULL service links** (infra fix required).
- Volume lifecycle E2E: **BLOCKED** — sat0 Cinder has no usable backend (unchanged).

## 2026-10-08 (cont): Clean live IAD3 compute E2E — PASS on the Rackspace IAD3 environment

Per instruction to "use the IAD3 environment, as it is configured", the clean live compute
E2E was completed against the live Rackspace **IAD3** cloud via the Cline `substation__` MCP
(local `localhost:8080/v1` dev server). This supersedes the sat0-blocked E2E as the
completed rollout proof; sat0 remains blocked on its Keystone infra as above.

### What the E2E caught: the running IAD3 dev binary was STALE (pre-alias)
The local IAD3 server is an **Apple container** (`substation-mcp`, image
`swift:6.4-rhel-ubi10`) whose `/work` is a **bind mount of the `80e90` Cline worktree**
(`/Users/cloudnull/.cline/worktrees/80e90/openstack-mcp`, gitdir
`/Users/cloudnull/Projects/openstack-mcp/.git/worktrees/openstack-mcp`), launched:
`/work/.build/debug/substation-mcp serve --config /work/dist/rackspace-iad3/config.yaml`
(port 8080). That worktree was checked out at `daf83a8` — **before** the alias commit
`8749860` — so its compiled binary ignored the `timeout` alias. The E2E symptom:
`timeout: 2` on an unsatisfied wait blew **past the 60s client timeout** (alias dropped →
120s default), while `timeout_seconds: 2` correctly returned `408 code:timeout` after 2s.

### Container-ops gotchas (Apple `container` CLI)
- `container stop` on this container **destroyed it entirely** (it had been created
  `--rm`); `container start` afterwards → "container not found". Recreate with
  `container run --name substation-mcp -p 8080:8080 -v <worktree>:/work -w /work
  swift:6.4-rhel-ubi10 sh -c '... serve --config /work/dist/rackspace-iad3/config.yaml'`.
  **Do NOT pass `--rm`** if you want stop/start to work (recreated without `--rm` on
  2026-10-08).
- `container copy hostfile cont:path` did NOT reliably update files in this environment;
  use `cat file | container exec -i cont sh -c 'cat > /work/...'` (or a bind mount) instead.
- The IAD3 cloud config lives at **`<worktree>/dist/rackspace-iad3/{config,clouds}.yaml`**
  (bind-mounted into the container at `/work/dist/rackspace-iad3/`). `dist/` is
  **gitignored**, so these are local-only; the `80e90` worktree copy was used as the
  canonical source to restore it. `clouds.yaml` holds an app credential for
  `https://keystone.api.iad3.rackspacecloud.com` (region `IAD3`, `interface: public`).
- `os_whoami`/`os_clouds` report the **server's own app-cred identity**, not the client
  Bearer token (HANDOFF above) — treat them as "is the IAD3 app-cred healthy", not
  "is the client token healthy".

### Second latent bug found + fixed: `ImageRef` decode for bare-string Nova `image`
After rebuilding the IAD3 binary from current (main) sources, `os_list`/`os_get`/`os_wait`
on IAD3 returned **HTTP 500** `DecodingError.typeMismatch: Expected Dictionary, found a
string. Path: servers[0].image`. Rackspace Nova returns the server `image` field as a
**bare string id** (`"image": "<uuid>"`), whereas standard Nova (sat0) returns an object
(`{"id":..., "links":...}`). The committed `ImageRef.init(from:)` was keyed-only and
crashed on the string form — the same polymorphic-decode bug class already fixed for
`FlavorRef` in commit `3fb7621` (fresh sub-decoder per shape; never mix
`singleValueContainer` and `keyedBy` on one decoder). `ImageRef` was fixed to try a
string first, then fall back to the keyed object form, with 3 regression tests added
(bare-string `ImageRef`, full server response with bare-string image, object-form
`ImageRef`). The old IAD3 binary only "worked" because it was a stale build predating
the keyed-only `ImageRef`; a fresh build from `daf83a8`/HEAD would have broken it too.

### Final clean live IAD3 E2E (all PASS, 2026-10-08, region IAD3, server vtest1
`c2fa19dd-4f47-4094-8c84-b1cecb873a72`)
- `initialize` → session + `serverInfo substation-mcp 1.0.0`.
- `os_whoami` → full IAD3 service catalog (compute, volumev3, image, network, etc.).
- `os_get` server **by UUID** → `{status:ACTIVE, name:vtest1}` (raw-id path works).
- `os_wait timeout:2 until:[ACTIVE]` (already satisfied) → immediate `status:ACTIVE`, ~0.3s.
- `os_wait timeout_seconds:2 until:[ACTIVE]` → immediate `status:ACTIVE`, ~0.2s.
- `os_wait timeout:2 until:[SHUTOFF]` (never happens) → **`408 code:timeout` "after 2s,
  Last status: ACTIVE"** in **2.0s** — proves the `timeout` alias is honored end-to-end
  (pre-alias this hung past the 60s client timeout).
- `os_wait timeout_seconds:2 until:[SHUTOFF]` control → identical 408/2s.
- Precedence `timeout_seconds:2 + timeout:60 until:[SHUTOFF]` → honored **2**s (the
  documented key wins), elapsed 2.0s.

Tests: 502 unit tests, **0 failures** across all targets (OpenStackClientTests 237 incl.
the 3 new ImageRef tests, OpenStackMCPServerTests 176, HummingbirdMCPTests 47,
OpenStackMCPTests 42).

### Status (updated)
- Alias rollout: **DONE** — commit `8749860`; clean **live IAD3 compute E2E PASS** above
  (alias honored, precedence honored, transient/waiter behavior intact).
- `ImageRef` bare-string-image decode: **DONE** — committed alongside the E2E (see
  commit log); 3 regression tests added.
- Clean live compute E2E on **sat0**: still **BLOCKED** (sat0 Keystone NULL service
  links — infra fix required; unrelated to MCP code).
- Volume lifecycle E2E: still **BLOCKED** — sat0 Cinder has no usable backend.

---

## 2026-10-09: Rackspace IAD3 volume-decode fix — SHIPPED + E2E GREEN (handoff to next agent)

**TL;DR for the next agent:** The Rackspace IAD3 E2E gap is closed. `os_list volume`
was 500'ing because Rackspace Cinder returns non-stock JSON (minimal index rows with
no `status`/`size`, and `bootable`/`multiattach` as `"true"`/`"false"` strings). The
fix (commit `9c76180`, on `main`, pushed to `origin/main`) applies the same
lenient-decode pattern already used for `FlavorRef`/`ImageRef`. Full suite green
(607 tests), live IAD3 E2E green (15 PASS / 3 expected DENIED / 0 FAIL). **No further
code work is required.** Below is everything the next agent needs to verify, re-run,
or extend.

### What shipped (commit `9c76180`)
`fix(blockstorage): lenient Volume decode for Rackspace Cinder (IAD3)`
- **`Sources/OpenStackClient/Models/BlockStorageModels.swift`** (+23/−4):
  - `Volume.status`: `decode(String)` → `decodeIfPresent(String) ?? ""`
  - `Volume.size`: `decode(Int)` → `decodeIfPresent(Int) ?? 0`
  - New private helper `Volume.boolOrString(_:_)`: tries `Bool` first, then a
    `String` lowercased-and-compared to `"true"`; returns `nil` if the key is absent
    or neither shape. `bootable` and `multiattach` now use it (`?? false`).
  - This is the **same polymorphic/lenient-decode family** as `FlavorRef` (`3fb7621`)
    and the `ImageRef` bare-string fix. **Never mix `singleValueContainer` and
    `keyedBy` on one decoder** — always try each shape in its own `try?`.
- **`Tests/OpenStackClientTests/BlockStorageServiceTests.swift`** (+49): 3 regression
  tests — (1) minimal Rackspace index row `{id,name,links}` only → `status==""`,
  `size==0`; (2) string booleans `bootable:"true"`,`multiattach:"false"` → `true`/
  `false`; (3) stock-Cinder bool form still decodes.

### Root cause (why it broke — do not "fix" by re-tightening)
Rackspace IAD3 Cinder `volume` **LIST (index)** rows carry **only** `id`, `name`,
`links` — no `status`, no `size`. Stock Cinder (sat0) always includes them. The
**DETAIL** rows return `bootable`/`multiattach` as **strings** (`"true"`/`"false"`),
not JSON bools. The strict `Volume.init(from:)` threw `DecodingError`
(`typeMismatch: Expected Bool, found String` on `.bootable`; missing-key on
`.status`), which the MCP layer surfaced as **HTTP 500** on `os_list volume`.

### Test + build status
- **Full suite: 607 tests, 0 failures** (all targets).
- Local image rebuilt: **`ghcr.io/cloudnull/substation-mcp:local-main-volfix`**
  (digest `f4e4d860df2e`). (Other local tags present: `latest` `e21549e94639`,
  `local-main-9f3d5a4` `8c8eeae19762` — ignore those, they're older.)

### Live IAD3 E2E result (2026-10-09, region IAD3, local dev server)
- **15 PASS | 3 DENIED(expected) | 0 FAIL.** `os_list volumes` works end-to-end now.
- The **3 DENIED** are `insufficient_scope` on the write tools (`os_create`
  keypair/security_group, `os_delete` keypair) — **expected and correct**: the IAD3
  app credential is **user-scoped, not admin**, so scope enforcement is doing its
  job. `config.yaml` has `policy.read_only: false` (full 9-tool surface exposed);
  the *cloud role* is what denies writes, not the MCP policy.
- Read/discovery all PASS: `os_whoami`, `os_clouds`, `os_describe`, `os_list`
  (image/flavor/network/subnet/security_group/server/**volume**/keypair),
  `os_quota compute`, `os_find`, `os_get` server, `os_wait` server ACTIVE.

### Current environment state (as of 2026-10-09, all verified live)
- **Container** `substation-mcp` **RUNNING** on `localhost:8080` (Apple `container`
  CLI). Image `ghcr.io/cloudnull/substation-mcp:local-main-volfix`. `curl
  http://localhost:8080/v1` → **HTTP 401** (auth required = live, healthy). 4 CPU /
  1 GiB.
- **Config** (gitignored, local-only, at `dist/rackspace-iad3/`):
  - `config.yaml`: `server 0.0.0.0:8080 /v1`, `clouds.file:
    /work/dist/rackspace-iad3/clouds.yaml`, `default: rackspace-iad3`,
    `policy.read_only: false`, `max_calls_per_minute: 600`.
  - `clouds.yaml`: `region_name: IAD3`, `interface: public`,
    `auth_url: https://keystone.api.iad3.rackspacecloud.com` (BASE, no `/v3`),
    app-cred id `d15ab4a621d24277adee7dc6bdadd1b0`. **Secrets are real — do not
    print/commit.**
- **Client token** at **`/tmp/iad3_token.txt`** (269 bytes, Keystone opaque token
  `gAAAAAB...`). **Currently valid** (verified: `X-Auth-Token` → HTTP 200 from
  Keystone). **It WILL expire** — the next agent must mint a fresh one before
  re-running E2E (see recipe below).
- **HEAD** = `9c76180` on `main`, in sync with `origin/main`.

### ⚠️ Working-tree WIP — DO NOT COMMIT OR DISCARD
Unrelated **Provisioning WIP** is in the working tree and must be preserved:
- ` M Tests/OpenStackClientTests/ComputeServiceTests.swift` (modified, unstaged)
- `?? wip/` (untracked: `ProvisioningMCPTests.swift`, `README.md`, a `.patch`, a
  `.tar.gz` of untracked WIP)
- `?? .omp/` (untracked)
The `9c76180` commit contains **only** the two blockstorage files — the WIP was
deliberately left out. Do not `git add -A` / `git stash` / checkout these.

### How to re-run the E2E (recipe)
1. **Fresh token** (the old one may have expired). Mint from the IAD3 app cred:
   `POST https://keystone.api.iad3.rackspacecloud.com/v3/auth/tokens` with
   `application_credential_id` + `_secret` (from `dist/rackspace-iad3/clouds.yaml`),
   take the `X-Subject-Token` response header, write it to `/tmp/iad3_token.txt`.
2. **Server up**: `container ls` (see gotcha below) → confirm `substation-mcp`
   `running`. If not: start/recreate it against the `local-main-volfix` image with
   `dist/rackspace-iad3/` mounted at `/work/dist/rackspace-iad3/`, serving
   `--config /work/dist/rackspace-iad3/config.yaml` on port 8080. **Do NOT pass
   `--rm`** (see gotchas).
3. **Run**: `bash /tmp/e2e_validate.sh`. Read the summary line
   `Pass: N | Denied(expected): N | Skip: N | Fail: N`. Expect
   **`Fail: 0`** and **`Denied(expected): 3`**.

### E2E script notes (`/tmp/e2e_validate.sh`)
- `insufficient_scope` responses are classified as **DENIED(expected)**, not FAIL
  (this was a fix this session — previously scope denials were counted as failures).
- Server name/ID extraction for `os_get`/`os_wait` now uses a **full JSON parse**
  (`extract_full` + python `json.loads` on `items[0].id`/`.name`), not truncated
  text.
- Phases: (1) read/discovery, (2) find/get/wait, (3) write (expects DENIED). It
  auto-skips `os_get`/`os_wait` if no server is found.

### Container-ops gotchas (Apple `container` CLI) — CONFIRMED THIS SESSION
- **`container ps -a` FAILS** here: `Error: Plugin 'container-ps' not found.` Use
  **`container ls`** (alias `list`) to list containers.
- `container stop` on a `--rm` container **destroys it** (then `container start` →
  "not found"). Recreate, and **never pass `--rm`** for stop/start to work.
- `container copy`/`cp` is **unreliable** in this env; use
  `cat file | container exec -i <c> sh -c 'cat > /path'` (or a bind mount).

### Known limitations / still-blocked (not code issues)
- **Write-path E2E is NOT exercisable** with the current IAD3 credential: it lacks
  `admin`, so `os_create`/`os_update`/`os_delete`/`os_action` return
  `insufficient_scope`. To validate writes end-to-end, obtain an **IAD3 app cred
  with the `admin` role** and re-run the E2E. (The sat0 volume-lifecycle E2E is
  separately blocked — no cinder-volume daemonset on that cluster.)
- **IAD3 token is ephemeral** — any future E2E run needs a freshly minted token
  (recipe above).
- **sat0 compute E2E** remains blocked on sat0 Keystone infra (NULL service links);
  unrelated to this fix.

### Next-agent options (pick what's relevant)
1. **Nothing needed** — the volume-decode fix is complete, committed, pushed, and
   E2E-validated.
2. **Cleanup** if the local validation container is no longer wanted:
   `container stop substation-mcp && container rm substation-mcp`.
3. **Write-path E2E**: get an IAD3 `admin`-scoped cred, mint a token, re-run
   `/tmp/e2e_validate.sh`.
4. **Resuming Provisioning WIP**: preserve the unstaged
   `ComputeServiceTests.swift` and untracked `wip/` + `.omp/` (see ⚠️ above).
5. **More Rackspace decode fixes**: if another service 500s on a decode error,
   apply the lenient-decode pattern (absent field → default; string/bool polymorphic
   via a per-shape `try?` sub-decoder) — see `BlockStorageModels.swift`
   `Volume.boolOrString` for the reference implementation.

