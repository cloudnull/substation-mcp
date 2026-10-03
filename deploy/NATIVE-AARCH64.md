# Native aarch64 build (no docker)

`deploy/Dockerfile` is the standard multi-stage UBI10 build for **amd64** via
`docker build`. This host has **no docker** (only Apple `container`), so the
native **aarch64** deployable is produced by `scripts/build-image.sh`, which
packages a UBI10 **filesystem-image tarball** matching `Dockerfile` stage 2.

## What it produces

- A native aarch64 release binary (built in the `swift:6.4-rhel-ubi10`
  aarch64 container via `scripts/swift build -c release`, no QEMU).
- A UBI10 rootfs tarball at `dist/substation-mcp-aarch64-ubi10-<tag>.tar.gz`:
  - `/usr/local/bin/substation-mcp` (the native binary)
  - `substation-mcp` user/group (uid/gid 10001) in `/etc/passwd` + `/etc/group`
  - `/etc/openstack`, `/etc/substation-mcp`, `/var/log/substation-mcp` mount points
  - `/etc/ssl/certs` directory (ca-certificates must be present on the host)
- A `.manifest.json` next to the tarball recording tag, arch, binary sha256,
  size, entrypoint, cmd, exposed port, and the non-root user.

## Build

    scripts/build-image.sh            # default tag v0.1.0
    scripts/build-image.sh TAG=foo    # custom tag

The script builds the release binary if it is missing, then packages. Output
is a `filesystem-rootfs` — extract it on an arm64 UBI10/RHEL10 host (or feed it
as a layer payload for a custom base) and the binary runs directly.

## Why not `docker build` on this host

Apple `container` cannot nest (no runtime inside the container), and this host
has no docker daemon, so `docker build` (which for amd64 on Apple Silicon uses
QEMU emulation) is unavailable. The filesystem-image tarball is the equivalent
deliverable for the native aarch64 path and is verified to run via Apple
`container run ... swift:6.4-rhel-ubi10` (see the conformance smoke, which runs
the binary in-container against a live cloud).

## Running

    # extract the rootfs on an arm64 UBI10 host, then:
    sudo -u substation-mcp /usr/local/bin/substation-mcp serve \
      --config /etc/substation-mcp/config.yaml --cloud <name> \
      --host 0.0.0.0 --port 8080

`deploy/substation-mcp.service` (hardened systemd) and `deploy/caddy/Caddyfile`
/ `deploy/nginx/substation-mcp.conf` (SSE buffering off) are the same for both
arches — they reference the binary path, not the arch.
