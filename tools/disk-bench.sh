#!/usr/bin/env bash
# Run identical benchmark code against this checkout or a read-only source archive.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="${DISK_BENCH_SOURCE_DIR:-$repo}"
source_root="$(cd -- "$source_root" && pwd)"
optimize="${DISK_BENCH_OPTIMIZE:-ReleaseFast}"
[[ "$#" -ge 1 ]] || { echo 'Usage: disk-bench.sh <empty-store-root> [mib=64] [batch-rows=64] [read-samples=32] [trials=1]' >&2; exit 1; }
cache="$repo/.zig-cache/disk-bench"
mkdir -p "$cache/local" "$cache/global" "$cache/bin"
cd "$repo"
provenance="$(mise exec -- python - "$repo" "$source_root" "$optimize" "$@" <<'PY'
import hashlib, json, os, pathlib, platform, subprocess, sys
repo, source = map(pathlib.Path, sys.argv[1:3])
h = hashlib.sha256()
for directory in ('src', 'vectors'):
    for path in sorted((source / directory).rglob('*')):
        if path.is_file():
            relative = path.relative_to(source).as_posix().encode()
            data = path.read_bytes()
            h.update(len(relative).to_bytes(8, 'big')); h.update(relative)
            h.update(len(data).to_bytes(8, 'big')); h.update(data)
revision = None
for marker in ('.baseline-revision', '.source-revision'):
    if (source / marker).is_file(): revision = (source / marker).read_text().strip(); break
if revision is None:
    top = subprocess.run(['git', '-C', str(source), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if top.returncode == 0 and pathlib.Path(top.stdout.strip()).resolve() == source.resolve():
        result = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if result.returncode == 0: revision = result.stdout.strip()
cpu_model = platform.processor() or platform.machine()
if platform.system() == 'Darwin':
    result = subprocess.run(['sysctl', '-n', 'machdep.cpu.brand_string'], capture_output=True, text=True)
    if result.returncode == 0: cpu_model = result.stdout.strip()
try: memory_bytes = os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')
except (ValueError, OSError): memory_bytes = None
print(json.dumps(dict(phase='provenance', source_directory=str(source), source_revision=revision,
    library_tree_sha256=h.hexdigest(), benchmark_sha256=hashlib.sha256((repo/'tools/disk-bench.zig').read_bytes()).hexdigest(),
    optimize=sys.argv[3], arguments=sys.argv[4:], cpu_model=cpu_model,
    os_version=platform.mac_ver()[0] or platform.release(), physical_memory_bytes=memory_bytes)))
PY
)"
key="$(mise exec -- python -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:20])' "$provenance")"
binary="$cache/bin/$key"
mise exec -- zig build-exe "-O$optimize" \
    --dep bucketlist --dep bucketlist-disk "-Mroot=$repo/tools/disk-bench.zig" \
    "-O$optimize" --dep reference_vectors "-Mbucketlist=$source_root/src/lib.zig" \
    "-O$optimize" --dep bucketlist --dep bucketlist-store "-Mbucketlist-disk=$source_root/src/native.zig" \
    "-O$optimize" "-Mbucketlist-store=$source_root/src/store.zig" "-O$optimize" "-Mreference_vectors=$source_root/vectors/reference.zig" \
    --cache-dir "$cache/local" --global-cache-dir "$cache/global" "-femit-bin=$binary"
printf '%s\n' "$provenance"
exec "$binary" "$@"
