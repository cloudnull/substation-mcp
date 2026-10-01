#!/bin/sh
# Release build wrapper: builds the openstack-mcp binary via scripts/swift.
#
# On UBI10 with Swift 6.4, --static-swift-stdlib is attempted first (spec §13
# wants a self-contained binary). However the toolchain's static Foundation
# archives reference ICU symbols (libicuuc) that are not in the static link
# path, so a fully static binary is not yet achievable. If the static link
# fails, we fall back to a dynamically-linked release binary that runs on any
# UBI10/RHEL10 system with the standard Swift runtime (shipped with the
# swift:6.4-rhel-ubi10 image).
#
# Usage: scripts/build.sh   (produces ./.build/release/openstack-mcp)
set -eu

SWIFT="$(dirname "$0")/swift"

echo "==> Attempting static release build (swift:6.4-rhel-ubi10)..."
if "$SWIFT" build -c release --static-swift-stdlib 2>/dev/null; then
  echo "==> Static build succeeded: ./.build/release/openstack-mcp"
else
  echo "==> Static build failed (ICU symbols unavailable); falling back to dynamic release build."
  "$SWIFT" build -c release
  echo "==> Dynamic release build succeeded: ./.build/release/openstack-mcp"
fi
