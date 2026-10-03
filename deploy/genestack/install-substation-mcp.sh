#!/bin/bash
# install-substation-mcp.sh — install/upgrade the substation-mcp Helm chart
# into a Genestack cluster, following the Genestack add-on pattern
# (mirrors bin/install-barbican-exporter.sh).
#
# Usage (from the Genestack controller node):
#   ./install-substation-mcp.sh                        # use defaults
#   ./install-substation-mcp.sh --set image.repository=registry.example.com/openstack/substation-mcp \
#                              --set image.tag=1.2.3   # override values
#   ./install-substation-mcp.sh --dry-run              # print the helm command, don't execute
#
# The operator must:
#   1. Build + push the image (deploy/Dockerfile, amd64) to their registry.
#   2. Add an entry to /etc/genestack/helm-chart-versions.yaml:
#        substation-mcp: <chart-version>
#   3. (Optional) create /etc/genestack/helm-configs/substation-mcp/*.yaml
#      with service-specific overrides.
#
# This script is idempotent: `helm upgrade --install` is safe to re-run.

# shellcheck disable=SC2124,SC2145,SC2294

set -euo pipefail

# Service
SERVICE_NAME_DEFAULT="substation-mcp"
SERVICE_NAMESPACE="openstack"

# Helm chart path (in-tree; the operator can also publish it to a repo).
# Default: use the chart from this repo's deploy/genestack/helm/substation-mcp/.
# Override with --chart <path> or HELM_CHART_PATH env.
GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CHART_PATH="${SCRIPT_DIR}/helm/${SERVICE_NAME_DEFAULT}"

# Determine chart path: env override > --chart flag > in-tree default.
HELM_CHART_PATH="${HELM_CHART_PATH:-}"
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart) HELM_CHART_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done
: "${HELM_CHART_PATH:=$DEFAULT_CHART_PATH}"
if [[ ! -d "$HELM_CHART_PATH" ]]; then
  echo "Error: chart path '$HELM_CHART_PATH' does not exist." >&2
  echo "Build the chart or pass --chart <path>." >&2
  exit 1
fi

# Read the desired chart version from helm-chart-versions.yaml (if present).
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"
SERVICE_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
  SERVICE_VERSION=$(grep "^[[:space:]]*${SERVICE_NAME_DEFAULT}:" "$VERSION_FILE" | sed "s/.*${SERVICE_NAME_DEFAULT}: *//" || true)
fi
if [[ -n "$SERVICE_VERSION" ]]; then
  echo "Found version for $SERVICE_NAME_DEFAULT: $SERVICE_VERSION"
fi

