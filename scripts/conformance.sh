#!/usr/bin/env bash
#
# conformance.sh — conformance-HTTP-smoke (spec §14.5).
#
# Drives the FULL MCP Streamable-HTTP handshake against a RUNNING `substation-mcp
# serve` instance using the binary itself as the HTTP client — the hidden
# `conformance` subcommand (no curl, which is absent from the ubi10-minimal
# runtime and not assumed on dev hosts).
#
# The subcommand asserts, in order:
#   1. 401 challenge on an unauthenticated request (WWW-Authenticate
#      invalid_token + resource_metadata)
#   2. PRM document shape (resource / authorization_servers / scopes_supported)
#   3. initialize -> 200 + MCP-Session-Id
#   4. tools/list -> 15 tools (write) or 9 tools (read-only)
#   5. tools/call os_whoami -> 200, not isError
#   6. DELETE -> 200 (session terminated)
#
# Usage:
#   # Against a server you have already started (recommended; the caller
#   # controls the backend — a fake in tests, a real cloud in CI):
#   scripts/conformance.sh --url http://127.0.0.1:8080/v1 --token <minted-id>
#
#   # Or let the subcommand mint a token itself against the same Keystone:
#   scripts/conformance.sh --url http://127.0.0.1:8080/v1 \
#       --auth-url http://127.0.0.1:9999/keystone/v3 \
#       --app-cred-id <id> --app-cred-secret <secret>
#
#   # Expect the read-only (9-tool) surface:
#   scripts/conformance.sh --url ... --token ... --read-only
#
# Exits 0 on all-pass, 1 on any failure, 2 on usage/build error.

set -euo pipefail

# Locate the built binary (prefer release, fall back to debug).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/substation-mcp" "$ROOT/.build/debug/substation-mcp"; do
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done
if [[ -z "$BIN" ]]; then
    echo "conformance: no built substation-mcp binary found in .build/release or .build/debug" >&2
    echo "conformance: run 'scripts/swift build' (or build --configuration release) first" >&2
    exit 2
fi
echo "conformance: using binary $BIN" >&2

# Pass through all remaining args to the conformance subcommand. The script is a
# thin convenience wrapper: `conformance.sh --url ... --token ...` ==
# `substation-mcp conformance --url ... --token ...`. This keeps the real
# handshake logic in the binary (testable, no curl) and lets the caller point
# it at any already-running server.
if [[ $# -eq 0 ]]; then
    echo "conformance: missing args. Pass --url http://host:port/v1 and either" >&2
    echo "            --token <id>  or  --auth-url <url> --app-cred-id <id> --app-cred-secret <s>" >&2
    echo "            (add --read-only to expect the 9-tool surface)" >&2
    exit 2
fi

exec "$BIN" conformance "$@"
