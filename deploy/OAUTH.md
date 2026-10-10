# OAuth 2.1 login (P3, default)

substation-mcp fronts its Keystone as a **stateless OAuth 2.1 authorization
server**. This is the default `auth.profile` since P3: a client with no
pre-minted credentials discovers the AS from the Protected Resource Metadata,
registers deterministically, runs the authorization-code + PKCE flow against a
browser consent page, and presents the resulting `stst.at.`-prefixed JWT on
subsequent MCP requests.

## What is stateless

- **Authorization code**: a short-lived HS256 JWT (default `oauth.code_ttl =
  120s`), bound to `(client_id, redirect_uri, code_challenge)`.
- **Access token**: `stst.at.` + an HS256 JWT wrapping the Keystone token id
  (`osk`), project, scopes, and an expiry capped at both `oauth.token_ttl`
  (default 3600s) and the Keystone token's own remaining lifetime.
- **Client registration**: deterministic DCR (RFC 7591). `client_id =
  "client_" + base64url(sha256(normalized registration))[:32]`; the derived
  `client_secret` is `HMAC-SHA256(server_secret, "substation-dcr-" + client_id)`.
  The same registration always yields the same credentials. No client store.
- **User tokens**: the server holds **no** persisted or in-memory OAuth codes,
  clients, or Keystone tokens. The only server-side state is the
  authorization-code replay store for single-use code enforcement (RFC 6749
  §4.1.2), keyed by the code's `jti` with a 300s TTL. It is instance-local
  in-memory by default (`oauth.replay_store: local`); with
  `oauth.replay_store: memcached` it is backed by memcached and shared across
  replicas.

### Multi-replica deployments (shared replay store)

With the default `local` replay store, a code redeemed on one replica is not
seen by another: run a **single replica** for strict single-use, or enable the
**shared store**:

```yaml
oauth:
  replay_store: memcached
  # optional — only needed when the cloud's catalog has no `memcached` service
  replay_store_endpoint: "memcached.openstack.svc.cluster.local:11211"
```

- **Endpoint discovery**: the memcached endpoint is resolved from each token's
  **Keystone service catalog** (service type `memcached`, interface preference
  public → internal → admin) — the same mechanism the server uses for Nova and
  every other upstream (spec §6.5). Register the cloud's memcached as a
  catalog service (one line, alongside `deploy/register-catalog.sh`):

  ```sh
  openstack service create --type memcached --name memcached "Memcached"
  openstack endpoint create --service memcached --region <R> \
      --interface internal http://memcached.openstack.svc.cluster.local:11211
  ```

  No credential is needed for the cache — the endpoint lives on the internal
  network. `oauth.replay_store_endpoint` (`host:port`) overrides the catalog
  for non-catalog deployments; when it is unset **and** the catalog has no
  `memcached` entry, the store degrades to instance-local enforcement.
- **Semantics**: a redeemed `jti` is recorded with memcached NO_OVERWRITE
  (`add`), so the *first* replica to redeem a code wins and a replay is
  rejected cluster-wide. Keys are namespaced `stst:<issuer-fingerprint>:<jti>`,
  so a memcached shared with other OpenStack services cannot collide.
- **Fail-open**: any discovery or cache error (endpoint unreachable, timeout,
  protocol error) degrades that one exchange to the local store with a
  warning log — a memcached outage never breaks the OAuth flow; it only
  narrows replay enforcement to the handling replica until the cache is
  reachable again.

## Endpoints

Under `<endpoint>` (default `/v1`):

| Endpoint | Purpose |
|---|---|
| `GET <issuer>/.well-known/oauth-authorization-server` | RFC 8414 AS metadata |
| `POST <endpoint>/oauth/register` | RFC 7591 DCR (deterministic) |
| `GET/POST <endpoint>/oauth/authorize` | Browser consent page; returns a code |
| `POST <endpoint>/oauth/token` | Authorization-code grant; PKCE S256 required |
| `POST <endpoint>/oauth/dev-mint` | **DEBUG builds only** — mint a code without the browser flow |

The issuer defaults to `<server.public_url><endpoint>/oauth`. Set
`server.public_url` for production so the issuer matches the externally
visible URL.

## Config

| Key | Env var | Default | Notes |
|---|---|---|---|
| `auth.profile` | `OSMCP_AUTH__PROFILE` | `oauth` | `oauth` (default) or `keystone_token` |
| `oauth.server_secret` | `OSMCP_OAUTH__SERVER_SECRET` | derived (dev) | **Required for production** |
| `oauth.code_ttl` | `OSMCP_OAUTH__CODE_TTL` | `120` | Seconds |
| `oauth.token_ttl` | `OSMCP_OAUTH__TOKEN_TTL` | `3600` | Seconds, capped at Keystone token expiry |
| `oauth.issuer` | `OSMCP_OAUTH__ISSUER` | `<public_url><endpoint>/oauth` | Override the RFC 8414 issuer |

### The derived dev secret

When `oauth.server_secret` is unset, the AS derives:

```
secret = "dev-" + sha256_hex("substation-oauth-dev" + issuer)
```

This is a **statelessness-friendly bootstrap** so the OAuth experience works
with zero config. It is **not** a production control: anyone who knows the
public URL can recompute the secret and forge tokens. Set
`oauth.server_secret` to a high-entropy random value (≥ 32 bytes) on any
deployment reachable by untrusted parties. Changing the derived secret (e.g.
by changing the public URL) invalidates previously issued `stst.at.` tokens.

## MCP client config

### Authless default (OAuth flow)

The client follows the Protected Resource Metadata challenge. No static
bearer token is required. For Cline / opencode / any MCP client implementing
RFC 9728 + RFC 8414 discovery, just point at the endpoint:

```json
{
  "mcpServers": {
    "openstack": {
      "url": "https://mcp.example.dev/v1"
    }
  }
}
```

### Bearer override (P1 compatibility)

Existing P1 clients keep working unchanged. Present a raw Keystone v3 bearer
token and the composite MCP gate delegates to the P1 `TokenValidator`
exactly as before:

```json
{
  "mcpServers": {
    "openstack": {
      "url": "https://mcp.example.dev/v1",
      "headers": {
        "Authorization": "Bearer <keystone-token-id>"
      }
    }
  }
}
```

## Production checklist

1. Set `server.public_url` to the externally visible base.
2. Set `oauth.server_secret` to a high-entropy random value (rotate by
   reissuing; previously minted `stst.at.` tokens will be invalidated).
3. Terminate TLS in front of the server (the OAuth flow redirects the user's
   browser).
4. Multi-replica: set `oauth.replay_store: memcached` (endpoint from the
   cloud's service catalog, or `oauth.replay_store_endpoint`) — see
   "Multi-replica deployments" above. Single replica: the default `local`
   store is sufficient.
5. The DEBUG-only `POST /v1/oauth/dev-mint` endpoint is **not** compiled into
   release builds.