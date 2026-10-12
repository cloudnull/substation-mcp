# Non-Expert UX Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the substation-local MCP tools guide non-cloud-expert LLM harnesses through correct workflows by surfacing platform constraints, prerequisites, and next steps proactively — eliminating the trial-and-error failure loops observed in production testing.

**Architecture:** Eight enhancements across three layers: (1) new aggregate-read tools that give the harness a "what can I do right now" view before starting workflows, (2) enriched error/validation responses that turn opaque API failures into actionable instructions, (3) schema/description improvements that steer the LLM toward correct multi-step sequences without requiring cloud expertise.

**Tech Stack:** Swift 6.4, Hummingbird MCP server, custom OpenStack client (no SDK), Apple container runtime for local builds.

**Spec:** Session learnings from moylands/SanRafael deployment testing (see `erebine.memory` entry `mem_vTKhj2EKveV1Hc2Gs9NiQNsE`). The eight enhancements are enumerated in the "Enhancements" section below.

## Global Constraints

- All new read-only tools must be added to `Policy.swift:toolsEnabled()` (line 96-102) and `ToolListFormatter.swift` (lines 20-29) for visibility.
- Error hints use the existing `OpenStackError.hint` field (rendered as "Hint: <hint>" by `errorParagraph()` at `ResultFormatting.swift:62-79`). No new error format needed.
- New tools follow the `os_quota` pattern: Tool def in `AllTools.swift` → dispatch case in `ToolRegistry.swift` → handler method → NameResolver or direct service calls.
- Tests use the `InProcessMCPTests` harness: `makeRegistry()` → mint token → call tool via `InMemoryTransport` → assert on text output. Fake state seeded via `FakeApp.start()`.
- Build with `scripts/swift build` (Apple container, Swift 6.4-rhel-ubi10). Test with `scripts/swift test`.
- Commit after each task. Push to `origin/main`. Rebuild local image with `container build -f deploy/Dockerfile -t ghcr.io/cloudnull/substation-mcp:local-fixes .`.

## Review Focus

1. **Harness calls os_project_readiness before any workflow** — if it skips this and goes straight to os_create(server), the dry_run validation still catches missing networks. Both paths must produce actionable errors, not silent failures.
2. **dry_run=true on a valid spec returns success without side effects** — no Nova/Cinder/Neutron POST calls are made. Test by asserting FakeOpenStack state is unchanged after a dry_run create.
3. **Error hints don't leak internal IDs or tokens** — `redact()` at `ResultFormatting.swift:84-108` must strip secrets from hint strings. Test with a hint containing a fake token.
4. **Next-step hints are contextually correct** — after creating a network, the hint says "create a subnet" (not "attach a router" which requires a subnet first). Test the sequence ordering.
5. **os_recommend_flavor handles unknown workload keywords gracefully** — returns the general-purpose default rather than erroring. Test with "quantum computing" as input.

---

### Task 1: `os_project_readiness` — Aggregate Infrastructure Check

**Files:**
- Create: `Sources/OpenStackMCPServer/Tools/ProjectReadinessHandler.swift`
- Modify: `Sources/OpenStackMCPServer/Tools/AllTools.swift:109` (add Tool entry before os_quota)
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift:258-282` (add dispatch case)
- Modify: `Sources/OpenStackMCPServer/Policy/Policy.swift:96-102` (add to read-only list)
- Modify: `Sources/OpenStackMCPServer/Tools/ToolListFormatter.swift:20-29` (add to both lists)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift` (add test)

**Interfaces:**
- Consumes: `OpenStackClient` (network, compute, blockStorage services), `ResourceCatalog`
- Produces: `handleProjectReadiness(_ params: CallTool.Parameters) async throws -> CallTool.Result` — returns structured JSON with `networks`, `volumes`, `flavors`, `keypairs`, `security_groups`, `blockers` fields

- [ ] **Step 1: Write the failing test**

