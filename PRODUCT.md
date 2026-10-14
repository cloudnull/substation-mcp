# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (the login experience); everything else is backend/CLI with no user-facing surface.

## Users

- **LLM MCP clients** (Claude, OpenCode, and similar) — the primary "user." The product exposes a stable set of catalog-driven tools to an agent that consumes an OpenStack cloud on behalf of a human operator.
- **OpenStack operators/administrators** — configure `clouds.yaml` / `config.yaml`, register the MCP service in Keystone, run the server, and browse the application-credential login page.

## Product Purpose

Let an LLM client consume a whole OpenStack cloud — identity, compute, network, block storage, images, object storage, key management, load balancing, DNS, containers, orchestration, and shared file systems — through a small, stable, catalog-driven tool surface. Success means the MCP handshake connects, tools resolve against real resources under the caller's token, and mutating calls are safely gated and audited.

## Positioning

A stateless, multi-tenant auth boundary *in front of* OpenStack: every request carries its own Keystone token, so substation-mcp holds no user credentials, enforces project isolation by construction, and can front Keystone as its own stateless OAuth 2.1 AS. A neighboring product could not copy the additive-only verb-tool stability invariant plus token-per-request scope gating without rearchitecting both identity and the catalog.

## Operating Context

- Transport: MCP Streamable HTTP (`/v1`) over Hummingbird, plus a `stdio` mode for local clients.
- Auth profiles: `oauth` (default — fronts Keystone as a stateless OAuth 2.1 AS via browser login, RFC 8414 discovery + PKCE) or `keystone_token` (raw bearer, unchanged).
- Development runs entirely inside a pinned Linux container (`swift:6.4-rhel-ubi10`) via the `scripts/swift` wrapper; native macOS builds are intentionally avoided. The Makefile is the single entry point for the local build/test/run loop; production deploy (Genestack/K8s, systemd, reverse proxy) is separate.
- A seeded in-process fake cloud (`FakeOpenStack`) drives the entire test suite, so tests need no real OpenStack.

## Capabilities and Constraints

- 20 verb tools (14 read-only + 6 write), organized as additive-only verbs (`os_list`, `os_get`, `os_create`, `os_update`, `os_delete`, `os_action`, `os_attach`, `os_detach`) plus discovery/topology/wait/helper tools. New OpenStack services appear as new catalog *resources*, never as new tools.
- Token-per-request identity; token-metadata cache scoped per token ID. Read-only tokens get `403 insufficient_scope` on mutating calls.
- Stateless OAuth: codes and access tokens are short-lived signed JWTs (HS256), not in-memory state; DCR is deterministic. Replay store is pluggable (`local` default or `memcached` across replicas).
- Redaction of secrets in logs, one audit record per mutating call, per-source-IP auth-failure limit, and per-session tool rate limit.
- TLS is terminated off-host by a reverse proxy; the server binds `0.0.0.0`.
- Constraint: the login experience is the only browser UI — no dashboard, settings, or other web surface exists today.

## Brand Commitments

Name: `substation-mcp` (MIT, copyright 2026 Kevin Carter). An embedded logo PNG exists in the binary but there is no documented palette, type system, or other visual brand guideline. Future design is open except where the user makes a binding commitment.

## Evidence on Hand

README, [`docs/`](docs/) (index, quickstart, tools, architecture, configuration, security, oauth, deploying), full design rationale in [`specs/substation-mcp-spec.md`](specs/substation-mcp-spec.md), and a 90 KB [`HANDOFF.md`](HANDOFF.md) recording shipped milestones. No customer data, testimonials, pricing, or deployment-count claims exist — future work must not fabricate them.

## Product Principles

1. **Stability by invariant.** Tools are additive-only; the surface stays small while the catalog grows.
2. **Identity at the boundary.** Token-per-request means no held credentials, project isolation by construction, and a clean place to front OpenStack with a stateless OAuth layer.
3. **Operator-first safety.** Scope gating, secret redaction, per-call audit, and dry-run blockers before any mutation reaches a real cloud.
