# openstack-mcp

A Hummingbird-hosted Swift MCP (Model Context Protocol) server that lets an LLM
client consume an OpenStack cloud — identity (Keystone), compute (Nova),
network (Neutron), block storage (Cinder), and image (Glance) — through a small
set of catalog-driven tools. Identity is token-per-request: every request
carries a Keystone token, the server validates it and uses only that token
upstream, so it is multi-tenant and holds no user credentials.

## Build & test

All Swift work runs inside the pinned Linux container image
(`swift:6.4-rhel-ubi10`) via the `scripts/swift` wrapper, which resolves your
container runtime (docker, podman, or Apple `container`) for you. Never build
natively on macOS.

```sh
scripts/swift --version   # verify the container toolchain
scripts/swift build       # debug build
scripts/swift test        # run the test suite
```

Release build (Task 21+):

```sh
scripts/build.sh          # swift build -c release --static-swift-stdlib
```

## Layout

- `Sources/OpenStackClient` — OpenStack client library (no MCP knowledge).
- `Sources/OpenStackMCPServer` — MCP server logic (catalog, policy, tools).
- `Sources/HummingbirdMCP` — Hummingbird ⇄ MCP SDK transport adapter.
- `Sources/openstack-mcp` — executable: `serve`, `stdio`, `check`, …
- `Sources/FakeOpenStack` — in-process fake cloud for tests.
- `specs/openstack-mcp-spec.md` — the specification this implements.
