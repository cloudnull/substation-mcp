# Makefile — the full LOCAL build / test / release / container-lifecycle loop.
#
# Everything a developer needs on a workstation lives here. Production
# deployment (Genestack Helm, systemd installs, catalog registration) is
# intentionally NOT in this file; those paths live under deploy/ and its docs.
#
# The project builds with the Swift 6.4 toolchain. On Linux the canonical
# toolchain is the `swift:6.4-rhel-ubi10` container image (invoked via
# scripts/swift). macOS builds also go through the container: the 6.3.3 release
# toolchain crashes compiling dependency manifests and cannot compile this
# codebase's async-defer patterns (added in Swift 6.4). All Swift work therefore
# runs inside the pinned container via scripts/swift, which itself resolves your
# container runtime (docker, podman, or Apple `container`). Never build natively
# on macOS.
#
# ── Build / test / release ───────────────────────────────────────────────────
#   make build          # debug build of all products (fast, for iteration)
#   make release        # release build (static-attempt -> dynamic fallback)
#   make test           # run the unit + service test suites
#   make lint           # build with warnings surfaced (no -warnings-as-errors)
#   make warnings       # build and capture a clean, deduped list of warnings
#   make conformance    # MCP HTTP handshake smoke test vs a RUNNING server
#                        #   e.g. make conformance ARGS="--url http://127.0.0.1:8080/v1 --token <id>"
#   make package        # build the native UBI10 rootfs tarball (docker-less host)
#   make clean          # remove build artifacts
#
# ── Local container lifecycle (image + running dev container) ────────────────
#   make container-build     # build a local image from $(DOCKERFILE); default deploy/Dockerfile
#   make container-run       # start it (publishes :8080); CONTAINER_NAME/PORT overridable
#   make container-logs      # tail its logs
#   make container-exec      # run a command in it (e.g. make container-exec CMD="ps aux")
#   make container-stop      # stop it
#   make container-rm        # stop + delete it
#   make container-list      # list running containers
#   make container-clean     # stop + delete our named container (idempotent)
#
#   # The IAD3-baked, self-contained dev image (needs dist/local/ + release build):
#   make container-build DOCKERFILE=deploy/Dockerfile.local IMAGE_TAG=local-dev
#
# The active container runtime is resolved by preferring docker, then podman,
# then Apple `container`; override explicitly with RT=... :
#   make container-build RT=podman     # force a specific runtime

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

# ── Resolve the container runtime (same preference order as scripts/swift) ────
# Used only for the container image / lifecycle targets below. Build & test go
# through scripts/swift, which resolves the runtime itself.
# Prefer docker -> podman -> Apple `container`. Force one with RT=docker|podman|container.
RT ?=
ifneq ($(RT),)
  RUNTIME := $(RT)
else
  RUNTIME := $(shell \
	if command -v docker >/dev/null 2>&1;  then echo docker; \
	elif command -v podman >/dev/null 2>&1; then echo podman; \
	elif command -v container >/dev/null 2>&1; then echo container; \
	else echo none; fi)
endif

# ── Container lifecycle variables (all overridable) ──────────────────────────
IMAGE_NAME  ?= substation-mcp
IMAGE_TAG   ?= local-dev
IMAGE       := $(IMAGE_NAME):$(IMAGE_TAG)
# Default: the self-contained multi-stage deploy/Dockerfile (builds the binary
# in-image; needs no local config). For the IAD3-baked dev image that requires
# dist/local/ locally: DOCKERFILE=deploy/Dockerfile.local
DOCKERFILE  ?= deploy/Dockerfile
CONTAINER   ?= substation-mcp
HOST_PORT   ?= 8080
CONT_PORT   ?= 8080
.PHONY: all build release test lint warnings conformance package image clean \
		container-build container-run container-logs container-exec \
		container-stop container-rm container-list container-clean help
all: build

# ══ Build / test / release ════════════════════════════════════════════════

## build: debug build of every product (fast iteration, via scripts/swift)
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

## conformance: MCP Streamable-HTTP handshake smoke test against a RUNNING server.
##   Requires the built binary and a live `serve` instance (see container-run).
##   Pass --url/--token as ARGS, e.g.:
##     make conformance ARGS="--url http://127.0.0.1:8080/v1 --token <id>"
conformance:
ifeq ($(ARGS),)
	@echo "ERROR: pass ARGS with at least --url (and --token or minting creds)." >&2
	@echo "       e.g. make conformance ARGS=\"--url http://127.0.0.1:8080/v1 --token <id>\"" >&2
	@exit 2
else
	./scripts/conformance.sh $(ARGS)
endif

## package: native UBI10 rootfs tarball for docker-less hosts (aarch64 on Apple Silicon).
##   Produces dist/substation-mcp-<arch>-ubi10-<TAG>.tar.gz (+ manifest). TAG overridable.
package:
	TAG=$(or $(TAG),v0.1.0) ./scripts/build-image.sh

