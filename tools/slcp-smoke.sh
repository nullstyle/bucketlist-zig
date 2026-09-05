#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
revision=458e25effc3e9676ac02f9a34c104521a5e0757b
source_repo="${SLCP_SOURCE:-$repo/../slcp-zig}"
remote="${SLCP_REMOTE:-https://github.com/nullstyle/slcp-zig.git}"
companion="$repo/.zig-cache/companions/slcp"
export ZIG_LOCAL_CACHE_DIR="$repo/.zig-cache/slcp-local"
export ZIG_GLOBAL_CACHE_DIR="$repo/.zig-cache/slcp-global"
export ZIG_LOCAL_PKG_DIR="$repo/.zig-cache/slcp-packages"
mkdir -p "$repo/.zig-cache/companions" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_PKG_DIR"
# The pinned commit is fetched from the public remote when no local source
# holds it; the object hash itself pins the content. Read Git objects only;
# compilation and package resolution happen entirely inside bucketlist-zig.
if [[ ! -f "$companion/.bucketlist-revision" ]] || [[ "$(cat "$companion/.bucketlist-revision")" != "$revision" ]]; then
    if [[ -e "$companion" ]]; then
        echo "Unexpected companion cache; remove $companion to prepare the pinned source again." >&2
        exit 1
    fi
    stage="$(mktemp -d "$repo/.zig-cache/companions/slcp-stage.XXXXXX")"
    trap 'rm -rf -- "$stage"' EXIT
    if git -C "$source_repo" cat-file -e "$revision^{commit}" >/dev/null 2>&1; then
        git -C "$source_repo" archive "$revision" | tar -x -C "$stage"
    else
        fetch="$(mktemp -d "$repo/.zig-cache/companions/slcp-fetch.XXXXXX")"
        git -C "$fetch" init -q
        git -C "$fetch" remote add origin "$remote"
        git -C "$fetch" fetch -q --depth 1 origin "$revision"
        git -C "$fetch" archive "$revision" | tar -x -C "$stage"
        rm -rf "$fetch"
    fi
    printf '%s\n' "$revision" > "$stage/.bucketlist-revision"
    mv "$stage" "$companion"
    trap - EXIT
fi
# Fetch with curl's bounded timeout, then let Zig verify the manifest's exact
# content hash in the isolated package directory. No compiler/C++ tools needed.
capnp_hash=capnpc_zig-0.16.0-nUduFXLZNgAmDvsQZOn7lNOEtNbRBYquaALRB24zUAvS
if [[ ! -d "$ZIG_LOCAL_PKG_DIR/$capnp_hash" ]]; then
    archive="$repo/.zig-cache/companions/capnp-v0.16.0.tar.gz"
    curl --fail --silent --show-error --location --max-time 60 \
        https://github.com/nullstyle/capnp-zig/archive/refs/tags/v0.16.0.tar.gz -o "$archive"
    fetched="$(cd "$repo" && mise exec -- zig fetch --pkg-dir "$ZIG_LOCAL_PKG_DIR" "$archive")"
    if [[ "$fetched" != "$capnp_hash" ]]; then
        echo "Pinned capnp package hash mismatch: $fetched" >&2
        exit 1
    fi
    # This development compiler caches tarballs but preserves the archive root
    # when re-expanding them. Materialize the already-verified package at its
    # canonical local package path so dependency builds see build.zig.zon.
    mkdir -p "$ZIG_LOCAL_PKG_DIR/$capnp_hash"
    tar -xzf "$archive" --strip-components=1 -C "$ZIG_LOCAL_PKG_DIR/$capnp_hash"
fi
cd "$repo/examples/slcp-directory"
mise exec -- zig build test install --cache-dir "$ZIG_LOCAL_CACHE_DIR" "$@"
"$repo/examples/slcp-directory/run-processes.sh" "$PWD/zig-out/bin/slcp-directory-host" "$repo/.zig-cache"
