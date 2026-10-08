# Makefile — repeatable build/test entry points for substation-mcp.
#
# The project builds with the Swift 6.4 toolchain. On Linux the canonical
# toolchain is the `swift:6.4-rhel-ubi10` container image (invoked via
# scripts/swift). On macOS we build natively with the installed toolchain, but
# the Swift 6.3.3 release toolchain crashes compiling dependency manifests
# unless the macOS SDK is pinned via SDKROOT. We detect the OS and pick the
# right path so `make build` / `make test` work on either platform.
#
# Common targets:
#   make build          # debug build of all products (fast, for iteration)
#   make release        # release build (static-attempt -> dynamic fallback)
#   make test           # run the unit + service test suites
#   make lint           # build with warnings surfaced (no -warnings-as-errors)
#   make warnings       # build and capture a clean, deduped list of warnings
#   make image          # build the linux/amd64 container image (deploy/Dockerfile)
#   make clean          # remove build artifacts
#
# Override the toolchain explicitly if needed:
#   make build SWIFT=scripts/swift     # force the Linux container path
#   make build SWIFT=swift             # force the native toolchain

SHELL := /bin/sh
SWIFT ?=
PLATFORM := $(shell uname -s)
DESTDIR := .build

# ── Resolve the Swift invocation ──────────────────────────────────────────────
# Default: the pinned Swift 6.4 container toolchain (scripts/swift) on every
# platform, matching CI. Native `swift` overrides only via SWIFT=swift.
#
# History: macOS previously used the native toolchain with a pinned SDKROOT
# (the 6.3.3 release toolchain crashed compiling dependency manifests without
# it), but it cannot compile this codebase's async-defer patterns (added in
# Swift 6.4), so all local builds now go through the container.
ifneq ($(SWIFT),)
  SWIFT_CMD := $(SWIFT)
else
  SWIFT_CMD := scripts/swift
endif

.PHONY: all build release test lint warnings image clean help
all: build

## build: debug build of every product (fast iteration)
build:
	$(SWIFT_CMD) build

## release: optimized build (static attempt -> dynamic fallback, per scripts/build.sh)
release:
	./scripts/build.sh

## test: run the full unit + service test suites
test:
	$(SWIFT_CMD) test

## lint: debug build with all warnings printed (used to track warning count)
lint:
	$(SWIFT_CMD) build 2>&1 | grep -E "warning:|error:" | grep -v "swiftinterface\|swiftmodule" || echo "(no diagnostics)"

## warnings: capture a clean, deduplicated list of build warnings
warnings:
	$(SWIFT_CMD) build 2>&1 \
		| grep "warning:" \
		| grep -E "/Sources/.*\.swift:[0-9]+:[0-9]+:" \
		| sed -E 's/\x1b\[[0-9;]*m//g; s/^.*\.swift/\.swift/' \
		| sort -u

## image: build the linux/amd64 container image (requires a container runtime)
image:
	./scripts/build-image.sh

## clean: remove build artifacts
clean:
	rm -rf $(DESTDIR) .swiftpm

help:
	@echo "Targets:"
	@echo "  build      debug build of all products"
	@echo "  release    optimized (static->dynamic fallback) build"
	@echo "  test       run the test suites"
	@echo "  lint       build, print warnings/errors"
	@echo "  warnings   clean deduped list of warnings"
	@echo "  image      build the linux/amd64 container image"
	@echo "  clean      remove build artifacts"
	@echo ""
	@echo "Override the toolchain with SWIFT=... (e.g. SWIFT=scripts/swift)."