Add to `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`:

```swift
@Test("project_readiness reports missing private network")
func projectReadinessMissingNetwork() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_project_readiness", [:])
    #expect(result.contains("\"ready_for_servers\":false"))
    #expect(result.contains("No private network"))
}

@Test("project_readiness reports ready when infra exists")
func projectReadinessComplete() async throws {
    let reg = try await makeRegistry()
    // Seed a private network + subnet + router via os_create calls
    _ = try await firstText(reg, "os_create", ["resource": "network", "spec": "{\"name\":\"test-net\"}"])
    // ... (seed subnet, router, interface)
    let result = try await firstText(reg, "os_project_readiness", [:])
    #expect(result.contains("\"ready_for_servers\":true"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter projectReadiness`
Expected: FAIL — "os_project_readiness" tool not found

- [ ] **Step 3: Implement the Tool definition in AllTools.swift**

Add before the `os_quota` Tool (line ~109):

```swift
Tool(
    name: "os_project_readiness",
    description: "Check what infrastructure exists in this project and what's needed before deploying servers. Returns: available networks (private/public), routers, volume quotas and types, flavors by AZ, keypairs, security groups, and a blockers list of missing prerequisites.",
    inputSchema: .init(type: "object", properties: [:], additionalProperties: false),
    annotations: .init(readOnlyHint: true, destructiveHint: false)
)
```

- [ ] **Step 4: Implement the handler in ProjectReadinessHandler.swift**

New file. The handler:
1. Calls `ns.listNetworks(vt, region)` — count private (router:external != 1) vs public
2. Calls `ns.listRouters(vt, region)` — count routers with external gateway
3. Calls `cs.getQuotaSet(vt, region)` — volume/server/image quotas
4. Calls `bs.getQuota(vt, region)` — Cinder quota (volumes, gigabytes)
5. Calls `cs.listFlavors(vt, region)` — count available, note AZ
6. Calls `cs.listKeypairs(vt, region)` — list names
7. Calls `ns.listSecurityGroups(vt, region)` — list with rule counts
8. Assembles `blockers: [String]` array:
   - If no private network: "No private network with router — create one before deploying servers (os_create network → subnet → router → router_interface)"
   - If no keypairs: "No SSH keypairs — create one with os_create(keypair)"
   - If volume quota == 0: "Volume quota exhausted"
9. Returns JSON: `{"networks": {...}, "routers": N, "volumes": {...}, "flavors": {...}, "keypairs": [...], "security_groups": [...], "ready_for_servers": bool, "blockers": [...]}`

- [ ] **Step 5: Wire dispatch in ToolRegistry.swift**

Add to the switch at line 258:
```swift
case "os_project_readiness": outcome = (try await handleProjectReadiness(params), nil)
```

Add to `visibleToolNames` read-only list (line 148) and `ToolListFormatter.swift`.

- [ ] **Step 6: Add to Policy.swift read-only tools list**

Add `"os_project_readiness"` to the array at line 96-102.

- [ ] **Step 7: Run tests to verify they pass**

Run: `scripts/swift test --filter projectReadiness`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/OpenStackMCPServer/Tools/ProjectReadinessHandler.swift Sources/OpenStackMCPServer/Tools/AllTools.swift Sources/OpenStackMCPServer/Tools/ToolRegistry.swift Sources/OpenStackMCPServer/Policy/Policy.swift Sources/OpenStackMCPServer/Tools/ToolListFormatter.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat: add os_project_readiness aggregate infrastructure check"
```

---

### Task 2: Server Create Dry-Run Validation

**Files:**
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift:858-938` (handleCreate)
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift:938-1145` (server create path)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: Existing `handleCreate` dry_run flag (already parsed at ToolRegistry:862), `NameResolver.createPublic()`
- Produces: When `dry_run=true` and resource is "server", validates all prerequisites and returns `{valid: true/false, errors: [...], warnings: [...]}` without calling Nova

- [ ] **Step 1: Write the failing test**

```swift
@Test("server dry_run rejects missing private network")
func serverDryRunMissingNetwork() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_create", [
        "resource": "server",
        "spec": "{\"name\":\"test\",\"flavor\":\"gp.0.2.6\",\"image\":\"fake-img\",\"networks\":[{\"network\":\"PUBLICNET\"}]}",
        "dry_run": "true"
    ])
    #expect(result.contains("\"valid\":false"))
    #expect(result.contains("publicNetworkRejected"))
}

