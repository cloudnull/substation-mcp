# openstack-mcp

A Hummingbird-hosted Swift MCP (Model Context Protocol) server that lets an LLM
client consume an OpenStack cloud — identity (Keystone), compute (Nova),
network (Neutron), block storage (Cinder), and image (Glance) — through a small
set of catalog-driven tools.

Identity is **token-per-request**: every HTTP request carries a Keystone token
(`Authorization: Bearer <token>`). The server validates it and uses only that
token upstream, so it is multi-tenant, holds no user credentials, and enforces
project isolation by construction.

## Tools

Phase 1 exposes 15 tools (9 read-only + 6 write):

| Tool | Read | Description |
|------|:----:|-------------|
| `os_list` | ✓ | List a resource type (server, network, volume, image, …) with filters, limit, marker |
| `os_get` | ✓ | Get one resource by ID or name (project-scoped) |
| `os_describe` | ✓ | Get + resolved name + attached resources (volumes, ports, SGs) |
| `os_topology` | ✓ | Graph of connected resources from an anchor (depth 1–3, optional diagnosis) |
| `os_find` | ✓ | Search across resource types by name/ID |
| `os_whoami` | ✓ | Token identity: project, domain, roles, scopes, regions |
| `os_quota` | ✓ | Quota usage for a resource type |
| `os_clouds` | ✓ | Cloud catalog: regions, services, endpoints |
| `os_wait` | ✓ | Poll a resource until it reaches a target state (with progress) |
| `os_create` | | Create a resource (schema-validated) |
| `os_update` | | Update a resource |
| `os_delete` | | Delete a resource |
| `os_action` | | Run a server action (start, stop, reboot, resize, …) |
| `os_attach` | | Attach a resource (volume, interface, SG, floating IP, …) |
| `os_detach` | | Detach a resource |

Read-only mode (`--read-only` / `policy.read_only: true`) restricts the server
to the 9 read tools. Write tools are additionally gated by the token's derived
scopes: a token without the `openstack:write` scope gets `403 insufficient_scope`
on mutating calls.

## Architecture

```
MCP Client (Claude, etc.)
  │  Authorization: Bearer <keystone-token>
  ▼
openstack-mcp serve
  ├── MCPRoute (HummingbirdMCP adapter)
  │     ├── Token-per-request validation (GET /v3/auth/tokens, cached)
  │     ├── Scope gate (read-only / write)
  │     ├── Per-token MCP.Server (SessionRegistry)
  │     └── SSE / Streamable-HTTP transport
  ├── /healthz, /readyz
  ├── /.well-known/oauth-protected-resource (PRM, RFC 9728)
  ├── /v1/login (URL-mode token elicitation)
  └── /metrics (Prometheus, optional bearer gate)
  │
  ▼
OpenStackClient (stateless per-identity actor)
  ├── Transport (async-http-client, retry, request-id)
  ├── Cache (TTL + per-token invalidation)
  ├── KeystoneService (token decode, catalog, scopes)
  ├── ComputeService (Nova)
  ├── NetworkService (Neutron)
  ├── BlockStorageService (Cinder)
  └── ImageService (Glance)
```

## Build & test

All Swift work runs inside the pinned Linux container image
(`swift:6.4-rhel-ubi10`) via the `scripts/swift` wrapper, which resolves your
container runtime (docker, podman, or Apple `container`) for you. Never build
natively on macOS.

```sh
scripts/swift --version   # verify the container toolchain
scripts/swift build       # debug build
scripts/swift test        # run the test suite (364 tests; integration target self-skips without OSMCP_IT_CLOUD)
```

Release build:

```sh
scripts/build.sh          # swift build -c release (attempts --static-swift-stdlib first)
# → ./.build/release/openstack-mcp
```

> **Note:** the static build is attempted first (spec §13 wants a
> self-contained binary). As of Swift 6.4 on UBI10, the toolchain's static
> Foundation archives reference ICU symbols that are not in the static link
> path, so the build falls back to a dynamically-linked release binary. This
> binary runs on any UBI10/RHEL 10 system with the Swift runtime.

