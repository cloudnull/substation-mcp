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
- **An operator admin credential** (an application credential *or* a
  user/password with the `admin` role) to bootstrap the deployment's standing
  identity. This is the one **required, user-definable** input: the chart's
  provisioner Job uses it (only to mint a short-lived admin token) to create
  the `substation` service user + application credential in the OpenStack
  `service` domain and to register the `mcp` catalog entry. It is never stored
  in any Secret. See Step 4.

## Files

| Path | Purpose |
|------|---------|
| `helm/substation-mcp/` | The Helm chart (Deployment, Service, config ConfigMap, clouds Secret, ServiceAccount, optional Gateway+HTTPRoute, and — when `serviceUser.enabled` — the provisioner Job + RBAC that auto-creates the service user + app-cred + `mcp` catalog entry). |
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

## Step 1 — Get the image

The project maintains a pre-built `linux/amd64` image on GHCR — **you do not
need to build it yourself** unless you are making changes:

> **Managed image:**
> https://github.com/cloudnull/substation-mcp/pkgs/container/substation-mcp
>
> Repository: `ghcr.io/cloudnull/substation-mcp`

Available tags:

| Tag | Meaning |
|-----|---------|
| `0.1.0` (and future semver) | Coordinated release — matches the chart `version`. Recommended for production. |
| `latest` | Newest build from `main` (updated on every push). |
| `main` | Same as `latest` (branch ref). |
| `sha-<commit>` | Exact commit digest — pin to a known-good build. |

So in the override you can write any of:

```yaml
image:
  repository: ghcr.io/cloudnull/substation-mcp
  tag: "0.1.0"        # coordinated release
  # tag: "latest"      # or the newest build
  # tag: "sha-5755e66" # or a pinned commit
  pullPolicy: IfNotPresent
```

### Build your own (optional)

If you are developing the server, build from the repo root (amd64) and push to
your own registry:

```sh
# From the repo root:
docker build --platform linux/amd64 -f deploy/Dockerfile \
  -t registry.example.com/openstack/substation-mcp:0.1.0 .
docker push registry.example.com/openstack/substation-mcp:0.1.0
```

Then point `image.repository` / `image.tag` at your registry in the override.

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
- **`config.server.public_url`** — the FQDN that will be exposed (must match
  `gateway.fqdn`).
- **`config.auth.keystone_url`** — your Keystone URL (drives `readyz`).
- **`config.server.metrics_token`** — set a strong token to gate `/metrics`.
- **`config.clouds.default`** — your cloud name.
- **`clouds.<name>.auth`** — your OpenStack auth details (Keystone URL,
  region, etc.).
- **`gateway.enabled` / `gateway.fqdn` / `gateway.gatewayClassName`** —
  external exposure via Gateway API (Envoy or Poundcake).
- **`serviceUser`** — **required.** See below.

### The `serviceUser` block (required deployment input)

This provisions the deployment's standing identity — a service user in the
OpenStack `service` domain (mirroring `nova_service_user`) with an application
credential — and registers the `mcp` catalog entry (public/internal/admin
endpoints). A Helm **post-install/post-upgrade** Job runs this automatically;
the provisioned app-cred is written to the `<release>-service-identity`
Secret, and an initContainer injects it into `clouds.yaml` before the server
starts. The Job is idempotent (re-runs reuse the existing user/app-cred).

You MUST set `serviceUser.enabled: true` and provide the operator's admin
credential via `serviceUser.auth`. There are **two ways** to supply it:

### Option 1 — k8s Secret (recommended)

Store the operator credential in a k8s Secret and reference it by name. The
provisioner Job's env is populated via `secretKeyRef`, so the credential never
appears in the override file or anywhere on the controller's filesystem:

```yaml
serviceUser:
  enabled: true
  username: substation            # service-domain user to create/reuse
  domain: service                 # OpenStack domain
  appCredName: substation-cred    # name of the application credential
  roles: [admin]                  # roles to grant on the domain
  region: SAT0                    # region the mcp catalog endpoints go in
  catalog:                        # public/internal/admin endpoint URLs
    publicURL: "https://substation.api.sat0.cloudnull.dev"
    internalURL: "https://substation.api.sat0.cloudnull.dev"   # defaults to publicURL
    adminURL: "https://substation.api.sat0.cloudnull.dev"      # defaults to publicURL
  auth:
    # Point at a k8s Secret in the release namespace that carries the
    # operator credential. The plaintext fields below are IGNORED.
    secretName: substation-admin
```

Create the Secret (choose **password** or **app-cred** keys):

