# OpenStack MCP — multi-stage build (spec §13)
#
# Builder: swift:6.4-rhel-ubi10 (same toolchain used by scripts/swift).
# Runtime: ubi10-minimal + ca-certificates. Non-root user uid 10001.
#
# Build (from repo root):
#   docker build --platform linux/amd64 -f deploy/Dockerfile -t substation-mcp:local .
#
# Run:
#   docker run --rm -p 8080:8080 \
#     -v /path/to/clouds.yaml:/etc/openstack/clouds.yaml:ro \
#     -v /path/to/config.yaml:/etc/substation-mcp/config.yaml:ro \
#     substation-mcp:local
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

# Release build. On UBI10/Swift 6.4 the fully-static link fails (static
# Foundation references ICU symbols not in the static path), so attempt
# static first and fall back to a dynamic release binary — the same logic as
# scripts/build.sh. The dynamic binary runs on UBI10-minimal with the
# standard Swift runtime already present via the toolchain image's libs.
RUN set -eux; \
    if swift build -c release --static-swift-stdlib --scratch-path /build; then \
      echo "static release build succeeded"; \
    else \
      echo "static build failed (ICU); falling back to dynamic release build"; \
      swift build -c release --scratch-path /build; \
    fi; \
    test -x /build/release/substation-mcp

# ── Stage 2: runtime ────────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi10/ubi10-minimal:latest AS runtime

# TLS roots + every runtime lib the (dynamically-linked) Swift binary needs.
# From `ldd` of the release binary: glibc stack, libstdc++, libicu (Foundation
# ICU backend), libcurl + libnghttp2, openssl (libssl/libcrypto), and the
# curl→krb5/unistring/selinux/pcre2/z transitive set. ca-certificates for
# TLS roots. ubi10-minimal ships none of these, so install them explicitly.
RUN dnf install -y \
        ca-certificates \
        glibc glibc-langpack-en \
        libstdc++ \
        libicu \
        libcurl libnghttp2 \
        openssl-libs \
        krb5-libs libunistring libselinux pcre2 \
        zlib \
        && dnf clean all

# Non-root user.
RUN groupadd -g 10001 substation-mcp \
    && useradd -u 10001 -g substation-mcp -m -s /sbin/nologin substation-mcp

# Bundle the dynamic Swift runtime from the toolchain image so the
# (dynamically-linked) binary runs without needing the full toolchain.
# The toolchain keeps its Swift libs under /usr/lib/swift.
COPY --from=builder /usr/lib/swift /usr/lib/swift

# Install the binary.
COPY --from=builder /build/release/substation-mcp /usr/local/bin/substation-mcp

# Default config locations (override by mounting).
RUN mkdir -p /etc/openstack /etc/substation-mcp \
    && chown -R substation-mcp:substation-mcp /etc/openstack /etc/substation-mcp

USER substation-mcp

# The server binds 0.0.0.0 inside the container regardless of OSMCP_SERVER__HOST
# (TLS terminates at the reverse proxy; the container must accept all interfaces).
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/substation-mcp"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8080"]
