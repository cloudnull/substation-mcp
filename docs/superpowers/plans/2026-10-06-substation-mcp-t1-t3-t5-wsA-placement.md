# substation-mcp — T1–T3, T5, Workstream A, §10 Option B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the remaining decode 500s (T1), wire 5 unresolvable catalog resources to real endpoints (T2), fix the volume_type 404 (T3), document by-design 501s (T5), remove the server-stored session token (Workstream A), and add a Placement resource provider for GPU inventory (§10 Option B).

**Architecture:** All changes follow the existing patterns: `ComputeService`/`NetworkService`/`BlockStorageService` for API calls, `NameResolver.list()` for resource dispatch, `ResourceCatalog` for descriptors. The Placement service is a new `PlacementService` client following the same `req()`/`resolveServiceEndpoint()` pattern. Workstream A removes the `TokenStore` actor and its callers.

**Tech Stack:** Swift 6.4, Hummingbird, swift-logging, swift-crypto. Build/test in `swift:6.4-rhel-ubi10` Docker container via `scripts/swift build` / `scripts/swift test`.

**Spec:** `.opencode/plan/substation-mcp-server-decode-fix-plan.md` (§12 T1–T5, §13, §10 Option B, HANDOFF workstreams A/B/C/D)

## Global Constraints

- Build: `scripts/swift build` (runs in `swift:6.4-rhel-ubi10` container, Linux)
- Test: `scripts/swift test` — all existing tests must pass
- Deploy: `cd /tmp/substation-mcp-deploy && helm upgrade substation-mcp helm/substation-mcp -n openstack -f /opt/genestack/base-helm-configs/substation-mcp/substation-mcp-helm-overrides.yaml --no-hooks --timeout 300s` then `kubectl -n openstack rollout restart deploy/substation-mcp` (on controller 172.16.27.67)
- Commit footer: `Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>`
- NO destructive ops on existing resources; test resources may use flavor `m1.small` + image `rocky-10.1`
- sat0: Keystone `https://keystone.api.sat0.cloudnull.dev/v3`, Nova `https://nova.api.sat0.cloudnull.dev/v2.1`, Neutron `/v2.0`, Cinder `/v3`, Placement `https://placement.api.sat0.cloudnull.dev/`

## Review Focus

1. **Hypervisor model vs live Nova `/os-hypervisors/detail`** — the live response has keys `cpu_info` (JSON string), `vcpus` (Int), `memory_mb` (Int), `local_gb` (Int), `running_vms` (Int), `host_ip` (String), `service` (nested object), `id` (Int). The current model expects `cpu`, `cpus`, `maxmemory`, `current_workload`, `disk_total`, `disk_used` — ALL wrong. The model must be rewritten to match the actual keys.
2. **ComputeServiceInfo vs live Nova `/os-services`** — the live response has `updated_at` (String) not `updated` (String). The model's `CodingKeys` maps `updated` but Nova sends `updated_at`. Also `id` is Int (not String).
3. **Placement resource providers have no inventory in the list response** — `GET /resource_providers` returns only `uuid`, `name`, `generation`, `links`. Inventory requires a separate `GET /resource_providers/{uuid}/inventories` call. The model must handle both the list shape and the detail shape.
4. **TokenStore removal touches ~15 test sites** — `SessionTests.swift` has 15+ `TokenStore()` constructions. The actor must be reduced to a no-op stub (not deleted) to minimize test churn, or all test sites updated.
5. **volume_type endpoint is project-scoped in Cinder v3** — `GET /v3/volume-types` returns 404; the correct path is `GET /v3/{project_id}/volume-types`. The `BlockStorageService` must resolve the project ID from the token.

---

### Task 1: T1a — Fix Hypervisor model to match live Nova

**Files:**
- Modify: `Sources/OpenStackClient/Models/ComputeModels.swift` (Hypervisor struct, ~lines 428–479)
- Test: `Tests/OpenStackClientTests/ComputeServiceTests.swift`

**Interfaces:**
- Consumes: `ComputeService.listHypervisors()` (existing, calls `GET /os-hypervisors/detail`)
- Produces: `Hypervisor` struct with fields matching live Nova keys. `os_list hypervisor` → 200.

