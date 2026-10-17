[← Documentation home](index.md)
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
  # Single server:
  # replay_store_endpoint: "memcached.openstack.svc.cluster.local:11211"
  # Multi-server pool (comma-separated, routed via Rendezvous Hashing):
  # replay_store_endpoint: "10.0.0.1:11211,10.0.0.2:11211,10.0.0.3:11211"
  # optional — only needed when the cloud's catalog has no `memcached` service
  replay_store_endpoint: ""
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
  network. `oauth.replay_store_endpoint` overrides the catalog for non-catalog
  deployments; it accepts a single `host:port` or a comma-separated list for
  multi-server pools (see below). When it is unset **and** the catalog has no
  `memcached` entry, the store degrades to instance-local enforcement.
- **Multi-server routing (Rendezvous Hashing / HRW)**: when
  `replay_store_endpoint` lists two or more servers, each replay key is routed
  to exactly one server deterministically using the Highest Random Weight
  algorithm — the same scheme pymemcache's `HashClient` and oslo.cache use for
  their memcached pools. For every candidate node the score is
  `FNV-1a64("host:port" + "-" + key)`; the node with the highest score wins.
  Ties are broken lexicographically by node label so every replica agrees
  without shared state. Adding or removing a server remaps only ~1/N of keys
  (vs 100% with modulo hashing), which matters when a node is replaced during
  a rolling upgrade. The Keystone catalog always advertises at most one
  endpoint per service type, so multi-server routing applies only via the
  explicit override.
- **Semantics**: a redeemed `jti` is recorded with memcached NO_OVERWRITE
  (`add`), so the *first* replica to redeem a code wins and a replay is
  rejected cluster-wide. Keys are namespaced `stst:<issuer-fingerprint>:<jti>`,
  so a memcached shared with other OpenStack services cannot collide.
- **Fail-open**: any discovery or cache error (endpoint unreachable, timeout,
  protocol error) degrades that one exchange to the local store with a
  warning log — a memcached outage never breaks the OAuth flow; it only
  narrows replay enforcement to the handling replica until the cache is
  reachable again. Set `replay_store_fail_open: false` to reject the code
  instead, trading availability for a stricter single-use guarantee.

## Endpoints

Under `<endpoint>` (default `/v1`):

| Endpoint | Purpose |
|---|---|
| `GET <issuer>/.well-known/oauth-authorization-server` | RFC 8414 AS metadata |
| `POST <endpoint>/oauth/register` | RFC 7591 DCR (deterministic) |
| `GET/POST <endpoint>/oauth/authorize` | Browser consent page; returns a code |
| `POST <endpoint>/oauth/token` | Authorization-code grant; PKCE S256 required |
| `POST <endpoint>/oauth/dev-mint` | Headless mint (no browser flow). **Opt-in only** — mounted when `oauth.dev_mint_enabled: true` |
| `GET <endpoint>/oauth/federate` | WebSSO entry: 302 redirect to Keystone's OS-FEDERATION route. Mounted when `federation.enabled: true` |
| `GET/POST <endpoint>/oauth/federation/callback` | Keystone WebSSO callback (form_post). Receives the unscoped token, renders the project picker |
| `POST <endpoint>/oauth/federation/pick-project` | Project selection from the picker: exchanges the unscoped token for a scoped one, mints an authorization code, redirects to the client |
The issuer defaults to `<server.public_url><endpoint>/oauth`. Set
`server.public_url` for production so the issuer matches the externally
visible URL.

## Keystone federation (OS-FEDERATION passthrough)

substation-mcp can accept **Keystone OS-FEDERATION** tokens — the unscoped,
IdP-verified tokens that a cloud's identity provider mints during Web SSO.
This lets an end user whose cloud uses SAML/OIDC/Kerberos federation sign in
without ever typing a password into substation-mcp.

There are two routes; use whichever matches your cloud's topology.

### Route A — Browser bounce (WebSSO)

**Applies when:** the cloud's Keystone itself is the SAML/OIDC service
provider (i.e. `identity_providers/<idp>` is registered directly on Keystone)
AND Keystone will relay an unscoped token back to a third-party origin.

Flow:

