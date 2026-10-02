# Genestack Production Deployment — Design Spec

**Date:** 2026-10-02
**Status:** Draft — awaiting review
**Owner:** cloudnull

## Summary

Add a **Genestack production deployment** capability to `openstack-mcp`, delivered as:
1. A container image build target (reuses `deploy/Dockerfile`, amd64).
2. A **Helm chart** (`deploy/genestack/helm/openstack-mcp/`) that deploys the MCP server into the Genestack `openstack` namespace.
3. **Kustomize overlays** (`deploy/genestack/kustomize/`) that wire the chart into Genestack's `install-<svc>.sh` + `kustomize.sh` post-renderer flow.
4. An **install script** (`deploy/genestack/install-openstack-mcp.sh`) modeled on `bin/install-barbican-exporter.sh`.
5. A **README section** (`## Production deployment (Genestack)`) documenting the end-to-end path.

This is **additive**: the existing `deploy/Dockerfile`, `deploy/openstack-mcp.service` (systemd), and `scripts/build-image.sh` (native UBI10 rootfs tarball) remain untouched and are the deployables for non-Genestack hosts. Genestack is Kubernetes-based and consumes a container image, so it does **not** use the rootfs tarball or the systemd unit.

## Why Genestack (context)

Genestack (github.com/rackerlabs/genestack) is a K8s-based OpenStack deployer. Its canonical add-on pattern (reference: `barbican-exporter`) is:

- A **Helm chart** published to a repo (e.g. `rackerlabs.github.io/genestack-<svc>-helm-chart`).
- `base-kustomize/<svc>/base/kustomization.yaml` + an `overlay/` dir.
- `base-helm-configs/<svc>/<svc>-helm-overrides.yaml`.
- `bin/install-<svc>.sh` — runs `helm upgrade --install --namespace openstack --post-renderer /etc/genestack/kustomize/kustomize.sh --post-renderer-args <svc>/overlay`.
- A `helm-chart-versions.yaml` entry.
- `docs/<svc>.md`.

All OpenStack services live in the `openstack` namespace. External exposure is **Gateway API** (Envoy or Poundcake) + **MetalLB** VIP + a per-service FQDN (e.g. `keystone.domain.tld`). Secrets are created via `/opt/genestack/bin/create-secrets.sh` → `kubesecrets.yaml`.

