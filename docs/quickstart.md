[← Documentation home](index.md)
# Quickstart

Get from a clean clone to a connected MCP client. All Swift work runs inside the
pinned Linux container image (`swift:6.4-rhel-ubi10`) via the `scripts/swift`
wrapper, which resolves your container runtime (docker, podman, or Apple
`container`) for you. **Never build natively on macOS.**

The `Makefile` is the single entry point for the whole **local** loop — build, test,
release, and the running dev container (image + lifecycle). Prefer it over calling
the scripts directly; it wraps them and resolves your container runtime. Production
deployment (Genestack / systemd) is intentionally *not* in the Makefile. See
[§ 0. The Makefile](#0-the-makefile-local-loop).

## 0. The Makefile (local loop)

Every local workflow is a `make` target. Build and test run through
`scripts/swift`, which picks your container runtime automatically; the container
lifecycle targets dispatch to whichever of **docker**, **podman**, or Apple
**container** you have installed (override with `RT=docker|podman|container`).

| Goal | Command |
|------|---------|
| Debug build (fast iteration) | `make build` |
| Release binary (static → dynamic fallback) | `make release` |
| Run the unit + service suites | `make test` |
| Print / capture warnings | `make lint` · `make warnings` |
| MCP handshake smoke test vs a running server | `make conformance ARGS="--url http://127.0.0.1:8080/v1 --token <id>"` |
| Native UBI10 rootfs tarball (docker-less host) | `make package` |

**Local dev container** — build and run, publishing :8080:

```sh
# Default: self-contained multi-stage deploy/Dockerfile (builds the binary in-image)
make container-build    # docker/podman/Apple-container image from deploy/Dockerfile
make container-run      # foreground; Ctrl-C stops it (CONTAINER/HOST_PORT/CONT_PORT overridable)

# in another shell:
make container-logs     # tail its logs
make container-exec CMD="ps aux"
make container-stop && make container-rm   # stop, then delete
```

The default image binds `0.0.0.0:8080` with no baked config — mount your
`clouds.yaml` / `config.yaml` at runtime (see [Deploying](deploying.md#docker)).
For a fully self-contained Rackspace IAD3 image (binary + config baked in), use
the local dev Dockerfile, which needs a fresh release build + `dist/local/`:

```sh
make release
make container-build DOCKERFILE=deploy/Dockerfile.local IMAGE_TAG=local-dev


All variables are overridable on the command line (`IMAGE_NAME`, `IMAGE_TAG`,
`DOCKERFILE`, `CONTAINER`, `HOST_PORT`, `CONT_PORT`, `TAG`, plus `SWIFT=` and
`RT=`). `make help` lists everything.

## 1. Build

```sh
scripts/build.sh            # swift build -c release → ./.build/release/substation-mcp
```

> The static build is attempted first (spec §13 wants a self-contained binary).
> As of Swift 6.4 on UBI10 the toolchain's static Foundation archives reference
> ICU symbols not in the static link path, so it falls back to a dynamically-
> linked release binary that runs on any UBI10/RHEL 10 system with the Swift
> runtime. See [Deploying — Native aarch64](deploying.md#native-aarch64-no-docker)
> for the docker-less host path.

Sanity-check the container toolchain first if unsure:

```sh
scripts/swift --version
```

## 2. Validate your credential

```sh
# Using an existing token:
OS_AUTH_TOKEN=<token-id> ./.build/release/substation-mcp check --cloud mycloud

# Or let it mint a token from the cloud's application credential:
./.build/release/substation-mcp check --cloud mycloud
```

Expected output: project name, derived scopes (`[openstack:read openstack:write]`),
regions, negotiated microversions, Neutron extensions, and any access-rule gaps.

## 3. Register the MCP service in Keystone (operator, once per cloud/region)

The server's endpoints must appear in the Keystone catalog so clients can
discover them. Run once as an operator with an identity-admin credential:

```sh
export OS_CLOUD=mycloud REGION=RegionOne PUBLIC_URL=https://mcp.example.com
export OS_AUTH_TOKEN=<admin-token>   # or OS_APPLICATION_CREDENTIAL_ID+SECRET
deploy/register-catalog.sh
```

This is **idempotent** — re-running reuses the existing `type=mcp` service and
endpoints. For Kubernetes/Genestack clouds this step is part of the deploy flow;
see [Deploying](deploying.md#genestack-kubernetes--openstack).

## 4. Run the server

```sh
./substation-mcp serve \
  --config /etc/substation-mcp/config.yaml \
  --host 127.0.0.1 --port 8080 \
  --public-url https://mcp.example.com
```

Or via Docker:

```sh
docker build --platform linux/amd64 -f deploy/Dockerfile -t substation-mcp:local .
docker run --rm -p 8080:8080 \
  -v /path/to/clouds.yaml:/etc/openstack/clouds.yaml:ro \
  -v /path/to/config.yaml:/etc/substation-mcp/config.yaml:ro \
  substation-mcp:local
```

## 5. Connect an MCP client

### Claude (HTTP)

```sh
claude mcp add --transport http openstack \
  https://mcp.example.com/v1 \
  --header "Authorization: Bearer <keystone-token>"
```

### Claude Desktop (stdio)

```json
{
  "mcpServers": {
    "openstack": {
      "command": "/usr/bin/substation-mcp",
      "args": ["stdio", "--cloud", "mycloud"],
      "env": { "OS_AUTH_TOKEN": "<keystone-token>" }
    }
  }
}
```

### OpenCode

OpenCode connects over Streamable HTTP. Because substation-mcp is its own
stateless OAuth 2.1 AS by default, a client that speaks RFC 9728 discovery can
just point at the URL and complete the browser login flow ([OAuth 2.1 login](oauth.md)).
For the quick path — or for clients without OAuth discovery — use the P1 bearer
header with a pre-minted token (`oauth: false`):

```jsonc
// opencode.jsonc  (project root, or ~/.config/opencode/opencode.jsonc for global)
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "openstack": {
        "type": "remote",
        "url": "https://mcp.example.com/v1",
        "oauth": false,
        "headers": { "Authorization": "Bearer {env:OS_AUTH_TOKEN}" }
      }
    }
  }
}
```

Then verify:

```sh
export OS_AUTH_TOKEN=<keystone-token>
opencode mcp list          # expect: ✓ openstack  connected
/mcps                      # in-session: view / connect / authenticate
```

Notes: OpenCode names exposed tools `openstack_<tool>` (e.g.
`openstack_os_list`). Set `"codemode": false` to put tools on OpenCode's native
tool list instead of Code Mode.

## Three ways to get a token

| Path | How | When |
|------|-----|------|
| **OAuth 2.1 flow (default, P3)** | Client follows the 401 challenge → PRM → substation-mcp's stateless OAuth AS → browser consent → presents the resulting `stst.at.` JWT | No pre-minted credential needed |
| **Client-side mint (P1)** | Client mints a Keystone token and presents it as a Bearer header; on `401` it re-mints and retries. Tokens cached at `~/.config/openstack/mcp-tokens/<cloud>.token` (`0600`) | Simplest to reason about |
| **URL-mode elicitation** | Client visits `/<endpoint>/login`, enters credentials (+ optional region), server mints a token; the completion page shows the bearer to use — on multi-region clouds it is shown as `region:<REGION>:<token>` so validation and API calls target the selected region | Interactive browser flow |

Full details, including multi-replica replay-store configuration, are in
[OAuth 2.1 login](oauth.md).

## Related

- [Tools reference](tools.md) — what each tool does after you're connected.
- [Deploying](deploying.md) — how to run it in production (Docker, systemd, K8s).

