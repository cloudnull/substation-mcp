# OpenStack MCP Server — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `openstack-mcp`, a Hummingbird-hosted Swift MCP server that lets an LLM client consume an OpenStack cloud (identity, compute, network, block storage, image) through 15 catalog-driven tools, with application-credential auth, links/topology, sessions, metrics, and a fake-cloud test harness.

**Architecture:** Four targets. `OpenStackClient` (library, no MCP knowledge) does clouds.yaml config, Keystone application-credential auth, endpoint/version negotiation, transport with retry and error normalization, and typed service APIs over AsyncHTTPClient. `OpenStackMCPServer` (library) holds the declarative resource catalog, policy, name resolution, waiter, the 15 verb/link/topology tools, MCP resources and prompts. `HummingbirdMCP` (library, no OpenStack knowledge) adapts Hummingbird routes to the MCP Swift SDK's `StatefulHTTPServerTransport` with an actor session registry. `openstack-mcp` (executable) wires config, subcommands (`serve`, `stdio`, `check`, `access-rules`, `tools`), routes, and metrics. Every catalog operation is tested against an in-process fake OpenStack (a Hummingbird app in a test-support target).

**Tech Stack:** Swift 6.4 (strict concurrency), Linux only — builds and tests run in the `swift:6.4-rhel-ubi10` container. Hummingbird 2.26.x, modelcontextprotocol/swift-sdk 0.12.x (protocol revision 2025-11-25), async-http-client 1.36.x, swift-nio-ssl, swift-log 1.x, swift-metrics 2.x, swift-prometheus 2.x, swift-configuration 1.2.x, swift-argument-parser 1.x, Yams 5.x, swift-crypto 3.x. Testing: Swift Testing + HummingbirdTesting.

**Spec:** `specs/openstack-mcp-spec.md` — this plan implements phase 1 (spec §16, parts 1–6). The spec travels with this plan; executors read both.

## Global Constraints

