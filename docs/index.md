# substation-mcp documentation

A Hummingbird-hosted Swift **MCP (Model Context Protocol) server** that lets an
LLM client consume a whole OpenStack cloud — identity, compute, network, block
storage, images, object storage, key management, load balancing, DNS, containers,
orchestration, and shared file systems — through **20 small, catalog-driven
tools**.

Every request carries its own Keystone token (`Authorization: Bearer <token>`).
The server validates it and uses only that token upstream, so it is
multi-tenant, holds no user credentials, and enforces project isolation by
construction.

## Where to go next

| Page | What you'll find |
|------|------------------|
| [Quickstart](quickstart.md) | Build, validate a token, run the server, and connect a client in ~5 steps |
| [Tools reference](tools.md) | All 20 tools, the read/write split, and argument conventions |
| [Architecture](architecture.md) | How the pieces fit: transport, client, catalog, versioning, caching |
| [Configuration](configuration.md) | Every config key, env var, layering rules, and example files |
| [Security model](security.md) | Token-per-request identity, scope gating, redaction, audit, rate limits |
| [OAuth 2.1 login](oauth.md) | The default stateless OAuth AS: discovery, PKCE, multi-replica replay store |
| [Deploying](deploying.md) | Docker, systemd, reverse proxy, Genestack/Kubernetes, native aarch64 |


## At a glance

- **Transport:** MCP Streamable HTTP (`/v1`) over Hummingbird, plus a `stdio`
  mode for local clients.
- **Identity:** token-per-request; no long-lived session token is minted or held.
- **Auth profile:** `oauth` (default, P3 — substation-mcp fronts Keystone as its
  own stateless OAuth 2.1 AS) or `keystone_token` (P1 raw bearer, unchanged).
- **Stable tool surface:** verbs are additive-only. New OpenStack services show
  up as new *resources* under the existing verbs, never as new tools.
- **Stateless where it counts:** OAuth codes and access tokens are short-lived
  signed JWTs, not in-memory state.

For the full design rationale see [`specs/substation-mcp-spec.md`](../specs/substation-mcp-spec.md).
Build/test/deploy assets live in `scripts/`, `deploy/`, and `Package.swift`.
