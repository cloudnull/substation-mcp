# substation-mcp Conversational Tool Validation

**Purpose:** The canonical, reusable validation plan for exercising the *entire* MCP tool suite conversationally — feeding this document to a chat harness (LLM agent with `substation-local` MCP access) so it drives every resource across **every code path it supports**. It is the single source of truth for all future conversational-interface test validations.

**Reference cloud:** Rackspace IAD3. But the plan is **capability-driven**: it discovers what the connected cloud actually exposes and adapts, so the same document runs on any OpenStack deployment. On IAD3 it exercises everything IAD3 has; on another cloud it automatically skips services the endpoint doesn't provide.

**"All resources / all code paths" means:** for every resource the catalog exposes that the cloud actually provides, exercise all four path classes it supports — **(V) verbs** list/get/create/update/delete, **(A) actions** (every named action in its descriptor), **(L) links** (attach + detach for each link kind), and **(W) wait** to a terminal state when it has one. Read-only resources are exercised over their read verbs only. See the per-service matrix in Part D.

---

## How to run

Paste Part 0 + the relevant parts into the harness as its task brief. The harness MUST:
- Drive the cloud **only through the MCP tools** (`os_*`). No CLI, no curl, no direct API calls.
- Create everything with a unique prefix `e2e-<ts>-` (all tiers, including expensive services) so cleanup is unambiguous.
- For any create/update/delete, call with `dry_run: true` first; proceed to the real mutation only when dry-run returns valid. Record the dry-run verdict.
- On any error, record the exact response text **including any `Hint:` line**, mark the step, and continue to the next independent step. Do not abort the whole run on one failure unless it blocks downstream steps.
- Fill the Part E results template at the end.

**Scope guardrails (bind every phase):**
- Never delete or modify resources you did not create this run. Pre-existing servers, shared networks (e.g. `PUBLICNET`), and production volumes are off-limits except as read-only anchors.
- Expensive long-lived services (database_instance, load_balancer, orchestration stack, share, container cluster) get a REAL create+delete lifecycle per the agreed all-tiers-together scope — but they are created late (after core compute/network/volume pass) and always torn down first-failure-first so a mid-run crash leaves fewer orphans.
- Teardown order is the strict reverse of creation dependency. After teardown, `os_list` filtered by the `e2e-<ts>-` prefix over every touched resource type MUST be empty. Any leftover = cleanup bug (record which).

---

## Part 0 — Capability discovery (drives everything)

Run once at the start. This produces the live capability matrix that determines what Parts A–D execute.

1. `os_whoami` → record project, region(s), roles, scopes. **Record whether the session has write scope.** If read-only, only Part A + the read verbs apply; skip all create/update/delete/action/link mutations and note "read-only session".
2. `os_clouds` → record regions and, per region, the `capabilities` array (`volume_types`, `availability_zones`, flavor count, public_networks) and the `services` map. Pick the target region (default the whoami region). Record which public network name to use as router gateway / FIP pool (typically `PUBLICNET`).
3. **Service probe loop.** For each resource name in the full catalog (list in Part D), issue ONE cheap read: `os_list(resource, limit=1)`. Classify each:
   - **PRESENT** — returned an array (possibly empty) or a success object.
   - **ABSENT** — returned `code:"no-endpoint"` (status 0) — the service endpoint isn't exposed on this cloud. Skip all its mutations; log it as absent.
   - **DENIED** — returned a policy/permission error (resource denied by policy, e.g. identity-admin `project`/`user`/`group`/`role`/`role_assignment`/`domain` are denied by default) or a scope error. Log as denied; do not retry.
   - Record the classification for every resource. **This matrix is the ground truth for the rest of the run.**
4. Capture reusable anchors for later phases (only if PRESENT):
   - `$IMAGE` = one `active` image from `os_list(image)`.
   - `$FLAVOR` = top recommendation from `os_recommend_flavor(workload="web app")` (verify it appears in `os_list(flavor)`).
   - `$PUBNET` = external network id (from os_clouds public_networks or `os_list(network, filters={external:true})`).
   - Quota headroom: `os_quota(compute)`, `os_quota(volume)`, `os_quota(network)` — record limits so a quota-exceeded negative test can be reasoned about.