## Quickstart

### 1. Build

```sh
scripts/build.sh
```

### 2. Validate your credential

```sh
# Using an existing token:
OS_AUTH_TOKEN=<token-id> ./.build/release/openstack-mcp check --cloud mycloud

# Or let it mint a token from the cloud's application credential:
./.build/release/openstack-mcp check --cloud mycloud
```

Expected output: project name, derived scopes (`[openstack:read openstack:write]`),
regions, negotiated microversions, Neutron extensions, and any access-rule gaps.

### 3. Register the MCP service in Keystone

The server's endpoints must appear in the Keystone catalog so clients can
discover them. Run once per cloud/region as an operator with an identity-admin
credential:

```sh
# Using the wrapper script:
export OS_CLOUD=mycloud REGION=RegionOne PUBLIC_URL=https://mcp.example.com
export OS_AUTH_TOKEN=<admin-token>   # or OS_APPLICATION_CREDENTIAL_ID+SECRET
deploy/register-catalog.sh

# Or directly:
./.build/release/openstack-mcp register-catalog \
  --cloud mycloud --region RegionOne \
  --public-url https://mcp.example.com \
  --admin-token <admin-token>
```

This is **idempotent** — re-running it reuses the existing `type=mcp` service
and endpoints.

### 4. Run the server

```sh
./openstack-mcp serve \
  --config /etc/openstack-mcp/config.yaml \
  --host 127.0.0.1 --port 8080 \
  --public-url https://mcp.example.com
```

Or via Docker:

```sh
docker build --platform linux/amd64 -f deploy/Dockerfile -t openstack-mcp:local .
docker run --rm -p 8080:8080 \
  -v /path/to/clouds.yaml:/etc/openstack/clouds.yaml:ro \
  -v /path/to/config.yaml:/etc/openstack-mcp/config.yaml:ro \
  openstack-mcp:local
```

### 5. Connect an MCP client

**Claude (HTTP):**

```sh
# Mint a token (or use the /v1/login page in a browser), then:
claude mcp add --transport http openstack \
  https://mcp.example.com/v1 \
  --header "Authorization: Bearer <keystone-token>"
```

**Claude Desktop (stdio):**

```json
{
  "mcpServers": {
    "openstack": {
      "command": "/usr/bin/openstack-mcp",
      "args": ["stdio", "--cloud", "mycloud"],
      "env": {
        "OS_AUTH_TOKEN": "<keystone-token>"
      }
    }
  }
}
```

**Token management:** the server supports two token-acquisition paths:
1. **Client-side mint** — the client mints a token via Keystone and presents it
   as a Bearer header. On `401`, the client re-mints and retries. Tokens are
   stored at `~/.config/openstack/mcp-tokens/<cloud>.token` (mode `0600`).
2. **URL-mode elicitation** — the client visits `/<endpoint>/login` in a
   browser, enters the application credential, and the server mints + stores
   the token in its `TokenStore`. The completion page displays the token ID.

### 6. Reverse proxy (TLS)

TLS terminates at the proxy; the server binds `127.0.0.1` (or `0.0.0.0`
inside a container) in plaintext. See `deploy/caddy/Caddyfile` and
`deploy/nginx/openstack-mcp.conf` for ready-to-use configs. The critical
setting: **disable response buffering** for the `/v1` and `/mcp` paths
(Caddy: `flush_interval -1`; nginx: `proxy_buffering off; proxy_cache off;`)
so SSE streams are not buffered.

## Configuration

Config is layered: **CLI flags > env vars > YAML file > defaults**.

Env vars use the `OSMCP_` prefix with `__` (double-underscore) as the section
separator. Example: `OSMCP_SERVER__PORT=9090` sets `server.port`.

