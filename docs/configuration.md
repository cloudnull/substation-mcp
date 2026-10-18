[← Documentation home](index.md)
# Configuration

Config is layered: **CLI flags > env vars > YAML file > defaults.**

Env vars use the `OSMCP_` prefix with `__` (double-underscore) as the section
separator. Example: `OSMCP_SERVER__PORT=9090` sets `server.port`.

## Keys

| Key | Default | Description |
|-----|---------|-------------|
| `server.host` | `127.0.0.1` | Bind address |
| `server.port` | `8080` | Bind port |
| `server.endpoint` | `/v1` | MCP transport path (`/mcp` retained as alias) |
| `server.allowed_origins` | localhost | `Origin` allow-list; `*` disables the check |
| `server.max_body_bytes` | `1048576` | Request body limit (1 MiB) |
| `server.metrics_token` | unset | Legacy alias for `/metrics` bearer gate (kept for compatibility) |
| `server.ops_token` | unset | Shared secret for **internal ops** routes. When set, `/metrics` requires `Authorization: Bearer <ops_token>` (401 otherwise). Canonical knob — takes precedence over `server.metrics_token`. Set it to keep `/metrics` reachable only by authorized scrapers/operators. `/healthz` & `/readyz` stay open (K8s probes can't send auth headers; responses are intentionally coarse) |
| `server.public_url` | unset | Canonical public base URL (PRM, login page, OAuth issuer) |
| `auth.profile` | `oauth` | `oauth` (P3, default — stateless OAuth 2.1 AS in front of Keystone) or `keystone_token` (P1, raw Keystone bearer) |
| `auth.keystone_url` | from catalog | Keystone base URL in PRM `authorization_servers` |
| `oauth.server_secret` | derived (dev) | HS256 AS signing secret; **set explicitly in production** (see [OAuth](oauth.md)) |
| `oauth.code_ttl` | `30s` | Authorization-code JWT lifetime |
| `oauth.token_ttl` | `3600s` | Max access-token lifetime (capped at Keystone token expiry) |
| `oauth.replay_store` | `local` | Code-replay store: `local` (single replica) or `memcached` (shared; endpoint from the token's Keystone catalog, service type `memcached`) |
| `oauth.replay_store_endpoint` | unset | Single `host:port` or comma-separated list (`h1:p,h2:p,…`) for multi-server pools. Multi-server lists are routed via **Rendezvous Hashing** (HRW): each key maps deterministically to exactly one server by FNV-1a64 score — adding/removing a node remaps only ~1/N of keys, same algorithm oslo.cache / pymemcache use. Malformed entries are skipped silently. When set, overrides Keystone catalog discovery |
| `oauth.replay_store_fail_open` | `true` | On a shared replay-store failure: fall back to the local store (`true`) or reject the code (`false`). Ignored unless `replay_store = memcached` |
| `oauth.dev_mint_enabled` | `false` | Mount the headless `POST <endpoint>/oauth/dev-mint` protocol-test endpoint. **Off by default; set `true` explicitly** to enable it (no build-config fallback) |
| `auth.token_cache_ttl` | `60s` | Max age of cached validated-token entry |
| `auth.failed_auth_per_minute` | `10` | Per-source-IP auth-failure rate limit |
| `auth.login_page_enabled` | `true` | Serve the `/v1/login` page |
| `auth.default_domain` | *(empty → `default`)* | Keystone domain pre-filled in the user-domain field on `/v1/login` and `/v1/oauth/authorize`. Set to your cloud's end-user domain (e.g. `rackspace_cloud_domain`) so password login works without typing it |
| `federation.enabled` | `false` | Mount the Keystone OS-FEDERATION passthrough surface (`GET <endpoint>/oauth/federate` + websso callback) and expose "Federated" methods on the login / authorize forms |
| `federation.idp` | *(empty)* | The OS-FEDERATION identity-provider name configured in Keystone; used in the IdP-specific WebSSO route. Required for the browser-bounce flow |
| `federation.protocol` | *(empty)* | Federation protocol under that IdP: `saml2`, `oidc`, or `kerberos` |
| `federation.paste_token` | `true` (when section present) | Add a "Federated token" paste field to the forms — for clouds whose federation SP is a portal, not Keystone (e.g. Rackspace Skyline), where the operator pastes an unscoped/scoped token from their portal session |
| `federation.origin_allowlist` | `[]` | Extra origins (host[:port]) the websso callback accepts beyond the server's own public URL. Never trust foreign origins by default — Keystone relays the unscoped token to `origin` verbatim |
| `clouds.file` | search order | Path to `clouds.yaml` |
| `session.idle_ttl` | `30m` | Idle session timeout |
| `session.max_lifetime` | `12h` | Maximum session lifetime |
| `session.max_sessions` | `500` | Concurrent session cap |
| `policy.read_only` | `false` | Restrict to read-only tools |
| `policy.deny_resources` | `[project, user, group, role, role_assignment, domain]` | Resources hidden from the catalog |
| `policy.max_list_limit` | `200` | Max `limit` for list operations |
| `policy.write_roles` | `[admin]` | Token roles that grant `openstack:write` scope (e.g. add `creator`, `member` for clouds whose writer role is not `admin`) |
| `client.request_timeout` | `60s` | Upstream request timeout |
| `cache.ttl.<resource>` | per resource | Cache TTL per resource type |
| `log.level` | `info` | Log level |
| `log.format` | `json` | `json` or `logfmt` |
| `log.audit` | `true` | Audit log for mutating tool calls |

## Example config file

```yaml
server:
  host: 127.0.0.1
  port: 8080
  public_url: https://mcp.example.com
  metrics_token: "change-me"

# Keystone OS-FEDERATION passthrough (see oauth.md "Keystone federation" for the full flow).
# Mount /oauth/federate + websso callback + "Federated token" form methods.
federation:
  enabled: false            # flip to true to mount the federation surface
  idp: ""                   # OS-FEDERATION identity provider name in Keystone (required for WebSSO)
  protocol: saml2           # saml2 | oidc | kerberos
  paste_token: true         # add "Federated token" paste field to login/authorize forms
  origin_allowlist: []      # extra origins the websso callback accepts (default: self only)

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

- `--mode read-only` — GET-only rules for all tool paths
- `--mode operator` — all methods (default)

```sh
substation-mcp access-rules --mode read-only --services compute,network
# → {"rules": [{"match": "GET /servers", "service": "compute"}, ...]}
```

> For these rules to be enforced by Keystone, each service must be registered
> with the correct `service_type` in keystonemiddleware.

### `tools`

```sh
substation-mcp tools                  # human-readable table (20 tools)
substation-mcp tools --read-only      # 14 read-only tools
substation-mcp tools --json           # machine-readable JSON
```

## Observability config & output

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

## Related

- [Security model](security.md) — how the auth/rate-limit/audit keys behave.
- [OAuth 2.1 login](oauth.md) — all `auth.*` and `oauth.*` key details.

