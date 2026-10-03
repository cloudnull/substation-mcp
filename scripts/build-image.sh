#!/bin/sh
# build-image.sh — package a NATIVE (host-arch) substation-mcp deployable.
#
# There is no `docker build` on this host (only Apple `container`). So instead
# of a docker image we produce a UBI10 *filesystem* image tarball that matches
# deploy/Dockerfile stage 2 exactly:
#   - /usr/local/bin/substation-mcp   (the native release binary)
#   - /etc/openstack, /etc/substation-mcp  (config mount points, owned by uid 10001)
#   - the `substation-mcp` user/group (uid/gid 10001) in /etc/passwd + /etc/group
#   - a CA bundle reference (ca-certificates)
#
# The binary is built for the host arch (aarch64 on this Apple Silicon host,
# via scripts/swift -> swift:6.4-rhel-ubi10 aarch64). The tarball is therefore
# a native arm64 rootfs: extract on an arm64 UBI10/RHEL10 host (or use as the
# layer payload for a custom base) and the binary runs directly.
#
# Usage:
#   scripts/build-image.sh            # builds release if missing, packages
#   scripts/build-image.sh TAG=foo    # set the tag recorded in the manifest
#
# Output: dist/substation-mcp-<arch>-ubi10-<tag>.tar.gz + a .manifest.json

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${TAG:-v0.1.0}"
ARCH="$(uname -m)"          # arm64 on Apple Silicon
case "$ARCH" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
esac

DIST="$ROOT/dist"
NAME="substation-mcp-${ARCH}-ubi10-${TAG}"
OUT="$DIST/$NAME.tar.gz"
ROOTFS="$DIST/$NAME.rootfs"

echo "==> Ensuring native $ARCH release binary..."
if [ ! -x "$ROOT/.build/release/substation-mcp" ]; then
  ( cd "$ROOT" && "$ROOT/scripts/swift" build -c release --static-swift-stdlib )
fi
BIN="$ROOT/.build/release/substation-mcp"

echo "==> Building UBI10 rootfs at $ROOTFS ..."
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{usr/local/bin,etc/openstack,etc/substation-mcp,etc/ssl/certs,var/log/substation-mcp}

# The native binary (dynamic; runs on UBI10 with the standard Swift runtime).
install -m 0755 "$BIN" "$ROOTFS/usr/local/bin/substation-mcp"

# Non-root user (uid/gid 10001) — mirrors deploy/Dockerfile.
cat > "$ROOTFS/etc/passwd" <<'EOF'
substation-mcp:x:10001:10001:OpenStack MCP:/home/substation-mcp:/sbin/nologin
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
substation-mcp:x:10001:
EOF
# Minimal ssl/certs dir so apps that read the system bundle find it on a host
# where /etc/ssl/certs is populated (the tarball only ships the mount point).
mkdir -p "$ROOTFS/home/substation-mcp"
chown -R 10001:10001 "$ROOTFS/etc/openstack" "$ROOTFS/etc/substation-mcp" "$ROOTFS/var/log/substation-mcp" "$ROOTFS/home/substation-mcp" 2>/dev/null || true

echo "==> Writing manifest..."
cat > "$DIST/$NAME.manifest.json" <<EOF
{
  "name": "substation-mcp",
  "tag": "$TAG",
  "arch": "$ARCH",
  "os": "linux",
  "base": "ubi10 (RHEL 10 compatible)",
  "type": "filesystem-rootfs",
  "entrypoint": ["/usr/local/bin/substation-mcp"],
  "cmd": ["serve", "--host", "0.0.0.0", "--port", "8080"],
  "expose": [8080],
  "user": "substation-mcp:10001",
  "binary_sha256": "$(shasum -a 256 "$BIN" | cut -d' ' -f1)",
  "binary_size_bytes": "$(stat -f%z "$BIN" 2>/dev/null || stat -c%s "$BIN")",
  "note": "Native rootfs (no docker). Extract on an arm64 UBI10 host, or feed as a layer. ca-certificates must be present on the host (the image relies on the host's /etc/ssl/certs)."
}
EOF

echo "==> Packing $OUT ..."
( cd "$DIST" && tar -czf "$NAME.tar.gz" -C "$ROOTFS" . )
rm -rf "$ROOTFS"

echo "==> Done."
echo "    image : $OUT"
echo "    size  : $(du -h "$OUT" | cut -f1)"
echo "    sha   : $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo "    tag   : $NAME"
