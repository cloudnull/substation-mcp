# OpenStack MCP — multi-stage build (spec §13)
#
# Builder: swift:6.4-rhel-ubi10 (same toolchain used by scripts/swift).
# Runtime: ubi10-minimal + ca-certificates. Non-root user uid 10001.
#
# Build (from repo root):
#   docker build --platform linux/amd64 -f deploy/Dockerfile -t openstack-mcp:local .
#
# Run:
#   docker run --rm -p 8080:8080 \
#     -v /path/to/clouds.yaml:/etc/openstack/clouds.yaml:ro \
#     -v /path/to/config.yaml:/etc/openstack-mcp/config.yaml:ro \
#     openstack-mcp:local
#
# NOTE: the runtime is UBI10 (RHEL 10 compatible), not Rocky 9 as originally
# sketched in the spec. UBI10 is the base of the Swift 6.4 toolchain image and
# is what the container build produces; Rocky 9 is not available for the
# static-swift-stdlib target triple. This is a documented deviation.

# ── Stage 1: build ──────────────────────────────────────────────────────────────
FROM --platform=linux/amd64 swift:6.4-rhel-ubi10 AS builder

WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/

# Dynamic release build (static not yet achievable due to ICU; see scripts/build.sh).
RUN swift build -c release \
    --scratch-path /build

# ── Stage 2: runtime ────────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi10/ubi10-minimal:latest AS runtime

# TLS roots + minimal runtime deps.
RUN dnf install -y ca-certificates && dnf clean all

# Non-root user.
RUN groupadd -g 10001 openstack-mcp \
    && useradd -u 10001 -g openstack-mcp -m -s /sbin/nologin openstack-mcp

# Install the binary.
COPY --from=builder /build/release/openstack-mcp /usr/local/bin/openstack-mcp

# Default config locations (override by mounting).
RUN mkdir -p /etc/openstack /etc/openstack-mcp \
    && chown -R openstack-mcp:openstack-mcp /etc/openstack /etc/openstack-mcp

USER openstack-mcp

# The server binds 0.0.0.0 inside the container regardless of OSMCP_SERVER__HOST
# (TLS terminates at the reverse proxy; the container must accept all interfaces).
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/openstack-mcp"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8080"]