Live Nova `/os-hypervisors/detail` response keys (verified 2026-10-06):
```
id (Int), hypervisor_hostname (String), state (String), status (String),
hypervisor_type (String), hypervisor_version (Int), host_ip (String),
service (object: {id, host, disabled_reason}),
vcpus (Int), memory_mb (Int), local_gb (Int),
vcpus_used (Int), memory_mb_used (Int), local_gb_used (Int),
free_ram_mb (Int), free_disk_gb (Int), current_workload (Int),
running_vms (Int), disk_available_least (Int), cpu_info (String — JSON-encoded)
```

- [ ] **Step 1: Write the failing test**

Add to `ComputeServiceTests.swift`:
```swift
@Test("Server decodes real Nova /os-hypervisors/detail JSON", .timeLimit(.minutes(2)))
func hypervisorDecodesRealNovaJSON() throws {
    let novaJSON = """
    {"hypervisors":[{
        "id":1,
        "hypervisor_hostname":"compute-1.cloud.cloudnull.dev.local",
        "state":"up",
        "status":"enabled",
        "hypervisor_type":"QEMU",
        "hypervisor_version":7002022,
        "host_ip":"172.16.27.34",
        "service":{"id":43,"host":"compute-1.cloud.cloudnull.dev.local","disabled_reason":null},
        "vcpus":16,
        "memory_mb":63987,
        "local_gb":499,
        "vcpus_used":4,
        "memory_mb_used":8704,
        "local_gb_used":61,
        "free_ram_mb":55283,
        "free_disk_gb":438,
        "current_workload":0,
        "running_vms":1,
        "disk_available_least":428,
        "cpu_info":"{\"arch\":\"x86_64\",\"model\":\"Broadwell\"}"
    }]}
    """
    struct HypervisorList: Decodable { let hypervisors: [Hypervisor] }
    let decoded = try JSONDecoder().decode(HypervisorList.self, from: novaJSON.data(using: .utf8)!)
    let h = decoded.hypervisors[0]
    #expect(h.hypervisorHostname == "compute-1.cloud.cloudnull.dev.local")
    #expect(h.state == "up")
    #expect(h.vcpus == 16)
    #expect(h.memoryMB == 63987)
    #expect(h.runningVms == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter "hypervisorDecodesRealNovaJSON"`