# Load chart metadata from custom override YAML if defined (for repo-based charts).
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/${SERVICE_NAME_DEFAULT}"
for yaml_file in "${SERVICE_CUSTOM_OVERRIDES}"/*.yaml; do
  if [[ -f "$yaml_file" ]]; then
    # If the operator has configured a remote chart repo, use it.
    if command -v yq >/dev/null 2>&1; then
      REMOTE_REPO=$(yq eval '.chart.repo_url // ""' "$yaml_file" 2>/dev/null || true)
      if [[ -n "$REMOTE_REPO" && "$REMOTE_REPO" != "null" ]]; then
        echo "Using remote chart repo: $REMOTE_REPO"
        if [[ "$REMOTE_REPO" == oci://* ]]; then
          HELM_CHART_PATH="${REMOTE_REPO}/${SERVICE_NAME_DEFAULT}"
        else
          helm repo add "${SERVICE_NAME_DEFAULT}-repo" "$REMOTE_REPO" 2>/dev/null || true
          helm repo update 2>/dev/null || true
          HELM_CHART_PATH="${SERVICE_NAME_DEFAULT}-repo/${SERVICE_NAME_DEFAULT}"
        fi
      fi
    fi
    break
  fi
done

# Prepare -f override arguments (base + global + custom, in precedence order).
SERVICE_BASE_OVERRIDES="${GENESTACK_BASE_DIR}/base-helm-configs/${SERVICE_NAME_DEFAULT}"
GLOBAL_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR}/helm-configs/global_overrides"
overrides_args=()

if [[ -d "$SERVICE_BASE_OVERRIDES" ]]; then
  echo "Including base overrides from: $SERVICE_BASE_OVERRIDES"
  for file in "$SERVICE_BASE_OVERRIDES"/*.yaml; do
    [[ -e "$file" ]] && overrides_args+=("-f" "$file")
  done
else
  echo "Warning: base override directory not found: $SERVICE_BASE_OVERRIDES"
fi

if [[ -d "$GLOBAL_OVERRIDES_DIR" ]]; then
  echo "Including global overrides from: $GLOBAL_OVERRIDES_DIR"
  for file in "$GLOBAL_OVERRIDES_DIR"/*.yaml; do
    [[ -e "$file" ]] && overrides_args+=("-f" "$file")
  done
else
  echo "Warning: global override directory not found: $GLOBAL_OVERRIDES_DIR"
fi

if [[ -d "$SERVICE_CUSTOM_OVERRIDES" ]]; then
  echo "Including custom overrides from: $SERVICE_CUSTOM_OVERRIDES"
  for file in "$SERVICE_CUSTOM_OVERRIDES"/*.yaml; do
    [[ -e "$file" ]] && overrides_args+=("-f" "$file")
  done
else
  echo "Warning: custom override directory not found: $SERVICE_CUSTOM_OVERRIDES"
fi

# Post-renderer (kustomize) — Genestack convention.
POST_RENDERER="${GENESTACK_OVERRIDES_DIR}/kustomize/kustomize.sh"
POST_RENDERER_ARGS="${SERVICE_NAME_DEFAULT}/overlay"
post_renderer_args=()
if [[ -f "$POST_RENDERER" ]]; then
  post_renderer_args=(--post-renderer "$POST_RENDERER" --post-renderer-args "$POST_RENDERER_ARGS")
  echo "Using post-renderer: $POST_RENDERER ($POST_RENDERER_ARGS)"
else
  echo "Warning: post-renderer not found at $POST_RENDERER — skipping kustomize post-render."
fi

# Build the helm command.
helm_command=(
  helm upgrade --install "$SERVICE_NAME_DEFAULT" "$HELM_CHART_PATH"
  --namespace="$SERVICE_NAMESPACE"
  --create-namespace
  --timeout 120m
)
# --version is only meaningful for repo charts (not in-tree directory charts).
# Pass it only when the chart came from a remote repo (HELM_CHART_PATH is a
# repo/chart reference, not a local directory).
if [[ -n "$SERVICE_VERSION" && ! -d "$HELM_CHART_PATH" ]]; then
  helm_command+=("--version" "$SERVICE_VERSION")
fi
if [[ ${#overrides_args[@]} -gt 0 ]]; then
  helm_command+=("${overrides_args[@]}")
fi
if [[ ${#post_renderer_args[@]} -gt 0 ]]; then
  helm_command+=("${post_renderer_args[@]}")
fi
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  helm_command+=("${EXTRA_ARGS[@]}")
fi

echo
echo "Executing:"
printf '%q ' "${helm_command[@]}"
echo

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo
  echo "(dry-run: not executing)"
  exit 0
fi

"${helm_command[@]}"

echo
echo "==> Done. substation-mcp installed in namespace $SERVICE_NAMESPACE."
echo
echo "Next steps:"
echo "  1. Verify the deployment:"
echo "     kubectl -n $SERVICE_NAMESPACE get deploy substation-mcp"
echo "  2. Run register-catalog (one-time, as an operator with an admin token):"
echo "     OS_CLOUD=mycloud REGION=RegionOne PUBLIC_URL=https://<fqdn> ./register-catalog.sh"
echo "  3. Connect an MCP client:"
echo "     claude mcp add --transport http openstack https://<fqdn>/v1 \\"
echo "       --header \"Authorization: Bearer <keystone-token>\""