@Test("server dry_run passes with valid private network")
func serverDryRunValid() async throws {
    let reg = try await makeRegistry()
    // Seed private network + subnet + router
    // ...
    let result = try await firstText(reg, "os_create", [
        "resource": "server",
        "spec": "{\"name\":\"test\",\"flavor\":\"gp.0.2.6\",\"image\":\"fake-img\",\"networks\":[{\"network\":\"test-net\"}]}",
        "dry_run": "true"
    ])
    #expect(result.contains("\"valid\":true"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter serverDryRun`
Expected: FAIL — dry_run for server doesn't validate networks yet

- [ ] **Step 3: Implement validation in NameResolver server create path**

In `NameResolver.swift` server create case (~line 938), after network resolution but BEFORE `createServer` call, add a `dryRun` parameter. When true:
1. Validate network is not external (reuse existing `publicNetworkRejected` check)
2. Validate flavor exists (call `cs.getFlavor`)
3. Validate image is visible (call `is.getImages` filtered by ID)
4. Validate keypair exists (call `cs.listKeypairs`)
5. Validate volume quota has room (call `bs.getQuota`)
6. Return a `JSONValue.object` with `valid`, `errors`, `warnings` instead of calling `createServer`

Thread the `dryRun` flag from `handleCreate` (which already parses it at ToolRegistry:862) through to `createPublic`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter serverDryRun`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackMCPServer/Tools/ToolRegistry.swift Sources/OpenStackMCPServer/NameResolver.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(server): dry_run validates all prerequisites without creating"
```

---

### Task 3: Error Message Enrichment (Actionable Hints)

**Files:**
- Modify: `Sources/OpenStackClient/Transport/OpenStackError.swift:33-88` (normalize method)
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift` (various error throw sites)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: `OpenStackError.hint` field (already exists, rendered by `errorParagraph`)
- Produces: Every thrown `OpenStackError` has a non-nil `hint` with actionable guidance

- [ ] **Step 1: Write the failing test**

```swift
@Test("404 error includes hint listing available options")
func error404HasHint() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_get", ["resource": "server", "id_or_name": "nonexistent-server"])
    #expect(result.contains("Hint:"))
    #expect(result.lowercased().contains("available"))
}