```
browser ──GET /v1/oauth/federate?client_id=…&redirect_uri=http://localhost:PORT/…──► substation-mcp
          │  302 Location: <keystone>/v3/auth/OS-FEDERATION/identity_providers/<idp>/protocol/<proto>/websso?origin=…&relay_state=…
          ▼
    Keystone WebSSO route
          │  redirects browser to IdP (e.g. ADFS, Okta, Keycloak)
          ▼
    IdP login page (user authenticates here)
          │  form_post with unscoped_token + origin + relay_state
          ▼
browser ──POST /v1/oauth/federation/callback──────────────────────► substation-mcp
          │  verifies origin against allowlist
          │  verifies token via GET /v3/auth/tokens/<id> (must be a fed token from the configured IdP)
          │  lists accessible projects via GET /v3/auth/projects
          │  renders project-picker HTML page
          ▼
    user picks a project on the picker page
          │  POST /v1/oauth/federation/pick-project  {relay_state, project_id}
          ▼
substation-mcp exchanges unscoped→project-scoped (methods:["token"])
             mints an authorization code JWT
          │  302 redirect to client's loopback redirect_uri with ?code=…&state=…
          ▼
    MCP client completes the normal RFC 8414 code exchange at /oauth/token
```

Configuration:

| Key | Required for | Notes |
|---|---|---|
| `federation.enabled` | yes | Mounts all three federation routes + form methods |
| `federation.idp` | yes | The OS-FEDERATION identity-provider name as registered in Keystone |
| `federation.protocol` | no (defaults `saml2`) | `saml2`, `oidc`, or `kerberos` |
| `federation.origin_allowlist` | recommended | Extra origins beyond this server's own host that the callback accepts. Leave `[]` unless you run multiple replicas behind a load balancer with a different public hostname per replica. |

**Trust model.** The callback handler performs three independent checks before
rendering anything:

1. **Origin check** — if Keystone echoes `origin` in the form body, its host
   must match this server's issuer host (or appear in `origin_allowlist`).
   This rejects misconfigured multi-replica setups early. It is not the sole
   defense: an attacker who controls the IdP could set `origin`.
2. **Relay-state check** — the `relay_state` must resolve to a live entry in
   the single-use TTL store (default 300 s). An expired or already-consumed
   state returns an error page and forces a restart.
3. **Token verification** — the unscoped token ID is validated against
   Keystone (`GET /v3/auth/tokens/<id>`); the `OS-FEDERATION.identity_provider`
   field in the token body must equal `federation.idp`. Only then are the
   caller's accessible projects listed and rendered.

After the user selects a project, the unscoped token is exchanged for a
project-scoped one using `methods:["token"]` (no re-authentication), and the
resulting Keystone token ID is embedded in a standard authorization code JWT
— downstream it is indistinguishable from any other OAuth-minted token.

### Route B — Paste-token (portal fallback)

**Applies when:** the cloud's federation SP is a separate portal (not
Keystone) — e.g. Rackspace Skyline, where the Shibboleth SP entityID points
at `skyline.api.*` rather than Keystone. In this topology there is no WebSSO
bounce through Keystone, so the operator obtains an unscoped (or scoped)
token from their portal session and pastes it into the login/authorize form.

The "Federated token" option appears in the method `<select>` on both
`/v1/login` and `/v1/oauth/authorize` whenever `federation.enabled: true`
and `federation.paste_token: true` (the default when the section is present).
The handler treats the pasted value as an opaque token ID and calls
`LoginMinter.mint(method: .federationToken(tokenID:, isScoped:))`:

- `isScoped == false` (unscoped): the token is verified, then project-
  detection runs (same as the password flow) to pick the target project.
- `isScoped == true`: the token is used as-is; its scope determines access.

No extra configuration beyond `federation.enabled: true` is needed for
Route B.

### Which route do I need?

| Your cloud | Use |
|---|---|
| Keystone is the SP (OpenStack-native federation, most Genestack/RDO clouds) | Route A (WebSSO) |
| Federation SP is a separate portal (Skyline, some enterprise proxies) | Route B (paste-token) |
| Both | Enable both — the forms offer paste; `/oauth/federate` offers the bounce |


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
5. Leave `oauth.dev_mint_enabled` unset (or `false`) — the headless
   `POST /v1/oauth/dev-mint` endpoint is mounted **only** when explicitly set
   to `true`. It is off by default in every build; there is no debug-build
   auto-enable.

## Related

- [Security model](security.md) — token-per-request identity, scope gating, redaction, audit.
- [Configuration](configuration.md) — every OAuth and auth config key.
- [Quickstart](quickstart.md) — connecting a client to a running server.