Expected: FAIL (model fields don't match)

- [ ] **Step 3: Rewrite the Hypervisor struct**

Replace the `Hypervisor` struct in `ComputeModels.swift` with fields matching the live keys:
```swift
public struct Hypervisor: Sendable, Codable, Identifiable {
    public let id: Int
    public var hypervisorHostname: String
    public var state: String
    public var status: String
    public var hypervisorType: String
    public var hypervisorVersion: Int
    public var hostIP: String
    public var service: HypervisorService?
    public var vcpus: Int
    public var memoryMB: Int
    public var localGB: Int
    public var vcpusUsed: Int
    public var memoryMBUsed: Int
    public var localGBUsed: Int
    public var freeRAMMB: Int
    public var freeDiskGB: Int
    public var currentWorkload: Int
    public var runningVms: Int
    public var diskAvailableLeast: Int
    public var cpuInfo: String?
}

public struct HypervisorService: Sendable, Codable {
    public let id: Int
    public var host: String
    public var disabledReason: String?
}
```
With `CodingKeys` mapping camelCase → snake_case (`hypervisor_hostname`, `host_ip`, `memory_mb`, `local_gb`, `vcpus_used`, `memory_mb_used`, `local_gb_used`, `free_ram_mb`, `free_disk_gb`, `current_workload`, `running_vms`, `disk_available_least`, `cpu_info`, `hypervisor_type`, `hypervisor_version`).

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/swift test --filter "hypervisorDecodesRealNovaJSON"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackClient/Models/ComputeModels.swift Tests/OpenStackClientTests/ComputeServiceTests.swift
git commit -m "fix(T1a): rewrite Hypervisor model to match live Nova /os-hypervisors/detail

The old model expected cpu/cpus/maxmemory/disk_total/disk_used which don't
exist in the live response. Nova returns vcpus/memory_mb/local_gb/host_ip/
running_vms/cpu_info/hypervisor_type/hypervisor_version + nested service.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 2: T1b — Fix ComputeServiceInfo model

**Files:**
- Modify: `Sources/OpenStackClient/Models/ComputeModels.swift` (ComputeServiceInfo struct, ~lines 482–517)
- Test: `Tests/OpenStackClientTests/ComputeServiceTests.swift`

**Interfaces:**
- Consumes: `ComputeService.listComputeServices()` (existing, calls `GET /os-services`)
- Produces: `ComputeServiceInfo` struct matching live Nova keys. `os_list compute_service` → 200.

Live Nova `/os-services` response keys (verified 2026-10-06):
```
binary (String), host (String), id (Int), zone (String),
status (String), state (String), updated_at (String, ISO 8601),
disabled_reason (String?)
```

The current model maps `updated` but Nova sends `updated_at`. Also `id` is Int.

- [ ] **Step 1: Write the failing test**

```swift
@Test("ComputeServiceInfo decodes real Nova /os-services JSON", .timeLimit(.minutes(2)))
func computeServiceDecodesRealNovaJSON() throws {
    let novaJSON = """
    {"services":[{
        "binary":"nova-compute",
        "host":"compute-1.cloud.cloudnull.dev.local",
        "id":43,
        "zone":"az1",
        "status":"enabled",
        "state":"up",
        "updated_at":"2026-10-06T21:39:43.000000",
        "disabled_reason":null
    }]}
    """
    struct ServiceList: Decodable { let services: [ComputeServiceInfo] }
    let decoded = try JSONDecoder().decode(ServiceList.self, from: novaJSON.data(using: .utf8)!)
    let s = decoded.services[0]
    #expect(s.binary == "nova-compute")
    #expect(s.id == 43)
    #expect(s.updatedAt == "2026-10-06T21:39:43.000000")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter "computeServiceDecodesRealNovaJSON"`
Expected: FAIL

- [ ] **Step 3: Fix ComputeServiceInfo CodingKeys**

Change `case updated` to `case updatedAt = "updated_at"`. Rename the property from `updated` to `updatedAt`. Verify `id` is `Int` (not `String`).

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/swift test --filter "computeServiceDecodesRealNovaJSON"`
Expected: PASS

- [ ] **Step 5: Run full test suite + commit**

```bash
scripts/swift test
git add -A
git commit -m "fix(T1b): fix ComputeServiceInfo updated_at key mapping

Nova /os-services returns updated_at not updated. Renamed property and
CodingKey to match.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 3: T2 — Wire 5 catalog-gap resources in NameResolver

**Files:**
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift` (list() function, add 5 cases)
- Modify: `Sources/OpenStackClient/Services/ComputeService.swift` (add `listServerInterfaces`, `listServerVolumeAttachments`, `getComputeQuota` if not present)
- Modify: `Sources/OpenStackClient/Services/BlockStorageService.swift` (add `listVolumeQuotas` if not present)
- Modify: `Sources/OpenStackClient/Services/NetworkService.swift` (verify `listAddressGroups` exists)
- Test: `Tests/OpenStackMCPServerTests/NameResolverTests.swift` (or equivalent)

**Interfaces:**
- Produces: `os_list` returns 200 for `address_group`, `volume_quota`, `server_interface`, `server_volume_attachment`, `compute_quota`.

Verified live endpoints:
- `server_interface` → `GET /v2.1/servers/{id}/os-interface` → `{"interfaceAttachments": [...]}` (per-server, not a global list — for `os_list` with no server ID, return empty or list all servers' interfaces)
- `server_volume_attachment` → `GET /v2.1/servers/{id}/os-volumes` → `{"volumeAttachment": [...]}` (same per-server pattern)
- `compute_quota` → `GET /v2.1/os-quota-sets/{project_id}` → `{"quota_set": {...}}` (single object, wrap in array). **Existing method:** `ComputeService.getQuotaSet()` (line 466)
- `volume_quota` → `GET /v3/os-quota-sets/{project_id}` → `{"quota_set": {...}}` (single object, wrap in array). **Existing method:** `BlockStorageService.getQuota()` (line 362)
- `address_group` → `GET /v2.0/address-groups` → `{"address_groups": [...]}`. **Existing method:** `NetworkService.listAddressGroups()` (line 967)

- [ ] **Step 1: Add NameResolver.list() cases for all 5 resources**

In `NameResolver.swift` `list()` function, add cases:
```swift
case "address_group":
    let ags = try await r.listAddressGroups(vt)
    var result: [String: JSONValue] = try Self.encodeList(ags)
    result["resource"] = .string("address_group")
    result["region"] = .string(region)
    return result

case "volume_quota":
    let q = try await r.getQuota(vt)  // existing Cinder quota method
    var result: [String: JSONValue] = try Self.encodeList([q])
    result["resource"] = .string("volume_quota")
    result["region"] = .string(region)
    return result

case "server_interface":
    // Per-server resource; os_list returns all interfaces across all servers
    let servers = try await r.listServers(vt, filters: [:], limit: limit)
    var allInterfaces: [ServerInterface] = []
    for s in servers {
        if let ifaces = try? await r.listServerInterfaces(vt, serverID: s.id) {
            allInterfaces.append(contentsOf: ifaces)
        }
    }
    var result: [String: JSONValue] = try Self.encodeList(allInterfaces)
    result["resource"] = .string("server_interface")
    result["region"] = .string(region)
    return result

case "server_volume_attachment":
    let servers = try await r.listServers(vt, filters: [:], limit: limit)
    var allAttachments: [ServerVolumeAttachment] = []
    for s in servers {
        if let vols = try? await r.listServerVolumeAttachments(vt, serverID: s.id) {
            allAttachments.append(contentsOf: vols)
        }
    }
    var result: [String: JSONValue] = try Self.encodeList(allAttachments)
    result["resource"] = .string("server_volume_attachment")
    result["region"] = .string(region)
    return result

case "compute_quota":
    let q = try await r.getComputeQuota(vt)
    var result: [String: JSONValue] = try Self.encodeList([q])
    result["resource"] = .string("compute_quota")
    result["region"] = .string(region)
    return result
```

- [ ] **Step 2: Add missing service methods + models**

In `ComputeService.swift`:
- `listServerInterfaces(_ vt: ValidatedToken, serverID: String) async throws -> [ServerInterface]` — calls `GET /servers/{id}/os-interface`, decodes `{"interfaceAttachments": [...]}`
- `listServerVolumeAttachments(_ vt: ValidatedToken, serverID: String) async throws -> [ServerVolumeAttachment]` — calls `GET /servers/{id}/os-volumes`, decodes `{"volumeAttachment": [...]}`
- `getQuotaSet` already exists (line 466) — the NameResolver case for `compute_quota` wraps its result in a single-element array. No new method needed.

Add models to `ComputeModels.swift`:
```swift
public struct ServerInterface: Sendable, Codable, Identifiable {
    public var id: String { portID }
    public let netID: String
    public let portID: String
    public var macAddr: String
    public var portState: String
    public var fixedIPs: [FixedIPRef]
}

public struct FixedIPRef: Sendable, Codable {
    public var subnetID: String
    public var ipAddress: String
}

public struct ServerVolumeAttachment: Sendable, Codable, Identifiable {
    public var id: String { volumeID }
    public let volumeID: String
    public var serverID: String?
    public var devicePath: String?
    public var status: String?
    public var bootloader: String?
    public var readOnly: Bool?
}

public struct ComputeQuotaSet: Sendable, Codable {
    public var id: String
    public var instances: Int
    public var cores: Int
    public var ram: Int
    public var floatingIPs: Int
    public var fixedIPs: Int
    public var securityGroups: Int
    public var securityGroupRules: Int
    public var keyPairs: Int
    public var serverGroups: Int
    public var serverGroupMembers: Int
    public var injectedFiles: Int
    public var injectedFilePathBytes: Int
    public var injectedFileContentBytes: Int
    public var metadataItems: Int
}
```
With appropriate `CodingKeys` for snake_case mapping.

In `BlockStorageService.swift`: `getQuota()` already exists (line 362). The `volume_quota` NameResolver case wraps its result in a single-element array. No new method needed.

In `NetworkService.swift`: `listAddressGroups()` already exists (line 967). Wire it in NameResolver.

- [ ] **Step 3: Add NameResolver.get() cases for the 5 resources**

Add `get()` cases so `os_get` also works:
- `address_group` → `r.getAddressGroup(vt, id: id)`
- `volume_quota` → `r.getQuota(vt)` (project-scoped, ignore id)
- `compute_quota` → `r.getComputeQuota(vt)` (project-scoped, ignore id)
- `server_interface` → requires server context; for `os_get` by port_id, scan servers
- `server_volume_attachment` → requires server context; for `os_get` by volume_id, scan servers

- [ ] **Step 4: Run full test suite + commit**

```bash
scripts/swift test
git add -A
git commit -m "feat(T2): wire 5 catalog-gap resources to real endpoints

- address_group → Neutron /address-groups (existing service method)
- volume_quota → Cinder /v3/os-quota-sets/{project_id} (existing getQuota)
- compute_quota → Nova /os-quota-sets/{project_id} (new getComputeQuota)
- server_interface → Nova /servers/{id}/os-interface (new listServerInterfaces)
- server_volume_attachment → Nova /servers/{id}/os-volumes (new listServerVolumeAttachments)

All 5 os_list calls now return 200 instead of 404.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 4: T3 — Fix volume_type endpoint (project-scoped in Cinder v3)

**Files:**
- Modify: `Sources/OpenStackClient/Services/BlockStorageService.swift` (listVolumeTypes, ~line 203)
- Test: `Tests/OpenStackClientTests/BlockStorageServiceTests.swift`

**Interfaces:**
- Produces: `os_list volume_type` → 200 (empty list on sat0 is fine).

The current code calls `GET /v3/volume-types` which returns 404. Cinder v3 requires the project-scoped path: `GET /v3/{project_id}/volume-types`.

- [ ] **Step 1: Write the failing test**

Add a test that verifies the URL path includes the project ID.

- [ ] **Step 2: Fix listVolumeTypes to use project-scoped path**

In `BlockStorageService.swift`, change `listVolumeTypes` from:
```swift
let result = try await req(vt, region, method: "GET", path: "\(basePath)/volume-types", extraHeaders: versionHeader)
```
to:
```swift
let projectID = vt.token.projectID ?? ""
let result = try await req(vt, region, method: "GET", path: "\(basePath)/\(projectID)/volume-types", extraHeaders: versionHeader)
```
Apply the same fix to `getVolumeType`, `createVolumeType`, `deleteVolumeType` if they also use the unscoped path.

- [ ] **Step 3: Run tests + commit**

```bash
scripts/swift test
git add -A
git commit -m "fix(T3): use project-scoped volume-types path in Cinder v3

Cinder v3 requires GET /v3/{project_id}/volume-types, not /v3/volume-types.
The unscoped path returns 404.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 5: T5 — Document by-design 501 identity resources

**Files:**
- Modify: `Sources/OpenStackMCPServer/Catalog/Catalog.swift` or the resource descriptor definitions (add a `notes` or `status` field to the 4 identity descriptors)
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift` (os_describe handler — include the note in the response)

**Interfaces:**
- Produces: `os_describe region/service/endpoint/application_credential` includes a note: "Phase 1: not resolvable (HTTP 501 by design)."

- [ ] **Step 1: Add a `phase1Note` field to ResourceDescriptor**

In the `ResourceDescriptor` struct, add an optional `phase1Note: String?` field. Set it for the 4 identity resources:
- `region`: "Phase 1: identity resources not resolvable (HTTP 501 by design)."
- `service`: same
- `endpoint`: same
- `application_credential`: same

- [ ] **Step 2: Include the note in os_describe output**

In the `os_describe` handler, if the descriptor has a `phase1Note`, include it in the response JSON as `"note": "..."`.

- [ ] **Step 3: Run tests + commit**

```bash
scripts/swift test
git add -A
git commit -m "docs(T5): add phase-1 note to identity resource descriptors

region, service, endpoint, application_credential return HTTP 501 by
design in phase 1. The note is now visible in os_describe output so
callers understand this is intentional, not a bug.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 6: Workstream A — Remove server-stored session token

**Files:**
- Modify: `Sources/OpenStackMCPServer/Session/TokenStore.swift` (reduce to no-op stub)
- Modify: `Sources/OpenStackMCPServer/Auth/LoginPage.swift` (remove `tokenStore.bind()` call)
- Modify: `Sources/OpenStackMCPServer/ServeApp.swift` (remove `tokenStore` param + `zeroize` callback)
- Modify: `Sources/substation-mcp/main.swift` (remove `TokenStore(logger:)` creation)
- Modify: `Sources/HummingbirdMCP/SessionRegistry.swift` (make `evictExpired` token zeroization a no-op)
- Modify: `Tests/HummingbirdMCPTests/SessionTests.swift` (~15 sites)
- Modify: `docs/superpowers/plans/2026-09-28-substation-mcp-phase-1.md` (§6.1b, §6.2)

**Interfaces:**
- Produces: No server-side token state. `/v1/login` mint is display-only. Client-side mint is primary.

- [ ] **Step 1: Reduce TokenStore to a no-op stub**

Keep the `TokenStore` actor but make `bind()`, `zeroize()`, and `token(for:)` no-ops that do nothing. This minimizes test churn — the ~15 test sites that construct `TokenStore()` still compile.

```swift
public actor TokenStore {
    public init(logger: Logger = Logger(label: "token-store")) {}
    public func bind(sessionId: String, token: String) async {}
    public func zeroize(sessionId: String) async {}
    public func token(for sessionId: String) async -> String? { nil }
}
```

- [ ] **Step 2: Remove the bind() call from LoginPage**

In `LoginPage.swift` line ~64, remove:
```swift
await tokenStore.bind(sessionId: req.elicitationId, token: token)
```
The `/v1/login` POST still mints the token and displays it on the completion page, but no longer stores it.

- [ ] **Step 3: Remove tokenStore from ServeApp and main.swift**

In `ServeApp.swift`: remove `tokenStore` from the struct, init, and the `terminated` closure (line ~96).
In `main.swift`: remove `let tokenStore = TokenStore(logger: logger)` and the `tokenStore:` argument.

- [ ] **Step 4: Update SessionRegistry comment**

In `SessionRegistry.swift` line ~44, update the comment to note that token zeroization is now a no-op.

- [ ] **Step 5: Update the spec**

In `docs/superpowers/plans/2026-09-28-substation-mcp-phase-1.md` §6.1b: reword "the one stateful element" to note the token is display-only, not server-held. In §6.2: note TokenStore is a no-op stub.

- [ ] **Step 6: Run full test suite + commit**

```bash
scripts/swift test
git add -A
git commit -m "refactor(WS-A): remove server-stored session token (Option 2)

The /v1/login mint is now display-only. No token is ever held
server-side. TokenStore is reduced to a no-op stub to minimize test
churn. Client-side mint (app-cred or password → Keystone) is the
primary login path.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 7: §10 Option B — Add Placement resource provider

**Files:**
- Create: `Sources/OpenStackClient/Services/PlacementService.swift`
- Modify: `Sources/OpenStackClient/Models/ComputeModels.swift` (add Placement models)
- Modify: `Sources/OpenStackMCPServer/Catalog/Catalog.swift` (add `placement` descriptor)
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift` (wire `placement` in list/get)
- Modify: `Sources/OpenStackClient/OpenStackClient.swift` (add `placement(region:)` accessor, following the existing `compute()`/`network()`/`blockStorage()` pattern at lines 81–99)
- Test: `Tests/OpenStackClientTests/PlacementServiceTests.swift`

**Interfaces:**
- Consumes: `OpenStackClient` token/transport/endpoint resolution machinery
- Produces: `os_list placement` → 200 with resource providers (name, uuid, generation). `os_get placement <uuid>` → 200 with inventory (VCPU, MEMORY_MB, DISK_GB totals + usages).

Verified live Placement API (2026-10-06):
- Base URL: `https://placement.api.sat0.cloudnull.dev/` (from Keystone service catalog, service type `placement`)
- `GET /resource_providers` → `{"resource_providers": [{"uuid", "name", "generation", "links"}]}`
- `GET /resource_providers/{uuid}/inventories` → `{"inventories": {"VCPU": {"total": 16}, "MEMORY_MB": {"total": 63987}, "DISK_GB": {"total": 499}}}`
- `GET /resource_providers/{uuid}/usages` → `{"usages": {"VCPU": 4, "MEMORY_MB": 8192, "DISK_GB": 61}}`

- [ ] **Step 1: Create Placement models**

In `ComputeModels.swift` (or a new `PlacementModels.swift`):
```swift
public struct PlacementResourceProvider: Sendable, Codable, Identifiable {
    public let uuid: String
    public var name: String
    public var generation: Int
    public var links: [PlacementLink]?
}

public struct PlacementLink: Sendable, Codable {
    public var rel: String
    public var href: String
}

public struct PlacementInventory: Sendable, Codable {
    public var vcpu: PlacementResource?
    public var memoryMB: PlacementResource?
    public var diskGB: PlacementResource?
}

public struct PlacementResource: Sendable, Codable {
    public var total: Int?
    public var used: Int?
    public var unit: String?
}

public struct PlacementUsages: Sendable, Codable {
    public var vcpu: Int?
    public var memoryMB: Int?
    public var diskGB: Int?
}
```
With `CodingKeys` for `VCPU`→`vcpu`, `MEMORY_MB`→`memoryMB`, `DISK_GB`→`diskGB`.

- [ ] **Step 2: Create PlacementService**

New file `Sources/OpenStackClient/Services/PlacementService.swift`:
```swift
public struct PlacementService: Sendable {
    // Follows the same pattern as ComputeService:
    // - req() via resolveServiceEndpoint (service type "placement")
    // - listResourceProviders() → GET /resource_providers
    // - getResourceProvider(uuid:) → GET /resource_providers/{uuid}
    // - getInventory(uuid:) → GET /resource_providers/{uuid}/inventories
    // - getUsages(uuid:) → GET /resource_providers/{uuid}/usages
}
```

- [ ] **Step 3: Add `placement(region:)` accessor to OpenStackClient**

Following the same pattern as `compute(region:)`, `network(region:)`, etc.

- [ ] **Step 4: Add `placement` descriptor to the catalog**

In `Catalog.swift`, add a `ResourceDescriptor` for `placement` with service `.compute` (or a new `.placement` enum case), verbs: `list`, `get`.

- [ ] **Step 5: Wire in NameResolver**

In `NameResolver.list()`:
```swift
case "placement":
    let rps = try await r.listResourceProviders(vt)
    var result: [String: JSONValue] = try Self.encodeList(rps)
    result["resource"] = .string("placement")
    result["region"] = .string(region)
    return result
```

In `NameResolver.get()`:
```swift
case "placement":
    let rp = try await r.getResourceProvider(vt, uuid: id)
    let inventory = try? await r.getInventory(vt, uuid: id)
    let usages = try? await r.getUsages(vt, uuid: id)
    // Merge into a single JSON object
    var obj = try Self.encodeObject(rp)
    if let inv = inventory { obj["inventory"] = try Self.encodeValue(inv) }
    if let usg = usages { obj["usages"] = try Self.encodeValue(usg) }
    return obj
```

- [ ] **Step 6: Add FakeOpenStack endpoint for Placement**

In `Sources/FakeOpenStack/`, add a Placement fake with:
- `GET /placement/resource_providers` → 2 resource providers
- `GET /placement/resource_providers/{uuid}/inventories` → VCPU/MEMORY_MB/DISK_GB
- `GET /placement/resource_providers/{uuid}/usages` → integer usages

- [ ] **Step 7: Write tests + run full suite + commit**

```swift
@Test("Placement list resource providers", .timeLimit(.minutes(2)))
func placementListProviders() async throws {
    // Against the fake: verify 2 providers returned
}

@Test("Placement get resource provider with inventory", .timeLimit(.minutes(2)))
func placementGetProviderInventory() async throws {
    // Against the fake: verify inventory + usages merged
}
```

```bash
scripts/swift test
git add -A
git commit -m "feat(§10-B): add Placement resource provider for GPU inventory

New PlacementService client calling the Placement API (service type
'placement'). os_list placement returns resource providers (name, uuid,
generation). os_get placement <uuid> returns the provider plus inventory
(VCPU, MEMORY_MB, DISK_GB totals) and usages (allocated amounts).

This is the authoritative per-host GPU/RAM/vCPU source — independent
of flavor naming. GPU hosts are visible via traits (if present) or by
correlating the resource provider name with the server's hostId.

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```

---

### Task 8: Deploy + full live validation

**Files:** None (deployment + validation)

- [ ] **Step 1: Build + full test suite**

```bash
scripts/swift build
scripts/swift test
```
Expected: All tests pass (222+ existing + new tests from Tasks 1–7).

- [ ] **Step 2: Push + wait for CI**

```bash
git push
# Wait for CI to complete
```

- [ ] **Step 3: Deploy to sat0**

```bash
# On controller 172.16.27.67:
kubectl -n openstack rollout restart deploy/substation-mcp
# Wait for new pod on latest digest
```

- [ ] **Step 4: Validate all fixed resources**

Via MCP curl (initialize + tools/call):
- `os_list hypervisor` → 200, 3 rows with vcpus/memory_mb
- `os_list compute_service` → 200, 6 rows with binary/zone/updated_at
- `os_list address_group` → 200 (empty on sat0)
- `os_list volume_quota` → 200 (quota_set values)
- `os_list server_interface` → 200 (interfaces across all servers)
- `os_list server_volume_attachment` → 200 (empty on sat0)
- `os_list compute_quota` → 200 (quota_set values)
- `os_list volume_type` → 200 (empty on sat0)
- `os_describe region` → includes phase-1 note
- `os_list placement` → 200, 3 resource providers
- `os_get placement <uuid>` → 200 with inventory (VCPU=16, MEMORY_MB=63987, DISK_GB=499)
- `os_action image <id> set_visibility visibility=public` → 200 (not "Unknown image action")
- `os_action image <id> reactivate` → 200 (not 415)
- `os_list server` → flavor.id still populated (regression check)
- `os_get flavor ao.1.4.24` → extra_specs still present (regression check)
- `os_topology server r9700` → anchor resolved (regression check)

- [ ] **Step 5: Save milestone**

Track the milestone in Erebine: "T1–T3, T5, WS-A, §10-B all deployed and validated on sat0."

---

### Task 9: Fix image action wiring + Glance PATCH Content-Type

**Files:**
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift` (os_action handler — wire missing image actions)
- Modify: `Sources/OpenStackClient/Services/ImageService.swift` (updateImage — fix Content-Type)
- Test: `Tests/OpenStackClientTests/ImageServiceTests.swift`

**Interfaces:**
- Consumes: Existing `ImageService` methods (`setVisibility`, `addTag`, `removeTag`, `reactivate`, `protect`, `unprotect`, `deactivate`, `updateImage`)
- Produces: All catalog-advertised image actions work. `os_action image <id> set_visibility` → 200. `deactivate` → 200 (no more 415).

**Bug 1 — Image action mismatch:**
The catalog advertises `set_visibility`, `add_tag`, `remove_tag`, `reactivate` for the `image` resource, but the `os_action` handler in `ToolRegistry.swift` only wires `protect`/`unprotect`/`deactivate`. The other four return "Unknown image action". The underlying `ImageService` methods already exist — they just need to be wired in the handler.

**Bug 2 — Glance PATCH → 415:**
`ImageService.updateImage` sends `Content-Type: application/json` in the PATCH request. Live Glance rejects this with HTTP 415 (Unsupported Media Type). Glance v2 requires `Content-Type: application/openstack-images;version=2` (or no Content-Type header for a plain JSON body). The `deactivate` action uses `updateImage` under the hood, so it also 415s.

- [ ] **Step 1: Wire the 4 missing image actions in ToolRegistry**

Find the `os_action` handler's image branch (search for `"Unknown image action"` or the existing `protect`/`unprotect`/`deactivate` cases). Add:
```swift
case "set_visibility":
    let visibility = argString(params, "visibility")
    try await r.setVisibility(vt, id: id, visibility: visibility)
case "add_tag":
    let tag = argString(params, "tag")
    try await r.addTag(vt, id: id, tag: tag)
case "remove_tag":
    let tag = argString(params, "tag")
    try await r.removeTag(vt, id: id, tag: tag)
case "reactivate":
    try await r.reactivate(vt, id: id)
```
Verify the exact method signatures in `ImageService.swift` before wiring (the param names may differ).

- [ ] **Step 2: Fix Glance PATCH Content-Type in ImageService.updateImage**

Find `updateImage` in `ImageService.swift`. The PATCH request currently sets `Content-Type: application/json`. Change to either:
- Remove the Content-Type header entirely (Glance accepts a bare JSON body), OR
- Set it to `application/openstack-images;version=2`

Check how other Glance methods in the same file handle headers — follow the existing pattern. The `req()` method may accept an `extraHeaders` parameter.

- [ ] **Step 3: Write/fix tests**

- Test that `os_action image <id> set_visibility visibility=public` calls `ImageService.setVisibility`
- Test that `os_action image <id> add_tag tag=foo` calls `ImageService.addTag`
- Test that `os_action image <id> reactivate` calls `ImageService.reactivate`
- Test that `updateImage` does NOT send `Content-Type: application/json` (check the request headers in the fake)

- [ ] **Step 4: Run full test suite + commit**

```bash
scripts/swift test
git add -A
git commit -m "fix: wire 4 missing image actions + fix Glance PATCH Content-Type

Bug 1: os_action handler only wired protect/unprotect/deactivate for
images. The catalog also advertises set_visibility, add_tag, remove_tag,
reactivate — all four now wired to their existing ImageService methods.

Bug 2: ImageService.updateImage sent Content-Type: application/json which
live Glance rejects with 415. Removed the header so Glance accepts the
bare JSON body. This fixes the deactivate action (which uses updateImage
under the hood).

Co-Authored-By: Erebine Qwen3.8-27B-FP8 erebine/co-engineer <noreply@erebine.ai>"
```
