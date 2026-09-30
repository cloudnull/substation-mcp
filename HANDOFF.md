# Handoff: OpenStack MCP Phase 1 — Task 15 onwards

## Current State

- **Branch**: `openstack-mcp` in worktree `/Users/cloudnull/Projects/openstack-mcp/.worktrees/openstack-mcp/`
- **Main**: up through Task 14 (commit `e96cad4`). All tasks through 14 merged.
- **Latest commit**: `e96cad4` — Task 14: ToolRegistry with 15 scope-aware MCP tools, in-process tests
- **Tests**: 233 tests in 22 suites, all green (84 MCP server in 6 suites, 149 client in 16 suites)
- **Build**: `scripts/swift build` (Apple Container, `swift:6.4-rhel-ubi10`, native arm64, `--cpus 8 --memory 16g`)

## Immediate Next Step

**Start Task 15: Links, topology, diagnosis, waiter with progress**

Implement `os_attach`/`os_detach` link operations (volume attach/detach, interface attach/detach, security group, floating IP, router interface/gateway).
Implement `os_topology` with depth-limited graph traversal and optional diagnosis findings.
Implement `os_wait` with polling loop and progress notifications.

## Remaining Tasks After 13

| Task | Description |
|------|-------------|
| 14 | Tool registry + describe tools + verb tools (in-process MCP tests) |
| 15 | Links, topology, diagnosis, waiter with progress |
| 16 | MCP resources and prompts |
| 17 | HummingbirdMCP adapter — route, token-per-request auth, SSE, PRM, login route |
| 18 | OpenStack validator + login page + token store + serve/stdio wiring |
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

## Fakes

| Fake | File | Base Path | Error Shape |
|------|------|-----------|-------------|
| Keystone | `KeystoneFake.swift` | `/keystone/v3` | `{"error":{"code","message"}}` |
| Nova | `NovaFake.swift` | `/nova` | `{"itemNotFound":{"message"}}` |
| Neutron | `NeutronFake.swift` | `/neutron/v2.0` | `{"NeutronError":{"type","message"}}` |
| Cinder | `CinderFake.swift` | `/cinder/v3` | `{"badRequest":{"message"}}` / `{"itemNotFound":{"message"}}` |
| Glance | `GlanceFake.swift` | `/glance/v2` | Plain text (`404 Not Found`) |

## Seeded Fixture Facts

- `proj-one`: `net-ext`/`net-int`, `subnet-ext` (10.0.0.0/24)/`subnet-int` (192.168.1.0/24),
  `port-001` (10.0.0.5), `fip-001` (203.0.113.10 DOWN), `sg-default`, `router-1`,
  3 servers (srv-0001..0003, ACTIVE), `seed-vol` (available, 10GB, lvmdriver-1), `img-1` (ubuntu-24.04, active, public, qcow2)
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
- `RequestIdentity` struct: Sendable` — holds `vt: ValidatedToken` + `whoami: Whoami`, built at session init
- `ToolRegistry: Sendable` — holds `client`, `catalog` (policy-filtered), `policy`, `identity`, `logger`
- `ToolRegistry.makeServer()` → `MCP.Server` with `ListTools` and `CallTool` handlers
- 15 tools: os_list, os_get, os_describe, os_topology, os_find, os_whoami, os_quota, os_clouds, os_wait, os_create, os_update, os_delete, os_action, os_attach, os_detach
- Scope-aware: `visibleToolNames` → 9 read-only or 15 (with write). `dispatch()` returns 403 error for mutating tools without write scope
- `dispatch(_ params: CallTool.Parameters)` routes to per-tool handlers (`handleList`, `handleGet`, `handleDescribe`, etc.)
- `handleLink` and `handleTopology`/`handleWait` are stubs (implemented in Task 15)
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

### Package.swift
- `OpenStackClientTests` depends on: `OpenStackClient`, `FakeOpenStack`, `HummingbirdTesting`, `Hummingbird`
- `OpenStackMCPServerTests` depends on: `OpenStackClient`, `FakeOpenStack`, `Hummingbird`, `MCP`

### Git / SDD Discipline
- Commit per task with descriptive message
- Merge to main after each task, sync worktree
- SDD ledger at `.superpowers/sdd/2026-09-28-openstack-mcp-phase-1/progress.md` (gitignored, local-only)
- Plan at `docs/superpowers/plans/2026-09-28-openstack-mcp-phase-1.md`
- Spec at `specs/openstack-mcp-spec.md`