| Key | Default | Description |
|-----|---------|-------------|
| `server.host` | `127.0.0.1` | Bind address |
| `server.port` | `8080` | Bind port |
| `server.endpoint` | `/v1` | MCP transport path (`/mcp` retained as alias) |
| `server.allowed_origins` | localhost | `Origin` allow-list; `*` disables the check |
| `server.max_body_bytes` | `1048576` | Request body limit (1 MiB) |
| `server.metrics_token` | unset | Bearer token required for `/metrics` when set |
| `server.public_url` | unset | Canonical public base URL (PRM, login page) |
| `auth.profile` | `keystone_token` | `keystone_token` (P1) or `oauth` (P2) |
| `auth.keystone_url` | from catalog | Keystone base URL in PRM `authorization_servers` |
| `auth.token_cache_ttl` | `60s` | Max age of cached validated-token entry |
| `auth.failed_auth_per_minute` | `10` | Per-source-IP auth-failure rate limit |
| `auth.login_page_enabled` | `true` | Serve the `/v1/login` page |
| `clouds.default` | first in `clouds.yaml` | Default cloud |
| `clouds.allowed` | all | Names a session may select |
| `clouds.file` | search order | Path to `clouds.yaml` |
| `session.idle_ttl` | `30m` | Idle session timeout |
| `session.max_lifetime` | `12h` | Maximum session lifetime |
| `session.max_sessions` | `500` | Concurrent session cap |
| `policy.read_only` | `false` | Restrict to read-only tools |
| `policy.deny_resources` | `[project, user, group, role, role_assignment, domain]` | Resources hidden from the catalog |
| `policy.max_list_limit` | `200` | Max `limit` for list operations |
| `client.request_timeout` | `60s` | Upstream request timeout |
| `cache.ttl.<resource>` | per resource | Cache TTL per resource type |
| `log.level` | `info` | Log level |
| `log.format` | `json` | `json` or `logfmt` |
| `log.audit` | `true` | Audit log for mutating tool calls |

### Example config file

```yaml
server:
  host: 127.0.0.1
  port: 8080
  public_url: https://mcp.example.com
  metrics_token: "change-me"

policy:
  read_only: false

log:
  level: info
  format: json
  audit: true
```

## Subcommands

| Command | Description |
|---------|-------------|
| `serve` | Run the HTTP (Streamable-HTTP) MCP server |
| `stdio` | Run the MCP server over stdio (single cloud, single token) |
| `healthz` | Print liveness JSON and exit 0 |
| `check` | Validate a token, print identity/scopes/regions/versions/extensions/access-rule gaps |
| `access-rules` | Emit the Keystone access-rule JSON for a mode/service/resource subset |
| `tools` | Dump the tool list (name, description, annotations, inputSchema) |
| `register-catalog` | Idempotently install the MCP service + endpoints in the Keystone catalog |

### `access-rules`

Generates the JSON that `openstack application credential create --access-rules`
accepts. Two modes:

- `--mode read-only` — GET-only rules for all 15 tool paths
- `--mode operator` — all methods (default)

```sh
openstack-mcp access-rules --mode read-only --services compute,network
# → {"rules": [{"match": "GET /servers", "service": "compute"}, ...]}
```

> **Note:** for these rules to be enforced by Keystone, each service must be
> registered with the correct `service_type` in keystonemiddleware.

### `tools`

```sh
openstack-mcp tools                  # human-readable table (15 tools)
openstack-mcp tools --read-only      # 9 read-only tools
openstack-mcp tools --json           # machine-readable JSON
```

## Security model

- **Bearer token = Keystone token.** The server validates every request's
  `Authorization: Bearer` header via `GET /v3/auth/tokens` (cached,
  `auth.token_cache_ttl`). It never accepts client-supplied `auth_url` or
  credentials.
- **Token-per-request.** There is no long-lived session token; the Keystone
  token *is* the identity. Expired token → `401` on the next request, even if
  the `Mcp-Session-Id` is still alive.
- **Project isolation.** Each token is project-scoped; the token-metadata cache
  holds one entry per distinct token ID. Two sessions with different project
  tokens interleaving requests never see each other's resources.
