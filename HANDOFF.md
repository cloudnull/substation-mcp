# Handoff: OpenStack MCP Phase 1 — Task 10 onwards

## Current State

- **Branch**: `openstack-mcp` in worktree `/Users/cloudnull/Projects/openstack-mcp/.worktrees/openstack-mcp/`
- **Main**: up through Task 9 (merge commit `26ed426`). All tasks through 9 merged.
- **Latest commit**: `26ed426` — merge of Task 9 (NetworkService)
- **Tests**: 107 tests in 13 suites, all green
- **Build**: `scripts/swift build` (Apple Container, `swift:6.4-rhel-ubi10`, native arm64, `--cpus 8 --memory 16g`)

## Immediate Next Step

**Start Task 10: BlockStorageService (Cinder) + ImageService (Glance) + fakes**

**Files to create:**
- `Sources/FakeOpenStack/NeutronFake.swift` — extend fake with:
  - networks CRUD (provider attrs gated on extension `provider`)
  - subnets CRUD (allocation pools, `ip_version` 4/6, `enable_dhcp`, gateway)
  - ports CRUD (`fixed_ips`, `security_groups`, `extra_dhcp_opts`, `device_id/owner`, `admin_state_up`, `port_security_enabled`)
  - routers CRUD (+ `external_gateway_info` update)
  - floating IPs CRUD (+ `port_id`/`fixed_ip_address` update = associate/disassociate)
  - security groups CRUD + rules create/delete/list (immutable: no rule update)
  - address groups CRUD gated on extension `address-group`
  - quotas get/update
  - 404 `NeutronError{type:"ItemNotFound"}`, 400 `InvalidInput`, 409 `IpAddressInUse`
  - `limit/marker/_links` pagination
  - extension discovery endpoint returning seeded aliases

- `Sources/OpenStackClient/Services/NetworkService.swift`
- `Sources/OpenStackClient/Models/NetworkModels.swift`
- `Tests/OpenStackClientTests/NetworkServiceTests.swift`

**Interfaces (same vt-first convention as Task 8):**
- `NetworkService { init(cloud:transport:cache:logger:basePath:); func region(_ r: String?) -> NetworkRegion }`
- `NetworkRegion` with:
  - networks CRUD, subnets CRUD, ports CRUD, routers CRUD
  - floating IPs CRUD (+ associate/disassociate via update)
  - security groups CRUD + rules
  - address groups (extension-gated: throw feature error when alias absent)
  - quotas get/update