## clean: remove build artifacts (keeps source; removes dist packages too)
clean:
	rm -rf $(DESTDIR) .swiftpm
	rm -f dist/*.tar.gz dist/*.manifest.json
	rm -rf dist/*.rootfs

# ══ Local container lifecycle (image + running dev container) ═════════════
# Dispatches on RUNTIME (docker / podman / Apple `container`). Apple `container`
# spells flags differently from docker/podman, so it gets its own branch.

# Fail fast with a hint if no runtime is available. Runs inline in each recipe.
define require-runtime
	@if [ "$(RUNTIME)" = "none" ]; then \
		echo "ERROR: no container runtime found (tried docker, podman, Apple container)." >&2; \
		echo "       Install one (e.g. colima/docker, podman, or 'brew install container' for Apple)." >&2; \
		exit 127; fi
endef

## container-build: build a local image tagged $(IMAGE) from $(DOCKERFILE).
##   Default deploy/Dockerfile is self-contained (builds the binary in-image).
##   The IAD3-baked dev image needs a pre-built release binary + dist/local/:
##     DOCKERFILE=deploy/Dockerfile.local IMAGE_TAG=local-dev
container-build:
	$(require-runtime)
	if [ "$(RUNTIME)" = "container" ]; then \
		case "$(DOCKERFILE)" in *Dockerfile.local) \
			test -x .build/release/substation-mcp || ./scripts/build.sh; \
			test -f dist/local/config.yaml && test -f dist/local/clouds.yaml \
				|| { echo "ERROR: ead3 dev image needs dist/local/{config,clouds}.yaml (gitignored)." >&2; exit 1; }; \
			container build --platform linux/arm64 --file $(DOCKERFILE) -t $(IMAGE) . ;; \
		*) container build --platform linux/arm64 --file $(DOCKERFILE) -t $(IMAGE) . ;; esac ; \
	else \
		case "$(DOCKERFILE)" in *Dockerfile.local) \
			test -x .build/release/substation-mcp || ./scripts/build.sh; \
			test -f dist/local/config.yaml && test -f dist/local/clouds.yaml \
				|| { echo "ERROR: ead3 dev image needs dist/local/{config,clouds}.yaml (gitignored)." >&2; exit 1; }; \
			$(RUNTIME) build --platform linux/amd64 --file $(DOCKERFILE) -t $(IMAGE) . ;; \
		*) $(RUNTIME) build --platform linux/amd64 --file $(DOCKERFILE) -t $(IMAGE) . ;; esac ; \
	fi

## container-run: start the named dev container, publishing HOST_PORT:CONT_PORT.
##   Foreground (Ctrl-C stops it). Override CONTAINER/HOST_PORT/CONT_PORT as needed.
container-run:
	$(require-runtime)
	if [ "$(RUNTIME)" = "container" ]; then \
		container run --name $(CONTAINER) --rm \
			-p $(HOST_PORT):$(CONT_PORT) -c 4 -m 1G \
			$(IMAGE) ; \
	else \
		$(RUNTIME) run --rm --name $(CONTAINER) \
			-p $(HOST_PORT):$(CONT_PORT) \
			$(IMAGE) ; \
	fi

## container-logs: tail the logs of the named container.
container-logs:
	$(require-runtime)
	$(RUNTIME) logs -f $(CONTAINER)

## container-exec: run a command inside the named container. Usage: make container-exec CMD="ps aux"
container-exec:
	$(require-runtime)
ifeq ($(CMD),)
	@echo "ERROR: pass CMD, e.g. make container-exec CMD=\"ps aux\"" >&2
	@exit 2
else
	$(RUNTIME) exec $(CONTAINER) $(CMD)
endif

## container-stop: stop the named container (no-op if not running).
container-stop:
	$(require-runtime)
	-$(RUNTIME) stop $(CONTAINER) 2>/dev/null || true

## container-rm: stop + delete the named container (no-op if absent).
container-rm:
	$(require-runtime)
	-$(RUNTIME) stop $(CONTAINER) 2>/dev/null || true
	-$(RUNTIME) rm -f $(CONTAINER) 2>/dev/null || true

## container-list: list running containers.
container-list:
	$(require-runtime)
	if [ "$(RUNTIME)" = "container" ]; then \
		container list ; \
	else \
		$(RUNTIME) ps ; \
	fi

## container-clean: idempotent stop + delete of our named container (keeps the image).
container-clean: container-rm

## image: alias for container-build (legacy name kept for existing muscle memory).
image: container-build

help:
	@echo "Local build / test / release / container-lifecycle loop."
	@echo ""
	@echo "Build & test (via scripts/swift, auto-selects container toolchain):"
	@echo "  build          debug build of all products"
	@echo "  release        optimized (static->dynamic fallback) build"
	@echo "  test           run the test suites"
	@echo "  lint           build, print warnings/errors"
	@echo "  warnings       clean deduped list of warnings"
	@echo "  conformance    MCP HTTP smoke test vs a running server (pass ARGS=...)"
	@echo "  package        native UBI10 rootfs tarball (docker-less host)"
	@echo ""
	@echo "Container lifecycle (auto-picks $(RUNTIME); force with RT=docker|podman|container):"
	@echo "  container-build    build the local dev image (DOCKERFILE=..., IMAGE_TAG=...)"
	@echo "  container-run      run it (CONTAINER/HOST_PORT/CONT_PORT overridable)"
	@echo "  container-logs     tail its logs"
	@echo "  container-exec     run a command in it (CMD=\"...\")"
	@echo "  container-stop     stop it"
	@echo "  container-rm       stop + delete it"
	@echo "  container-list     list running containers"
	@echo "  container-clean    idempotent stop + delete"
	@echo ""
	@echo "Other:"
	@echo "  clean          remove build artifacts + dist packages"
	@echo "  image          alias for container-build"
	@echo ""
	@echo "Examples:"
	@echo "  make release && make container-build && make container-run"
	@echo "  make container-build DOCKERFILE=deploy/Dockerfile.local IMAGE_TAG=local-dev"
	@echo "  make conformance ARGS=\"--url http://127.0.0.1:8080/v1 --token <id>\""
	@echo "  Override toolchain: SWIFT=swift   |   Force runtime: RT=podman"