Our openstack-mcp chart mirrors this layout under `deploy/genestack/` so a Genestack operator recognizes it, and so it can be dropped into a Genestack tree (or referenced from the operator's overlay) without translation.

## Architecture

```
MCP Client (Claude, etc.)
  │  Authorization: Bearer <keystone-token>
  ▼
Genestack Edge (MetalLB VIP + Gateway API — Envoy or Poundcake)
  │  https://openstack-mcp.<domain.tld>
  ▼
openstack-mcp Deployment (namespace: openstack)
  │  port 8080 (plaintext; TLS terminates at Gateway)
  ▼
Service openstack-mcp
  │
  ├── ConfigMap: openstack-mcp-config      (config.yaml)
  ├── ConfigMap: openstack-mcp-clouds      (clouds.yaml)
  └── Secret:    openstack-mcp-appcred     (app-cred id+secret for login page, optional)
  │
  ▼
Keystone / Nova / Neutron / Cinder / Glance  (in-cluster OpenStack services)
```

### Components

| Component | Purpose |
|-----------|---------|
| `deploy/genestack/helm/openstack-mcp/Chart.yaml` | Chart metadata (apiVersion v2, name `openstack-mcp`). |
| `deploy/genestack/helm/openstack-mcp/values.yaml` | Defaults: image repo/tag/pullPolicy, replicas, resources, `server`/`policy`/`log`/`session`/`auth`/`client`/`cache` config sections, `clouds` (name, allowed, region), `gateway` (fqdn, namespace, gatewayName, listener), `metrics` (enabled, token). |
| `deploy/genestack/helm/openstack-mcp/templates/deployment.yaml` | Deployment: non-root `securityContext`, `env` from config (OSMCP_* form), volume mounts for `clouds.yaml` + `config.yaml` (from ConfigMaps), `/metrics` port, liveness/readiness probes on `/healthz` + `/readyz`. |
| `deploy/genestack/helm/openstack-mcp/templates/service.yaml` | ClusterIP Service, port 8080 → container 8080. |
| `deploy/genestack/helm/openstack-mcp/templates/configmap.yaml` | Two ConfigMaps: `openstack-mcp-config` (renders the `server`/`policy`/`log`/… YAML) and `openstack-mcp-clouds` (renders `clouds.yaml`). |
| `deploy/genestack/helm/openstack-mcp/templates/secret.yaml` | `openstack-mcp-appcred` Secret (optional; only when `appCred` configured). |
| `deploy/genestack/helm/openstack-mcp/templates/_helpers.tpl` | Label/name helpers. |
| `deploy/genestack/helm/openstack-mcp/templates/gateway.yaml` | **Optional** HTTPRoute + Gateway (or references the operator's existing Gateway) + `tls` config. Conditionally rendered when `gateway.enabled`. This is the Genestack-recommended path for external exposure (MetalLB VIP + per-service FQDN). |
| `deploy/genestack/helm/openstack-mcp/templates/NOTES.txt` | Post-install: FQDN, how to connect a client, how to run `register-catalog`. |
| `deploy/genestack/kustomize/base/kustomization.yaml` | `resources: [all.yaml]` — points at the rendered Helm output. |
| `deploy/genestack/kustomize/overlay/kustomization.yaml` | Genestack `--post-renderer-args openstack-mcp/overlay` target; applies namespace/label patches. |
| `deploy/genestack/install-openstack-mcp.sh` | Modeled on `install-barbican-exporter.sh`: reads `helm-chart-versions.yaml`, `helm repo add` + `helm upgrade --install openstack-mcp ... --namespace openstack --post-renderer $OVERRIDES/kustomize/kustomize.sh --post-renderer-args openstack-mcp/overlay`. |
| `deploy/genestack/README.md` | Standalone how-to (mirrors `docs/<svc>.md` in Genestack). Also the source for the README section in the root repo. |
| `deploy/genestack/helm-chart-versions.yaml` (snippet) | The one-line entry the operator appends: `openstack-mcp: <version>`. |

### Data flow

1. **Build & push image.** `deploy/Dockerfile` (amd64) builds the release binary into `ubi10-minimal`, non-root uid 10001. The operator builds it and pushes to their cluster registry (e.g. `registry.<domain>/openstack/openstack-mcp:<tag>`).
2. **Chart values → config.** The Helm chart renders the server's YAML config (`server`, `policy`, `log`, `session`, `auth`, `client`, `cache`, `clouds`) into a ConfigMap. The server reads `--config /etc/openstack-mcp/config.yaml` (mounted) and `clouds.yaml` (mounted at `/etc/openstack/clouds.yaml`).
3. **Env vars.** `OSMCP_*` env vars (e.g. `OSMCP_SERVER__HOST`) are set on the Deployment as a secondary override layer, per the existing CLI > env > YAML > defaults precedence.
4. **Auth.** Token-per-request. The MCP client presents a Keystone Bearer token; the server validates via `GET /v3/auth/tokens`. No long-lived session token. The optional `appCred` secret powers the `/v1/login` URL-mode elicitation page.
5. **External exposure.** Gateway API (Envoy or Poundcake) routes `https://openstack-mcp.<domain.tld>` to the ClusterIP Service. TLS terminates at the Gateway. **Response buffering must be disabled** for `/v1` and `/mcp` (SSE) — in the Envoy/Poundcake Gateway config this maps to disabling buffering on those paths (documented in the Gateway template + README).
6. **Keystone catalog.** After the deployment is live, the operator runs `openstack-mcp register-catalog` (or `deploy/register-catalog.sh`) with an admin token to publish the `mcp` service + endpoints. This is a **separate, one-time** step, not part of the Helm chart.
7. **Connect a client.** `claude mcp add --transport http openstack https://openstack-mcp.<domain.tld>/v1 --header "Authorization: Bearer <token>"`.
8. **Verify.** `openstack-mcp check --cloud <name>` and `scripts/conformance.sh` against the live URL.

### Error handling

- **Image pull failure** → Deployment `ImagePullBackOff`; operator checks registry + pullSecret.
- **Keystone unreachable** → server logs auth failures; `osmcp_auth_failures_total` metric increments; per-source-IP rate limit (429) kicks in.
- **Config drift** → ConfigMap mount is read-only; a `helm upgrade` re-renders and the pod restarts (rollout).
- **SSE buffering** → documented anti-pattern; the Gateway template sets `buffering: disabled` (Envoy) or equivalent for the `/v1`/`/mcp` routes. If the operator's existing Gateway is reused, this is called out in the README as a manual step.

### Testing

- **Helm lint + template:** `helm lint deploy/genestack/helm/openstack-mcp/` and `helm template` (with sample values) → asserts all resources render, no `nil` errors.
- **Kustomize build:** `kubectl kustomize deploy/genestack/kustomize/overlay/` → asserts the rendered output applies cleanly (dry-run).
- **Install script:** shellcheck on `install-openstack-mcp.sh`; a `--dry-run` mode that prints the helm command without executing.
- **End-to-end (opt-in, in CI or on a Genestack cluster):** deploy the chart, run `scripts/conformance.sh` against the in-cluster URL. This is the real acceptance test and is **not** automated in CI (no Genestack cluster in CI); it's documented as a manual verification step.

## Global constraints

- **Namespace:** `openstack` (Genestack convention; all OpenStack services live here).
- **Image arch:** `linux/amd64` (Genestack clusters are typically amd64; the existing Dockerfile already pins `--platform=linux/amd64`).
- **Non-root:** container runs as uid 10001 (matches `deploy/Dockerfile` and the rootfs tarball).
- **No TLS in the server:** TLS terminates at the Gateway; the server binds `0.0.0.0:8080` plaintext (matches existing design).
- **SSE buffering off:** `/v1` and `/mcp` paths must not buffer responses (existing requirement).
- **Idempotent:** `helm upgrade --install` is safe to re-run; `register-catalog` is idempotent (existing behavior).
- **No new Swift code:** this is a deployment-asset + docs task; it does not modify `Sources/` or `Tests/`.

## Out of scope

- **Helm chart publishing/packaging** to a public repo (the operator builds and pushes their own chart or references `deploy/genestack/helm/` directly via `--chart`).
- **CI pipeline** for building + pushing the image (operator-owned).
- **Modifying existing `deploy/Dockerfile`, `deploy/openstack-mcp.service`, `scripts/build-image.sh`** (untouched).
- **Gateway implementation choice** (Envoy vs Poundcake) — the chart ships an Envoy-compatible HTTPRoute; the README notes Poundcake needs the same route.
- **Monitoring** (Prometheus scrape, Loki logging) — documented as a follow-up; the `/metrics` endpoint is already exposed.

## Open questions (for review)

1. **Chart distribution:** should the chart be a standalone repo (like `genestack-barbician-exporter-helm-chart`) or stay in-tree at `deploy/genestack/helm/`? *Recommendation: in-tree for now; the install script supports `--chart <path>` so it works without a published repo.*
2. **Gateway:** ship the HTTPRoute in the chart, or assume the operator wires it to their existing Gateway? *Recommendation: ship an optional `gateway.enabled` template; default `false` so the operator opts in.*
3. **README length:** the README section should be a pointer to `deploy/genestack/README.md` (canonical, detailed) plus a short "quick path" summary. *Recommendation: yes — keep the root README concise, push detail into the standalone how-to.*