@Test("quota exceeded error includes actionable path")
func quotaExceededHasHint() async throws {
    // Set quota to 0 in fake state, attempt create
    // ...
    #expect(result.contains("Hint:"))
    #expect(result.lowercased().contains("delete unused") || result.lowercased().contains("request a quota increase"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter error404HasHint`
Expected: FAIL — no hint on 404

- [ ] **Step 3: Add hints to OpenStackError.normalize()**

In `OpenStackError.swift:33-88`, extend the `normalize()` function:
- 404: `hint = "Resource not found. Use os_list(<resource>) to see available options."`
- 403 with "quota" in message: `hint = "Quota exceeded. Delete unused resources or request a quota increase from your cloud provider."`
- 403 with "forbidden" in message: `hint = "Your token lacks required permissions. Check os_whoami for available scopes."`
- 409: `hint = "Resource is in a conflicting state. Wait for it to reach a stable state, then retry."`
- 400 with "required property": `hint = "Missing required field. Call os_describe(<resource>) to see the expected schema."`

- [ ] **Step 4: Add specific hints at NameResolver throw sites**

At the `publicNetworkRejected` throw (already has a long message — move the actionable part into `hint`):
```swift
throw OpenStackError(service: "compute", status: 400, code: "publicNetworkRejected",
    message: "Cannot create server on external network",
    hint: "Create a private network: (1) os_create(network) (2) os_create(subnet) (3) os_create(router with external_gateway_info) (4) os_attach(link:router_interface). Then retry on the private network.")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/swift test --filter error404HasHint`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenStackClient/Transport/OpenStackError.swift Sources/OpenStackMCPServer/NameResolver.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(errors): actionable hints on 404/403/409/400 responses"
```

---

### Task 4: Next-Step Workflow Hints in Mutation Responses

**Files:**
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift` (handleCreate, handleAttach)
- Modify: `Sources/OpenStackMCPServer/Tools/ResultFormatting.swift` (add next_steps to MutationResult)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: `MutationResult` struct (ResultFormatting.swift:6-30)
- Produces: `next_steps: [String]?` field in mutation responses, populated based on resource type + action

- [ ] **Step 1: Write the failing test**

```swift
@Test("network create returns next_steps for subnet")
func networkCreateNextSteps() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_create", ["resource": "network", "spec": "{\"name\":\"test-net\"}"])
    #expect(result.contains("next_steps"))
    #expect(result.contains("subnet"))
}

@Test("subnet create returns next_steps for router")
func subnetCreateNextSteps() async throws {
    let reg = try await makeRegistry()
    // Create network first, then subnet
    // ...
    #expect(result.contains("router"))
    #expect(result.contains("router_interface"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter networkCreateNextSteps`
Expected: FAIL — no next_steps in response

- [ ] **Step 3: Add next_steps to MutationResult and populate in handlers**

In `ResultFormatting.swift`, add `next_steps: [String]?` to `MutationResult`. In `handleCreate` (ToolRegistry:858), after a successful create, append contextual next steps:

| Resource created | next_steps |
|---|---|
| network | ["Create a subnet: os_create(subnet, {name, network_id, cidr})", "Create a router: os_create(router, {name, external_gateway_info})"] |
| subnet | ["Attach to router: os_attach(link:router_interface, source=<router>, target=<subnet-id>)"] |
| router | ["Attach private subnet: os_attach(link:router_interface, source=<router-id>, target=<subnet>)"] |
| server (with volumes) | ["Wait for ACTIVE: os_wait(server, <id>)", "Allocate floating IP if internet access needed: os_create(floating_ip)", "Verify provisioning: os_action(server, <name>, provisioning_status)"] |
| volume (with imageRef) | ["Use as boot volume: os_create(server, {volumes: [{volume_id: <id>, boot: true}]})"] |

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter networkCreateNextSteps`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackMCPServer/Tools/ToolRegistry.swift Sources/OpenStackMCPServer/Tools/ResultFormatting.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(responses): next_steps hints on mutation results"
```

---

### Task 5: Flavor Recommendation Tool

**Files:**
- Create: `Sources/OpenStackMCPServer/Tools/FlavorRecommendationHandler.swift`
- Modify: `Sources/OpenStackMCPServer/Tools/AllTools.swift` (add Tool entry)
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift` (dispatch + handler)
- Modify: `Sources/OpenStackMCPServer/Policy/Policy.swift` (read-only list)
- Modify: `Sources/OpenStackMCPServer/Tools/ToolListFormatter.swift`
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: `ComputeService.listFlavors(vt, region)`
- Produces: `os_recommend_flavor(workload: String?, min_vcpu: Int?, min_ram_gb: Int?)` → ranked list with reasoning

- [ ] **Step 1: Write the failing test**

```swift
@Test("recommend_flavor matches database workload to RAM-heavy flavor")
func recommendFlavorDatabase() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_recommend_flavor", ["workload": "database"])
    #expect(result.contains("hr") || result.contains("RAM"))  // hr = high RAM family
}