- **Scope gate.** Read-only tokens get `403 insufficient_scope` on mutating
  tool calls. The write-tool gate (`WriteToolGate`) names the specific tools
  that require write scope.
- **No held user credentials.** The server holds application-credential secrets
  only for the login page (URL-mode elicitation); they are zeroized after use.
- **Access rules.** Use `openstack-mcp access-rules` to generate the
  Keystone access-rule JSON for application credentials. Combine with
  `keystonemiddleware` for per-service path enforcement.
- **TLS off-host.** The server does not terminate TLS (phase 1); a reverse
  proxy (Caddy/nginx) handles it. In containers, the server binds `0.0.0.0`
  and the proxy binds the public interface.
- **Rate limiting.** Per-source-IP auth-failure limit (429 after
  `auth.failed_auth_per_minute` failures in 1 minute). Per-session tool-call
  rate limit (`policy.max_calls_per_minute`, default 120/min).
- **Redaction.** All log lines pass through a redaction layer that masks
  `Authorization`, `X-Auth-Token`, `X-Subject-Token`, `secret`, `password`,
  `adminPass`, `user_data`, `token`, `application_credential`, `appcredsecret`.
- **Audit.** One record per mutating tool call: time, token ID, project ID,
  tool, outcome, request ID, application credential ID.

## Observability

- **Logs:** JSON (default) or logfmt, to stdout in `serve`, stderr in `stdio`.
  Every line carries `session`, `cloud`, `region`, `tool`, `request_id`.
- **Metrics** (`/metrics`, Prometheus format, optional bearer gate):
  - `osmcp_tool_calls_total{tool,outcome}`
  - `osmcp_tool_duration_seconds{tool}`
  - `osmcp_openstack_requests_total{service,method,status}`
  - `osmcp_openstack_request_duration_seconds{service}`
  - `osmcp_sessions_active`
  - `osmcp_auth_failures_total{reason}`
  - `osmcp_cache_hits_total{resource}`
- **Audit log:** one `.info` record per mutating tool call (gated by
  `log.audit`).

## Deployment

### Docker

```sh
docker build --platform linux/amd64 -f deploy/Dockerfile -t openstack-mcp:local .
docker run --rm -p 8080:8080 \
  -v $(pwd)/clouds.yaml:/etc/openstack/clouds.yaml:ro \
  -v $(pwd)/config.yaml:/etc/openstack-mcp/config.yaml:ro \
  openstack-mcp:local
```

The container runs as non-root user `openstack-mcp` (uid 10001) on
`ubi10-minimal`. The builder stage is `swift:6.4-rhel-ubi10` (same as
`scripts/swift`).

> **Note:** the runtime is UBI10 (RHEL 10 compatible), not Rocky 9. UBI10 is
> the base of the Swift 6.4 toolchain image.

### systemd

```sh
sudo install -m 755 ./.build/release/openstack-mcp /usr/bin/openstack-mcp
sudo install -m 644 deploy/openstack-mcp.service /etc/systemd/system/
sudo mkdir -p /etc/openstack-mcp
sudo cp config.yaml /etc/openstack-mcp/
# Create /etc/openstack-mcp/env with OSMCP_* variables (optional)
sudo systemctl daemon-reload
sudo systemctl enable --now openstack-mcp
```

### Reverse proxy

See `deploy/caddy/Caddyfile` and `deploy/nginx/openstack-mcp.conf`. Both
disable response buffering for `/v1` and `/mcp` (required for SSE).

## Development

### Fake OpenStack

The repo includes an in-process fake cloud (`Sources/FakeOpenStack`) with
seeded data (3 projects, servers, networks, volumes, images, SGs, routers).
It is used by all tests and is also runnable as a standalone binary:

```sh
scripts/swift run openstack-mcp-fake   # starts on :8080 (adjust in source)
```

