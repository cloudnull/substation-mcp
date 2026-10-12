# substation-mcp Conversational Tool Validation

**Purpose:** Feed this document to a chat harness (LLM agent with `substation-local` MCP access) to exercise the actual tool suite against a real cloud. It is the canonical, reusable validation plan for every conversational-interface test — smoke (fast, read-only + safe mutations) and end-to-end (full lifecycle, destructive).

**How to use:** Paste the relevant section(s) into the harness as its task brief. The harness must only act on resources it creates in the E2E phase, and MUST NOT touch or delete pre-existing infrastructure (existing servers, shared networks like `PUBLICNET`, production volumes). Record pass/fail per step in a results table at the end.

**Scope guardrails (bind every phase):**
- Never delete or modify resources you did not create this run.
- Prefixed names: create everything with a unique prefix (e.g. `smoke-<timestamp>-`) so cleanup is unambiguous and collisions are impossible.
- Prefer `dry_run: true` first for any `os_create`/`os_update`/`os_delete`; only proceed to the real mutation when dry-run returns valid.
- If a step fails, record the exact error text (including any `Hint:` line), continue to the next independent step, and note it in the results table. Do not abort the whole run on one failure unless it blocks downstream steps.
- All tool calls use the MCP tools directly (`os_*`). No CLI, no curl, no direct API calls.

---

## Part A — SMOKE TEST (read-only + cheap reversible mutations)

Goal: confirm the server is up, authenticated, discoverable, and that the guidance features respond correctly. Target duration: < 5 minutes. Safe to run against any project; creates nothing that outlives the session except optionally a throwaway keypair.

### A1. Identity & discovery (read-only)
| # | Call | Pass if |
|---|------|---------|
| 1 | `os_whoami` | Returns project name/domain, roles include an expected role, `scopes` non-empty |
| 2 | `os_clouds` | Lists ≥1 region; each region has a `services` map AND a `capabilities` array containing `volume_types` and `availability_zones` |
| 3 | `os_describe(server)` | Returns verbs including create/update/delete, actions incl. `reboot`/`console_output`/`provisioning_status`, and a `create_schema` with field names |
| 4 | `os_describe(network)` | Returns a `phase1Note` or description warning that external/public networks cannot be used for direct server attachment |
| 5 | `os_list(flavor)`, `os_list(image)`, `os_list(network)`, `os_list(security_group)`, `os_list(volume)` | Each returns an array (may be empty) without error; network list shows both private and any public nets |
| 6 | `os_quota(compute)`, `os_quota(volume)`, `os_quota(network)` | Each returns numeric limits |

### A2. Guidance features (the non-expert UX layer)
| # | Call | Pass if |
|---|------|---------|
| 7 | `os_project_readiness` | Returns `ready_for_servers` (bool) and a `blockers` array; blockers accurately reflect what's missing (e.g. "No private network" when there is none) |
| 8 | `os_recommend_flavor(workload="database")` | Returns top ≤3 recommendations with `reason` fields; picks a RAM-favored flavor |
| 9 | `os_recommend_flavor(workload="quantum computing")` | Does NOT error; falls back to general-purpose flavors with a sensible `reason` |
| 10 | `os_recommend_flavor(workload="web app", min_ram_gb=<large>)` | Respects the filter; returns fewer/no results rather than ignoring it |
| 11 | `os_find(value=<a known IP or name from A1>)` | Finds ≥1 matching resource |

### A3. Error-guidance behavior (expect specific structured errors)
These verify the actionable-hint and rejection layer. Each MUST return the documented signal, not a bare 500.
| # | Call | Pass if |
|---|------|---------|
| 12 | `os_get(resource=server, id_or_name="definitely-not-a-real-server-xyz")` | 404 with a `Hint:` mentioning `os_list` |
| 13 | `os_create(resource=server, spec={name:"smoke-x", flavor:<real>, image:<real>, networks:[{network:"PUBLICNET"}]}, dry_run=true)` | Returns `valid:false` with a `publicNetworkRejected` / "Cannot create server on external network" message and a `Hint:` listing the network→subnet→router→router_interface creation sequence |
| 14 | `os_create(resource=server, spec={name:"smoke-x", flavor:"no-such-flavor", image:<real>, networks:[...]}, dry_run=true)` | Returns `valid:false` with a `flavorNotFound` error in the collected errors array |
| 15 | `os_create(resource=server, spec={...both a bad image AND a bad network...}, dry_run=true)` | Returns BOTH errors in a single response (errors are accumulated, not fail-fast) |