```sh
# Password auth:
kubectl -n openstack create secret generic substation-admin \
  --from-literal=username=admin \
  --from-literal=password='<admin-password>' \
  --from-literal=domain=default \
  --from-literal=project=admin

# — or — application-credential auth:
kubectl -n openstack create secret generic substation-admin \
  --from-literal=app_cred_id='<operator-app-cred-id>' \
  --from-literal=app_cred_secret='<operator-app-cred-secret>'
```

The provisioner reads these keys via `secretKeyRef` (all `optional: true`, so a
Secret that only carries the password keys still works).

### Option 2 — plaintext in the override (simpler, less secure)

Type the credential directly in the override. Convenient for quick local
deploys, but the value lands in the file — keep it to a tight ACL (`chmod 600`).

```yaml
serviceUser:
  # ... (same as above, minus auth.secretName)
  auth:
    # Option A — application credential:
    appCred:
      id: "<operator app-cred id>"
      secret: "<operator app-cred secret>"
    # Option B — user password (mutually exclusive with appCred):
    # password:
    #   username: "admin"
    #   password: "<admin password>"
    #   domain: "default"
    #   project: "admin"
```

> **Security:** in **both** options the operator credential is used solely to
> mint a short-lived admin token and is **never written to any k8s Secret** by
> the chart. Only the *provisioned* app-cred (the `substation` service user's
> own credential) is persisted — to the `<release>-service-identity` Secret —
> and that is what the server uses. Option 1 (Secret) is preferred because the
> operator credential never touches the filesystem.

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

## Step 6 — Service user + catalog registration (automatic)

When `serviceUser.enabled: true` (Step 3), the Helm chart's provisioner Job
(a `post-install`/`post-upgrade` hook) runs automatically on every install and
upgrade:

1. **Provisions** the `substation` service user in the `service` domain + its
   application credential (idempotent — reuses on re-run).
2. **Writes** the app-cred to the `<release>-service-identity` Secret.
3. **Registers** the `substation-mcp` catalog service (type `mcp`) + its
   public/internal/admin endpoints at the `serviceUser.catalog.*` URLs
   (idempotent — reuses existing entries).
4. **Rolls** the Deployment (the initContainer picks up the app-cred from the
   identity Secret into `clouds.yaml`).

Verify it ran:

```sh
# The provisioner Job completed:
kubectl -n openstack get jobs | grep substation-mcp-provision
# The identity Secret exists (the app-cred is in here — DO NOT print it):
kubectl -n openstack get secret substation-mcp-service-identity
# The pod is Ready (initContainer succeeded → server has the app-cred):
kubectl -n openstack get pods -l app.kubernetes.io/name=substation-mcp
# The catalog entry exists (as an OpenStack admin):
openstack service list | grep -i substation
openstack endpoint list --service substation-mcp
```

### Manual fallback (openstack CLI)

If you'd rather manage the identity yourself (e.g. pre-create the service user
and app-cred out-of-band, or if the provisioner Job is not available), set
`serviceUser.enabled: false` and create the service user + application
credential manually using the `openstack` CLI. You need an admin credential
(project-scoped to the `admin` project in the `default` domain).

