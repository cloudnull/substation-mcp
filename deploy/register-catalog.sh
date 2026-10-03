#!/bin/sh
# register-catalog.sh — idempotent Keystone service+endpoint registration.
#
# Thin wrapper over `substation-mcp register-catalog`. Safe to re-run: it
# reuses the existing `mcp` service if present, creates it otherwise, and
# ensures the three endpoint types (public/internal/admin) exist.
#
# The catalog entry is created by a *service user* (e.g. `substation` in the
# `service` domain, mirroring `nova_service_user`) holding an application
# credential with the admin role. That credential is the service's standing
# identity — not a one-shot token — so it is reusable for every re-run and
# for the login page.
#
# Required env:
#   OS_CLOUD        — cloud name from clouds.yaml
#   REGION          — region to register (e.g. SAT0 / RegionOne)
#   PUBLIC_URL      — externally reachable MCP URL, e.g. https://substation.api.sat0.cloudnull.dev
#
# Auth (one of):
#   (preferred)   — the cloud entry in clouds.yaml carries an application
#                   credential (appCredID / appCredSecret); the binary mints
#                   an admin token from it natively (no curl/python needed).
#   OS_AUTH_TOKEN — a pre-minted Keystone admin token (X-Auth-Token)
#
# Optional:
#   OSMCP_BIN   — path to the substation-mcp binary (default: substation-mcp)
#   OS_CONFIG   — clouds.yaml path (default: ~/.config/openstack/clouds.yaml)
#
# Exit codes: 0 = success, 1 = auth/connectivity failure.

set -eu

: "${OS_CLOUD:?OS_CLOUD is required (cloud name from clouds.yaml)}"
: "${REGION:?REGION is required (e.g. RegionOne)}"
: "${PUBLIC_URL:?PUBLIC_URL is required (externally reachable MCP URL)}"

BIN="${OSMCP_BIN:-substation-mcp}"

# Token resolution happens in the binary, not here:
#   --admin-token / OS_AUTH_TOKEN  >  the cloud's application credential.
# When OS_AUTH_TOKEN is unset, the binary mints a token from the cloud entry's
# appCredID/appCredSecret natively (no curl/python3, so it works in the
# ubi10-minimal runtime) and discards it after registration. The cloud must
# therefore carry the service user's application credential.
if [ -z "${OS_AUTH_TOKEN:-}" ]; then
  echo "==> No OS_AUTH_TOKEN; the binary will mint one from $OS_CLOUD's application credential" >&2
fi

echo "==> Registering substation-mcp service + endpoints in $OS_CLOUD/$REGION" >&2
"$BIN" register-catalog \
  --cloud "$OS_CLOUD" \
  --region "$REGION" \
  --public-url "$PUBLIC_URL" \
  --config "${OS_CONFIG:-$HOME/.config/openstack/clouds.yaml}"
echo "==> Done." >&2