- **Build/test environment:** ALL `swift build` / `swift test` / `swift run` commands run inside the Linux container: `docker run --rm --platform linux/amd64 -v "$PWD":/work -w /work swift:6.4-rhel-ubi10 <cmd>` (use `podman` if that is the host's runtime; the plan writes `docker` and assumes it exists). `--platform linux/amd64` is required on Apple Silicon hosts so the UBI10 image matches the release/CI target (on x86_64 hosts the flag is a no-op). Never build natively on macOS. Task 1 verifies the container works and pins this exact command shape in `scripts/swift`; later tasks invoke Swift only through `scripts/swift <args>`.
- **Swift version:** 6.4 toolchain; language mode 6 with strict concurrency enabled (`swiftLanguageModes: [.v6]`, `StrictConcurrency: complete`). No `@preconcurrency` workarounds in library public APIs.
- **Target cloud:** OpenStack 2026.1 Gazpacho and later; older clouds supported by negotiation. Nova microversion floor 2.79, client max tracks what the models decode (Gazpacho max 2.104). Cinder v3 floor 3.44.
- **Phase 1 services:** identity (Keystone v3), compute (Nova), network (Neutron), block storage (Cinder), image (Glance v2). Nothing else. Octavia/Designate/Swift/Barbican are phase 2/3 and must NOT appear in the catalog.
- **Identity admin resources denied by default:** `policy.deny_resources` default is `[project, user, group, role, role_assignment, domain]` (decision dec_KmRnPXFEcIBwbsd4BixZAhnN). They exist in the catalog and are re-enable-able.
- **Interconnectivity interpretation (decision dec_obVZnZOPvP3xrr4KrLM0bjAv):** (a) `os_attach`/`os_detach` links, (b) `os_topology` + diagnosis, (c) multi-cloud/multi-region addressing. No load balancer or DNS.
- **Auth:** HTTP mode bearer is `application_credential_id:application_credential_secret`, split on the FIRST colon only (decision dec_6j2qHxbqxw3T2in15wGtp0xe); clients may send `X-OpenStack-Cloud`; clients never supply `auth_url`. stdio mode reads `OS_CLOUD` (clouds.yaml `auth_type: v3applicationcredential`) or the `OS_AUTH_URL` / `OS_APPLICATION_CREDENTIAL_ID` / `OS_APPLICATION_CREDENTIAL_SECRET` trio (+ optional `OS_REGION_NAME`, `OS_INTERFACE`, `OS_CACERT`).
- **Secrets:** the application credential secret lives in memory only, is never logged, never written to disk, and is zeroized (overwritten) when the session ends.
- **Safe by default:** read-only mode registers exactly 9 tools (`os_list`, `os_get`, `os_describe`, `os_topology`, `os_find`, `os_whoami`, `os_quota`, `os_clouds`, `os_wait`); full mode registers 15. `server.host` default is `127.0.0.1`.
- **Naming:** resources are singular python-openstacksdk nouns (`server`, `flavor`, `keypair`, `network`, `subnet`, `port`, `router`, `floating_ip`, `security_group`, `security_group_rule`, `address_group`, `volume`, `volume_type`, `volume_snapshot`, `volume_backup`, `image`, `project`, `user`, `group`, `role`, `role_assignment`, `domain`, `service`, `endpoint`, `region`, `application_credential`, `server_group`, `availability_zone`, `hypervisor`, `compute_service`, `server_interface`, `server_volume_attachment`, `quota`). Tools are `os_`-prefixed. Package and executable are `openstack-mcp`.
- **Spec-pinned config defaults** (all of spec §11.2): `server.port` 8080, `server.endpoint` `/mcp`, `server.allowed_origins` localhost, `server.max_body_bytes` 1048576, `auth.failed_auth_per_minute` 10, `session.idle_ttl` 30m, `session.max_lifetime` 12h, `session.max_sessions` 500, `session.max_streams_per_session` 4, `policy.max_list_limit` 200, `policy.max_calls_per_minute` 120, `client.request_timeout` 60s, `client.max_connections_per_host` 16, `cache.max_entries_per_session` 2000, `log.level` info, `log.format` json, `log.audit` true.
- **Cache TTLs** (spec §10.4, verbatim — this table is the source of truth for the plan; the spec §4 "starting values" paragraph is a different, Substation-derived table and is NOT used): catalog and version documents 1800s; flavors, images, networks, subnets, security groups 300s; servers, ports, volumes, floating IPs 60s; no caching of `get` after a mutation on the same resource within the session; `fresh: true` bypasses; `cache.max_entries_per_session` 2000 (LRU). Resources not named in §10.4 (keypair, server_group, hypervisor, compute_service, quota, security_group_rule, address_group, volume_type, volume_snapshot, volume_backup, identity resources) use 120s — a documented middle value between the 60s hot tier and the 300s warm tier.
- **Every task ends with a commit.** No task leaves the tree failing; `scripts/swift test` is green before each commit.

## Review Focus

The spec is a vision document; these five input classes are not pinned by a task's tests and are most likely to bite a real user. Each line's test is added to the owning task.

1. **Bearer header with a secret containing a colon** (`Bearer 0123456789abcdef0123456789abcdef:sec:ret:more`) — the server must split on the first colon only and authenticate successfully; a naive `split(separator:)` breaks auth for legitimate secrets. (Parsing unit test in Task 2; end-to-end auth test in Task 18, Review Focus 1.)
2. **Clouds.yaml with a trailing top-level `secure:` merge or an entry missing `auth_url`** — config load must either parse or fail with a named-key error, never crash and never silently default `auth_url` to something wrong. (Test added to Task 2.)
3. **Keystone returns a token whose catalog lacks the requested region's service** (e.g., Cinder absent in RegionTwo) — `cloud.blockStorage(region: "RegionTwo")` must raise `OpenStackError` with a hint naming the missing service/region, not a connection error. (Test added to Task 6.)
4. **An MCP client sends a second `initialize` on an existing session** — the SDK transport handles it, but the session must NOT be re-bound to a different credential; a fingerprint mismatch is 401, not a session replacement. (Test added to Task 17.)
5. **A tool call after the session's credential secret was zeroized by eviction, while the client still holds the session ID** — must be 404 (session gone; the client re-initializes), and the server must not attempt re-auth with a zeroed secret (which would log/leak or crash). (Test added to Task 17.)

---

## File Structure (locked in)

```
openstack-mcp/
  Package.swift
  .gitignore
  README.md
  scripts/
    swift                 # wrapper: docker/podman run swift:6.4-rhel-ubi10, mounts repo
    build.sh              # release build (used by Task 22)
  Sources/
    OpenStackClient/
      CloudConfig/CloudConfig.swift          # CloudConfig, CloudEntry, ApplicationCredential, search order
      Identity/Identity.swift                # token auth, Principal, whoami, refresh
      Transport/Transport.swift              # Transport actor, retry, headers, timeouts
      Transport/OpenStackError.swift         # OpenStackError + per-service normalization
      Versioning/Microversion.swift          # Microversion, Negotiator, feature table
      Versioning/Extensions.swift            # Neutron extension discovery
      EndpointResolver.swift                 # + ServiceCatalog/TokenResponse (IdentityModels extended in Task 5)
      Cache.swift                            # actor, LRU, TTL, principal-keyed (Task 4, before Versioning)
      Services/IdentityService.swift
      Services/ComputeService.swift
      Services/NetworkService.swift
      Services/BlockStorageService.swift
      Services/ImageService.swift
      Models/IdentityModels.swift
      Models/ComputeModels.swift
      Models/NetworkModels.swift
      Models/BlockStorageModels.swift
      Models/ImageModels.swift
    OpenStackMCPServer/
      Catalog/ResourceDescriptor.swift       # descriptor type + schema/filter/action/link declarations
      Catalog/Catalog.swift                  # ResourceCatalog: all phase 1 entries (split per service by file if > ~600 lines: ComputeEntries.swift, NetworkEntries.swift, etc.)
      Policy/Policy.swift                    # Policy + PolicyContext
      Tools/ToolRegistry.swift               # builds Tool list, inputSchemas, dispatch
      Tools/ResultFormatting.swift           # ToolOutcome, structuredContent, error paragraph, projections
      Tools/DescribeTools.swift              # os_describe, os_clouds, os_whoami
      Tools/VerbTools.swift                  # os_list, os_get, os_find, os_create, os_update, os_delete, os_action, os_quota, os_wait
      Links/LinkRegistry.swift               # 7 link kinds, preconditions
      Links/Links.swift                      # os_attach, os_detach handlers
      Links/Topology.swift                   # os_topology + diagnosis
      NameResolver.swift
      Waiter.swift
      Resources/MCPResources.swift           # openstack:// catalog + lazy resource URIs
      Prompts/MCPPrompts.swift               # provision_server, diagnose_connectivity, audit_security_groups
      Session/Principal.swift                # MCP-side principal (credential, fingerprint, whoami)
    HummingbirdMCP/
      HummingbirdMCP.swift                   # MCPRoute, request/response mapping incl. SSE
      SessionRegistry.swift                  # actor registry, limits, cleanup task
      Authenticator.swift                    # BearerAppCred parsing, fingerprint, rate limiting
    OpenStackMCP/
      main.swift
      Config.swift                           # swift-configuration keys, §11.2 defaults
      Commands/Serve.swift
      Commands/Stdio.swift
      Commands/Check.swift
      Commands/AccessRules.swift
      Commands/Tools.swift
      Commands/Conformance.swift             # hidden subcommand used by scripts/conformance.sh (Task 22)
      Logging.swift                          # JSON/text logger factory + redaction
      Metrics.swift                          # swift-prometheus collectors
  Tests/
    FakeOpenStack/
      FakeApp.swift              # Hummingbird app composing the fakes + admin seed API
      KeystoneFake.swift
      NovaFake.swift
      NeutronFake.swift
      CinderFake.swift
      GlanceFake.swift
    OpenStackClientTests/
      CloudConfigTests.swift
      CredentialParsingTests.swift
      TransportTests.swift
      VersioningTests.swift
      CacheTests.swift
      ErrorNormalizationTests.swift
      IdentityServiceTests.swift
      ComputeServiceTests.swift
      NetworkServiceTests.swift
      BlockStorageServiceTests.swift
      ImageServiceTests.swift
    OpenStackMCPServerTests/
      CatalogCompletenessTests.swift
      PolicyTests.swift
      NameResolverTests.swift
      SchemaValidationTests.swift
      DescribeToolsTests.swift
      VerbToolsTests.swift
      LinkToolsTests.swift
      TopologyTests.swift
      WaiterTests.swift
      ResourcesPromptsTests.swift
      InProcessMCPTests.swift
    HummingbirdMCPTests/
      AuthTests.swift
      SessionTests.swift
      TransportTests.swift
      SoakTests.swift
    OpenStackMCPTests/
      ConfigTests.swift
      RedactionTests.swift
      AccessRulesTests.swift
      SubcommandTests.swift
  IntegrationTests/            # opt-in, OSMCP_IT_CLOUD
    IntegrationTests.swift
  deploy/
    Dockerfile
    openstack-mcp.service
    caddy/Caddyfile
    nginx/openstack-mcp.conf
```

Target boundaries (spec §15): `OpenStackClient` and `HummingbirdMCP` never import each other. `FakeOpenStack` imports only `OpenStackClient` (and Hummingbird). Executable test targets may import `FakeOpenStack` via test-product dependency.

## Task 1: Repo scaffold, container build wrapper, first green test

**Files:**
- Create: `Package.swift`, `.gitignore`, `scripts/swift`, `scripts/build.sh`
- Create: `Sources/OpenStackClient/Version.swift` (placeholder target file with `public let openStackClientVersion = "0.1.0"`)
- Create: `Tests/OpenStackClientTests/ScaffoldTests.swift`
- Create: `README.md` (title, one-paragraph description, build/test instructions pointing at `scripts/swift`)

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/swift <args>` — runs `docker run --rm --platform linux/amd64 -v "$PWD":/work -w /work swift:6.4-rhel-ubi10 swift <args>` (podman fallback if `docker` is absent; see Global Constraints). All later tasks invoke Swift through this wrapper. Package manifest declaring all four targets' names/paths now (empty directories are fine) so later tasks never edit `Package.swift` structure, only dependency versions if resolution demands it.

- [ ] **Step 1: Initialize git and write `Package.swift`**

Run: `git init` (if not already a repo), then create `Package.swift` declaring platform `.macOS(.v14)` (harmless; builds run on Linux), tools version 6.0, strict concurrency, and exactly these targets:

```swift
// targets, in dependency order:
// .target(name: "OpenStackClient", dependencies: [AHC, NIOSSL, Log, Metrics, Yams, Crypto])
// .target(name: "HummingbirdMCP", dependencies: [Hummingbird, .product("MCP", package: "swift-sdk")])
// .target(name: "OpenStackMCPServer", dependencies: [.target(name: "OpenStackClient"), .product("MCP", package: "swift-sdk")])
// .executableTarget(name: "openstack-mcp", dependencies: [OpenStackMCPServer, HummingbirdMCP, ArgumentParser, Configuration, Prometheus, TLS product if needed])
// .testTarget(name: "OpenStackClientTests", dependencies: [OpenStackClient, HummingbirdTesting])
// .testTarget(name: "OpenStackMCPServerTests", dependencies: [OpenStackMCPServer, .product(name: "FakeOpenStack", ...), MCP client product])
// .testTarget(name: "HummingbirdMCPTests", dependencies: [HummingbirdMCP, HummingbirdTesting, MCP])
// .testTarget(name: "OpenStackMCPTests", dependencies: [openstack-mcp-as-target?, FakeOpenStack])
// .target(name: "FakeOpenStack", dependencies: [OpenStackClient, Hummingbird], isTestSearch: ... )  -- see note
```

Note: `FakeOpenStack` must be importable by test targets AND buildable as `openstack-mcp-fake` for manual testing (spec §14.2). Model it as a regular library target with an `@main` entry gated behind the executable product `openstack-mcp-fake` only if SPM allows; otherwise make it a test-support library and add a second small executable target `OpenStackMCPFake` (not in the spec layout, additive) that runs it. Choose whichever SPM accepts; document the choice in the commit message. Dependencies pinned per spec §15 table: hummingbird 2.26.x, modelcontextprotocol/swift-sdk from: "0.12.0", async-http-client from: "1.36.0", swift-log from: "1.6.0", swift-metrics from: "2.5.0", swift-prometheus from: "2.0.0", swift-configuration from: "1.2.0", swift-argument-parser from: "1.5.0", Yams from: "5.1.0", swift-crypto from: "3.0.0".

- [ ] **Step 2: Write `scripts/swift` and make it executable**

A POSIX sh script: resolve runtime as `docker`, else `podman`; error clearly if neither. `exec "$RT" run --rm --platform linux/amd64 -v "$PWD":/work -w /work swift:6.4-rhel-ubi10 swift "$@"`. Same pattern for `scripts/build.sh` (`swift build -c release --static-swift-stdlib`).

- [ ] **Step 3: Write the failing scaffold test**

`Tests/OpenStackClientTests/ScaffoldTests.swift` (Swift Testing):

```swift
import Testing
@testable import OpenStackClient

struct ScaffoldTests {
    @Test func versionIsPinned() {
        #expect(openStackClientVersion == "0.1.0")
    }
}
```

- [ ] **Step 4: Verify the container toolchain and run the test**

Run: `scripts/swift --version` — expected: `Swift version 6.4.x` on Ubuntu/UBI-style Linux. Then `scripts/swift test` — expected: first `swift package resolve` may fail on SDK dependency availability; if resolution fails, pin `modelcontextprotocol/swift-sdk` to the exact resolvable 0.12.x tag and note it in the commit. End state: `Test run with 1 test ... passed`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore scripts/ README.md Sources/OpenStackClient/Version.swift Tests/
git commit -m "chore: scaffold package, UBI10 Swift 6.4 build wrapper, green scaffold test"
```

---

## Task 2: CloudConfig — clouds.yaml, secure.yaml, env, bearer parsing

**Files:**
- Create: `Sources/OpenStackClient/CloudConfig/CloudConfig.swift`
- Test: `Tests/OpenStackClientTests/CloudConfigTests.swift`, `Tests/OpenStackClientTests/CredentialParsingTests.swift`

**Interfaces:**
- Consumes: Yams (Task 1 dependency).
- Produces:
  - `struct CloudEntry: Codable { name: String; authURL: URL; regionName: String?; interface: String; cacert: String?; verify: Bool; project: String?; userID: String?; appCredID: String?; appCredSecret: String? }` (YAML keys: `auth`, `region_name`, `interface`, `cacert`, `verify`, `project_name`, `user_id`, `application_credential_name/id/secret` under `auth`, with `auth_type: v3applicationcredential`).
  - `struct CloudConfig { clouds: [CloudEntry]; func cloud(named: String) throws -> CloudEntry; var defaultCloud: CloudEntry }`; `static func load(file: URL?) throws -> CloudConfig` — search order `./clouds.yaml`, `~/.config/openstack/clouds.yaml`, `/etc/openstack/clouds.yaml`, then `$OS_CLIENT_CONFIG_FILE`; merges `secure.yaml` for `cacert`/`verify` only; validates `auth_type` is `v3applicationcredential` for any cloud that will be used.
  - `struct ApplicationCredential { id: String; secret: [Int8] }` (secret as a zeroizable buffer) with `static func parseBearer(_ header: String) throws -> ApplicationCredential` — throws `CredentialParseError.malformed` on no `Bearer ` prefix or no colon; splits on the FIRST colon only.
  - `struct CredentialParseError: Error { case malformed, missingCloud }`

- [ ] **Step 1: Write failing tests**

`CredentialParsingTests.swift`:

```swift
@Test func bearerSplitsOnFirstColonOnly() throws {
    let cred = try ApplicationCredential.parseBearer("Bearer 0123456789abcdef0123456789abcdef:sec:ret:more")
    #expect(cred.id == "0123456789abcdef0123456789abcdef")
    #expect(String(decoding: cred.secret, as: UTF8.self) == "sec:ret:more")
}
@Test func bearerWithoutColonThrowsMalformed() {
    #expect(throws: CredentialParseError.self) { _ = try ApplicationCredential.parseBearer("Bearer justanid") }
}
@Test func bearerWithoutSchemeThrowsMalformed() {
    #expect(throws: CredentialParseError.self) { _ = try ApplicationCredential.parseBearer("Basic abc:def") }
}
```

`CloudConfigTests.swift`: write temp `clouds.yaml` fixtures in the test (XCTemporaryDirectory / FileManager): one file with two clouds (`dev` with `v3applicationcredential` app-cred fields, `prod` with `region_name: RegionTwo`), one file with a `secure.yaml` sibling overriding `cacert` and `verify: false`, one malformed file (cloud entry missing `auth`). Assert: load by explicit path; `cloud(named:)` returns the right entry; `defaultCloud` is the first cloud in file order; missing-name lookup throws; malformed `auth` throws a `DecodingError` whose context names the cloud; secure merge changes only `cacert`/`verify`. **Review Focus 2 (pinned here):** add a test `cloudsYamlWithTrailingSecureMergeParses` — a file ending in a top-level `secure:` key alongside `clouds:` must parse (Swift SDK clients commonly generate this shape) and a test `entryMissingAuthURLFailsNamed` — a cloud with no `auth:` key throws an error message containing the cloud name.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/swift test --filter CloudConfigTests` — expected: compile failure / missing symbols.

- [ ] **Step 3: Implement `CloudConfig.swift`**

Approach: Yams `load` into a `struct Root: Codable { clouds: [String: RawCloud] }` (map preserves names, array order recovered via a parallel `__order__` key or by using an array of keyed structs — pick the one that makes `defaultCloud` = first-declared work; document choice). `ApplicationCredential.secret` stores UTF-8 bytes in an `UnsafeMutableRawPointer`-backed buffer with `zeroize()` (use swift-crypto's `Insecure` is NOT for this — a plain `Data` is fine if `Data` offers no zeroize; implement a tiny `ZeroizedBuffer` struct with `deinit`-free explicit `zeroize()` and `withUnsafeMutableBytes`); `parseBearer` trims the `Bearer ` prefix, `range(of: ":")` first occurrence.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter "CloudConfigTests|CredentialParsingTests"` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackClient/CloudConfig/ Tests/OpenStackClientTests/CloudConfigTests.swift Tests/OpenStackClientTests/CredentialParsingTests.swift
git commit -m "feat(client): clouds.yaml/secure.yaml loading and first-colon bearer parsing"
```

---

## Task 3: Transport — HTTP wrapper, headers, retry, timeouts, request ID

**Files:**
- Create: `Sources/OpenStackClient/Transport/Transport.swift`
- Create: `Sources/OpenStackClient/Transport/OpenStackError.swift`
- Test: `Tests/OpenStackClientTests/TransportTests.swift`

**Interfaces:**
- Consumes: Task 1 deps (AHC, NIOSSL, Log, Metrics).
- Produces:
  - `struct OpenStackError: Error, Sendable { service: String; status: Int; code: String?; message: String; requestID: String?; retriable: Bool; hint: String? }` — `static func normalize(body: Data?, status: Int, service: String, requestID: String?, hasAccessRules: Bool) -> OpenStackError` per spec §10.3 shapes (Nova `itemNotFound`/`badRequest` etc., Neutron `NeutronError{type,message}`, Cinder `badRequest`/`overLimit`, Keystone `error{code,message,title}`, Glance plain text); 403 + `hasAccessRules` appends the access-rules hint verbatim: "the application credential's access rules do not allow METHOD PATH; regenerate with `openstack-mcp access-rules`".
  - `actor Transport { init(cloud: CloudEntry, tokenSource: @Sendable () async throws -> String, maxConnectionsPerHost: Int, requestTimeout: Duration, logger: Logger); func request(method: String, service: String, path: String, query: [URLQueryItem] = [:], body: Data? = nil, tokenOverride: String? = nil, extraHeaders: [(String,String)] = [], timeoutOverride: Duration? = nil) async throws -> (status: Int, body: Data, requestID: String?) }`
  - Behavior pinned: headers on every request — `X-Auth-Token` (from `tokenSource` or `tokenOverride`), `Accept: application/json`, `User-Agent: openstack-mcp/<version>` (version from Task 1's `openStackClientVersion`), `X-OpenStack-Request-Id` generated client-side (UUID) and returned to the caller in `requestID`; microversion headers are passed via `extraHeaders` (added by Versioning in Task 6); per-cloud TLS: `cacert` sets trust roots, `verify == false` sets `certificateVerification = .none` for this cloud only; HTTP/2 when offered; pool `maxConnectionsPerHost` default 16; connect timeout 10s; request timeout default 60s with per-call override. Retries: GET/HEAD and idempotent DELETE retry up to 3 total attempts, exponential backoff base 1s cap 60s with jitter, on connection errors and status 429 (honor `Retry-After`), 502, 503, 504. POST/PUT never retried (re-auth on 401 is the caller's job, not the transport's). `swift-metrics` timers per service+method+status.

- [ ] **Step 1: Write failing tests**

`TransportTests.swift` — stand up a small Hummingbird server inline (test target already depends on HummingbirdTesting; a plain `Hummingbird` app on a random port is fine) with routes:
  - `GET /flaky`: first 2 responses 503, then 200 `{"ok":true}` — assert `request` returns 200 (retries worked) and that exactly 3 attempts were recorded (server-side counter).
  - `GET /retry-after`: 429 with `Retry-After: 1` then 200 — assert success and that the client waited ~1s (elapsed >= 0.9s).
  - `POST /no-retry`: always 503 — assert the error is thrown after exactly 1 attempt for POST.
  - `GET /headers`: echoes received headers — assert `X-Auth-Token == "tok-123"`, `User-Agent == "openstack-mcp/0.1.0"`, `X-OpenStack-Request-Id` present (UUID shape), `Accept == "application/json"`.
  - `GET /error-nova`: 404 body `{"itemNotFound": {"message": "Item not found."}}` — assert `OpenStackError` fields: service, status 404, code "itemNotFound", message, and (with `hasAccessRules: false`) no access-rule hint.
  - 403 + `hasAccessRules: true` — hint contains "access-rules".
  - Glance plain-text 400 body `Image not found` — normalized to code nil, message "Image not found".
  - Timeout: route that sleeps 2s, call with `timeoutOverride: .milliseconds(300)` — expect connection/timeout error mapped to `OpenStackError` with `retriable == true` (only for GET) — actually timeout on POST should be non-retriable `OpenStackError(status: 0)`.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter TransportTests` — expected: missing symbols.

- [ ] **Step 3: Implement** — `AsyncHTTPClient` configured per cloud (`tlsConfiguration` from `CloudEntry`), backoff as `base * 2^(attempt-1)` clamped to cap, jitter `Double.random(in: 0...0.5)` added; 429 reads `Retry-After` seconds. Request ID: `UUID().uuidString` in header, returned as the tuple's `requestID`.

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter TransportTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): transport with per-cloud TLS, retry, error normalization"` (add `Transport/` + test file).

---

## Task 4: Cache — principal-keyed, TTL, LRU, invalidation

**Files:**
- Create: `Sources/OpenStackClient/Cache.swift`
- Test: `Tests/OpenStackClientTests/CacheTests.swift`