@Test("recommend_flavor handles unknown workload gracefully")
func recommendFlavorUnknown() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_recommend_flavor", ["workload": "quantum computing"])
    #expect(result.contains("gp") || result.contains("general"))  // falls back to general purpose
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter recommendFlavor`
Expected: FAIL — tool not found

- [ ] **Step 3: Implement the recommendation logic**

Workload keyword → flavor family mapping:
- "database", "postgres", "redis", "cache" → prefer `hr` (high RAM) or `gp` with large RAM
- "web", "api", "frontend", "general" → `gp` (general purpose)
- "compute", "hpc", "render", "compile" → `hc` (high compute)
- "storage", "data", "backup" → `hd` (high disk)
- "performance intensive", "io", "iops" → note volume type pairing (HA-Performance)

Return top 3 matches with: name, vCPU, RAM, disk, IOPS, network bandwidth, price/hr, and a `reason` string explaining the match. Always include a `volume_type_recommendation` field.

- [ ] **Step 4: Wire tool registration (AllTools, ToolRegistry, Policy, ToolListFormatter)**

Same pattern as Task 1.

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/swift test --filter recommendFlavor`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenStackMCPServer/Tools/FlavorRecommendationHandler.swift Sources/OpenStackMCPServer/Tools/AllTools.swift Sources/OpenStackMCPServer/Tools/ToolRegistry.swift Sources/OpenStackMCPServer/Policy/Policy.swift Sources/OpenStackMCPServer/Tools/ToolListFormatter.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat: add os_recommend_flavor workload-to-flavor matching"
```

---

### Task 6: Security Group Auto-Creation on Server Create

**Files:**
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift:938-1145` (server create path)
- Modify: `Sources/OpenStackMCPServer/Catalog/ComputeEntries.swift:7-167` (server createSchema)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: `NetworkService.createSecurityGroup`, `NetworkService.createSecurityGroupRule`
- Produces: When `security_groups` is empty/absent in server create spec, auto-create a per-server SG with SSH (port 22) + any `firewall` ports from the provisioning spec

- [ ] **Step 1: Write the failing test**

```swift
@Test("server create auto-creates SG with SSH when none specified")
func serverAutoSG() async throws {
    let reg = try await makeRegistry()
    // Create server without security_groups
    let result = try await firstText(reg, "os_create", [
        "resource": "server",
        "spec": "{\"name\":\"auto-sg-test\",\"flavor\":\"gp.0.2.6\",\"image\":\"fake\",\"networks\":[{\"network\":\"test-net\"}],\"key_name\":\"test-key\"}"
    ])
    #expect(result.contains("security_group_created"))
    #expect(result.contains("22"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter serverAutoSG`
Expected: FAIL

- [ ] **Step 3: Implement auto-SG in server create path**

In NameResolver server create, after network resolution and BEFORE `createServer`:
1. If `securityGroups` is empty AND no explicit `security_groups` in spec:
   - Create SG named `<server-name>-sg` with description "Auto-created by openstack-mcp"
   - Add ingress rule: TCP port 22, source 0.0.0.0/0 (SSH)
   - If provisioning spec has `firewall` entries, add those rules too
   - Set `securityGroups = [newSG.name]`
   - Record in response: `security_group_created: "<name>"`
2. Update schema description for `security_groups`: "If omitted, a per-server security group is auto-created with SSH (port 22) and any provisioning firewall ports."

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter serverAutoSG`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackMCPServer/NameResolver.swift Sources/OpenStackMCPServer/Catalog/ComputeEntries.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(server): auto-create security group with SSH when none specified"
```

---

### Task 7: Stuck-State Diagnostics in os_get

**Files:**
- Modify: `Sources/OpenStackMCPServer/NameResolver.swift` (get/list encoding for volumes)
- Modify: `Sources/OpenStackMCPServer/Tools/ResultFormatting.swift` (add diagnostic rendering)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: Volume object from `BlockStorageService.getVolume`
- Produces: When volume status is `reserved` with no attachments, adds a `diagnostic` field to the response