**Part 0 verdict:** PASS if whoami/clouds succeed and the probe loop classified every catalog resource as exactly one of PRESENT/ABSENT/DENIED without unexpected errors.

---

## Part A — Smoke (identity, guidance, error layer)

Fast, safe, confirms the server is up/authenticated and the non-expert UX layer works. Runs fully in a read-only session too. All items below should hold regardless of which services are present.

| # | Call | Pass if |
|---|------|---------|
| A1 | `os_whoami` | project/domain present, roles non-empty, scopes recorded |
| A2 | `os_clouds` | ≥1 region; each region has `services` AND `capabilities` with `volume_types` + `availability_zones` |
| A3 | `os_describe(server)` | verbs incl. create/update/delete; actions incl. `reboot`,`console_output`,`provisioning_status`; `create_schema` has field names; `networks` description documents the private-network prerequisite chain |
| A4 | `os_describe(network)` | includes a note that external/public networks cannot host servers directly |
| A5 | `os_project_readiness` | returns `ready_for_servers` (bool) + `blockers[]` that accurately reflect missing prereqs |
| A6 | `os_recommend_flavor(workload="database")` | ≤3 recs, each with `reason`; **smallest-that-fits first** (never the biggest flavor), family-biased toward high-RAM at that smallest size |
| A7 | `os_recommend_flavor(workload="quantum computing")` | does NOT error; falls back to general purpose at the conservative default (1 vCPU / 2 GB) with `inferred_requirements.defaulted: true` |
| A8 | `os_recommend_flavor(workload="web app", min_ram_gb=<large>)` | minimums are **hard floors**: flavors below them are never offered; an empty result comes with a hint to lower them |
| A9 | `os_find(value=<known IP/name from Part 0>)` | finds ≥1 match |
| A10 | `os_get(server,"definitely-not-real-xyz")` | 404 with `Hint:` mentioning `os_list` |
| A11 | `os_create(server,{name:"smoke-x",flavor:$FLAVOR,image:$IMAGE,networks:[{network:$PUBNET}]},dry_run=true)` | `valid:false` + `publicNetworkRejected`/external-network message + `Hint:` listing network→subnet→router→router_interface sequence |
| A12 | `os_create(server,{name:"smoke-x",flavor:"no-such-flavor",image:$IMAGE,networks:[...]},dry_run=true)` | `valid:false` with `flavorNotFound` in errors array |
| A13 | `os_create(server,{...bad image AND bad network...},dry_run=true)` | returns BOTH errors in one response (accumulated, not fail-fast) |

**Smoke verdict:** PASS if A1–A13 pass. A1–A9 failure = functional regression. A10–A13 failure = guardrail regression (high priority — non-experts re-hit silent BUILD failures).

---

## Part B — Core stack E2E (compute + network + volume, full lifecycle)

The heart of the run. Builds a working private network, deploys a booting server, verifies provisioning, attaches a data volume + floating IP, then tears down cleanly. Everything here is prefixed `e2e-<ts>-`. Requires write scope.

### B1. Prereq
- [ ] `os_project_readiness` — note blockers; "No private network" expected (we build one). Note volume quota headroom.
- [ ] Confirm `$IMAGE` active, `$FLAVOR` exists, `$PUBNET` resolved (from Part 0).
- [ ] `os_create(keypair,{name:"e2e-<ts>-key"})` → capture `$KEY` (omit `public_key` to auto-generate). Needed for server + provisioning login.

### B2. Network foundation (strictly ordered; confirm each create's `next_steps` points at the next action)
- [ ] `os_create(network,{name:"e2e-<ts>-net"})` → `$NET`. Expect `next_steps` → subnet + router.
- [ ] `os_create(subnet,{name:"e2e-<ts>-sub",network_id:$NET,cidr:"10.<a>.<b>.0/24",enable_dhcp:true})` → `$SUB`. `next_steps` → router_interface.
- [ ] `os_create(router,{name:"e2e-<ts>-rtr",external_gateway_info:{network_id:$PUBNET}})` → `$RTR`.
- [ ] `os_attach(link:router_interface,source=$RTR,source_type=router,target=$SUB,target_type=subnet)` → routable.
- [ ] Verify `os_topology(network,$NET,diagnosis=true)` shows router attached.

