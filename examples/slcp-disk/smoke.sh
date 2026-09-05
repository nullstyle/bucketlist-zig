#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
revision=e2c48987e4f1237f1b87ee27c148ce51edfe8fda
companion="$repo/.zig-cache/companions/slcp-disk"
source_repo="${SLCP_SOURCE:-$repo/../slcp-zig}"
export ZIG_LOCAL_CACHE_DIR="$repo/.zig-cache/slcp-disk-$revision-local"
export ZIG_GLOBAL_CACHE_DIR="$repo/.zig-cache/slcp-disk-$revision-global"
export ZIG_LOCAL_PKG_DIR="$repo/.zig-cache/slcp-packages"
mkdir -p "$repo/.zig-cache/companions" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_PKG_DIR"
if [[ ! -f "$companion/.bucketlist-revision" ]]; then
    [[ ! -e "$companion" ]] || { echo "Unrecognized companion cache: $companion" >&2; exit 1; }
    stage="$(mktemp -d "$repo/.zig-cache/companions/slcp-disk-stage.XXXXXX")"
    trap 'rm -rf -- "$stage"' EXIT
    git -C "$source_repo" archive "$revision" | tar -x -C "$stage"
    printf '%s\n' "$revision" > "$stage/.bucketlist-revision"
    mv "$stage" "$companion"
    trap - EXIT
fi
[[ "$(cat "$companion/.bucketlist-revision")" == "$revision" ]] || { echo "Wrong cached SLCP revision" >&2; exit 1; }
capnp_hash=capnpc_zig-0.16.0-nUduFXLZNgAmDvsQZOn7lNOEtNbRBYquaALRB24zUAvS
if [[ ! -f "$ZIG_LOCAL_PKG_DIR/$capnp_hash/build.zig.zon" ]]; then
    archive="$repo/.zig-cache/companions/capnp-v0.16.0.tar.gz"
    curl --fail --silent --show-error --location --max-time 60 \
        https://github.com/nullstyle/capnp-zig/archive/refs/tags/v0.16.0.tar.gz -o "$archive"
    fetched="$(cd "$repo" && mise exec -- zig fetch --pkg-dir "$ZIG_LOCAL_PKG_DIR" "$archive")"
    [[ "$fetched" == "$capnp_hash" ]] || { echo "Capnp package hash mismatch: $fetched" >&2; exit 1; }
    # Materialize the verified archive to avoid this compiler's cached archive
    # expansion preserving the GitHub wrapper directory.
    mkdir -p "$ZIG_LOCAL_PKG_DIR/$capnp_hash"
    tar -xzf "$archive" --strip-components=1 -C "$ZIG_LOCAL_PKG_DIR/$capnp_hash"
fi
cd "$repo/examples/slcp-disk"
mise exec -- zig build test install --cache-dir "$ZIG_LOCAL_CACHE_DIR" "$@"
"$PWD/process-test.sh" "$PWD/zig-out/bin/slcp-disk-host" "$repo/.zig-cache"