**Interfaces:**
- Consumes: nothing beyond stdlib/Foundation + `swift-crypto` not needed.
- Produces:
  - `struct CacheKey: Hashable, Sendable { principalFingerprint: String; region: String; resource: String; suffix: String }` — `suffix` disambiguates filter sets for lists (`"f:" + sorted query string) and resource ids for gets.
  - `actor Cache { init(maxEntries: Int = 2000); func get<T: Codable & Sendable>(_ key: CacheKey, ttl: Duration, as type: T.Type) async -> T?` — returns decoded value if fresh (TTL per call, caller passes the resource's default from the table in Global Constraints); `func put<T: Codable & Sendable>(_ key: CacheKey, ttl: Duration, value: T) async; func invalidate(resource: String, principal: String, region: String) async` — clears all keys for that resource (used on mutation, including linked-resource invalidation by callers); `var stats: (hits: Int, misses: Int)` — feeds `osmcp_cache_hits_total{resource}` metric.
  - LRU: on put/eviction beyond `maxEntries` (default 2000), drop least-recently-accessed; access = get hit or put.
  - Stored as JSON `Data` (values already decoded from the wire once).

- [ ] **Step 1: Write failing tests** — `CacheTests.swift`:
  - put/get round-trip with `suffix`; TTL expiry with injected clock (add `clock` param defaulting to `ContinuousClock`); second get after expiry returns nil.
  - LRU: `maxEntries: 3`, put A,B,C, get A, put D → B evicted (assert B nil, A/C/D present).
  - `invalidate(resource:)` clears all suffixes for that resource only.
  - Different principals with same region+resource do not share entries.
  - `stats.hits` increments on hit only.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter CacheTests`.

- [ ] **Step 3: Implement** — dictionary `[CacheKey: (data: Data, expires: Instant, lastAccess: Int)]` + monotonic access counter for LRU order; `actor` for isolation.

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter CacheTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): principal-keyed TTL/LRU cache with invalidation"`.

---

## Task 5: Identity — application-credential auth, Principal, whoami, refresh

**Files:**
- Create: `Sources/OpenStackClient/Identity/Identity.swift`
- Create: `Sources/OpenStackClient/Models/IdentityModels.swift` (Task 6 creates this file with `ServiceCatalog`/`TokenResponse`; Task 5 extends it with `Token`, `IdentityRef`, `Whoami`)
- Test: `Tests/OpenStackClientTests/IdentityServiceTests.swift`

**Interfaces:**
- Consumes: `Transport`, `CloudConfig`, `ServiceCatalog`/`TokenResponse` (Task 6), `Cache` (Task 4).
- Produces:
  - `struct Token: Sendable { id: String; expiresAt: Date; catalog: ServiceCatalog; project: IdentityRef; user: IdentityRef; roles: [String] }` where `IdentityRef { id, name, domain }`.
  - `actor Principal { init(cloud: CloudEntry, credential: ApplicationCredential, transport: Transport); func token() async throws -> String` — returns current token; refreshes proactively at 80% of lifetime and reactively on the first 401 from any service (at most once per request — a second 401 throws an authentication error and marks the session for re-initialization, per spec §6.2); `func authenticate() async throws -> Token` — `POST /v3/auth/tokens` with `{"auth": {"methods": ["application_credential"], "identity": {"methods": ["application_credential"], "application_credential": {"id": ..., "secret": ...}}}}` (secret sent via `withUnsafeMutableBytes` into the JSON encoder — encode, send, do not log the body); `func whoami() async throws -> Whoami` — from token + `GET /v3/users/{user_id}/application_credentials/{id}` (name, `unrestricted`, `access_rules`), tolerating 403/404 on that read with a note; `func zeroize()` — clears the secret buffer and token.
  - `struct Whoami: Sendable { credentialName: String?; credentialID: String; project: IdentityRef; domain: IdentityRef; roles: [String]; expiresAt: Date; unrestricted: Bool?; accessRules: [[String: String]]?; regions: [String]; services: [String: [String]] }` (regions and services derived from the catalog).
  - `struct IdentityService` — typed reads used by catalog later: `listProjects/getProject`, `listUsers`, `listGroups`, `listRoles`, `listDomains`, `listServices`, `listEndpoints`, `listRoleAssignments(scope:)`, `createProject/user/group/role/domain`, `updateProject/...`, `deleteProject/...`, `grantRole(roleID:toUser:onProject:)`, `revokeRole(...)`, `listApplicationCredentials(userID:)`. All take `region: String? = nil` (identity is catalog-scoped, not regioned — pass the cloud's first region for endpoint resolution).

**Order note:** the token lives in a private `var current: Token?` on the `Principal` actor (no `Cache` needed); `Cache` (Task 4) is used for `IdentityService` list results only.

- [ ] **Step 1: Write failing tests** — `IdentityServiceTests.swift` against a stub Keystone (inline Hummingbird):
  - Auth body: capture the POST body; assert `methods == ["application_credential"]` (identity method list present), secret string appears in body, project is NOT in the body (app creds are project-scoped by the credential).
  - Token parse: stub returns a full catalog with 2 regions and 3 service types; assert `Token.expiresAt` decoded from RFC3339, `catalog` populated, `Whoami.regions == ["RegionOne","RegionTwo"]` order-independent.
  - Refresh at 80%: stub returns token with 60s expiry; advance via injected `ContinuousClock` (add `clock: any Clock<Duration> = ContinuousClock()` to `Principal.init`) — second `token()` call after 48s triggers a second auth (server counter 2). Also: stub returns 401 once from a service call — `token(reauth: true)` path calls auth again exactly once.
  - `whoami()` with the credentials endpoint returning 403 → `unrestricted == nil`, no throw, note recorded.
  - `zeroize()` → subsequent `token()` throws (not a crash) and the secret buffer reads zero (expose `secretIsZeroed: Bool` for tests).
  - `IdentityService.listProjects` against stub catalog body → decoded names.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter IdentityServiceTests`.

- [ ] **Step 3: Implement** — per interfaces above; JSON via `Codable` with `keyDecodingStrategy` none (OpenStack uses snake_case — use explicit `CodingKeys`).

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter IdentityServiceTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): application credential auth, principal, whoami, identity reads"`.

---

## Task 6: Versioning — microversions, Neutron extensions, endpoint resolver

**Files:**
- Create: `Sources/OpenStackClient/Versioning/Microversion.swift`, `Sources/OpenStackClient/Versioning/Extensions.swift`, `Sources/OpenStackClient/EndpointResolver.swift`
- Test: `Tests/OpenStackClientTests/VersioningTests.swift`

**Interfaces:**
- Consumes: `Transport` (Task 3), `CloudConfig` (Task 2), `Cache` (Task 4).
- Produces:
  - `struct Microversion: Comparable, Sendable { major: Int; minor: Int }` with `var stringValue: String` ("2.79") and `init?(_ string: String)`.
  - `actor VersionNegotiator { init(transport: Transport, serviceType: String, clientMax: Microversion, floor: Microversion?); func negotiate(region: String) async throws -> Microversion }` — discovery once per session/region/service, cached: Keystone `GET /v3`, Nova `GET /` (version document `max_version`), Cinder `GET /` v3, Glance `GET /versions`, Neutron `GET /v2.0/extensions` (no microversion; returns extension list instead). Picks `min(serverMax, clientMax)`; throws `OpenStackError` with hint if below floor ("cloud advertises Nova max 2.78; floor is 2.79").
  - `enum NovaFeature: String { case deleteOnTermination, hostname, pinnedAvailabilityZone, schedulerHintsEcho, asyncVolumeAttach }` + `func minMicroversion() -> Microversion` mapping to 2.79 / 2.90 / 2.96 / 2.100 / 2.101 (spec §10.1); `func available(in negotiated: Microversion) -> Bool`.
  - `struct NeutronExtensions: Sendable { aliases: Set<String> }` with `func has(_ alias: String) -> Bool`; aliases tracked: `router`, `external-net`, `port-security`, `address-group`, `qos`, `trunk`, `dns-integration`.
  - `struct EndpointResolver { init(catalog: ServiceCatalog, preferredInterface: String); func endpoint(serviceType: String, region: String) throws -> URL }` — `ServiceCatalog` is the decoded Keystone token catalog (`[service_type, name, endpoints: [[region, interface, url]]]`); prefers configured interface, falls back `public` → `internal` → `admin`; **Review Focus 3 (pinned here):** throws `OpenStackError(service: serviceType, status: 0, code: "no-endpoint", message: "no <serviceType> endpoint in region <region> (interfaces tried: ...)", hint: "check the cloud's service catalog")` when absent.
  - `struct ServiceCatalog: Codable { ... }` + `TokenResponse: Codable` (Keystone `/v3/auth/tokens` body: `token {id, expires_at, catalog}` and `user`, `project`) — put these in `Models/IdentityModels.swift` (created in this task; Task 5 extends).

- [ ] **Step 1: Write failing tests** — `VersioningTests.swift`:
  - `Microversion("2.79")` round-trips; `Microversion("2.79") < Microversion("2.104")` (numeric, not lexicographic — the classic bug); `Microversion("garbage") == nil`.
  - `NovaFeature.deleteOnTermination.available(in: .init(2:78)) == false`, `true` at 2.79; `asyncVolumeAttach` false at 2.100, true at 2.101.
  - Negotiation against a stub transport (inline Hummingbird server per Task 3's pattern): Nova `GET /` returning `max_version 2.104` with clientMax 2.104 → 2.104; server max 2.78 with floor 2.79 → throws with floor in the message. Second call serves from the shared `Cache` (Task 4; stub it with a fresh `Cache(maxEntries: 100)` in the test) — the stub server's request counter stays at 1.
  - `EndpointResolver`: catalog with RegionOne having `public`+`internal` and RegionTwo having only `internal` — preferred `public` resolves RegionOne to public URL; RegionTwo falls back to internal; missing service in RegionTwo throws the Review Focus 3 error with region in the message.
  - Neutron extensions stub: body with two extension aliases → `has("address-group")` true, `has("qos")` false.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter VersioningTests`.

- [ ] **Step 3: Implement** — version docs are cached in the shared `Cache` (Task 4) with TTL 1800s under resource key `__versions__/<service>/<region>` (e.g. `__versions__/nova/RegionOne`). No separate version-document cache exists; the `VersionNegotiator` takes a `Cache` in its init and stores/fetches through it. The `principalFingerprint` field of `CacheKey` is the client's principal fingerprint (Task 5's `Principal` exposes it; for the negotiator built before `Principal` exists in tests, pass the test's own constant).

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter VersioningTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): microversion negotiation, neutron extensions, endpoint resolution"`.

---

## Task 7: FakeOpenStack — Keystone + Nova fakes

**Files:**
- Create: `Sources/FakeOpenStack/FakeApp.swift`, `Sources/FakeOpenStack/KeystoneFake.swift`, `Sources/FakeOpenStack/NovaFake.swift` (and `Sources/FakeOpenStack/SharedState.swift` for the in-memory store)
- Test: `Tests/OpenStackMCPServerTests/FakeSmokeTests.swift` (smoke only; real coverage lands with each service task)

**Interfaces:**
- Consumes: `OpenStackClient` (for `TokenResponse`/`ServiceCatalog` shapes to emit correctly — these are produced by Task 6's `EndpointResolver.swift`/`Models/IdentityModels.swift`), Hummingbird.
- Produces:
  - `actor FakeState` — in-memory resources per project: servers, flavors, images(refs), networks, subnets, ports, routers, floating_ips, security_groups, rules, volumes, snapshots, backups, images, projects, users, roles...; seeded defaults: 2 regions (`RegionOne`, `RegionTwo`), 2 clouds' worth of one Keystone, flavors `m1.small`/`m1.large`/`m1.xlarge`, one image `ubuntu-26.04` (active), default security group `default`, one network `ext-net` (`router:external`), one subnet, one router with gateway.
  - `enum FakeApp { static func make() async -> (app: some any HummingbirdApplicationProtocol, state: FakeState, url: URL, keystoneURL: URL) }` — actually one app, path-dispatched: `/v3/*` → keystone, and per-service sub-apps mounted by path prefix matching the catalog URLs the fake Keystone returns (Nova at `/compute/<tokenproject>` etc. — the fake catalog points all services at the same host with distinct prefixes: `/keystone/v3`, `/nova`, `/neutron/v2.0`, `/cinder/v3`, `/glance/v2`). Simpler and sufficient.
  - Keystone fake: `GET /keystone/v3` version doc; `POST /keystone/v3/auth/tokens` validates `application_credential.id/secret` against seeded credentials (`fake-cred-one`/`secret-one` for project `proj-one`, `fake-cred-two`/`secret-two` for `proj-two`); wrong secret → 401 Keystone-shaped error; correct → `X-Subject-Token` header + body with 3600s expiry and the catalog (both regions, all five services in RegionOne; RegionTwo deliberately lacks cinder — Review Focus 3 fixture lives here).
  - Nova fake: version doc `GET /nova` (max 2.104); microversion enforcement: requests with `X-OpenStack-Nova-API-Version` below 2.79 → 400; above 2.104 → 400; `servers` (detail/simple, filters `name`, `status`, `limit`/`marker` pagination), `flavors`, `keypairs`, `server_groups`, `os-availability-zone`, `os-volume_attachments`, `os-interface` (attach/detach creating/destroying ports), `actions` (`POST /servers/{id}/action` — start/stop/reboot/pause/unpause/suspend/resume/lock/unlock/shelve/unshelve/rescue/unrescue/resize/confirm_resize/revert_resize/rebuild/snapshot/console_output/console_url/addSecurityGroup/removeSecurityGroup/evacuate/migrate), `os-quota-sets`, `os-hypervisors` (403 unless role `admin` present in token — fakes honor roles), `os-services` (enable/disable). Errors: 404 `itemNotFound`, 400 `badRequest`, 409 `buildRequestRejectedException` (e.g., resize while building), 413 `overLimit` for quota.
  - Project isolation: all nova reads filter by the token's project (tokens carry project ID in the fake's token store) — this is what the Task 20 soak test asserts.

- [ ] **Step 1: Write failing smoke tests** — `FakeSmokeTests.swift`:
  - `keystoneAuthSucceedsAndReturnsCatalog` — POST with seeded credential, assert 201, `X-Subject-Token`, catalog has 5 service types in RegionOne, only 4 in RegionTwo.
  - `keystoneRejectsWrongSecret` — 401, body has `error.code == "forbidden"` (Keystone shape).
  - `novaVersionDoc` — GET `/nova` returns max 2.104.
  - `novaMicroversionTooLowRejected` — `X-OpenStack-Nova-API-Version: 2.78` on servers list → 400.
  - `novaServersListPaginates` — seed 5 servers via admin API, list with `limit=2` → 2 items + marker; follow marker → next page; assert `next_marker` shape matches real Nova (last id).
  - `novaServerNotFoundIsItemNotFound` — 404 body shape.
  - `projectIsolation` — auth as cred-two, list servers → sees only proj-two servers.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter FakeSmokeTests`.

- [ ] **Step 3: Implement** — Hummingbird router per prefix; state mutations `nonisolated(unsafe)`? NO — everything through the actor; request handlers `await` state. Use `App.Storage` (actor) to hold `FakeState`.

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter FakeSmokeTests`.

- [ ] **Step 5: Commit** — `git commit -m "test(fake): fake Keystone + Nova with microversion enforcement and project isolation"`.

---

## Task 8: ComputeService — full Nova coverage against the fake

**Files:**
- Create: `Sources/OpenStackClient/Services/ComputeService.swift`, `Sources/OpenStackClient/Models/ComputeModels.swift`
- Test: `Tests/OpenStackClientTests/ComputeServiceTests.swift`

**Interfaces:**
- Consumes: `Principal` (Task 5), `Transport` (Task 3), `VersionNegotiator` + `EndpointResolver` (Task 6), `Cache` (Task 4), `FakeState` (Task 7, tests).
- Produces: `struct ComputeService { init(principal: Principal, cloud: CloudEntry, cache: Cache, logger: Logger) }; func region(_ r: String?) -> ComputeRegion` where `ComputeRegion` (bound to one region, resolves endpoint + negotiates once lazily) exposes:
  - `listServers(filters: [String:String] = [:], limit: Int? = nil, marker: String? = nil) async throws -> [Server]`; `getServer(id:)`; `createServer(_ spec: CreateServerSpec) async throws -> Server`; `updateServer(id:, name:, description:, metadata:, tags:)`; `deleteServer(id:, force: Bool)`; `action(_ serverID: String, _ action: ServerAction) async throws -> Server?` (`ServerAction` enum covering §8.6 compute rows: `.start, .stop, .reboot(soft: Bool), .pause, .unpause, .suspend, .resume, .lock, .unlock, .shelve, .unshelve, .rescue, .unrescue, .resize(flavorID: String), .confirmResize, .revertResize, .rebuild(imageID: String, adminPassword: String?), .snapshot(name: String), .consoleOutput(lines: Int), .consoleURL(type: String), .addSecurityGroup(id: String), .removeSecurityGroup(id: String), .evacuate, .liveMigrate, .migrate`);
  - flavors list/get/create/delete; keypairs list/get/create(import or generate)/delete; server groups CRUD; availability zones list; hypervisors list/get (admin); compute services list + `setService(host:, disabled:, reason:)`; quotas get/update; `attachVolume(serverID:, volumeID:, device:, deleteOnTermination:)` / `detachVolume(...)` (uses feature `deleteOnTermination`; returns 202-async handling per `asyncVolumeAttach` feature — poll attachment until visible); `attachInterface(serverID:, netID:/subnetID:/portID:/fixedIP:)` / `detachInterface(...)`.
  - Models: `Server { id, name, status, flavor: FlavorRef, addresses: [String: [Address]], created: Date, metadata: [String:String], tags: [String], hostId, keyName, configDrive, availabilityZone, user_id, project_id }`, `CreateServerSpec` (name, flavor, image, networks, keyName, availabilityZone, configDrive, metadata, personality, userData, schedulerHints, minCount, maxCount, serverGroup) with the feature-gated fields (hostname 2.90, pinned AZ 2.96) throwing a clear error if used below their microversion.
  - **`user_data` rule:** accepted in spec, base64, never stored in decoded form in models/logs — the service sends it as-is.

- [ ] **Step 1: Write failing tests** — against the Task-7 fake (every operation above needs at least one test; list the critical assertions):
  - create server with `minCount/maxCount` → 202-style or immediate `BUILD`; fake returns `REBUILD`? No — fake returns `BUILD` then a background task flips to `ACTIVE` after ~50ms (add `func tick()` or use `Task.sleep` in fake; tests call a `FakeState.settle()` helper that waits for pending transitions).
  - microversion: create with `hostname` when negotiated < 2.90 → client-side throw before request (assert server never saw the call).
  - `attachVolume` with negotiated 2.79 → body includes `delete_on_termination`; below 2.79 impossible (floor) so skip.
  - action `rebuild` with `adminPassword` → password in request body to fake; fake records it; assert fake never echoes it in any response (and model does not decode it back).
  - quota get → `os-quota-sets/{project}` shape decoded; update → 200.
  - hypervisor list with non-admin token → `OpenStackError` status 403 normalized.
  - pagination: list 5 servers limit 2 → `[2, 2, 1]` page sizes via repeated marker.
  - errors: delete running server without force → fake 400 `badRequest`; with force → 202? Nova returns 202 for some deletes — handle 200/202/204 all as success (pin this).

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter ComputeServiceTests`.

- [ ] **Step 3: Implement** — endpoint resolved via `EndpointResolver` (service type `compute`), token from `Principal`, microversion header injected per negotiated value (call `VersionNegotiator` lazily once per `ComputeRegion`), cache lists with TTL 60s (Global Constraints) under `CacheKey(principalFingerprint:region:resource:"server":suffix:"f:")+sorted-filter-string`, invalidate on mutation per §10.4 (list cache for `server` and for linked resources via the catalog in Task 12).

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter ComputeServiceTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): nova compute service with actions, attachments, microversion gating"`.

---

## Task 9: NetworkService — full Neutron coverage against the fake

**Files:**
- Create: `Sources/FakeOpenStack/NeutronFake.swift` (extend fake: networks, subnets, ports, routers, floating IPs, security groups + rules, address groups when extension present; 404 `NeutronError{type:"ItemNotFound"}`, 400 `InvalidInput`, 409 `IpAddressInUse`; `limit/marker/_links` pagination; extension discovery endpoint returning seeded aliases)
- Create: `Sources/OpenStackClient/Services/NetworkService.swift`, `Sources/OpenStackClient/Models/NetworkModels.swift`
- Test: `Tests/OpenStackClientTests/NetworkServiceTests.swift`

**Interfaces:**
- Consumes: as Task 8.
- Produces: `NetworkRegion` exposing:
  - networks CRUD (provider attrs `provider:network_type/physical_network/segmentation_id` gated on extension `provider`? spec says "when the extension exists" — gate on alias `provider` OR `qos`? Use alias set: provider attrs accepted only when extension `provider` advertised; fakes advertise it), subnets CRUD (allocation pools, `ip_version` 4/6, `enable_dhcp`, gateway), ports CRUD (`fixed_ips: [{ip_address?} | null-for-auto]`, `security_groups`, `extra_dhcp_opts`, `device_id/owner`, `admin_state_up`, `port_security_enabled`), routers CRUD (+ `external_gateway_info` update), floating IPs CRUD (+ `port_id`/`fixed_ip_address` update = associate/disassociate), security groups CRUD + rules create/delete/list (immutable: no rule update), address groups CRUD gated on extension `address-group` (client throws feature error when absent), quotas get/update.
  - Models per Neutron JSON with `status` on network/port/router/floating_ip (`ACTIVE`/`DOWN`), `subnet_id`, `network_id`, etc.

- [ ] **Step 1: Write failing tests** — mirror Task 8 coverage: CRUD each resource against fake; `createPort(fixed_ips: [])` auto-assigns (fake picks from pool); `associateFloatingIP` sets `status ACTIVE` and `port_id`; `disassociate` back to `DOWN`; extension-gated: fake without `address-group` alias → `listAddressGroups()` throws feature error naming the alias; `404 NeutronError` normalized (code `ItemNotFound`); pagination via `marker`+`_links.next`.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter NetworkServiceTests`.

- [ ] **Step 3: Implement** — service type `network`, version doc via `GET /v2.0/extensions` for features (no microversion header on neutron), cache TTL 300s for networks/subnets/security_groups, 60s for ports/floating_ips (Global Constraints), invalidation on mutation incl. linked resources (port mutation invalidates `server` list too? NO — client cache invalidation stays within the resource + its obvious parents; cross-resource invalidation is the MCP-layer's job via catalog links in Task 12).

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter NetworkServiceTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): neutron network service with extension gating"`.

---

## Task 10: BlockStorageService + ImageService against the fakes

**Files:**
- Create: `Sources/FakeOpenStack/CinderFake.swift`, `Sources/FakeOpenStack/GlanceFake.swift`
- Create: `Sources/OpenStackClient/Services/BlockStorageService.swift`, `Sources/OpenStackClient/Services/ImageService.swift`, `Sources/OpenStackClient/Models/BlockStorageModels.swift`, `Sources/OpenStackClient/Models/ImageModels.swift`
- Test: `Tests/OpenStackClientTests/BlockStorageServiceTests.swift`, `Tests/OpenStackClientTests/ImageServiceTests.swift`

**Interfaces:**
- Consumes: as Tasks 8–9.
- Produces:
  - `BlockStorageRegion` (Cinder v3, floor 3.44, `OpenStack-API-Version: volume 3.x`): volumes CRUD (create from `image`/`source_vol`/`snapshot_id`/`bootstrap_volume_id`+`image_id`; `availability_zone`, `size`, `volume_type`, `metadata`, `name`, `description`, `multiattach`), `extend(volumeID:, size:)`, `retype(volumeID:, volumeType:)`, `resetStatus`, `uploadToImage(volumeID:) -> imageID`, `setBootable(volumeID:, bootable:)`, volume types CRUD, snapshots CRUD (`force`), backups list/create/delete (+ `restore` action into `volume_id` or new volume), quotas get/update. Statuses `creating/available/in-use/error/deleting`; terminal per spec §8.9.
  - `ImageRegion` (Glance v2): images CRUD (create registers metadata: `name`, `visibility`, `disk_format`, `container_format`, `size`, `min_ram`, `properties`; upload via `import` mechanism `web-download` from URL the cloud can reach — against the fake, the URL can point at a static route the fake serves — OR small base64 payload via direct `PUT /v2/images/{id}` with `X-Image-Meta` headers; implement BOTH paths, test both), `update` (name, visibility, properties, `protected`, `status` for deactivation/reactivation), tags add/remove, `setVisibility`, `protect/unprotect`, `deactivate/reactivate`, delete. Pagination via `marker`/`next` link header `Link: <...>; rel="next"` — decode it. Terminal `active`/`killed`.

- [ ] **Step 1: Write failing tests** — cinder: create from image (fake copies image ref), extend grows `size`, retype changes `volume_type`, backup restore creates new volume with `os-extended-volume-backup:backup_id` marker, `OpenStack-API-Version` header observed by fake (fake rejects when missing → pins the header), floor: fake with max 3.40 vs floor 3.44 → negotiation throw (reuse Task-6 pattern). glance: web-download import (fake fetches from its own static file route, sets `status active`), base64 small payload upload, `Link: rel=next` pagination followed, `killed` terminal on failed import (fake import URL 404 → image `killed` with error message), tags round-trip.

- [ ] **Step 2: Run to verify failure** — both test files.

- [ ] **Step 3: Implement** — service types `volumev3` (fall back `volume` if absent in catalog — pin: prefer `volumev3`), `image`. Cache TTLs: volumes 60s, images 300s.

- [ ] **Step 4: Run to verify pass** — both.

- [ ] **Step 5: Commit** — `git commit -m "feat(client): cinder block storage and glance image services"`.

---

## Task 11: OpenStackClient facade — `cloud.compute(region:)` etc.

**Files:**
- Create: `Sources/OpenStackClient/OpenStackClient.swift`
- Test: `Tests/OpenStackClientTests/OpenStackClientTests.swift`

**Interfaces:**
- Consumes: all of Tasks 2–10 (CloudConfig, Transport, Versioning, Identity, Cache, fakes, services).
- Produces: `actor OpenStackClient { init(cloud: CloudEntry, credential: ApplicationCredential, config: ClientSettings, logger: Logger); var identity: IdentityService; func compute(region: String?) -> ComputeRegion; func network(region: String?) -> NetworkRegion; func blockStorage(region: String?) -> BlockStorageRegion; func image(region: String?) -> ImageRegion; func whoami() async throws -> Whoami; func regions() -> [String]` (from catalog) `func zeroize()`. `struct ClientSettings { requestTimeout: Duration; maxConnectionsPerHost: Int; cacheMaxEntries: Int; ttlOverrides: [String: Duration] }`. One shared `Transport` + `Cache` per client; region strings defaulted to the cloud's `regionName` else first catalog region (resolve helper lives here, reused by the MCP layer).

- [ ] **Step 1: Write failing tests** — construct against the fake (Task 7+9+10 fakes now complete): `regions() == [RegionOne, RegionTwo]`; `compute(region: nil)` defaults to `RegionOne`; `blockStorage(region: "RegionTwo")` → first call throws the no-endpoint error (Review Focus 3 end-to-end through the facade); two `compute(region: "RegionOne")` calls return regions sharing one negotiator (version discovery counter stays 1).

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter OpenStackClientTests`.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(client): OpenStackClient facade over services"`.

**Phase-1 checkpoint:** `scripts/swift test` fully green (client + fakes). The client library is now complete per spec §16 part 1–2.

---

## Task 12: Resource catalog — all phase 1 entries

**Files:**
- Create: `Sources/OpenStackMCPServer/Catalog/ResourceDescriptor.swift`
- Create: `Sources/OpenStackMCPServer/Catalog/Catalog.swift` (+ per-service entry files if large: `ComputeEntries.swift`, `NetworkEntries.swift`, `IdentityEntries.swift`, `BlockStorageEntries.swift`, `ImageEntries.swift`)
- Test: `Tests/OpenStackMCPServerTests/CatalogCompletenessTests.swift`

**Interfaces:**
- Consumes: `OpenStackClient` service types (Task 11) for dispatch closures.
- Produces:
  - `enum Verb: String, CaseIterable, Sendable { case list, get, create, update, delete }`
  - `struct ActionSpec: Sendable { name: String; destructive: Bool; adminOnly: Bool; params: [ParamSpec] }`
  - `struct ParamSpec: Sendable { name: String; type: JSONType; required: Bool; enumValues: [String]?; description: String? }`
  - `struct LinkSpec: Sendable { kind: String; source: ResourceRef; target: ResourceRef; params: [ParamSpec]; preconditions: [String] }`
  - `struct ResourceRef: Hashable, Sendable { resource: String; idOrName: String? }`
  - `struct ResourceDescriptor: Sendable { name: String; service: Service; verbs: Set<Verb>; actions: [ActionSpec]; createSchema: JSONSchema?; updateSchema: JSONSchema?; listFilters: Set<String>; idField: String; nameField: String?; statusField: String?; terminalStates: [String]; defaultListFields: [String]; destructiveHints: [String]; dispatch: ServiceDispatch }`
  - `enum Service: String, Sendable { case identity, compute, network, blockStorage, image }`
  - `struct JSONSchema: Sendable, Codable` — small JSON-Schema subset (`type, properties, required, items, enum, description, additionalProperties`); `func validate(_ json: [String: AnyCodable-ish]) -> [ValidationIssue]` where `ValidationIssue { path: String; expected: String; found: String; fragment: String }` (spec §8.2: failing path, expected type, schema fragment so the model self-corrects in one turn). Use a `[String: JSONValue]` enum rather than AnyCodable to stay Sendable and testable.
  - `struct ResourceCatalog { static func phase1() -> ResourceCatalog; func descriptor(_ name: String) -> ResourceDescriptor?; var resources: [ResourceDescriptor] }` — every resource in spec §8.5 with verbs exactly as the matrix, actions exactly as §8.6, links exactly as §8.7, terminal states from §8.9 (server `ACTIVE/SHUTOFF/ERROR/SHELVED_OFFLOADED`; volume `available/in-use/error`; image `active/killed`; router+floating_ip `ACTIVE/DOWN`; subnet `ACTIVE`? spec does not list subnet terminal states — use `ACTIVE` and document; port `ACTIVE`; network `ACTIVE`; compute `ERROR`; others: empty list = wait unsupported → `os_wait` on them returns a clear "no terminal states" error.
  - `ServiceDispatch` — a `Sendable` struct of closure bundles mapping verb/action/link to the client calls (e.g. `list: @Sendable (ListRequest) async throws -> ListResult`); this is the seam that keeps the catalog declarative while the MCP layer never touches client types directly.

- [ ] **Step 1: Write failing tests** — `CatalogCompletenessTests.swift`:
  - Every descriptor with `.create` in verbs has a non-nil `createSchema`; every `.update` has `updateSchema`; every descriptor has ≥1 verb (spec §14.1).
  - Resource set matches the §8.5 matrix exactly — assert the full name list (33 names, Global Constraints) and per-resource verb sets for a sample that covers every cell type (server L/G/C/U/D; availability_zone L only; quota G/U only; security_group_rule L/C/D no U; image L/G/C/U/D).
  - Actions match §8.6: count and destructiveness flags — assert `server.rebuild.destructive == true`, `server.snapshot.destructive == false`, `floating_ip.disassociate.destructive == true`, `router.clear_gateway.destructive == true`, `compute_service.disable.destructive == true`, `image.deactivate.destructive == true`, `volume.reset_status.destructive == true`, `volume_backup.restore.destructive == true`, `server.evacuate.adminOnly == true`.
  - Terminal states match §8.9 for server/volume/image/router/floating_ip.
  - Links present: `volume`, `interface`, `security_group`, `floating_ip`, `router_interface`, `router_gateway`, `image` (spec §8.7).
  - Schema validation: `JSONSchema.validate` on a bad server create (missing `name`, `flavor` wrong type) yields issues with path `"flavor"`, expected `"string"`, and the fragment; a good spec yields zero issues.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter CatalogCompletenessTests`.

- [ ] **Step 3: Implement** — entries as data; schemas as the `JSONSchema` literals; dispatch closures wire to `OpenStackClient` facade (Task 11) — `dispatch` receives the client + region and performs the call, returning raw decoded JSON (`[String: JSONValue]`) so formatting (Task 13) is separate.

- [ ] **Step 4: Run to verify pass** — `scripts/swift test --filter CatalogCompletenessTests`.

- [ ] **Step 5: Commit** — `git commit -m "feat(server): phase-1 resource catalog with schemas, actions, links"`.

---

## Task 13: Policy + name resolution + validation + output shaping

**Files:**
- Create: `Sources/OpenStackMCPServer/Policy/Policy.swift`, `Sources/OpenStackMCPServer/NameResolver.swift`, `Sources/OpenStackMCPServer/Tools/ResultFormatting.swift`
- Test: `Tests/OpenStackMCPServerTests/PolicyTests.swift`, `Tests/OpenStackMCPServerTests/NameResolverTests.swift`, `Tests/OpenStackMCPServerTests/SchemaValidationTests.swift`

**Interfaces:**
- Consumes: `ResourceCatalog` (Task 12).
- Produces:
  - `struct Policy: Sendable { readOnly: Bool; denyResources: Set<String>; denyVerbs: [String: Set<Verb>]; denyActions: [String: Set<String>]; maxListLimit: Int; maxCallsPerMinute: Int; var defaultPolicy: Policy` (defaults: readOnly false, denyResources = the six identity-admin names per Global Constraints, maxListLimit 200, maxCallsPerMinute 120) `func effective(_ catalog: ResourceCatalog) -> ResourceCatalog` (applies denials) `func toolsEnabled(readOnlyList: [String] = ["os_list","os_get","os_describe","os_topology","os_find","os_whoami","os_quota","os_clouds","os_wait"]) -> Set<String>`.
  - `actor NameResolver { init(catalog: ResourceCatalog, client: @Sendable () -> OpenStackClient?) ; func resolve(descriptor: ResourceDescriptor, idOrName: String, region: String) async throws -> (id: String, raw: [String: JSONValue])` — exact ID first (`get` by id; 404 → not ID), exact name filter (`filters[name]`), then case-insensitive scan of listed names; ≥2 matches → throws `AmbiguousNameError(candidates: [(id, name)])` whose description lists id + name each (spec §8.2).
  - `struct ToolOutcome: Sendable { items: [ResourceItem]... }` — concretely: `struct ListResult: Codable, Sendable { resource: String; region: String; count: Int; items: [[String: JSONValue]]; nextMarker: String? }`; `struct MutationResult: Codable, Sendable { resource: [String: JSONValue]; requestID: String? }`; `func project(_ raw: [String: JSONValue], _ fields: [String]) -> [String: JSONValue]` (top-level projection; default per descriptor); `func errorParagraph(_ err: OpenStackError, what: String) -> String` — one paragraph: what failed, HTTP status, OpenStack message, request ID, hint; asserts no token/secret substrings (test with a fake error whose message contains "secret" → redacted to `[REDACTED]`).
  - `struct AmbiguousNameError: Error { candidates: [(id: String, name: String)] }`

- [ ] **Step 1: Write failing tests**
  - `PolicyTests`: default policy denies exactly the six identity names; `read_only` tool set == the 9 named; `denyVerbs ["server": [.delete]]` removes delete from server descriptor; `maxListLimit` clamps 500→200 (clamp applied in list tool, tested in Task 14 — here just assert policy exposes it).
  - `NameResolverTests` (against fake + Task-12 catalog): ID hit; name hit; case-insensitive hit ("My-Server" → "my-server"); ambiguous: two servers "web" → error listing both with IDs; ID that 404s then name that 404s → `notFound` error.
  - `SchemaValidationTests` (unit, no fake): validation issue fields per spec §8.2 (path, expected type, fragment); unknown list filter rejected with known list (filter validation function lives here: `func checkFilters(descriptor:, filters:) throws`); projection keeps only named top-level fields; `errorParagraph` contains status + request ID + hint and never the token.

- [ ] **Step 2: Run to verify failure** — all three test files.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(server): policy, name resolution, schema validation, result shaping"`.

---

## Task 14: Tool registry + describe tools + verb tools (in-process MCP tests)

**Files:**
- Create: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift`, `Sources/OpenStackMCPServer/Tools/DescribeTools.swift`, `Sources/OpenStackMCPServer/Tools/VerbTools.swift`, `Sources/OpenStackMCPServer/Session/Principal.swift` (MCP-side: wraps `OpenStackClient` + `Whoami` + fingerprint + elicitation flag)
- Test: `Tests/OpenStackMCPServerTests/DescribeToolsTests.swift`, `Tests/OpenStackMCPServerTests/VerbToolsTests.swift`, `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: Tasks 12–13, MCP SDK (`Server`, `Tool`, `InMemoryTransport`, `Client`).
- Produces:
  - `struct ServerContext: Sendable { policy: Policy; catalog: ResourceCatalog; clientFactory: @Sendable (MCPPrincipal) -> OpenStackClient; callLimiter: RateLimiter }`
  - `actor MCPPrincipal { init(credential: ApplicationCredential, cloudName: String, client: OpenStackClient); var whoami: Whoami?; var clientFingerprint: String` (SHA-256 of `cloud + id + secret` via swift-crypto; computed once at init, secret then zeroizable) `func zeroize()`.
  - `struct ToolRegistry { init(context: ServerContext); func server(for principal: MCPPrincipal) -> Server` — builds an MCP `Server` named `openstack-mcp` with the spec §8.4 instructions string (verbatim workflow: describe/find first, get before mutating, dry_run for destructive, os_wait after transitional creates/actions, os_topology before connectivity answers) and registers the 15 tools (9 under read-only):
    - `os_describe(resource: String?)` → catalog JSON for one or all (readOnly annotation).
    - `os_clouds()` → configured clouds + regions + session binding (readOnly).
    - `os_whoami()` → `Whoami` (readOnly).
    - `os_list(resource, region?, filters?, limit?, marker?, fields?, fresh?)` — limit default 50, clamped by `policy.maxListLimit`; result `ListResult` shape §8.3; readOnly.
    - `os_get(resource, id_or_name, region?, fields?)` — via NameResolver; readOnly.
    - `os_find(needle, region?)` — matches name, id, IPv4/IPv6 (fixed IPs), MAC (port), hostname across servers/ports/floating_ips/networks; readOnly.
    - `os_create(resource, spec, region?, wait?, timeout?, dry_run?)` — validate spec first (Task-13 `JSONSchema.validate`); `dry_run` returns the exact wire body without sending. The `wait`/`timeout` parameters are REGISTERED in this task (the input schema is final and never changes in Task 15), but their execution path dispatches through the `WaiterProtocol` seam (below); this task ships `NoOpWaiter` (returns the just-created resource immediately with a note that waiting is not yet wired) and Task 15 swaps in the real `Waiter` — no re-registration, no schema change, no TODO left in code.
    - `os_update(resource, id_or_name, patch, region?, dry_run?)` — idempotent annotation.
    - `os_delete(resource, id_or_name, region?, force?, dry_run?)` — destructive; `dry_run` lists dependents (network→ports, volume→attachments, router→interfaces+gateway, server→volumes+interfaces) via catalog links + client reads; elicitation per spec §8.3 (client capability flag on principal; decline → non-error "nothing deleted").
    - `os_action(resource, id_or_name, action, params, region?, wait?)` — destructive flag per action (§8.6).
    - `os_quota(resource in [compute, network, volume], region?, update?)` — update admin+policy-gated.
    - `os_attach` / `os_detach` / `os_topology` / `os_wait` — registered here as thin entries dispatching through three `Sendable` protocol seams — `LinkExecutorProtocol`, `TopologyBuilderProtocol`, `WaiterProtocol` — whose concrete implementations land in Task 15; the tool schemas are final in THIS task and never change in Task 15.
  - `WaiterProtocol` (declared here): `protocol WaiterProtocol: Sendable { func wait(resource: String, id: String, region: String, until: [String]?, timeout: Duration, progress: (@Sendable (String, Duration) -> Void)?) async throws -> [String: JSONValue] }` with `struct NoOpWaiter: WaiterProtocol` shipping in this task; Task 15's concrete `Waiter` conforms to the same protocol and is injected in its place — `ToolRegistry` holds `any WaiterProtocol`.
  - Every tool sets `structuredContent` + mirrored text block (§8.3); mutations return `requestID` from `X-OpenStack-Request-Id`.
  - `inputSchema` for `resource` is the catalog-generated enum; `filters`/`spec` are objects with the tool description pointing at `os_describe`.

- [ ] **Step 1: Write failing tests** — `InProcessMCPTests.swift` uses SDK `Client` + `InMemoryTransport` with a server built from `ToolRegistry` bound to the fake (Task 7–10) principal:
  - `initialize` succeeds; server instructions contain "os_describe".
  - `tools/list` full mode == 15 names (assert exact set); read-only mode == the 9.
  - `os_describe(resource: "server")` returns the schema; `os_list(resource: "server")` returns `count` and `items` with default projection `id,name,status,flavor,addresses,created` (assert keys exactly); unknown `resource` → tool error listing valid enum.
  - `os_list` limit clamp: request 500 → capped 200 items (fake seeded 250 servers? cheaper: fake returns limit-respecting pages; seed 250 lightweight servers via `FakeState.seed(count:)` helper added here).
  - `os_get` ambiguous name → error paragraph lists 2 candidates with IDs.
  - `os_create(server, spec)` happy path → `requestID` present; `dry_run` → returns body, fake server count unchanged (assert via direct state read).
  - `os_delete(dry_run: true)` on a network with a port → dependent listed, network still exists.
  - `os_find("10.0.0.5")` → resolves to the port AND the server owning it (assert both).
  - `os_action(server, stop)` destructive flag visible in tool annotations (assert `destructiveHint == true` on `os_action` metadata? per-action annotation is not expressible in one tool — pin: `os_action` is annotated destructive:true overall; the per-action table is in its description; assert the description contains "reboot" and "resize").
  - Error path: `os_create` with bad spec → tool error contains JSON path `"flavor"` and expected type string (self-correctable in one turn).

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter InProcessMCPTests`.

- [ ] **Step 3: Implement** — MCP SDK tool registration per the 0.12.x API (executor closure returns `CallToolResult` with `structuredContent`); progress tokens plumbed through to `os_wait` later.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(server): 15-tool registry, describe/verb tools, in-process MCP tests"`.

---

## Task 15: Links, topology, diagnosis, waiter with progress

**Files:**
- Create: `Sources/OpenStackMCPServer/Links/LinkRegistry.swift`, `Sources/OpenStackMCPServer/Links/Links.swift`, `Sources/OpenStackMCPServer/Links/Topology.swift`, `Sources/OpenStackMCPServer/Waiter.swift`
- Test: `Tests/OpenStackMCPServerTests/LinkToolsTests.swift`, `Tests/OpenStackMCPServerTests/TopologyTests.swift`, `Tests/OpenStackMCPServerTests/WaiterTests.swift`

**Interfaces:**
- Consumes: Tasks 11–14 (client, catalog; replaces Task 14's `LinkExecutorProtocol` / `TopologyBuilderProtocol` / `WaiterProtocol` seams with concrete implementations — the tool registrations and schemas from Task 14 are untouched).
- Produces:
  - `struct LinkExecutor: LinkExecutorProtocol, Sendable` (concrete; the protocol is declared in Task 14) — implements the 7 links from §8.7 with the exact APIs and precondition checks named there:
    - `volume`: Nova `os-volume_attachments` with `device` (default `vda`? pin: required param, error if absent) and `delete_on_termination` (feature-gated 2.79); preconditions: volume `available` (or multiattach) else error naming volume status; server not `BUILD`/`REBUILD`.
    - `interface`: Nova `os-interface`; target may be network/subnet/port; preconditions: target resolvable in region; resulting port unattached check when port given.
    - `security_group`: on server → Nova `addSecurityGroup`; on port → Neutron port update `security_groups`; precondition: port security enabled when on port.
    - `floating_ip`: Neutron floating IP update `port_id` (+`fixed_ip_address`); target port or server (server → first port on a router-reachable subnet — resolution helper `func firstRouterReachablePort(serverID:)`); precondition: port's subnet reachable from the FIP's external network via a router (check router interfaces/gateway; error naming the missing hop).
    - `router_interface`: Neutron `add_router_interface`; preconditions per §8.7.
    - `router_gateway`: Neutron router update `external_gateway_info` with `enable_snat` (default true) / `external_fixed_ips`; precondition: target network has `router:external` tag else error.
    - `image`: create-time link (Cinder from `imageRef`) — `os_attach` on link `image` is REJECTED with a message pointing at `os_create(volume, spec: {image: ...})` (pin this behavior; the reverse is the `upload_to_image` action already in the catalog).
    - `os_detach` reverses each (floating_ip detach = disassociate, never delete; volume detach deletes the attachment; router_gateway detach = `clear_gateway`? NO — detach removes `external_gateway_info`; same API shape).
    - `wait: true` on attach/detach uses the Waiter against the affected resources' terminal states.
  - `struct TopologyBuilder: TopologyBuilderProtocol, Sendable` (concrete; protocol declared in Task 14) — `os_topology(anchor: {resource, id_or_name}, depth: 1...3, diagnosis: Bool = false, region?)` returning `{nodes: [{resource, id, name, status, attributes}], edges: [{kind, source, target}], findings: [String]?}`; traversal rules exactly §8.8 for anchors server/network/router/floating_ip (subnet/port anchors: treat like their network's traversal from that node — document); `diagnosis` findings exactly the §8.8 list (port-security with no matching ingress rule for asked protocol — protocol/port come from optional `diagnose: {protocol, port}` param; subnet without router interface; router without gateway; FIP on unrouted subnet; server SHUTOFF/ERROR; DHCP disabled without fixed IP).
  - `struct Waiter` — `func wait(resource: String, id: String, region: String, until: [String]?, timeout: Duration, clock: any Clock<Duration>, progress: @Sendable (String, Duration) -> Void?) async throws -> [String: JSONValue]` — backoff 1s→10s (double each poll, cap 10s), stops on terminal (default catalog's), `ERROR`/`killed` (return with fault message), deleted-404 when waiting for delete, or timeout (tool error with elapsed + last status); `until` validated against known states (unknown state name → immediate error listing valid ones).

- [ ] **Step 1: Write failing tests** — `LinkToolsTests.swift` (fake-backed, in-process MCP client from Task 14):
  - volume attach: `os_attach(link: "volume", source: server, target: volume, params: {device: "vdb"}, wait: true)` → attachment visible, volume `in-use`, server `ACTIVE`; preconditions: volume `in-use` already → error naming status; `dry_run` on attach? (spec only pins dry_run for create/update/delete — attach has none; don't add).
  - floating_ip attach to server (not port) resolves first router-reachable port; unrouted subnet → error naming the missing router hop.
  - router_gateway attach to non-external network → error.
  - image link attach → rejected with the create-pointer message.
  - detach floating_ip → disassociated (`status DOWN`), FIP still exists.
  - `TopologyTests`: seed a full stack (network+subnet+router+gateway+ext+server+port+fip+volume) in fake; `os_topology(anchor: server, depth: 3)` → nodes include server, port, subnet, network, router, ext-net, fip, volume; edges include kinds `interface`, `router_interface`, `router_gateway`, `floating_ip`, `volume`; anchor network → ports grouped by device owner (assert group key); anchor floating_ip → path to external network; `diagnosis: true` with FIP on unrouted subnet → finding present; port security with no ssh ingress rule + `diagnose: {protocol: tcp, port: 22}` → finding.
  - `WaiterTests`: fake server transitions BUILD→ACTIVE after ~50ms (Task-8 `settle`); `os_wait(resource: server, id, timeout 5s)` returns `ACTIVE` with `elapsedSeconds < 5`; waiting for delete: id gone → success with `deleted: true` (pin result field); unknown `until` state → immediate error listing valid states; progress: server's initializeHook recorded a progress token? in InMemoryTransport, the test client captures notifications — assert ≥1 progress notification carrying the interim status (use the fake's slower transition: add `FakeState.transitionDelay` knob, set 120ms for this test).

- [ ] **Step 2: Run to verify failure** — all three.

- [ ] **Step 3: Implement** — wire into `ToolRegistry` (replacing Task-14 stubs); progress notifications via the SDK's progress-token support on `CallTool` requests.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(server): link operations, topology with diagnosis, waiter with progress"`.

---

## Task 16: MCP resources and prompts

**Files:**
- Create: `Sources/OpenStackMCPServer/Resources/MCPResources.swift`, `Sources/OpenStackMCPServer/Prompts/MCPPrompts.swift`
- Test: `Tests/OpenStackMCPServerTests/ResourcesPromptsTests.swift`

**Interfaces:**
- Consumes: Tasks 12, 14 (registry/server factory).
- Produces:
  - Resources on the `Server`: `openstack://catalog` and `openstack://catalog/{resource}` (static JSON from catalog, `subscribe: false`); `openstack://{cloud}/{region}/{resource}/{id}` registered in `resources/list` ONLY for the session's own cloud (URI template listed, not instances — list returns the template + catalog URIs; read resolves live via the client). Read of an unknown resource id → tool-style error message, not crash.
  - Prompts: `provision_server(name, flavor, image, network, public: Bool, volume_gb: Int)` → returns a user message containing the ordered plan text (find, create server, wait, create floating IP, attach, attach volume) with the argument values substituted; `diagnose_connectivity(from, to, port, protocol)` → message directing `os_topology` with `diagnosis: true` on both ends and to explain the first blocking finding; `audit_security_groups()` → message directing list of security_group_rule with `0.0.0.0/0` ingress on ports 22/23/3389/5900 and listing groups with zero rules.

- [ ] **Step 1: Write failing tests** — in-process MCP client: `resources/list` includes the catalog URIs and the template (assert exact URIs); `resources/read openstack://catalog/server` returns JSON containing `"verbs"` and the create schema; `prompts/list` == the three names with declared arguments (assert argument names/types per spec §9); `prompts/get provision_server` with sample args → text contains "floating IP" and the given name/flavor values.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter ResourcesPromptsTests`.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(server): openstack:// resources and three prompts"`.

---

## Task 17: HummingbirdMCP adapter — route, request/response mapping, SSE

**Files:**
- Create: `Sources/HummingbirdMCP/HummingbirdMCP.swift`, `Sources/HummingbirdMCP/SessionRegistry.swift`, `Sources/HummingbirdMCP/Authenticator.swift`
- Test: `Tests/HummingbirdMCPTests/TransportTests.swift`

**Interfaces:**
- Consumes: Hummingbird 2.26, MCP SDK 0.12 (`StatefulHTTPServerTransport`, `Server`, validators).
- Produces:
  - `struct MCPConfig { endpoint: String; allowedOrigins: [String]; maxBodyBytes: Int; maxSessions: Int; maxStreamsPerSession: Int; idleTTL: Duration; maxLifetime: Duration; cleanupInterval: Duration = .seconds(60) /* default 1 minute per spec §7.1; test-only override for eviction tests */ }`
  - `struct MCPRoute { init(config: MCPConfig, authenticator: any BearerAuthenticator, serverFactory: @Sendable (SessionContext) async throws -> Server, logger: Logger); func install(on router: Router) }` — mounts `POST/GET/DELETE` on `config.endpoint`.
  - `protocol BearerAuthenticator: Sendable { func authenticate(request: HTTPRequest-ish, body: Data) async throws -> PrincipalCandidate }` with `struct PrincipalCandidate { fingerprint: String; displayName: String }` — the OpenStack implementation (real Keystone check) lands in Task 18; here the adapter takes the protocol so `HummingbirdMCP` stays OpenStack-free.
  - `actor SessionRegistry { struct Session { server: Server; transport: StatefulHTTPServerTransport; principal: PrincipalCandidate; lastAccessedAt: Date; createdAt: Date; clientInfo: ClientInfo? } ; func get(id: String) -> Session?; func register(...); func terminate(id: String); func evictExpired(now: Date) }` + a cleanup task started by `MCPRoute.install` (1-minute interval, spec §7.1).
  - Request flow exactly §7.1: body-collecting middleware (limit → 413), fingerprint check on known sessions (mismatch → 401), unknown session id → 404, no session id + non-initialize → 400 JSON-RPC, initialize → factory + transport creation + session id from response header.
  - Response mapping §7.1.4: `.accepted`→202, `.ok`→200, `.data`→200 `application/json`, `.stream`→200 `text/event-stream` + `Cache-Control: no-cache` + `X-Accel-Buffering: no` + `ResponseBody(asyncSequence:)` over Data chunks, `.error`→its status + JSON-RPC body.
  - DELETE → `server.stop()`, transport disconnect, `terminated` callback (Task 18 uses it to zeroize), 200.
  - Validator pipeline §7.1: `OriginValidator(allowedOrigins)` (default localhost; invalid present Origin → 403), `AcceptHeaderValidator(.sseRequired)`, `ContentTypeValidator`, `ProtocolVersionValidator`, `SessionValidator`.

- [ ] **Step 1: Write failing tests** — `HummingbirdMCPTests/TransportTests.swift` with a TRIVIAL fake server factory (an MCP `Server` with one tool `echo` returning its input; no OpenStack):
  - `initialize` via `HummingbirdTesting` returns 200, `Mcp-Session-Id` header present, result has serverInfo.
  - `tools/call echo` with session id → 200 JSON-RPC result.
  - `tools/call` without session id → 400; with bogus session id → 404.
  - SSE: client sends `Accept: text/event-stream` on POST → response content-type `text/event-stream`, body contains `data:` framing for the notification; a GET stream connection receives at least one event and stays open until server pushes (assert framing bytes, then close).
  - Origin: `Origin: https://evil.example` → 403; `Origin: http://localhost:3000` (in allow list) → proceeds.
  - Body > limit → 413.
  - DELETE → 200 and subsequent request with that session id → 404.
  - Idle eviction: `idleTTL` 1s, wait 1.2s, request → 404 (cleanup interval shortened to 200ms for tests via `MCPConfig.cleanupInterval` — pin this test-only knob).
  - **Review Focus 4 (pinned here):** re-`initialize` on a session with a DIFFERENT credential (factory sees two candidates) → 401, original session still works.
  - **Review Focus 5 (pinned here):** after DELETE/eviction, a late request must not trigger the factory (assert factory call count unchanged) — i.e., no re-auth with a zeroed principal.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter HummingbirdMCPTests.TransportTests`.

- [ ] **Step 3: Implement** — mirror the SDK conformance server's session pattern (spec §4) but with the actor registry and middleware; `ResponseBody(asyncSequence:)` over the SDK stream.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(adapter): HummingbirdMCP route, session registry, SSE mapping"`.

---

## Task 18: OpenStack authenticator + sessions + serve/stdio wiring

**Files:**
- Create: `Sources/OpenStackMCP/Config.swift`, `Sources/OpenStackMCP/Commands/Serve.swift`, `Sources/OpenStackMCP/Commands/Stdio.swift`, `Sources/OpenStackMCP/main.swift`, `Sources/OpenStackMCPServer/Session/AppCredAuthenticator.swift`
- Test: `Tests/HummingbirdMCPTests/SessionTests.swift` (auth flow against fake), `Tests/HummingbirdMCPTests/SoakTests.swift` (moved here from a dedicated file — it exercises the full stack)

**Interfaces:**
- Consumes: Tasks 11, 14, 17.
- Produces:
  - `struct AppCredAuthenticator: BearerAuthenticator` — parses bearer (Task 2 `parseBearer`, first-colon rule), resolves cloud via `X-OpenStack-Cloud` header or `clouds.default` (unknown cloud name → 401 with `WWW-Authenticate: Bearer error="invalid_cloud"`), authenticates against the fake-or-real Keystone via `Principal.authenticate()` (Task 5) — 401 `invalid_token` on failure; builds `MCPPrincipal` + `OpenStackClient`; fingerprint = SHA-256(`cloud + id + secret`) (swift-crypto).
  - `struct OpenStackMCPConfig` (swift-configuration): ALL keys from spec §11.2 table with the Global-Constraints defaults; providers order: flags → env `OSMCP_` (`__` separator) → YAML `--config` (default `/etc/openstack-mcp/config.yaml`, absent OK) → defaults.
  - `serve` command: builds Hummingbird app with middleware (request log, metrics, body limit, authenticator only on `/mcp`), routes `/mcp` (MCPRoute), `/healthz` (200), `/readyz` (per configured cloud: Keystone version discovery ≤ 2s else 503 with details; never authenticates), `/metrics` (Prometheus; optional `metrics_token` bearer check), `MCPRoute.install`; `initializeHook` records client name/version/capabilities incl. elicitation + progress token support onto the session; rate limiting: failed auths per source IP (default 10/min → 429) and per-session tool calls (`max_calls_per_minute` 120 → tool error).
  - `stdio` command: env per spec §6.1 stdio paragraph (`OS_CLOUD` + clouds.yaml app-cred entry OR the `OS_AUTH_URL`/`OS_APPLICATION_CREDENTIAL_ID`/`OS_APPLICATION_CREDENTIAL_SECRET` trio + optional `OS_REGION_NAME`/`OS_INTERFACE`/`OS_CACERT`), one `MCPPrincipal`, SDK `StdioTransport`, same `ToolRegistry` server; logs to stderr only (pin: `log.format` text in stdio regardless of config? spec says stderr only — keep configured format, force stderr).
  - Session end (DELETE or eviction) → `MCPPrincipal.zeroize()`.

- [ ] **Step 1: Write failing tests** — `SessionTests.swift` (HummingbirdTesting against the full serve app wired to the fake cloud via a test `clouds.yaml` fixture pointing at the fake's URL):
  - **Review Focus 1 (pinned here):** `initialize` with `Authorization: Bearer fake-cred-one:sec:ret:colon` where the seeded fake credential's secret IS `sec:ret:colon` → 200 + session (fake seeded accordingly in this test via `FakeState.seedCredential(id:secret:project:)`); assert first-colon split by also seeding `id` with a 32-hex value.
  - Wrong secret → 401 + `WWW-Authenticate: Bearer error="invalid_token"`, NO session created (registry count 0).
  - `X-OpenStack-Cloud` for unknown name → 401 `invalid_cloud`.
  - Auth rate limit: 11 consecutive bad-secret attempts from same IP → 11th is 429 (counter reset per minute; test injects clock).
  - Full happy path: initialize (seeded credential) → `tools/list` (15) → `os_list servers` (fake data) → DELETE 200.
  - `/healthz` 200; `/readyz` 200 with fake up, 503 with body naming the cloud when fake stopped.
  - `/metrics` contains `osmcp_sessions_active` after a session, `osmcp_tool_calls_total{tool="os_list",outcome="ok"}` after a call.
  - `SoakTests.swift` (spec §14.7): 50 concurrent sessions (25 cred-one, 25 cred-two) against the fake, each does initialize + `os_list servers` + delete; assert: all succeed, each session's server list contains ONLY its own project's seeded servers (project isolation — fake enforces per Task 7), no cross-session cache hits (`Cache.stats` per-principal keys distinct).

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter "SessionTests|SoakTests"`.

- [ ] **Step 3: Implement** — config wiring is mechanical (swift-configuration `Config` with `ConfigProvider` chain); serve app composition per above.

- [ ] **Step 4: Run to verify pass** (soak included; it is the first multi-second test — keep under 30s with a fake `transitionDelay` of 10ms).

- [ ] **Step 5: Commit** — `git commit -m "feat(app): serve/stdio commands, app-cred authenticator, health/metrics, soak test"`.

---

## Task 19: Logging, redaction, audit, metrics completeness

**Files:**
- Create: `Sources/OpenStackMCP/Logging.swift`, `Sources/OpenStackMCP/Metrics.swift`
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift` (audit hook), `Sources/OpenStackClient/Transport/Transport.swift` (metrics labels if missing)
- Test: `Tests/OpenStackMCPTests/RedactionTests.swift`, `Tests/OpenStackMCPTests/ConfigTests.swift`

**Interfaces:**
- Consumes: Tasks 18, swift-log, swift-metrics, swift-prometheus.
- Produces:
  - `func makeLogger(level:, format:, stream:) -> Logger` — JSON by default (serve→stdout, stdio→stderr); every record carries `session`, `cloud`, `region`, `tool`, `request_id` metadata fields when known (via `Logger.withMetadata` at call sites — the ToolRegistry sets them per call).
  - Redaction layer: a `LogHandler` wrapper or metadata sanitizer dropping values for keys `Authorization`, `X-Auth-Token`, `X-Subject-Token` and any field named `secret`, `password`, `adminPass`, `user_data` (replace with `"[REDACTED]"`). Applied to the JSON formatter's serialization of payloads.
  - Audit records: one log line (level `.info`, category `audit`) per MUTATING tool call: time, session fingerprint, application credential ID, project ID, tool, resource, id, outcome (ok/error), OpenStack request ID. Gated by `log.audit` (default true).
  - Metrics (all names/labels per spec §12): `osmcp_tool_calls_total{tool,outcome}`, `osmcp_tool_duration_seconds{tool}` (histogram), `osmcp_openstack_requests_total{service,method,status}`, `osmcp_openstack_request_duration_seconds{service}`, `osmcp_sessions_active` (gauge, via registry callbacks), `osmcp_auth_failures_total{reason}`, `osmcp_cache_hits_total{resource}`. Register once at serve startup; `/metrics` renders via swift-prometheus.

- [ ] **Step 1: Write failing tests** — `RedactionTests.swift`:
  - A log emission whose payload dict contains `password: "hunter2"` and `user_data: "bmF5..."` → serialized JSON contains `"[REDACTED]"` and NOT the values (capture via a test `LogHandler` that records formatted strings).
  - Audit line shape: call `os_create` (in-process, fake) → audit log captured (inject test handler) with credential ID, project ID, tool `os_create`, outcome `ok`, request ID non-nil; `os_list` (read) → NO audit line.
  - `ConfigTests.swift`: env `OSMCP_SERVER__PORT=9999` overrides default 8080 (parse via swift-configuration in a unit, no server bind); YAML file with `policy.read_only: true` → config reflects it; flag beats env beats yaml (3-source precedence test with three different values).

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter "RedactionTests|ConfigTests"`.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify pass** (full `scripts/swift test` green — metrics labels may surface in Task 18's `/metrics` assertions; ensure both test files agree on metric names).

- [ ] **Step 5: Commit** — `git commit -m "feat(app): redacting structured logs, audit records, prometheus metrics"`.

---

## Task 20: CLI — check, access-rules, tools

**Files:**
- Create: `Sources/OpenStackMCP/Commands/Check.swift`, `Sources/OpenStackMCP/Commands/AccessRules.swift`, `Sources/OpenStackMCP/Commands/Tools.swift`
- Test: `Tests/OpenStackMCPTests/AccessRulesTests.swift`, `Tests/OpenStackMCPTests/SubcommandTests.swift`

**Interfaces:**
- Consumes: Tasks 11–14 (client, catalog), swift-argument-parser.
- Produces:
  - `check` subcommand (spec §11.3): authenticates with the ENV application credential (stdio-mode env rules, Task 18), prints: project, roles, regions, services per region, negotiated versions (per service), Neutron extensions, and access-rule gaps (compare `whoami().accessRules` against the rules `access-rules --mode operator` would emit, per service; when the credential is `unrestricted`, print "unrestricted — gaps not applicable"; when the cloud's services lack `service_type` in keystonemiddleware (detect: rules present but a permitted GET still 403s on probe → say "rules may not be enforced"), print the spec's note). Exit 0 on success, 1 on auth failure, 2 on config error.
  - `access-rules` subcommand: walks the EFFECTIVE catalog (after policy, `--read-only` applies read-only policy) and emits the JSON list Keystone expects: per service, per verb/action/link: `{service, method, path}` with `*` for one segment, `**` for many. Paths are RELATIVE TO THE SERVICE ROOT as mounted in the Keystone catalog (this is what keystonemiddleware compares against). Exact pinned path sets, exported as `enum AccessRulePaths { static let compute: [Rule]; static let network: [Rule]; static let blockStorage: [Rule]; static let identity: [Rule]; static let image: [Rule] }` so the tests assert against the constants, not re-hardcoded strings:
    - compute (Nova): `GET/POST /servers`, `GET/PATCH/DELETE /servers/*`, `POST /servers/*/action`, `GET/POST /servers/*/os-volume_attachments`, `DELETE /servers/*/os-volume_attachments/*`, `GET/POST /servers/*/os-interface`, `DELETE /servers/*/os-interface/*`, `GET /servers/detail`, `GET/POST /flavors`, `GET/DELETE /flavors/*`, `GET/POST /os-keypairs`, `DELETE /os-keypairs/*`, `GET/POST /os-server-groups`, `GET/DELETE /os-server-groups/*`, `GET /os-availability-zone`, `GET /os-hypervisors`, `GET /os-hypervisors/*`, `GET /os-services`, `PUT /os-services/*`, `GET/PUT /os-quota-sets/*`
    - network (Neutron, paths under `/v2.0/`): `GET/POST /v2.0/networks`, `GET/PATCH/DELETE /v2.0/networks/*`, `GET/POST /v2.0/subnets`, `GET/PATCH/DELETE /v2.0/subnets/*`, `GET/POST /v2.0/ports`, `GET/PATCH/DELETE /v2.0/ports/*`, `GET/POST /v2.0/routers`, `GET/PATCH/DELETE /v2.0/routers/*`, `PUT /v2.0/routers/*/add_router_interface`, `PUT /v2.0/routers/*/remove_router_interface`, `GET/POST /v2.0/floatingips`, `GET/PATCH/DELETE /v2.0/floatingips/*`, `GET/POST /v2.0/security-groups`, `GET/PATCH/DELETE /v2.0/security-groups/*`, `GET/POST /v2.0/security-group-rules`, `DELETE /v2.0/security-group-rules/*`, `GET/POST /v2.0/address-groups` + `/v2.0/address-groups/*` (emitted only when the `address-group` extension is present — the generator takes the extension set as input), `GET/PUT /v2.0/quotas/*`
    - blockStorage (Cinder v3): `GET/POST /volumes`, `GET/PATCH/DELETE /volumes/*`, `POST /volumes/*/extend`, `POST /volumes/*/retype`, `POST /volumes/*/reset_status`, `POST /volumes/*/upload_to_image`, `POST /volumes/*/set_bootable`, `GET/POST /volumes/types` + `/volumes/types/*`, `GET/POST /volumes/snapshots`, `GET/PATCH/DELETE /volumes/snapshots/*`, `GET/POST /volumes/backups`, `GET/DELETE /volumes/backups/*`, `POST /volumes/backups/*/restore`, `GET/PUT /os-quota-sets/*`
    - identity (Keystone v3): `GET/POST /projects`, `GET/PATCH/DELETE /projects/*`, `GET/POST /users`, `GET/PATCH/DELETE /users/*`, `GET/POST /groups`, `GET/PATCH/DELETE /groups/*`, `GET/POST /roles`, `GET/PATCH/DELETE /roles/*`, `POST/DELETE /projects/*/users/*/roles/*` (Keystone v3 role assignments live under projects/users — there is no `role_assignments` collection path), `GET/POST /domains` + `/domains/*`, `GET /services`, `GET /endpoints`, `GET /endpoints/*`, `GET /users/*/application_credentials/*`, `GET /regions` + `/regions/*`. (The `check` subcommand's access-rule gap detection for the `role_assignment` resource uses `POST/DELETE /projects/*/users/*/roles/*`; there is no separate read-only rule set for role assignments.)
    - image (Glance v2): `GET/POST /images`, `GET/PATCH/DELETE /images/*`, `PUT /images/*` (upload), `GET/POST /images/*/tags`? — tags are `GET/POST /images/*/tags`, `DELETE /images/*/tags/*`
    - `--mode read-only` → GET (and HEAD, emitted as GET — Keystone rules use the method as-is; pin GET only) methods only; `--mode operator` → all methods above; `--services a,b` / `--resources x,y` subset filters (resource filter removes that resource's paths). Output: bare JSON to stdout (parseable by `openstack application credential create --access-rules`), human notes to stderr (including the spec's note that services must set `service_type` in keystonemiddleware for rules to be enforced).
  - `tools` subcommand: dumps the tool list (name, description, annotations, inputSchema) for the effective policy — `--json` machine output, default human table; this is the documentation/diff artifact (spec §11.3).

- [ ] **Step 1: Write failing tests** — `AccessRulesTests.swift`:
  - `--mode read-only` output: only `GET` (and `HEAD`? pin: GET only) methods present; count > 0; every rule has `service`, `method`, `path` keys; identity admin services appear ONLY if not denied (default policy denies the resources but the SERVICE still needs GET for whoami/catalog? pin: whoami needs `GET /v3/auth/tokens` (unauthenticated path — never in rules) and `GET /v3/users/*/application_credentials/*` → assert that rule present, `POST /v3/projects` absent).
  - `--mode operator` ⊇ read-only set; includes `POST /servers`, `DELETE /servers/*`, `POST /servers/*/action`, `PUT /v2.0/routers/*` (router gateway), `POST /v3/volumes/*/actions`? (cinder action path — pin from Task 10's actual paths; the test asserts against the constants exported by the access-rules builder, not re-hardcoded).
  - `--services compute` → no network rules.
  - `SubcommandTests.swift` (run the executable via Process in the container, or call the parser entry directly — pin: direct function calls into a `func run(_ args: [String]) async -> Int` exposed by the command types for testability): `check` against the fake (env vars set to fake's credential) → exit 0, stdout contains project name, regions, `2.104`; against bad secret → exit 1. `tools --json` → valid JSON with 15 tool names; `tools --read-only --json` → 9.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter "AccessRulesTests|SubcommandTests"`.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(cli): check, access-rules generator, tools dump"`.

---

## Task 21: Deployment assets + README

**Files:**
- Create: `deploy/Dockerfile`, `deploy/openstack-mcp.service`, `deploy/caddy/Caddyfile`, `deploy/nginx/openstack-mcp.conf`
- Modify: `README.md` (full), `scripts/build.sh` (release)

**Interfaces:**
- Consumes: Task 1 `build.sh`, Task 18 serve command.
- Produces (spec §13):
  - `Dockerfile`: multi-stage — builder `swift:6.4-rhel-ubi10`, runtime `ubi10-minimal`-equivalent from the Red Hat registry (`registry.access.redhat.com/ubi10/ubi10-minimal:latest` + `ca-certificates`) — wait, spec says `rockylinux:9-minimal`; but the build base chosen by the owner is UBI10 (memory). Pin: runtime `registry.access.redhat.com/ubi10/ubi10-minimal:latest` with `dnf install -y ca-certificates`, non-root user `openstack-mcp` (uid 10001), `clouds.yaml` expected at `/etc/openstack/clouds.yaml` (mount), config at `/etc/openstack-mcp/config.yaml` (mount), EXPOSE 8080, ENTRYPOINT `openstack-mcp serve --host 0.0.0.0 --port 8080` (the CLI flag beats the `OSMCP_` env per Task 19's precedence order — pin it: inside the container the bind MUST be 0.0.0.0 regardless of `OSMCP_SERVER__HOST`, because the port is published by docker; TLS terminates at the proxy per spec §7.3). Note the deviation from the spec's Rocky 9 runtime in the README (owner chose UBI10 toolchain image; runtime follows suit).
  - `openstack-mcp.service`: `DynamicUser=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, `EnvironmentFile=-/etc/openstack-mcp/env` for `OSMCP_*`, `ExecStart=/usr/bin/openstack-mcp serve --config /etc/openstack-mcp/config.yaml`.
  - Caddyfile + nginx conf: reverse proxy to 127.0.0.1:8080, `proxy_buffering off` for SSE (nginx: `proxy_buffering off; proxy_cache off;` on the `/mcp` location; Caddy: `flush_interval -1`).
  - README: overview, quickstart (container build, clouds.yaml example with app-cred auth, `serve` + Claude Code `claude mcp add --transport http openstack https://host/mcp --header "Authorization: Bearer ID:SECRET" --header "X-OpenStack-Cloud: prod"`), stdio setup (Claude Desktop entry with `OS_CLOUD`), config reference (table from spec §11.2), security notes (bearer = credential, TLS off-host, access rules, read-only mode), development (scripts/swift, fake server `openstack-mcp-fake`, integration test env `OSMCP_IT_CLOUD`).

- [ ] **Step 1: Verify release build in the container** — Run: `scripts/build.sh` — expected: single static binary `./.build/release/openstack-mcp` (on UBI10 with Swift 6.4, `--static-swift-stdlib` produces the static binary per spec §13); run `./.build/release/openstack-mcp tools --read-only --json` → 9 tools; `--help` → five subcommands.

- [ ] **Step 2: Write the assets** — per interfaces above.

- [ ] **Step 3: Smoke the docker build** — Run: `docker build -f deploy/Dockerfile -t openstack-mcp:local .` then `docker run --rm -e OSMCP_SERVER__PORT=8080 openstack-mcp:local tools --json | head` (the container image includes the binary; `tools` works without clouds.yaml) — expected: JSON tool list. If the registry image is unavailable in the test environment, mark the step as verified-by-build-arg and note it.

- [ ] **Step 4: Commit** — `git commit -m "feat(deploy): UBI10 dockerfile, systemd unit, proxy configs, README"`.

---

## Task 22: Integration test (opt-in) + conformance pass + final hardening sweep

**Files:**
- Create: `IntegrationTests/IntegrationTests.swift` (SwiftPM test target `OpenStackMCPIntegrationTests`, `enabledIfEnv OSMCP_IT_CLOUD`-style skip: the test self-skips when `OSMCP_IT_CLOUD` is unset — pin the skip mechanism: `#expect` inside `guard let cloud = ProcessInfo.processInfo.environment["OSMCP_IT_CLOUD"] else { return }`... that silently passes; better: print skip + return, documented as an opt-in target run explicitly)
- Create: `Package.swift` modification (add integration test target)
- Test: this task's deliverable

**Interfaces:**
- Consumes: everything.
- Produces:
  - Integration target (spec §14.6): reads `OSMCP_IT_CLOUD` (cloud name from the real `clouds.yaml`) + env credential; pass 1 read-only: `os_whoami`, `os_clouds`, `os_list servers/networks/volumes/images`, `os_describe`; pass 2 (only when `OSMCP_IT_MUTATE=1` additionally set — pin this gate so CI never mutates by accident): create a 1GB volume → attach to... a scratch server requires compute quota; pin the mutate pass as: create network+subnet, create port, delete port, delete subnet, delete network (network-only to avoid server quota), each cleanup in `defer`; tagged resources get metadata `openstack-mcp-it: true`.
  - Conformance (spec §14.5): a script `scripts/conformance.sh` that starts `openstack-mcp serve` against the fake (clouds.yaml fixture in `/tmp`), then drives the FULL MCP handshake with the BINARY ITSELF as the HTTP client — no `curl` (absent from the ubi10-minimal runtime and not assumed on dev hosts): add a hidden `openstack-mcp conformance --url http://127.0.0.1:8080/mcp --bearer <fake-cred>` subcommand (internal, not documented in `--help`; implements initialize → tools/list → tools/call os_whoami → DELETE with raw JSON-RPC over its own `URLSession`/AHC stack, asserting each response and printing PASS/FAIL per step, exit 0/1). MCP Inspector steps are documented in the README for manual runs. Mark this as conformance-HTTP-smoke.
  - Hardening sweep (spec §12 checklist): a final test `HardeningTests.swift` (in `HummingbirdMCPTests`) asserting: default bind is 127.0.0.1 (config default), origin validation rejects cross-origin, body limit 413, per-IP auth limit 429, per-session tool limit (121st call in a minute → tool error with rate-limit message), `user_data` never appears in any `os_get server` response or log (fake seeds a server with user_data; assert absence), console URLs from `os_action console_url` returned to the requesting session only (assert the value matches the fake's session-scoped console map); `server.metrics_token` set → `/metrics` without the token is 401, with it is 200; `session.max_lifetime` 1s → a session that survives its idle TTL but not its max lifetime is evicted (404 on the next request).

- [ ] **Step 1: Write failing tests** — `HardeningTests.swift` (per above) + integration target skeleton that compiles and self-skips + `conformance` subcommand (hidden) with its own test that runs against the in-process fake+serve app: initialize → tools/list (15) → os_whoami → DELETE, PASS per step.

- [ ] **Step 2: Run to verify failure** — `scripts/swift test --filter HardeningTests`.

- [ ] **Step 3: Implement** — per-session rate limiter in `ServerContext` (Task 14's `callLimiter` wired for real: sliding 60s window, 120 calls, tool error on overflow); user_data stripping at the result formatter (Task 13 `project`/raw passthrough must drop `user_data` key on server resources — pin the rule in `ResultFormatting`: servers never expose `user_data`); console URL scoping in the fake + service (fake already per-project; assert).

- [ ] **Step 4: Run the FULL suite** — `scripts/swift test` — expected: ALL targets green (client, fakes, MCP server, adapter, app, hardening). This is the phase-1 completion gate.

- [ ] **Step 5: Commit** — `git commit -m "test: hardening sweep, opt-in integration target, conformance smoke script"`.

---

## Sequencing and dependency map

```
1 (scaffold)
├── 2 (cloudconfig) ── 3 (transport) ──┬── 4 (cache)
│                                      ├── 5 (identity) ◄── 4,6
│                                      └── 6 (versioning) ◄── 4
├── 7 (fake keystone+nova) ◄── 5,6
│     └── 8 (compute) ── 9 (network) ── 10 (cinder+glance) ── 11 (facade)
└── 12 (catalog) ◄── 11
      └── 13 (policy/names) ── 14 (tools) ── 15 (links/topology/wait) ── 16 (resources/prompts)
                                                                                      │
17 (adapter) ── 18 (auth/sessions/serve/stdio) ◄── 14,16,17 ── 19 (logging/metrics)
      ── 20 (CLI) ◄── 14,18 ── 21 (deploy) ◄── 18 ── 22 (hardening/integration) ◄── all
```

Tasks 2–6: 3 needs 2's types; 4 (cache) is independent of 3–5 and could run alongside them; 5 (identity) needs 3 + 4 + 6's models; 6 (versioning) needs 3 — its production wiring uses 4's `Cache`, but its unit test stubs it, so 6 may land before 4 in a parallel run only if the stub is used in the commit (numeric order avoids this). 7 needs 5 + 6 (token catalog shape). 17 is independent of the client chain after 1 (it takes protocol seams) and can run in parallel with 12–16. Subagent-driven execution should follow numeric order for interface stability, dispatching 17 early if a spare worker is available.

## Self-Review Notes (run at plan write; fixed inline)

- **Spec coverage (post-renumbering):** §1–5 → Tasks 1, 11, 12, 17. §6.1 HTTP → 2, 17, 18; stdio → 18; phase-2 modes explicitly NOT built (non-goals). §6.2 → 5, 18. §6.3 → 20. §6.4 → 13. §7.1 → 17, 18. §7.2 → 18. §7.3 → 18, 19. §8.1–8.4 → 14, 15. §8.5 → 12 (+8–10 for client ops). §8.6 → 8, 10, 12. §8.7 → 15. §8.8 → 15. §8.9 → 15. §9 → 16. §10.1 → 6. §10.2 → 3, 8–10. §10.3 → 3. §10.4 → 4, 6, 8–10. §11 → 18, 19, 20, 21. §12 → 19, 22. §13 → 21. §14 → distributed per task; soak → 18; conformance → 22. §15 → 1, 21. §16 → whole plan. No uncovered phase-1 requirement found.
- **Type consistency:** `ApplicationCredential.parseBearer` (Task 2) used in Task 18; `OpenStackError.normalize` (Task 3) used in Tasks 5, 8–10, 13; `CacheKey` (Task 4) used in 6, 8–10; `ResourceDescriptor.dispatch` (Task 12) consumed by 14/15; protocol seams declared in Task 14 (`WaiterProtocol`, `LinkExecutorProtocol`, `TopologyBuilderProtocol`) with concrete conformers in Task 15 (`Waiter`, `LinkExecutor`, `TopologyBuilder`) — names match; `BearerAuthenticator` protocol (17) → `AppCredAuthenticator` (18); `MCPPrincipal` (14) zeroized in 18; metric names identical in 18 and 19 (Global Constraints list them).
- **Proportion:** 22 tasks, each carrying its own test cycle; the plan is ~1.3× the spec length, code blocks limited to test assertions and pinned data (schema paths, metric names, env var names). (Adversarial review pass 1 applied: task renumbering 4↔6, TTL table pinned to §10.4 verbatim, protocol seams renamed, container platform flag added, conformance script de-curl'd.)
- **Known deviations from spec (documented, owner-approved context):** (a) runtime base UBI10 instead of Rocky 9 (owner chose `swift:6.4-rhel-ubi10`; Task 21 runtime follows suit); (b) Swift 6.4 instead of the spec's 6.2 (owner's toolchain); (c) `openstack-mcp-fake` realized as a small second executable target if SPM forbids @main in a library (Task 1 note); (d) container build adds `--platform linux/amd64` for Apple Silicon host parity (Global Constraints); (e) Task 22 conformance smoke uses the binary's own HTTP stack instead of `curl` (absent from ubi10-minimal runtime); (f) cache TTLs follow spec §10.4 verbatim (Global Constraints) — the spec's §4 "starting values" paragraph is a different, Substation-derived table and is NOT the source of truth for this plan.
