#!/bin/sh
# register-catalog.sh — idempotent Keystone service+endpoint registration.
#
# Thin wrapper over `openstack-mcp register-catalog` (Task 20). Run as an
# operator with an admin token (minted from an application credential or
# user password). Safe to re-run: it reuses the existing `mcp` service if
# present, creates it otherwise, and ensures the three endpoint types
# (public/internal/admin) exist.
#
# Required env:
#   OS_CLOUD        — cloud name from clouds.yaml
#   REGION          — region to register (e.g. RegionOne)
#   PUBLIC_URL      — externally reachable MCP URL, e.g. https://mcp.example.com
#
# Auth (one of):
#   OS_AUTH_TOKEN            — a pre-minted Keystone admin token (X-Auth-Token)
#   OS_APPLICATION_CREDENTIAL_ID + OS_APPLICATION_CREDENTIAL_SECRET
#                             — a Keystone application credential (admin role)
#   OS_USER_DOMAIN_NAME + OS_USERNAME + OS_PASSWORD
#                             — user password auth (admin role)
#
# Optional:
#   OSMCP_BIN   — path to the openstack-mcp binary (default: openstack-mcp)
#   OS_CONFIG   — clouds.yaml path (default: ~/.config/openstack/clouds.yaml)
#
# Exit codes: 0 = success, 1 = auth/connectivity failure.

set -eu

: "${OS_CLOUD:?OS_CLOUD is required (cloud name from clouds.yaml)}"
: "${REGION:?REGION is required (e.g. RegionOne)}"
: "${PUBLIC_URL:?PUBLIC_URL is required (externally reachable MCP URL)}"

BIN="${OSMCP_BIN:-openstack-mcp}"

# If no OS_AUTH_TOKEN, mint one from the configured credential.
if [ -z "${OS_AUTH_TOKEN:-}" ]; then
  if [ -n "${OS_APPLICATION_CREDENTIAL_ID:-}" ] && [ -n "${OS_APPLICATION_CREDENTIAL_SECRET:-}" ]; then
    OS_AUTH_URL="${OS_AUTH_URL:-}"
    OS_AUTH_URL="${OS_AUTH_URL:-$(openstack endpoint list --service identity -f value -c URL 2>/dev/null | head -1)}"
    : "${OS_AUTH_URL:?Cannot determine auth URL; set OS_AUTH_URL explicitly}"
    TOKEN=$(curl -s -X POST "${OS_AUTH_URL}/auth/tokens" \
      -H "Content-Type: application/json" \
      -d "{
        \"auth\": {
          \"identity\": {
            \"methods\": [\"application_credential\"],
            \"application_credential\": {
              \"id\": \"${OS_APPLICATION_CREDENTIAL_ID}\",
              \"secret\": \"${OS_APPLICATION_CREDENTIAL_SECRET}\"
            }
          },
          \"scope\": {\"type\": \"project\", \"project\": {\"domain\": {\"name\": \"default\"}}}
        }
      }" | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['id'])" 2>/dev/null) \
      || { echo "ERROR: failed to mint token from application credential" >&2; exit 1; }
    export OS_AUTH_TOKEN="$TOKEN"
    echo "==> Minted admin token: ${TOKEN:0:8}…" >&2
  elif [ -n "${OS_USERNAME:-}" ] && [ -n "${OS_PASSWORD:-}" ]; then
    OS_AUTH_URL="${OS_AUTH_URL:-}"
    OS_AUTH_URL="${OS_AUTH_URL:-$(openstack endpoint list --service identity -f value -c URL 2>/dev/null | head -1)}"
    : "${OS_AUTH_URL:?Cannot determine auth URL; set OS_AUTH_URL explicitly}"
    TOKEN=$(curl -s -X POST "${OS_AUTH_URL}/auth/tokens" \
      -H "Content-Type: application/json" \
      -d "{
        \"auth\": {
          \"identity\": {
            \"methods\": [\"password\"],
            \"password\": {
              \"user\": {
                \"name\": \"${OS_USERNAME}\",
                \"domain\": {\"name\": \"${OS_USER_DOMAIN_NAME:-default}\"},
                \"password\": \"${OS_PASSWORD}\"
              }
            }
          },
          \"scope\": {\"type\": \"project\", \"project\": {\"domain\": {\"name\": \"default\"}}}
        }
      }" | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['id'])" 2>/dev/null) \
      || { echo "ERROR: failed to mint token from user password" >&2; exit 1; }
    export OS_AUTH_TOKEN="$TOKEN"
    echo "==> Minted admin token: ${TOKEN:0:8}…" >&2
  else
    echo "ERROR: set OS_AUTH_TOKEN, or OS_APPLICATION_CREDENTIAL_ID+SECRET, or OS_USERNAME+OS_PASSWORD" >&2
    exit 1
  fi
fi

echo "==> Registering openstack-mcp service + endpoints in $OS_CLOUD/$REGION" >&2
"$BIN" register-catalog \
  --cloud "$OS_CLOUD" \
  --region "$REGION" \
  --public-url "$PUBLIC_URL" \
  --config "${OS_CONFIG:-$HOME/.config/openstack/clouds.yaml}"
echo "==> Done." >&2
