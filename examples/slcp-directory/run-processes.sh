#!/usr/bin/env bash
set -euo pipefail
binary="$1"
cache_root="$2"
run_root="$(mktemp -d "$cache_root/slcp-process.XXXXXX")"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM
fail() {
    echo "SLCP process fixture failed: $*" >&2
    for file in "$run_root"/*.log; do tail -40 "$file" >&2; done
    echo "Retained evidence: $run_root" >&2
    exit 1
}
check_alive() {
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null || fail "child $pid exited early"; done
}
wait_file() {
    local path="$1"
    local attempts=0
    until [[ -s "$path" ]]; do
        check_alive
        ((attempts += 1))
        [[ "$attempts" -le 1200 ]] || fail "timed out waiting for $path"
        sleep 0.1
    done
}
wait_advance() {
    local index="$1"
    local target="$2"
    local attempts=0
    local actual=0
    while [[ "$actual" -lt "$target" ]]; do
        check_alive
        if [[ -s "$run_root/node$index.status" ]]; then
            read -r actual rest < "$run_root/node$index.status"
        fi
        ((attempts += 1))
        [[ "$attempts" -le 1200 ]] || fail "node $index stopped at $actual while waiting for $target"
        sleep 0.1
    done
    [[ "$actual" -eq "$target" ]] || fail "node $index unexpectedly passed controlled advance $target"
}
set_target() {
    printf '%s\n' "$1" > "$run_root/target.next"
    mv "$run_root/target.next" "$run_root/target"
}
start_node() {
    local index="$1"
    local limit="$2"
    shift 2
    "$binary" "$run_root" "$index" "$limit" "$@" >> "$run_root/node$index.log" 2>&1 &
    pids[$index]=$!
    wait_file "$run_root/node$index.ready"
}
set_target 7
start_node 0 100
peer="$(cat "$run_root/node0.ready")"
start_node 1 100 "$peer"
start_node 2 7 "$peer"
for index in 0 1 2; do wait_advance "$index" 7; done
echo "[slcp-process] three nodes reached advance 7; node 2 checkpoint retained"
set_target 9
for index in 0 1 2; do wait_advance "$index" 9; done
victim="${pids[2]}"
kill -KILL "$victim"
set +e
wait "$victim" 2>/dev/null
killed_status=$?
set -e
unset 'pids[2]'
[[ "$killed_status" -eq 137 ]] || fail "SIGKILL child exit status was $killed_status"
echo "[slcp-process] SIGKILL confirmed at advance 9 (exit 137)"
set_target 11
for index in 0 1; do wait_advance "$index" 11; done
rm "$run_root/node2.ready"
start_node 2 7 "$peer"
wait_advance 2 11
grep -q '^BOOT 2 7$' "$run_root/node2.log" || fail "node 2 did not restore its advance-7 checkpoint"
echo "[slcp-process] restored checkpoint 7, replayed journal 8..9, caught up missing slots 10..11"
# Remove a survivor: the restarted node must vote to satisfy 2-of-3 at 12.
retired="${pids[1]}"
kill -TERM "$retired"
wait "$retired" 2>/dev/null || true
unset 'pids[1]'
set_target 12
for index in 0 2; do wait_advance "$index" 12; done
for advance in {1..11}; do
    for index in 1 2; do
        cmp "$run_root/node0-$advance.value" "$run_root/node$index-$advance.value" || fail "values diverged at advance $advance"
    done
done
cmp "$run_root/node0-12.value" "$run_root/node2-12.value" || fail "restarted voter diverged at advance 12"
echo "[slcp-process] exact commands, roots and headers agree; restarted voter formed quorum at 12"
echo "[slcp-process] evidence: $run_root"
