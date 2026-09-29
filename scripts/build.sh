#!/bin/sh
# Release build wrapper: builds a single static binary via scripts/swift.
# Used by Task 21/22. On UBI10 with Swift 6.4, --static-swift-stdlib produces
# a self-contained binary (spec §13).
set -eu
exec "$(dirname "$0")/swift" build -c release --static-swift-stdlib "$@"