- [ ] **Step 1: Write the failing test**

```swift
@Test("reserved volume with no attachments shows diagnostic")
func reservedVolumeDiagnostic() async throws {
    let reg = try await makeRegistry()
    // Seed a volume in reserved state with no attachments in FakeOpenStack
    // ...
    let result = try await firstText(reg, "os_get", ["resource": "volume", "id_or_name": "stuck-vol"])
    #expect(result.contains("diagnostic"))
    #expect(result.contains("Cinder"))
    #expect(result.contains("force-release"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter reservedVolumeDiagnostic`
Expected: FAIL

- [ ] **Step 3: Add diagnostic logic to volume get/list encoding**

In NameResolver where volume objects are encoded (the `encodeObject` path for volumes), check:
- If `status == "reserved"` AND `attachments` is empty/nil:
  - Add `"diagnostic": "Volume is reserved with no active attachment. This typically occurs after server deletion when Cinder hasn't released a boot volume. Wait up to 30 minutes for Cinder periodic tasks, or contact support to force-release."`
- If `status == "error"`:
  - Add `"diagnostic": "Volume is in error state. Check the 'os-vol-host' field for the backend. Contact support if persistent."`

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter reservedVolumeDiagnostic`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackMCPServer/NameResolver.swift Sources/OpenStackMCPServer/Tools/ResultFormatting.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(volume): diagnostic hints for stuck reserved/error states"
```

---

### Task 8: Region Capability Matrix in os_clouds

**Files:**
- Modify: `Sources/OpenStackMCPServer/Tools/ToolRegistry.swift:541-550` (handleClouds)
- Test: `Tests/OpenStackMCPServerTests/InProcessMCPTests.swift`

**Interfaces:**
- Consumes: `OpenStackClient` (all services per region)
- Produces: Extended `os_clouds` response with per-region: volume_types, azs, flavor_count, public_networks

- [ ] **Step 1: Write the failing test**

```swift
@Test("clouds shows volume types per region")
func cloudsShowsVolumeTypes() async throws {
    let reg = try await makeRegistry()
    let result = try await firstText(reg, "os_clouds", [:])
    #expect(result.contains("volume_types"))
    #expect(result.contains("HA-Performance"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swift test --filter cloudsShowsVolumeTypes`
Expected: FAIL

- [ ] **Step 3: Extend handleClouds to query capabilities**

In `handleClouds` (ToolRegistry:541), for each region in the catalog:
1. Call `bs.listVolumeTypes(vt, region)` → extract names
2. Call `cs.listAvailabilityZones(vt, region)` → extract zone names
3. Call `cs.listFlavors(vt, region)` → count
4. Call `ns.listNetworks(vt, region)` → filter router:external=1 for public nets

Add these to the per-region output alongside the existing services list.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swift test --filter cloudsShowsVolumeTypes`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenStackMCPServer/Tools/ToolRegistry.swift Tests/OpenStackMCPServerTests/InProcessMCPTests.swift
git commit -m "feat(clouds): per-region capability matrix (volume types, AZs, flavors)"
```

---

## Execution Order & Dependencies

```
Task 1 (project_readiness) ──┐
Task 2 (dry_run)             ├── independent, can run in parallel
Task 3 (error hints)         │
Task 4 (next_steps)          │
Task 5 (recommend_flavor) ──┘
Task 6 (auto SG) ─── depends on Task 4 (uses next_steps pattern)
Task 7 (diagnostics) ── independent
Task 8 (clouds matrix) ── independent
```

Tasks 1-5 and 7-8 are fully independent. Task 6 should come after Task 4 (it adds `next_steps` to the server create response). Recommended execution order: 1 → 2 → 3 → 4 → 7 → 8 → 5 → 6.