### B3. Security group (explicit path — the auto-SG path is covered in B4b)
- [ ] `os_create(security_group,{name:"e2e-<ts>-sg",description:"e2e"})` → `$SG`.
- [ ] `os_create(security_group_rule,{security_group_id:$SG,direction:"ingress",ethertype:"IPv4",protocol:"tcp",port_range_min:8080,port_range_max:8080,remote_ip_prefix:"0.0.0.0/0"})` → rule created.

### B4. Server — boot-from-image WITH provisioning
- [ ] **B4a dry-run:** `os_create(server,{name:"e2e-<ts>-srv",flavor:$FLAVOR,image:$IMAGE,networks:[{network:$NET}],key_name:$KEY,security_groups:[$SG]},dry_run=true)` → expect `valid:true`. Fix anything in `warnings`.
- [ ] **B4b real (auto-SG path variant):** create a second server omitting `security_groups` to verify auto-creation: `os_create(server,{name:"e2e-<ts>-srv2",flavor:$FLAVOR,image:$IMAGE,networks:[{network:$NET}],key_name:$KEY},...)` → response MUST include `security_group_created` (auto SG with SSH). Use the B4a server ($SRV) as the primary one carrying the explicit $SG.
  ```json
  // provisioning block on both servers
  {"packages":["curl"],"users":[{"name":"testuser","sudo":true}],"firewall":[{"proto":"tcp","port":8080}]}
  ```
- [ ] Capture `$SRV` (primary) and `$SRV2` (auto-SG). Response `next_steps` should point to `os_wait`.

### B5. Boot + provisioning verification (HIGHEST-PRIORITY correctness check)
- [ ] `os_wait(server,$SRV)` until `ACTIVE` (or `os_task_submit` → poll `os_task_status` if the wait may exceed the client timeout; also exercise `os_task_cancel` on a throwaway task).
- [ ] `os_action(server,$SRV,provisioning_status)` → confirms cloud-init completed (package installed, user created, firewall port open). **Failure here = cloud-init rendering or console-output regression.**
- [ ] On failure: `os_action(server,$SRV,console_output,{lines:200})`, record the tail.

### B6. Data volume + floating IP
- [ ] `os_create(volume,{name:"e2e-<ts>-vol",size:1})` → `$VOL`; wait until `available`.
- [ ] `os_attach(link:volume,source=$SRV,source_type=server,target=$VOL,target_type=volume,params={device:"/dev/vdb"})` → attached (volume link REQUIRES a `device` param; source=server, target=volume).
- [ ] `os_create(floating_ip,{floating_network_id:$PUBNET})` → `$FIP`. `next_steps` says attach fip→server.
- [ ] `os_attach(link:floating_ip,source=$FIP,source_type=floating_ip,target=$SRV,target_type=server)` → associated.
- [ ] `os_get(server,$SRV)` → `access_ipv4` populated. (Optional: SSH in using $KEY.)

### B7. Update + action coverage on the live stack
- [ ] `os_update(server,$SRV,{name:"e2e-<ts>-srv-renamed"},dry_run=true)` then real rename; `os_get` confirms new name.
- [ ] `os_action(volume,$VOL,extend,{size:2})` → grows to 2 GB.
- [ ] `os_action(server,$SRV,reboot,{type:"soft"})` → returns to ACTIVE.
- [ ] `os_topology(server,$SRV,diagnosis=true)` → shows volume, FIP, network, SG.

