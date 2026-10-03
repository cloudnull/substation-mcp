# substation-mcp — Genestack Deployment

Deploy the **substation-mcp** server (an MCP server for consuming an OpenStack
cloud via Keystone/Nova/Neutron/Cinder/Glance) into a [Genestack](https://github.com/rackerlabs/genestack)
cluster as a canonical Genestack add-on.

This follows the same pattern as Genestack's built-in add-ons
(e.g. `barbican-exporter`): a Helm chart + kustomize overlays + an
`install-<svc>.sh` script + a `helm-chart-versions.yaml` entry.

## Prerequisites

- A Genestack cluster (Kubernetes + OpenStack already deployed).
- A container registry the cluster can pull from (e.g. the cluster's own
  registry, quay.io, ghcr.io, etc.).
- `kubectl`, `helm`, `yq` available on the Genestack controller node.
- An OpenStack application credential (admin role) for `register-catalog`.

## Files

| Path | Purpose |
|------|---------|
| `helm/substation-mcp/` | The Helm chart (Deployment, Service, config ConfigMap, clouds Secret, ServiceAccount, optional Gateway+HTTPRoute). |
| `kustomize/base/` | Kustomize base (namespace, common labels, `all.yaml` written by the post-renderer). |
| `kustomize/overlay/` | Kustomize overlay (post-renderer target for the install script). |
| `install-substation-mcp.sh` | The install/upgrade script (mirrors `bin/install-barbican-exporter.sh`). |
| `base-helm-configs/substation-mcp-helm-overrides.yaml` | Baseline Helm overrides to copy into the Genestack tree. |
| `helm-chart-versions.yaml` | The one-line version entry to append to `/etc/genestack/helm-chart-versions.yaml`. |

> **How the post-renderer works:** `install-substation-mcp.sh` invokes
> `helm upgrade --install --post-renderer /etc/genestack/kustomize/kustomize.sh
> --post-renderer-args substation-mcp/overlay`. Genestack's `kustomize.sh`
> writes the `helm template` output (stdin) to `kustomize/base/all.yaml`, then
> runs `kubectl kustomize kustomize/overlay/`. The overlay's `resources:
> [../base]` pulls in that written `all.yaml`, applies the Genestack namespace
> + labels, and emits the final manifests. The checked-in `all.yaml` is a
> placeholder so `kustomize build` works in CI without running the install
> script first.

## Step 1 — Build and push the image

The chart pulls a container image. Build it from the repo root (amd64, per
`deploy/Dockerfile`) and push to your cluster registry:

```sh
# From the repo root:
docker build --platform linux/amd64 -f deploy/Dockerfile \
  -t registry.example.com/openstack/substation-mcp:0.1.0 .
docker push registry.example.com/openstack/substation-mcp:0.1.0
```

> **Arch note:** Genestack clusters are typically `linux/amd64`. The
> `deploy/Dockerfile` pins `--platform=linux/amd64` in the builder stage.
> If your cluster is arm64, adjust the `--platform` flag.

## Step 2 — Copy the chart + overrides into the Genestack tree

On the Genestack controller node, copy the chart and baseline overrides:

```sh
# (adjust paths to match your Genestack checkout / install layout)
cp -r deploy/genestack/helm/substation-mcp /opt/genestack/base-helm-configs/  # optional; see below
mkdir -p /opt/genestack/base-helm-configs/substation-mcp
cp deploy/genestack/base-helm-configs/substation-mcp-helm-overrides.yaml \
   /opt/genestack/base-helm-configs/substation-mcp/

# Append the version entry:
echo "  substation-mcp: 0.1.0" >> /etc/genestack/helm-chart-versions.yaml
```

> **Chart location:** the install script uses the in-tree chart by default
> (`deploy/genestack/helm/substation-mcp`). If you prefer a published Helm
> repo, set `chart.repo_url` in a custom override YAML and the script will
> `helm repo add` it.

## Step 3 — Configure

Edit `/opt/genestack/base-helm-configs/substation-mcp/substation-mcp-helm-overrides.yaml`:

- **`image.repository` / `image.tag`** — your registry + tag.
- **`config.server.publicUrl`** — the FQDN that will be exposed (must match
  `gateway.fqdn` and the `PUBLIC_URL` used in `register-catalog`).
- **`config.server.metricsToken`** — set a strong token to gate `/metrics`.
- **`config.clouds.default`** — your cloud name.
- **`cloudsClouds.cloud_name.<name>.auth`** — your OpenStack auth details
  (Keystone URL, region, etc.).
- **`gateway.enabled` / `gateway.fqdn` / `gateway.gatewayClassName`** —
  external exposure via Gateway API (Envoy or Poundcake).

For an operator-specific override with the highest precedence, drop a file
into `/etc/genestack/helm-configs/substation-mcp/*.yaml`.

## Step 4 — Install

```sh
# Dry-run first (prints the helm command, does not execute):
./deploy/genestack/install-substation-mcp.sh --dry-run

# Real install:
./deploy/genestack/install-substation-mcp.sh \
  --set image.repository=registry.example.com/openstack/substation-mcp \
  --set image.tag=0.1.0

# Or with a custom override file:
./deploy/genestack/install-substation-mcp.sh
```

The script is idempotent (`helm upgrade --install`). Re-running it after a
config change re-renders and rolls the deployment.

## Step 5 — Expose externally (Gateway API)

If you set `gateway.enabled=true`, the chart renders an `HTTPRoute` (and a
`Gateway` if `gateway.createGateway=true`). Ensure:

1. The `gatewayClassName` matches your cluster's GatewayClass
   (`envoy-gateway` for Envoy, `poundcake` for Poundcake). Check with
   `kubectl get gatewayclass`.
2. A TLS certificate for `gateway.fqdn` is available to the listener
   (cert-manager or a manually-created Secret).
3. **SSE streaming:** Envoy Gateway and Poundcake do not buffer HTTP
   responses by default, so the Server-Sent Events on `/v1` and `/mcp`
   work out of the box — no special annotation is required. If your Gateway
   implementation DOES buffer responses, see its docs for the exact
   mechanism to disable buffering on this route.
4. The FQDN is reachable via MetalLB VIP (Genestack convention).

## Step 6 — Register the MCP service in Keystone

One-time, as an operator with an admin token:

```sh
export OS_CLOUD=mycloud REGION=RegionOne
export PUBLIC_URL=https://substation-mcp.example.com   # must match gateway.fqdn
export OS_AUTH_TOKEN=<admin-keystone-token>

./deploy/register-catalog.sh
```

This is idempotent — re-running it reuses the existing `mcp` service.

## Step 7 — Connect an MCP client

Mint a Keystone token (or use the `/v1/login` page in a browser), then:

```sh
claude mcp add --transport http openstack \
  https://substation-mcp.example.com/v1 \
  --header "Authorization: Bearer <keystone-token>"
```

## Step 8 — Verify

```sh
# 1. The deployment is running:
kubectl -n openstack get deploy substation-mcp
kubectl -n openstack get pods -l app.kubernetes.io/name=substation-mcp

# 2. Validate the credential + scopes:
OS_AUTH_TOKEN=<token> ./.build/release/substation-mcp check --cloud mycloud

# 3. Run the conformance handshake against the live URL:
scripts/conformance.sh \
  --url https://substation-mcp.example.com/v1 \
  --token <minted-keystone-token>
```

Expected: 401 challenge → PRM → initialize → tools/list (15 tools, or 9
with `read_only: true`) → `os_whoami` 200 → DELETE 200.

## Upgrading

```sh
# Bump the image tag in the override, then re-run the install script:
sed -i 's/tag: "0.1.0"/tag: "0.2.0"/' \
  /opt/genestack/base-helm-configs/substation-mcp/substation-mcp-helm-overrides.yaml
./deploy/genestack/install-substation-mcp.sh
```

`helm upgrade` performs a rolling update (maxSurge=1, maxUnavailable=0).

## Uninstalling

```sh
helm uninstall substation-mcp --namespace openstack
# Remove the version entry from /etc/genestack/helm-chart-versions.yaml
# (optional, if you want to keep the cluster clean).
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | Registry unreachable or wrong tag | Check `image.repository`/`tag`, verify the image exists, check `imagePullSecrets`. |
| Pod `CrashLoopBackOff` | Bad config | `kubectl -n openstack logs <pod>` — check the `config.yaml` rendered into the ConfigMap. |
| `401` on every request | Token expired or wrong | Re-mint the Keystone token; the server validates per-request. |
| No SSE streaming | Gateway buffering responses | Verify the Gateway's buffering is disabled for `/v1` + `/mcp` (see Step 5). |
| `403 insufficient_scope` on write tools | Token lacks `openstack:write` | Use a token with the write scope, or set `config.policy.read_only: false`. |

## Related

- Root repo `README.md` → "Production deployment (Genestack)" (quick path).
- `deploy/Dockerfile` — the container image build.
- `deploy/register-catalog.sh` — Keystone catalog registration.
- `scripts/conformance.sh` — HTTP handshake verification.