### A4. One cheap reversible mutation (optional)
| # | Call | Pass if |
|---|------|---------|
| 16 | `os_create(resource=keypair, spec={name:"smoke-<ts>-key"})` then `os_delete(resource=keypair, id_or_name=...)` | Create returns the key; delete succeeds; subsequent `os_get(keypair,...)` 404s |

**Smoke verdict:** PASS if items 1–15 all pass (item 16 optional). Any failure in A1/A2 = functional regression. Any failure in A3 = guardrail regression (high priority).

---

## Part B — END-TO-END TEST (full lifecycle, destructive)

Goal: build a complete working stack from scratch, deploy a booting server, verify provisioning, then tear down everything cleanly. Creates a real network/subnet/router/volume/server/floating-IP. Run only in a project where this is acceptable. Every resource is prefixed `e2e-<ts>-`.

### B1. Prerequisite check
- [ ] `os_project_readiness` → read `blockers`. If a blocker lists "No private network", that is expected (we create one below). Note volume quota headroom for later.
- [ ] `os_list(image)` → pick one **active** image ID/name for the server (record it as `$IMAGE`).
- [ ] `os_recommend_flavor(workload="web app")` → pick the top recommendation (record as `$FLAVOR`).

### B2. Network foundation (ordered — each depends on the prior)
Create in this exact order; after each create, confirm the `next_steps` hint matches the next action:
- [ ] `os_create(network, {name:"e2e-<ts>-net"})` → capture id `$NET`. Response should carry `next_steps` pointing to subnet+router.
- [ ] `os_create(subnet, {name:"e2e-<ts>-sub", network_id:$NET, cidr:"10.<a>.<b>.0/24"})` → capture `$SUB`. `next_steps` should point to router_interface.
- [ ] `os_create(router, {name:"e2e-<ts>-rtr", external_gateway_info:{network_id:"PUBLICNET"}})` → capture `$RTR`. (If the public net has a different name, get it from `os_list(network)` filtered by `router:external`.)
- [ ] `os_attach(link:router_interface, source=$RTR, source_type=router, target=$SUB, target_type=subnet)` → network now routable.
- [ ] Verify: `os_topology(resource=network, id_or_name=$NET, diagnosis=true)` shows the router attached.

### B3. Volume + security group
- [ ] `os_create(volume, {name:"e2e-<ts>-vol", size:1})` → capture `$VOL`.
- [ ] (Optional SG path) Either create an explicit `os_create(security_group,...)`, OR rely on auto-SG in B5 by omitting `security_groups`.

### B4. Server dry-run, then create
- [ ] `os_create(server, {name:"e2e-<ts>-srv", flavor:$FLAVOR, image:$IMAGE, networks:[{network:$NET}], key_name:<a keypair name — create one first if needed>}, dry_run=true)` → expect `valid:true` (all prerequisites resolved). Fix anything in `warnings`.
- [ ] Real `os_create(server, {...same, plus provisioning block...})` with a minimal `provisioning` block:
  ```json
  {"packages":["curl"],"users":[{"name":"testuser","sudo":true}],"firewall":[{"proto":"tcp","port":8080}]}
  ```
  → capture `$SRV`. If `security_groups` was omitted, response should include `security_group_created` (auto-SG with SSH). Response `next_steps` should point to `os_wait`.