### B8. Boot-from-volume path (distinct from boot-from-image)
- [ ] `os_create(server,{name:"e2e-<ts>-bv",flavor:$FLAVOR,image:$IMAGE,networks:[{network:$NET}],key_name:$KEY,volumes:[{boot:true,size:40}]},dry_run=true)` → `valid:true`.
- [ ] Real create → Nova makes a NEW root volume from the image (BDM v2 source_type=image, destination_type=volume). Wait to ACTIVE; `os_get` confirms a boot volume attachment. (Do NOT pre-create a volume for this — the boot entry takes `size`, not `volume_id`.)

### B9. Cleanup (reverse dependency order; dry_run-delete first to see dependents)
- [ ] `os_detach(link:floating_ip,source=$FIP,...)` (disassociate), then `os_delete(floating_ip,$FIP)`.
- [ ] `os_detach(link:volume,source=$SRV,source_type=server,target=$VOL,target_type=volume)`; wait volume → `available`, then `os_delete(volume,$VOL)`.
- [ ] `os_action(server,$SRV,stop)` then `os_delete(server,$SRV)`; same for `$SRV2` and boot-vol server `$BV`.
- [ ] Delete any SG rules then `os_delete(security_group,$SG)`; delete any auto-created SG the platform made for $SRV2 (find via `os_list(security_group,filters={name:e2e-<ts>-})`).
- [ ] `os_detach(link:router_interface,source=$RTR,target=$SUB,...)`, `os_delete(router,$RTR)`, `os_delete(subnet,$SUB)`, `os_delete(network,$NET)`.
- [ ] `os_delete(keypair,$KEY)`.
- [ ] Final sweep: `os_list` over server/network/subnet/router/volume/floating_ip/security_group/keypair filtered by `e2e-<ts>-` prefix → **must all be empty**. Leftovers = cleanup bug.

**Core-stack verdict:** PASS if B1–B9 complete with a clean final sweep. Provisioning_status failure = highest priority. Non-empty sweep = cleanup bug.

---

## Part C — Cross-cutting code paths

These cover behaviors no single-resource loop exercises. Run after Part B (they reuse anchors where possible).

### C1. Negative / precondition failures (expect specific structured errors)
| # | Scenario | Expected |
|---|----------|----------|
| C1.1 | `os_attach(link:volume, ...)` on a volume NOT in `available` (e.g. already in-use) | 409 `badVolumeState` with actionable hint |
| C1.2 | `os_attach(link:interface, source=<building server>, ...)` while a server is still building | 409 bad-state |
| C1.3 | `os_attach` interface on a port already attached to another device | 409 `portAttached` |
| C1.4 | `os_delete(network,$NET,dry_run=true)` while a subnet still exists on it | dry-run lists the dependent subnet as a blocker, does NOT delete |
| C1.5 | `os_delete(subnet,dry_run=true)` while a port still uses it | dry-run reports dependent ports |
| C1.6 | Attach FIP to a port whose subnet is not routed to the FIP's external net | precondition error / routing hint |
| C1.7 | `os_create` of something over quota (reason from Part 0 quota, e.g. many servers) | 403 quota error + `Hint:` to delete unused or request increase |
| C1.8 | `os_action` with an invalid action name | 400 with available-actions hint |

For each, the PASS criterion is: the call fails with the correct status/code AND the response carries a useful `Hint:` — not a bare 500 or opaque error.

### C2. Multi-region routing
If `os_clouds` reported >1 region: repeat two cheap reads (one present resource list + one os_quota) with an explicit `region:<other>` param and confirm they route to that region (different result set or same-but-scoped, no endpoint error). Single-region clouds: record "single region, skipped" and PASS.

### C3. Scope enforcement
If you have a way to present a read-only token (separate harness/session): confirm create/update/delete/action/link return a scope-denied error while list/get/describe still work. If no read-only token is available, record "not exercised" (do not fabricate).

### C4. Task subsystem
- [ ] `os_task_submit(server,<id>)` → returns `task_id` immediately.
- [ ] `os_task_status(task_id)` → transitions submitted→running→terminal; terminal result carries final status.
- [ ] `os_task_cancel(task_id)` on a still-running task → cancelled; a second cancel → no-op error (unknown/already-terminal).

