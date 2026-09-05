#!/usr/bin/env bash
set -euo pipefail
binary="$1"
cache="$2"
run_root="$(mktemp -d "$cache/slcp-disk-process.XXXXXX")"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM
fail() {
    echo "SLCP disk process fixture failed: $*" >&2
    for file in "$run_root"/*.log; do tail -50 "$file" >&2; done
    echo "Evidence retained: $run_root" >&2
    exit 1
}
check_alive() {
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null || fail "child $pid exited"; done
}
wait_file() {
    local path="$1" attempts=0
    until [[ -s "$path" ]]; do
        check_alive
        ((attempts += 1))
        [[ "$attempts" -le 2400 ]] || fail "timed out waiting for $path"
        sleep 0.1
    done
}
wait_advance() {
    local index="$1" target="$2" actual=0 attempts=0
    while [[ "$actual" -lt "$target" ]]; do
        check_alive
        if [[ -s "$run_root/node$index.status" ]]; then read -r actual rest < "$run_root/node$index.status"; fi
        ((attempts += 1))
        [[ "$attempts" -le 2400 ]] || fail "node $index at $actual waiting for $target"
        sleep 0.1
    done
    [[ "$actual" -eq "$target" ]] || fail "node $index passed controlled target $target"
}
wait_watermark() {
    local index="$1" target="$2" actual=0 attempts=0
    while [[ "$actual" -lt "$target" ]]; do
        check_alive
        if [[ -s "$run_root/node$index.watermark" ]]; then read -r actual < "$run_root/node$index.watermark"; fi
        ((attempts += 1))
        [[ "$attempts" -le 2400 ]] || fail "node $index watermark $actual waiting for $target"
        sleep 0.1
    done
    [[ "$actual" -eq "$target" ]] || fail "node $index acknowledged beyond durable target $target"
}
set_target() {
    printf '%s\n' "$1" > "$run_root/target.next"
    mv "$run_root/target.next" "$run_root/target"
}
start_node() {
    local index="$1"
    shift
    "$binary" "$run_root" "$index" "$@" >> "$run_root/node$index.log" 2>&1 &
    pids[$index]=$!
    wait_file "$run_root/node$index.ready"
}
compare() {
    local advance="$1"
    shift
    for index in "$@"; do
        cmp "$run_root/node0-$advance.value" "$run_root/node$index-$advance.value" || fail "durable roots/commands differ at $advance"
    done
}
set_target 7
start_node 0
peer="$(cat "$run_root/node0.ready")"
start_node 1 "$peer"
start_node 2 "$peer"
for index in 0 1 2; do wait_advance "$index" 7; wait_watermark "$index" 7; done
compare 7 1 2
rm -f "$run_root/node2.backpressure"
printf '1\n' > "$run_root/node2.pause"
wait_file "$run_root/node2.paused"
[[ "$(cat "$run_root/node2.paused")" == 1 ]] || fail "worker pause was not acknowledged"
set_target 11
wait_file "$run_root/node2.backpressure"
read -r durable accepted queued capacity < "$run_root/node2.backpressure"
[[ "$durable $accepted $queued $capacity" == '7 9 2 2' ]] || fail "unexpected pressure state: $durable $accepted $queued $capacity"
for index in 0 1; do wait_advance "$index" 11; done
compare 11 1
echo "[slcp-disk] bounded pressure: durable7, accepted9, queued2, journaled10; survivors11"
victim="${pids[2]}"
kill -KILL "$victim"
set +e
wait "$victim" 2>/dev/null
killed=$?
set -e
unset 'pids[2]'
[[ "$killed" -eq 137 ]] || fail "expected SIGKILL status137, got $killed"
printf '0\n' > "$run_root/node2.pause"
rm "$run_root/node2.ready"
set_target 12
for index in 0 1; do wait_advance "$index" 12; done
start_node 2 "$peer"
wait_advance 2 12
rg -q '^BOOT 2 7 replayed=3 accepted=10$' "$run_root/node2.log" || fail "restart did not replay exact journal8..10 from durable7"
compare 12 1 2
echo "[slcp-disk] SIGKILL137; restored7, replayed8..10, caught up missing11..12"
set_target 70
for index in 0 1 2; do wait_advance "$index" 70; wait_watermark "$index" 70; done
compare 70 1 2
retired="${pids[1]}"
kill -TERM "$retired"
wait "$retired" 2>/dev/null || true
unset 'pids[1]'
read -r first last count < <("$binary" --inspect-journal "$run_root/node1-journal")
[[ "$first" -gt 1 && "$first" -le 70 && "$last" -eq 70 ]] || fail "journal compaction was not exercised: $first $last $count"
echo "[slcp-disk] actual journal compaction retained $first..$last ($count values), durable70"
set_target 71
for index in 0 2; do wait_advance "$index" 71; wait_watermark "$index" 71; done
compare 71 2
echo "[slcp-disk] restarted voter formed quorum71; durable roots and exact commands agree"
echo "[slcp-disk] evidence: $run_root"
