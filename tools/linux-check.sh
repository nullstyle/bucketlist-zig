#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname -m)" in
    arm64|aarch64) linux_platform=linux/arm64 ;;
    *) linux_platform=linux/amd64 ;;
esac
# Copy source through stdin; no host workspace is mounted into the container.
# The disposable container installs all tools through this repository's mise file.
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.git --exclude=.zig-cache --exclude=zig-out --exclude=zig-pkg \
    --exclude=__pycache__ -cf - . |
docker run --rm -i --platform "$linux_platform" --entrypoint sh -w /work ghcr.io/jdx/mise:2026.8.10 -c '
    set -eu
    tar -xf -
    mise trust mise.toml
    mise install
    mise exec -- just doctor
    mise exec -- zig build test -j2 --summary all
    mise exec -- zig build test -j2 -Doptimize=ReleaseSafe --summary all
    mise exec -- zig build wasm-diff --summary all
'
