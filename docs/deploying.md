[← Documentation home](index.md)
# Deploying

substation-mcp ships four deploy paths. Pick by environment:

| Path | When | Assets |
|------|------|--------|
| **Docker** | Non-Kubernetes host, amd64 (or QEMU for arm) | `deploy/Dockerfile` |
| **systemd** | Bare-metal UBI10/RHEL 10 host | `deploy/substation-mcp.service` |
| **Genestack** | Kubernetes-based OpenStack (recommended for production) | `deploy/genestack/` |
| **Native aarch64** | Docker-less Apple Silicon / arm64 UBI10 host | `scripts/build-image.sh` |

All paths run the same binary; they differ only in packaging and exposure. TLS
terminates at a reverse proxy on every path — the server itself is plaintext
and binds `127.0.0.1` (or `0.0.0.0` inside a container).

## Docker

```sh
docker build --platform linux/amd64 -f deploy/Dockerfile -t substation-mcp:local .
docker run --rm -p 8080:8080 \
  -v $(pwd)/clouds.yaml:/etc/openstack/clouds.yaml:ro \
  -v $(pwd)/config.yaml:/etc/substation-mcp/config.yaml:ro \
  substation-mcp:local
```

The container runs as non-root user `substation-mcp` (uid 10001) on genuine Red
Hat **UBI10 minimal** (`registry.access.redhat.com/ubi10-minimal`, freely
pullable with no login). The builder stage is `swift:6.4-rhel-ubi10`. The dynamic
release binary is bundled with the Swift runtime and its runtime libraries.

> The runtime uses **microdnf** (the `-minimal` image has no full dnf); EPEL is
> enabled by writing the repo file directly. The base already ships
> libcurl/libstdc++/libssl/libnghttp2/krb5/glibc, so only `libicu` +
> `glibc-langpack-en` are installed.

A pre-built managed image lives on GHCR: `ghcr.io/cloudnull/substation-mcp`
(tags `0.2.0`, `latest`, `sha-<commit>`). Use it instead of building when you
aren't changing the server.

## systemd

```sh
sudo install -m 755 ./.build/release/substation-mcp /usr/bin/substation-mcp
sudo install -m 644 deploy/substation-mcp.service /etc/systemd/system/
sudo mkdir -p /etc/substation-mcp
sudo cp config.yaml /etc/substation-mcp/
# Create /etc/substation-mcp/env with OSMCP_* variables (optional)
sudo systemctl daemon-reload
sudo systemctl enable --now substation-mcp
```

## Reverse proxy (required)

TLS terminates at the proxy; see `deploy/caddy/Caddyfile` and
`deploy/nginx/substation-mcp.conf` for ready-to-use configs. The one critical
setting: **disable response buffering** for the `/v1` and `/mcp` paths
(Caddy: `flush_interval -1`; nginx: `proxy_buffering off; proxy_cache off;`)
so SSE streams are not buffered.

## Genestack (Kubernetes / OpenStack)

For production deployment into a [Genestack](https://github.com/rackerlabs/genestack)
cluster (a Kubernetes-based OpenStack deployer), use the Helm chart + kustomize
add-on under `deploy/genestack/`. This is the recommended path for pseudo-
production and production clouds. It follows the standard Genestack add-on
pattern: a Helm chart, kustomize overlays, an `install-substation-mcp.sh` script,
and a `helm-chart-versions.yaml` entry.

**Quick path:**

```sh
# 1. Build + push the image (amd64):
docker build --platform linux/amd64 -f deploy/Dockerfile \
  -t <registry>/openstack/substation-mcp:<tag> .
docker push <registry>/openstack/substation-mcp:<tag>

# 2. Install the chart into the Genestack cluster (on the controller node):
./deploy/genestack/install-substation-mcp.sh \
  --set image.repository=<registry>/openstack/substation-mcp \
  --set image.tag=<tag>

# 3. Connect a client:
claude mcp add --transport http openstack \
  https://substation-mcp.<domain.tld>/v1 \
  --header "Authorization: Bearer <keystone-token>"
```

(The old manual `register-catalog.sh` step is now done automatically by the
provisioner Job when `serviceUser.enabled=true`; see the reference below.)

The chart includes an optional **provisioner Job** (`serviceUser.enabled`) that
auto-creates the deployment's standing service user + application credential in
the OpenStack `service` domain and registers the `mcp` catalog entry, using a
bootstrap operator admin credential (only to mint a short-lived admin token;
never stored in any Secret).

**The detailed, step-by-step reference lives in**
[`deploy/genestack/README.md`](../deploy/genestack/README.md) — prerequisites,
GHCR image tags, chart configuration, the full `serviceUser` block (both
k8s-Secret and plaintext auth), Gateway API exposure, verifying the provisioner
ran, a manual `openstack` CLI fallback for identity/catalog, upgrading, and
troubleshooting. This page only summarizes the shape; go there for the details.

> The Docker and systemd paths above are for non-Kubernetes hosts. Genestack is
> Kubernetes and consumes the container image, not the native UBI10 rootfs
> tarball or the systemd unit.

## Native aarch64 (no docker)

`deploy/Dockerfile` is the standard multi-stage UBI10 build for **amd64** via
`docker build`. On a host with **no docker** (only Apple `container`) but a need
for a native **aarch64** deliverable, use `scripts/build-image.sh`, which
packages a UBI10 **filesystem-image tarball** matching `Dockerfile` stage 2.

**What it produces:**

- A native aarch64 release binary (built in the `swift:6.4-rhel-ubi10` aarch64
  container, no QEMU).
- A UBI10 rootfs tarball at `dist/substation-mcp-aarch64-ubi10-<tag>.tar.gz`:
  - `/usr/local/bin/substation-mcp`
  - `substation-mcp` user/group (uid/gid 10001) in `/etc/passwd` + `/etc/group`
  - `/etc/openstack`, `/etc/substation-mcp`, `/var/log/substation-mcp` mount points
  - `/etc/ssl/certs` directory (ca-certificates must be present on the host)
- A `.manifest.json` recording tag, arch, binary sha256, size, entrypoint, cmd,
  exposed port, and the non-root user.

**Build:**

```sh
scripts/build-image.sh            # default tag v0.1.0
scripts/build-image.sh TAG=foo    # custom tag
```

The script builds the release binary if missing, then packages. Extract the
rootfs on an arm64 UBI10/RHEL10 host (or feed it as a layer payload) and the
binary runs directly.

```sh
sudo -u substation-mcp /usr/local/bin/substation-mcp serve \
  --config /etc/substation-mcp/config.yaml --cloud <name> \
  --host 0.0.0.0 --port 8080
```

> Apple `container` cannot nest (no runtime inside the container), and without a
> docker daemon `docker build` (which for amd64 on Apple Silicon uses QEMU) is
> unavailable. The filesystem-image tarball is the equivalent deliverable for the
> native aarch64 path. `deploy/substation-mcp.service` and the Caddy/nginx configs
> are identical for both arches — they reference the binary path, not the arch.

## Related

- [Configuration](configuration.md) — the config file each deploy target reads.
- [Quickstart](quickstart.md) — building + connecting before you deploy.