> **References:**
> [Keystone service management](https://docs.openstack.org/keystone/latest/admin/manage-services.html),
> [Identity API v3](https://docs.openstack.org/api-ref/identity/v3/),
> [keystoneauth plugin options](https://docs.openstack.org/keystoneauth/latest/plugin-options.html).

#### 1. Create the service user in the `service` domain

```sh
# Authenticate as admin (project-scoped to admin/default):
export OS_AUTH_URL=https://keystone.api.sat0.cloudnull.dev/v3
export OS_USERNAME=admin
export OS_PASSWORD=<admin-password>
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_DOMAIN_NAME=default
export OS_REGION_NAME=SAT0

# Create the service user (idempotent — skip if it already exists):
openstack user show substation --domain service 2>/dev/null || \
  openstack user create --domain service --enable substation

# Grant the admin role on the service domain (the user needs admin to
# access all services via its app-cred):
openstack role add --domain service --user substation admin
```

#### 2. Create the application credential (as the service user)

Mint a domain-scoped token as the `substation` user, then create the app-cred
owned by that user. The app-cred secret is returned ONLY ONCE — save it:

```sh
# Mint a domain-scoped token as the substation user:
export OS_USERNAME=substation
export OS_USER_DOMAIN_NAME=service
export OS_PROJECT_NAME=          # clear project (domain-scoped, not project-scoped)
unset OS_AUTH_URL                # reuse the auth URL from above

OS_TOKEN=$(openstack token issue --domain service -f value -c id)

# Create the application credential (owned by the substation user):
# The secret is printed once — capture it:
APPCRED_ID=$(openstack application credential create substation-cred \
  --domain service \
  --project-admin \
  -f value -c id)
# The secret was printed to stdout during create; re-create to capture both:
openstack application credential create substation-cred \
  --domain service \
  --project-admin \
  -f value -c id > /tmp/appcred_id.txt
# (The secret is in the create output — see `openstack application credential create --help`)

# Alternatively, use the raw API to capture the secret:
curl -s -X POST \
  -H "X-Auth-Token: $OS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"application_credential": {"name": "substation-cred", "project_scoped": false, "service_scoped": false, "unscoped": false, "service_roles": ["admin"], "domain_scoped": true, "unrestricted_roles": false}}' \
  "$OS_AUTH_URL/users/<substation-user-id>/application_credentials" | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['application_credential']; print(d['id']); print(d.get('secret',''))"
```

> **Note:** The `openstack application credential create` CLI does not always
> print the secret in a machine-readable way. For automation, the raw API
> (`POST /v3/users/{user_id}/application_credentials`) returns the `secret`
> field in the response body. Capture it and store it in the
> `<release>-service-identity` Secret:
>
> ```sh
> kubectl -n openstack create secret generic substation-mcp-service-identity \
>   --from-literal=app_cred_id=<APPCRED_ID> \
>   --from-literal=app_cred_secret=<APPCRED_SECRET> \
>   --from-literal=app_cred_name=substation-cred \
>   --from-literal=domain=service \
>   --from-literal=user_id=<substation-user-id> \
>   --from-literal=username=substation \
>   --dry-run=client -o yaml | kubectl apply -f -
> ```

#### 3. Register the `mcp` catalog entry

```sh
export OS_USERNAME=admin
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=default
unset OS_AUTH_TOKEN   # re-mint as admin

export PUBLIC_URL=https://substation.api.sat0.cloudnull.dev
./deploy/register-catalog.sh
```

Or manually (service **name** `substation-mcp`, **type** `mcp`):

```sh
openstack service create --type mcp substation-mcp \
  "Model Context Protocol endpoint for the OpenStack cloud" 2>/dev/null || true
openstack endpoint create --region SAT0 --service substation-mcp public   "$PUBLIC_URL"
openstack endpoint create --region SAT0 --service substation-mcp internal "$PUBLIC_URL"
openstack endpoint create --region SAT0 --service substation-mcp admin    "$PUBLIC_URL"
```

> The service is identified by its **type** (`mcp`); the **name**
> (`substation-mcp`) is a human-readable label. The `register-catalog`
> subcommand looks up the service by type, so an existing entry (even a legacy
> one named `mcp`) is reused rather than duplicated.

#### 4. Configure the chart to use the pre-created identity

Set `serviceUser.enabled: false` and `serviceUser.output.id/secret` to the
app-cred you created manually:

```yaml
serviceUser:
  enabled: false
  output:
    id: "<APPCRED_ID>"
    secret: "<APPCRED_SECRET>"
```

This skips the provisioner Job and uses your pre-created app-cred directly
in the `clouds.yaml` rendered by the chart.

This is idempotent — re-running the catalog registration reuses the existing
`mcp` service.

## Step 7 — Connect an MCP client

Mint a Keystone token (or use the `/v1/login` page in a browser), then point
your MCP client at the **public URL** (the `serviceUser.catalog.publicURL` you
configured, e.g. `https://substation.api.sat0.cloudnull.dev/v1`):

```sh
# Replace <public-url> with serviceUser.catalog.publicURL and <keystone-token>
# with a minted token (app-cred or password).
claude mcp add --transport http openstack \
  "<public-url>" \
  --header "Authorization: Bearer <keystone-token>"
```

The login page (in a browser, e.g. `https://<fqdn>/v1/login`) mints a token
for you — pick **Application credential** or **User + password** and submit.

## Step 8 — Verify

The values below are rendered by the chart into `NOTES.txt` on install (the
`OS_CLOUD` / `REGION` / `PUBLIC_URL` come from `config.clouds.default`,
`serviceUser.region`, and `serviceUser.catalog.publicURL` respectively):

```sh
# 1. The deployment is running:
kubectl -n openstack get deploy substation-mcp
kubectl -n openstack get pods -l app.kubernetes.io/name=substation-mcp

# 2. The catalog entry (as an OpenStack admin):
openstack service list | grep -i substation
openstack endpoint list --service substation-mcp

# 3. Validate the credential + scopes:
OS_AUTH_TOKEN=<token> ./.build/release/substation-mcp check --cloud <cloud>

# 4. Run the conformance handshake against the live URL:
scripts/conformance.sh \
  --url "<public-url>" \
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