- Service type: `network`, no microversion header
- Cache TTL: 300s for networks/subnets/security_groups, 60s for ports/floating_ips
- Invalidation on mutation within resource + obvious parents only (cross-resource is MCP layer's job in Task 12)

**Test coverage required:**
- CRUD each resource against fake
- `createPort(fixed_ips: [])` auto-assigns (fake picks from pool)
- `associateFloatingIP` sets `status ACTIVE` + `port_id`; `disassociate` back to `DOWN`
- Extension-gated: fake without `address-group` → `listAddressGroups()` throws feature error
- 404 `NeutronError` normalized (code `ItemNotFound`)
- Pagination via `marker`+`_links.next`

**Steps:**
1. Write failing tests (`scripts/swift test --filter NetworkServiceTests`)
2. Implement NeutronFake routes
3. Implement NetworkModels + NetworkService
4. Run tests to green
5. Commit: `git commit -m "feat(client): neutron network service with extension gating"`

## Remaining Tasks After 9

| Task | Description |
|------|-------------|
| 10 | BlockStorageService (Cinder) + ImageService (Glance) + fakes |
| 11 | OpenStackClient facade — `cloud.compute(region:)` etc. |
| 12 | Resource catalog — all phase 1 entries |
| 13 | Policy + name resolution + validation + output shaping |
| 14 | Tool registry + describe tools + verb tools (in-process MCP tests) |
| 15 | Links, topology, diagnosis, waiter with progress |
| 16 | MCP resources and prompts |
| 17 | HummingbirdMCP adapter — route, token-per-request auth, SSE, PRM, login route |
| 18 | OpenStack validator + login page + token store + serve/stdio wiring |
| 19 | Logging, redaction, audit, metrics completeness |
| 20 | CLI — check, access-rules, tools, register-catalog |
| 21 | Deployment assets + README |
| 22 | Integration test (opt-in) + conformance pass + final hardening sweep |

## Key Implementation Patterns (learned from Tasks 1-8)

### Transport
- `Transport` is an **actor**, base URL = `cloud.authURL` (the host root)
- `transport.request(method:service:path:query:body:tokenOverride:extraHeaders:)` 
- Path includes the service prefix: `"nova/servers"`, `"neutron/v2.0/networks"`
- `basePath` parameter on each service (e.g. `"nova"`, `"neutron/v2.0"`) controls the URL prefix
- `tokenOverride` = the validated token ID (presented as `X-Auth-Token`)
- `syncShutdown()` is `nonisolated public` for use in `defer` blocks
- **Content-Type: application/json** is set on every request

### Cache
- `Cache` is an actor. Methods: `get(_:ttl:as:)`, `put(_:ttl:value:)`, `invalidate(resource:tokenID:region:)`
- `CacheKey(tokenID:region:resource:suffix:)`
- **Use `put` not `set`**

### Service Pattern (from ComputeService)
```swift
public struct ComputeService: Sendable {
    let cloud: CloudEntry
    let transport: Transport
    let cache: Cache
    let logger: Logger
    let basePath: String  // e.g. "nova"
    
    public func region(_ region: String? = nil) -> ComputeRegion { ... }
}

public struct ComputeRegion: Sendable {
    // Every operation takes `_ vt: ValidatedToken` as first arg
    public func listServers(_ vt: ValidatedToken, filters:..., limit:..., marker:...) async throws -> [Server]
    public func createServer(_ vt: ValidatedToken, _ spec: CreateServerSpec) async throws -> Server
    // ...
}
```

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

### Fake Registration
- `KeystoneFake.registerRoutes(router, state:baseHost:)`
- `NovaFake.registerRoutes(router, state:)`
- New: `NeutronFake.registerRoutes(router, state:)`
- Register in `FakeApp.start()` alongside the others
- Routes use `RouterPath` or string paths like `"/neutron/v2.0/networks"`
- Auth check: `req.headers[FakeHeaders.xAuthToken]` → `state.validateToken(tokenID)`
- JSON responses: manual string construction (avoid `try!` in fakes)
- Error responses: `NeutronError{type:"..."}` format for 404/400/409

### Linux/Swift Gotchas
- `import FoundationNetworking` in tests that use `URLRequest`/`URLSession`
- `.timeLimit(.minutes(n))` not `.seconds(n)`
- `Token.decode(from: Data)` is the public decoder for Keystone token responses
- `FakeHandle.stop()` is **synchronous** (not async) — safe in `defer`
- `Transport.syncShutdown()` is `nonisolated public` — safe in `defer`
- Swift 6.4 compiler bug: avoid `if case`/`guard case` on enums with `[Int8]` payloads in actor contexts
- `String(bytes:encoding:)` expects `[UInt8]` not `[Int8]`
- JSON body construction: use explicit string concatenation, not multi-line string interpolation (silent JSON corruption)
- On Linux, nested `Decodable` structs in route handlers may fail to decode — use hardcoded responses in fakes if needed

### Package.swift
- `OpenStackClientTests` depends on: `OpenStackClient`, `FakeOpenStack`, `HummingbirdTesting`, `Hummingbird`
- `OpenStackMCPServerTests` depends on: `OpenStackClient`, `FakeOpenStack`, `Hummingbird`, `MCP`

### Git / SDD Discipline
- Commit per task with descriptive message
- SDD ledger at `.superpowers/sdd/2026-09-28-openstack-mcp-phase-1/progress.md` (gitignored, local-only)
- Plan at `docs/superpowers/plans/2026-09-28-openstack-mcp-phase-1.md`
- Spec at `specs/openstack-mcp-spec.md`
