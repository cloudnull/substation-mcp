[← Documentation home](index.md)
# Security model

## Bearer token = identity

- **Bearer token = Keystone token.** The server validates every request's
  `Authorization: Bearer` header via `GET /v3/auth/tokens` (cached,
  `auth.token_cache_ttl`). It never accepts client-supplied `auth_url` or
  credentials.
- **Token-per-request.** There is no long-lived session token; the Keystone
  token *is* the identity. An expired token → `401` on the next request, even if
  the `Mcp-Session-Id` is still alive.
- **Project isolation.** Each token is project-scoped; the token-metadata cache
  holds one entry per distinct token ID. Two sessions with different project
  tokens interleaving requests never see each other's resources.
- **Scope gate.** Read-only tokens get `403 insufficient_scope` on mutating
  tool calls. The write-tool gate (`WriteToolGate`) names the specific tools
  that require write scope.
- **No held user credentials.** The server holds application-credential secrets
  only for the login page (URL-mode elicitation); they are zeroized after use.
- **Stateless OAuth (P3).** When `auth.profile = oauth`, substation-mcp fronts
  Keystone as its own stateless OAuth 2.1 AS. Codes and access tokens are signed
  short-lived JWTs (HS256), not in-memory state; DCR is deterministic with no
  client store. See [OAuth 2.1 login](oauth.md).

## Access control at the boundary

- **Access rules.** Use `substation-mcp access-rules` to generate the Keystone
  access-rule JSON for application credentials. Combine with
  `keystonemiddleware` for per-service path enforcement.
- **TLS off-host.** The server does not terminate TLS (phase 1); a reverse proxy
  (Caddy/nginx) handles it. In containers the server binds `0.0.0.0` and the
  proxy binds the public interface.
- **Origin allow-list.** `server.allowed_origins` restricts browser-originated
  MCP connections; `*` disables the check.

## Rate limiting

- **Auth failures:** per-source-IP limit — `429` after
  `auth.failed_auth_per_minute` (default 10) failures in a minute.
- **Tool calls:** per-session rate limit (`policy.max_calls_per_minute`, default
  120/min).

## Redaction & audit

- **Redaction.** All log lines pass through a redaction layer that masks
  `Authorization`, `X-Auth-Token`, `X-Subject-Token`, `secret`, `password`,
  `adminPass`, `user_data`, `token`, `application_credential`, `appcredsecret`.
- **Audit.** One record per mutating tool call: time, token ID, project ID,
  tool, outcome, request ID, application credential ID. Gated by `log.audit`.

## Threat notes worth knowing

- The derived dev OAuth secret (`"dev-" + sha256(...)`) makes OAuth zero-config
  but is **not** a production control — anyone who knows the public URL can
  recompute it. Set `oauth.server_secret` on any deployment reachable by
  untrusted parties. See [OAuth → Production checklist](oauth.md#production-checklist).
- The headless `POST /v1/oauth/dev-mint` endpoint mints codes without the
  browser flow. It is mounted **only** when `oauth.dev_mint_enabled: true`
  (default `false`, off in every build). Leave it unset in production.

## Related

- [OAuth 2.1 login](oauth.md) — the stateless OAuth AS in depth.
- [Configuration](configuration.md) — the keys that drive redaction, audit, rate limits.

