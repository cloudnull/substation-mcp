# OpenStack MCP — multi-stage build (spec §13)
#
# Builder: swift:6.4-rhel-ubi10 (same toolchain used by scripts/swift).
# Runtime: registry.access.redhat.com/ubi10-minimal (genuine Red Hat UBI10 /
# RHEL 10, freely pullable with no login) + EPEL + the dynamic Swift runtime.
# Non-root user uid 10001. Package manager in the runtime is microdnf (no full
# dnf in the -minimal image).
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
# NOTE on the runtime base: genuine Red Hat UBI10 minimal, pulled from
# registry.access.redhat.com/ubi10-minimal (the free Red Hat "access"
# registry) — freely pullable with no login, confirmed. EPEL is enabled by
# writing the repo file directly (the UBI repos carry no epel-release RPM).
# The -minimal base already ships libcurl/libstdc++/libssl/libnghttp2/krb5/
# glibc, so only libicu + glibc-langpack-en are installed. The *builder* stage
# uses the official swift:6.4-rhel-ubi10 toolchain image.

# ── Stage 1: build ──────────────────────────────────────────────────────────────
FROM --platform=linux/amd64 swift:6.4-rhel-ubi10 AS builder

WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/
# Tests/ + IntegrationTests/ must exist for Package.swift's manifest to parse
# (it declares test targets, incl. IntegrationTests with a custom path); the
# release build does not compile them, but `swift build` fails with
# "'src': Source files for target ... should be located under ..." if the
# directories are absent.
COPY Tests/ Tests/
COPY IntegrationTests/ IntegrationTests/

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
# Genuine Red Hat UBI10 (RHEL 10), freely pullable without a Red Hat login.
# The -minimal variant is built for microdnf (no full dnf).
FROM registry.access.redhat.com/ubi10-minimal:latest AS runtime

# Enable EPEL (microdnf has no epel-release RPM in the UBI repos, so write the
# repo file directly) and refresh the metadata cache. EPEL is a standing
# preference for this image even though the current binary's deps are all in
# the baseos/appstream repos.
RUN printf '[epel]\nname=Extra Packages for Enterprise Linux 10\nbaseurl=https://download.fedoraproject.org/pub/epel/10/Everything/$basearch/\nenabled=1\ngpgcheck=1\ngpgkey=https://download.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-$releasever\n' \
        > /etc/yum.repos.d/epel.repo \
    && microdnf makecache

# The ubi10-minimal base already ships libcurl, libstdc++, libssl, libnghttp2,
# krb5 and glibc (verified via ldconfig). The only runtime libs the dynamic
# Swift binary additionally needs are the ICU data/lib (Foundation's ICU
# backend) and the English locale pack. Install just those.
RUN microdnf install -y libicu glibc-langpack-en \
    && microdnf clean all

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