### C5. Wait subsystem
- [ ] `os_wait` on a fast resource reaches terminal within timeout; `os_wait` with a deliberately short `timeout_seconds` on a slow transition times out gracefully (structured timeout result, not a hang).

---

## Part D — Exhaustive per-service coverage matrix

**Method (the algorithm the harness follows):** For every resource classified **PRESENT** in Part 0 that has write support (and the session has write scope), exercise all supported path classes by deriving the exact fields from `os_describe(resource)` at runtime:

1. **Read verbs** (always, if present): `os_list(resource)`; pick/create one instance; `os_get(resource, <id_or_name>)`.
2. **Create:** `os_describe(resource)` → read `create_schema.required` + properties → build a minimal valid spec (use the per-service notes below for the concrete spec + dependencies) → `os_create(...,dry_run=true)` → real create → capture the id.
3. **Update** (if `updateSchema` present): rename/change one field, dry_run then real, confirm via `os_get`.
4. **Actions** (each in the descriptor's `actions`): invoke each with required params from `os_describe`; destructive ones (stop/reboot/disassociate/clear_gateway/reset_status/etc.) applied in an order that keeps the resource usable until teardown.
5. **Links** (each `LinkSpec` in the descriptor): `os_attach` then `os_detach` with the documented source/target types and required params.
6. **Wait** (if `terminalStates` present): `os_wait` to a terminal state after any transition.
7. **Delete** (last, reverse-dependency): `os_delete(...,dry_run=true)` to inspect dependents → real delete → confirm gone via `os_get` 404.

**Ordering rule:** create parents before children (network→subnet→router; lb→listener/pool→member/health_monitor; zone→recordset; container→object; sg→rule; reservation→allocation; volume→snapshot). Delete strictly reversed. Where a child needs a live parent anchor that Part B already tore down, create a minimal throwaway parent under the `e2e-<ts>-` prefix.

### Per-service concrete specs & ordering notes (only where a field differs or ordering matters)

| Resource (service) | Verbs | Concrete create spec (minimal valid) | Actions to hit | Links | Notes / ordering |
|---|---|---|---|---|---|
| server (compute) | L G C U D | `{name, flavor, image, networks:[{network}], key_name}` (+`provisioning`/`volumes`) | start/stop/reboot/rescue/unrescue*/suspend/resume*/pause/unpause*/shelve/unshelve*/snapshot/console_output/provisioning_status/add_security_group/remove_security_group | volume, interface, security_group | *destructive/stateful — order to keep usable; verify provisioning_status after create. Covered heavily in Part B. |
| flavor (compute) | L G C D | `{name, vcpus, ram, disk}` | — | — | May require admin; if denied, log DENIED. |
| keypair (compute) | L G C D | `{name}` (omit public_key to generate) | — | — | idField is name. |
| server_group (compute) | L G C D | `{name, policies:["soft-anti-affinity"]}` | — | — | |
| availability_zone (compute) | L | — | — | — | read-only. |
| hypervisor (compute) | L G | — | — | — | read-only; often admin. |
| compute_service (compute) | L U | — | enable/disable (adminOnly) | — | update `{disabled,reason}`; admin-gated — likely DENIED. |
| server_interface / server_volume_attachment (compute) | L | — | — | — | read-only views. |
| compute_quota (compute) | G U | — | — | — | get via os_quota(compute); update rarely permitted — likely DENIED, log it. |
| network (network) | L G C U D | `{name}` | — | router_gateway | phase1Note warns external nets can't host servers. |
| subnet (network) | L G C U D | `{name, network_id, cidr, enable_dhcp:true}` | — | — | needs a parent network. |
| port (network) | L G C U D | `{name, network_id}` | — | — | |
| router (network) | L G C U D | `{name, external_gateway_info:{network_id:$PUBNET}}` | set_gateway / clear_gateway | router_interface, router_gateway | |
| floating_ip (network) | L G C D | `{floating_network_id:$PUBNET}` | associate / disassociate | floating_ip (fip→port) | |
| security_group (network) | L G C U D | `{name, description}` | — | — | |
| security_group_rule (network) | L G C D | `{security_group_id, direction, ethertype, protocol, port_range_min/max, remote_ip_prefix}` | — | — | needs parent SG. |
| address_group (network) | L G C U D | `{name, ip_addresses:["1.2.3.4"]}` | — | — | |
| network_quota (network) | G U | — | — | — | get via os_quota(network); update likely DENIED. |
| image (image) | L G C U D | `{name, disk_format:"qcow2", container_format:"bare"}` (import via `import:{method:"web-download",uri:...}` only if a URI is available, else create empty shell) | set_visibility / protect / unprotect / add_tag / remove_tag / deactivate / reactivate | image (volume→image, create-time) | Terminal states active/killed. Prefer operating on a self-imported or tiny image; don't mutate shared images. |
| volume (block_storage) | L G C U D | `{name, size:1}` (add `volume_type` if needed; `image` to clone) | extend / retype / reset_status / upload_to_image / set_bootable | — (attached via server's volume link) | Terminal available/in-use. |
| volume_type (block_storage) | L G C D | `{name}` | — | — | Usually admin/DENIED. |
| volume_snapshot (block_storage) | L G C D | `{volume_id, name}` | — | — | needs parent volume. |
| volume_backup (block_storage) | L G C D | `{name, volume_id}` | restore | — | |
| volume_quota (block_storage) | G U | — | — | — | get via os_quota(volume); update likely DENIED. |
| container (object_storage) | L G C D | `{name}` | — | — | |
| object (object_storage) | L G C D | `{container, name, content}` | — | — | needs parent container. |
| secret (key_manager) | L G C D | `{name, ...payload fields from os_describe}` | get_payload | — | payload is secret — never echo it in output. |
| secret_container (key_manager) | L G D | — | — | — | |
| load_balancer (loadbalancer) | L G C U D | `{name, vip_subnet_id:$LB_SUBNET}` | — | — | Needs a VIP subnet (reuse e2e subnet or make one). Ordering: lb → listener + pool → member + health_monitor. |
| listener (loadbalancer) | L G C U D | `{name, protocol:"HTTP", protocol_port:80, load_balancer_id:$LB}` | `{default_pool_id:$POOL}` | — | parent lb; update binds the default pool. |
| pool (loadbalancer) | L G C U D | `{name, protocol:"HTTP", lb_algorithm:"ROUND_ROBIN", listener_id:$LISTENER}` | `{lb_algorithm:"LEAST_CONNECTIONS"}` | — | bind via `listener_id` (or `load_balancer_id`). |
| member (loadbalancer) | L G C U D | `{name, address:<ip>, protocol_port:80, pool_id:$POOL}` | `{weight:5}` | — | pool sub-resource; terminal ONLINE/OFFLINE. Field is `address`. |
| health_monitor (loadbalancer) | L G C U D | `{name, type:"PING", delay:5, timeout:5, max_retries:3, pool_id:$POOL}` | `{delay:10}` | — | parent pool. |
| zone (dns) | L G C D | `{name:"<fqdn>."}` (trailing dot) | — | — | |
| recordset (dns) | L G C D | `{zone_id/name, name:"host.", type:"A", ttl:60, records:["1.2.3.4"]}` (fields per os_describe) | — | — | parent zone. |
| cluster (container_infra) | L G C D | `{name, ...per os_describe}` | — | — | Expensive; create then delete promptly. |
| cluster_template (container_infra) | L G C D | `{name, ...}` | — | — | |
| database_instance (database) | L G C D | `{name, flavor, datastore:<datastore from os_list(database_datastore)>, volume:{size:N}}` (fields per os_describe) | — | — | Expensive + minutes to be ready; `os_wait`/task to online, then delete promptly. |
| database_flavor / database_datastore (database) | L G | — | — | — | read-only; datastore list feeds instance create. |
| queue (messaging) | L G | — | — | — | read-only. |
| metric (metric) | L G | — | — | — | read-only. |
| resource_type (metric) | L G | — | — | — | read-only. |
| reservation (reservation) | L G C D | `{name, ...per os_describe}` | — | — | |
| allocation (reservation) | L G | — | — | — | read-only; child of reservation. |
| share (sharev2) | L G C D | `{name, size:N, share_type:<from os_describe/os_list>}` | — | — | Expensive; delete promptly. |
| share_access (sharev2) | L G C D | `{share_id, access_to, access_type:<per os_describe>}` | — | — | parent share. |
| stack (orchestration) | L G C D | `{name, template_body:<minimal Heat/CFN>, parameters:{}}` | get_outputs | — | Expensive + creates nested resources; use a trivial template, then delete (deletes nested). |
| cfn_stack (cloudformation) | L G | — | — | — | read-only view. |
| backup (backup) | L G | — | — | — | read-only. |
| schedule (backup) | L G | — | — | — | read-only. |
| placement (placement) | L G | — | — | — | read-only (uuid/named). |
| region (identity) | L G | — | — | — | read-only. |
| project / user / group / role / role_assignment / domain (identity) | varies | — | — | — | **Denied by default policy** (`defaultDenyResources`). Expect DENIED for all six; log each, do not force. Create/update/delete only if policy explicitly allows. |
| service (identity) | L G | — | — | — | read-only service catalog view. |
| endpoint (identity) | L G | — | — | — | read-only; filter by type/region. |
| application_credential (identity) | L G | — | — | — | read-only list/get of existing app creds. |
| server_volume_attachment (compute) | L | — | — | — | read-only view of a server's volume attachments (also surfaced via server volume link). |

**Exhaustive-coverage verdict:** PASS if every PRESENT+write-supported resource had all of its supported verbs/actions/links exercised (or explicitly blocked by a recorded DENIED/quota/precondition with the correct error). Absent/denied resources are logged, not failed. Any PRESENT resource whose create produced a wrong shape, or whose action/link silently no-opped without effect, is a defect.

---

## Part E — Results template (fill in per run)

```
Cloud/Region/Project: <…>     Date: <ts>    Prefix: e2e-<ts>-
Session scope: <read-only | read-write>
Part 0 capability matrix: <N present> / <N absent> / <N denied>  (list absent+denied)
Part A smoke:   <N>/13 pass   Failures: <# + error + Hint>
Part B core:    <pass/partial/fail>   provisioning_status: <ok | FAILED + tail>
                 boot-from-volume: <ok/fail>   final sweep leftovers: <none | list>
Part C xcut:    C1 <n/8>  C2 <skipped/pass>  C3 <skipped/pass>  C4 <pass/fail>  C5 <pass/fail>
Part D matrix:  <resources fully exercised> / <total present-write>
                 Defects (wrong shape / silent no-op): <list>
Regressions flagged: <yes/no + which>
Notes / gotchas: <free text>
```

## Regression-priority matrix (what a failure means)

| Failing area | Severity | Likely cause |
|--------------|----------|--------------|
| Part 0 probe misclassifies / crashes | Blocker | Endpoint resolution or transport broken |
| Part A A1–A9 | High | Discovery/guidance features regressed |
| Part A A10–A13 | High | Guardrail/error-hint layer regressed (non-experts re-hit silent failures) |
| Part B B5 provisioning_status | Highest | cloud-init rendering or console-output retrieval regressed |
| Part B B8 boot-from-volume | High | BDM v2 boot-from-image→volume flow regressed |
| Part B B9 non-empty sweep | Medium | Cleanup/dependency logic gap; orphans accumulate |
| Part C1 any negative path returns opaque 500 | High | Structured error/hint layer regressed |
| Part D resource create wrong shape / silent no-op | High | That resource's NameResolver/service mapping regressed |
| Part C2 multi-region wrong routing | Medium | Region param not threaded through a service |

## Maintenance note
Do NOT hand-expand this file with every resource's full field list — that rots. Field authority lives in the live `os_describe` output and the Swift catalog under `Sources/OpenStackMCPServer/Catalog/`. When a new resource/service lands, add one row to the Part D matrix (verbs + minimal spec + ordering) and, if it introduces a new failure mode, one row to the regression matrix. Keep the concrete specs minimal-valid only.