### B5. Boot + provisioning verification
- [ ] `os_wait(server, $SRV)` until `ACTIVE` (or `os_task_submit` → poll `os_task_status` if the wait is long).
- [ ] `os_action(server, $SRV, provisioning_status)` → confirms cloud-init completed (packages installed, user created, firewall applied). **This is the critical boot-from-image + provisioning correctness check.**
- [ ] If provisioning failed: `os_action(server, $SRV, console_output, {lines:200})` and record the log tail.

### B6. Attachments & floating IP
- [ ] `os_attach(link:volume, source=$SRV, source_type=server, target=$VOL, target_type=volume, params={device:"/dev/vdb"})` → volume attached. (The volume link requires a `device` param; source is the server, target the volume.)
- [ ] `os_create(floating_ip, {floating_network_id:<public net>})` → capture `$FIP`. `next_steps` should say `os_attach(link:floating_ip, source=$FIP, target=$SRV)`.
- [ ] `os_attach(link:floating_ip, source=$FIP, source_type=floating_ip, target=$SRV, target_type=server)` → associated.
- [ ] `os_get(server,$SRV)` → `access_ipv4` populated. (Optional: SSH in if key is available.)

### B7. Update & action coverage
- [ ] `os_update(server, $SRV, {name:"e2e-<ts>-srv-renamed"}, dry_run=true)` then real rename.
- [ ] `os_action(volume, $VOL, extend, {size:2})` → volume grows.
- [ ] `os_action(server, $SRV, reboot, {type:"soft"})` → returns to ACTIVE.
- [ ] `os_topology(server, $SRV, diagnosis=true)` → shows attached volume, FIP, network, SG.

### B8. Cleanup (reverse dependency order)
Use `os_delete(..., dry_run=true)` first to inspect dependents, then real deletes in this order:
- [ ] `os_detach` floating_ip (disassociate, never delete the association blindly)
- [ ] `os_delete(floating_ip, $FIP)`
- [ ] `os_detach(link:volume, source=$SRV, source_type=server, target=$VOL, target_type=volume)` → volume detached
- [ ] `os_action(server, $SRV, stop)` then `os_delete(server, $SRV)`
- [ ] `os_delete(volume, $VOL)` (note: may need to wait for `available` state after detach)
- [ ] `os_delete` any explicitly-created security_group (+ its rules)
- [ ] `os_detach` router_interface, then `os_delete(router, $RTR)`
- [ ] `os_delete(subnet, $SUB)`, `os_delete(network, $NET)`
- [ ] `os_delete(keypair, ...)` for any keypair created
- [ ] Final `os_list` over server/network/subnet/router/volume/floating_ip filtered by the `e2e-<ts>-` prefix → **must be empty**. Any leftover = incomplete cleanup (record which).

**E2E verdict:** PASS if B1–B8 all succeed with a clean final `os_list` (zero leftovers). A provisioning_status failure in B5 = boot/cloud-init regression (highest priority). A non-empty final list = cleanup bug.

---

## Part C — Results template (fill in per run)

```
Run: <cloud/region/project>  Date: <ts>  Prefix: e2e-<ts>-
Phase A (smoke): <N>/<total> pass
  Failures: <list # + error + Hint text>
Phase B (e2E): <pass/partial/fail>
  provisioning_status: <ok / FAILED + log tail>
  Leftovers after cleanup: <none | list>
Regressions flagged: <yes/no + which>
Notes / gotchas observed: <free text>
```

## Regression-priority matrix (what a failure means)
| Failing step | Severity | Likely cause |
|--------------|----------|--------------|
| A1 (identity/discovery) | Blocker | Auth, transport, or endpoint resolution broken |
| A2 item 7 (project_readiness) | High | Readiness aggregation broke |
| A3 items 13–15 (rejections/dry-run) | High | Guardrail layer regressed — non-experts can hit silent BUILD failures again |
| B5 provisioning_status | Highest | cloud-init rendering or console-output retrieval regressed |
| B2 next_steps ordering | Medium | Workflow hints wrong — harness steered incorrectly |
| B8 non-empty final list | Medium | Cleanup/dependency logic gap; orphans will accumulate |