Seeded credentials:
- `fake-cred-admin` / `secret-admin` — proj-one, admin (read+write)
- `fake-cred-ro` / `secret-ro` — proj-one, read-only
- `fake-cred-two` / `secret-two` — proj-two, admin

### Integration test (opt-in)

Set `OSMCP_IT_CLOUD` to a cloud name in your `clouds.yaml` and run the
integration test target explicitly:

```sh
OSMCP_IT_CLOUD=mycloud scripts/swift test --filter IntegrationTests
```

Pass 1 is read-only (whoami, clouds, list, describe). Pass 2 (network-only
mutations: create/delete network+subnet+port) requires `OSMCP_IT_MUTATE=1`.

### Conformance (HTTP smoke)

`scripts/conformance.sh` drives the full MCP Streamable-HTTP handshake against a
**running** `openstack-mcp serve` using the binary itself as the HTTP client
(`openstack-mcp conformance`, a hidden subcommand — no curl, which is absent from
the ubi10-minimal runtime). It asserts, in order: 401 challenge on an
unauthenticated request, the PRM document shape (`resource` /
`authorization_servers` / `scopes_supported`), `initialize` → 200 +
`MCP-Session-Id`, `tools/list` (15 tools, or 9 with `--read-only`),
`tools/call os_whoami` (200, not an error), and `DELETE` (200).

```sh
# Start a server (against your cloud or a fake), then:
scripts/conformance.sh --url http://127.0.0.1:8080/v1 --token <minted-keystone-token>
# or let it mint a token itself:
scripts/conformance.sh --url http://127.0.0.1:8080/v1 \
    --auth-url http://127.0.0.1:9999/keystone/v3 \
    --app-cred-id <id> --app-cred-secret <secret>
# read-only (9-tool) surface:
scripts/conformance.sh --url ... --token ... --read-only
```

The same handshake is also covered in-process by `HummingbirdMCPTests`
(session init/list/call/DELETE/401/PRM), so CI exercises it without a live
server.

**MCP Inspector (manual).** For an interactive, human-driven conformance check,
point the [MCP Inspector](https://github.com/modelcontextprotocol/inspector) at
the running server and exercise the same surface manually:

```sh
npx @modelcontextprotocol/inspector \
  --transport http --url http://127.0.0.1:8080/v1 \
  --header "Authorization: Bearer <minted-keystone-token>"
```

In the Inspector UI: (1) confirm `initialize` completes and a session id is
issued; (2) open **Tools** and confirm the tool count (15 write / 9 read-only);
(3) call `os_whoami` and confirm it returns a project and roles with no error;
(4) call `os_list` for `server`/`network`/`volume`/`image` and confirm results;
(5) close the session (DELETE) and confirm the server returns 200.

### Repository layout

```
Sources/
  OpenStackClient/        # OpenStack API client (no MCP knowledge)
  OpenStackMCPServer/     # MCP server logic (catalog, tools, policy, sessions)
  HummingbirdMCP/         # Hummingbird ⇄ MCP SDK transport adapter (OpenStack-free)
  openstack-mcp/          # executable: serve, stdio, healthz, check, access-rules, tools, register-catalog
  openstack-mcp-fake/     # executable: standalone fake cloud
  FakeOpenStack/          # in-process fake cloud (test support)
Tests/
  OpenStackClientTests/
  OpenStackMCPServerTests/
  HummingbirdMCPTests/     # adapter: auth, sessions, transport, soak, hardening sweep
  OpenStackMCPTests/       # config, redaction, audit, access-rules, register-catalog, subcommands, check
IntegrationTests/          # opt-in, real-cloud (OSMCP_IT_CLOUD); self-skips in CI
deploy/
  Dockerfile
  openstack-mcp.service
  register-catalog.sh
  caddy/Caddyfile
  nginx/openstack-mcp.conf
specs/
  openstack-mcp-spec.md   # the specification
docs/
  superpowers/plans/      # implementation plans
scripts/
  swift                   # container wrapper (docker/podman/Apple container)
  build.sh                # release build
```
