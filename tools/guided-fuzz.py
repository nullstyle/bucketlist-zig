#!/usr/bin/env python3
"""Bounded, fail-closed orchestration for LLVM coverage-guided campaigns.

The pinned build runner can exit zero after a discovered fuzz failure, and its
advertised ``f/crash`` file can be empty. This wrapper therefore never trusts
the process status or the crash file alone: it scans the captured log for
failure diagnostics, preserves the campaign's mapped inputs before anything can
reuse them, validates the 20-byte input ABI, and replays every recovered input
exactly through the same Guided oracle via ``zig build fuzz-portable``.

Exit codes:
  0  clean bounded campaign (no failure diagnostics, build exit 0, no expiry)
  1  wrapper misuse or self-test failure
  2  recovery failed: diagnostics found but no valid mapped input
  3  watchdog expired before the build finished (inconclusive, not success)
  4  build failed without fuzz-failure diagnostics
  5  recovered input(s) did not replay the reported failure
  7  fuzz failure found, recovered, and exactly reproduced (a real finding)

Usage:
  python3 tools/guided-fuzz.py --cycles 20000 --seed 1 --timeout 1200
  python3 tools/guided-fuzz.py --self-test
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

FAILURE_DIAGNOSTICS = [
    re.compile(r"^\+- run test failure", re.MULTILINE),
    re.compile(r"^failed with error\.\S+", re.MULTILINE),
    re.compile(r"error: test '[^']+' exited with code \d+; input saved to '([^']+)'", re.MULTILINE),
]
ERROR_NAME = re.compile(r"^failed with error\.(\S+)", re.MULTILINE)
FUZZ_TEST = re.compile(r'^Fuzz test: "([^"]+)" \(([0-9a-f]+)\)', re.MULTILINE)
REPORT_BEGIN = "======= FUZZING REPORT ======="
MAPPED_HEADER = struct.Struct("<QIII")  # coverage digest, instance, test index, length
MAX_SMITH_INPUT = 4 + 64 * 1024  # u32 length frame plus the 64 KiB parser cap

EXIT_CLEAN = 0
EXIT_MISUSE = 1
EXIT_RECOVERY_FAILED = 2
EXIT_WATCHDOG = 3
EXIT_BUILD_FAILED = 4
EXIT_NOT_REPRODUCED = 5
EXIT_FOUND_FAILURE = 7

# Test-name suffixes map to replay targets; declaration order is the build's
# fuzz-test order, which is what the mapped-header test index counts.
TARGET_BY_SUFFIX = {
    "codec": "codec",
    "bucket": "bucket",
    "checkpoint": "checkpoint",
    "proof": "proof",
    "synthetic failure": "probe",
}


def log(message: str) -> None:
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    print(f"[guided-fuzz {stamp}] {message}", flush=True)


def run_mise(args: list[str], **kwargs) -> subprocess.Popen:
    return subprocess.Popen(
        ["mise", "exec", "--", *args], cwd=REPO, start_new_session=True, **kwargs
    )


def wait_with_watchdog(process: subprocess.Popen, timeout: float, log_file) -> tuple[int, bool, bytes]:
    """Wait for the process group, killing it on deadline. Returns (exit, expired, tail)."""
    deadline = time.monotonic() + timeout
    expired = False
    while True:
        code = process.poll()
        if code is not None:
            break
        if time.monotonic() > deadline:
            expired = True
            log(f"watchdog expired after {timeout:.0f}s; killing process group {process.pid}")
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            break
        time.sleep(0.5)
    return process.returncode if process.returncode is not None else -9, expired, b""


def zig_version() -> str:
    return subprocess.run(
        ["mise", "exec", "--", "zig", "version"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout.strip()


def git_state() -> dict:
    def git(*args: str) -> str:
        return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True).stdout.strip()

    return {
        "commit": git("rev-parse", "HEAD"),
        "dirty_files": len(git("status", "--porcelain").splitlines()),
        "subject": git("log", "-1", "--format=%s"),
    }


def parse_mapped(path: Path) -> dict:
    entry = {"file": path.name, "valid": False, "coverage": None, "instance": None,
             "test_index": None, "length": None, "size": path.stat().st_size, "test_name": None,
             "target": None, "error": None}
    try:
        with path.open("rb") as handle:
            blob = handle.read()
        if len(blob) < MAPPED_HEADER.size:
            entry["error"] = "truncated_header"
            return entry
        coverage, instance, test_index, length = MAPPED_HEADER.unpack_from(blob)
        entry.update(coverage=f"{coverage:016x}", instance=instance, test_index=test_index, length=length)
        if length > MAX_SMITH_INPUT:
            entry["error"] = "length_above_cap"
            return entry
        if len(blob) < MAPPED_HEADER.size + length:
            entry["error"] = "truncated_input"
            return entry
        # The mapped file is a fixed-size buffer; bytes past the input are padding.
        entry["valid"] = True
        entry["padding"] = len(blob) - MAPPED_HEADER.size - length
    except OSError as err:
        entry["error"] = f"read_failed:{err}"
    return entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cycles", type=int, default=20000, help="mutation cycles per fuzz test (--fuzz=N)")
    parser.add_argument("--seed", type=lambda v: int(v, 0), default=1, help="u32 build seed")
    parser.add_argument("--timeout", type=float, default=1200, help="wall-clock watchdog seconds")
    parser.add_argument("--step", default="guided-coverage", help="zig build step to run")
    parser.add_argument("--optimize", default="ReleaseSafe")
    parser.add_argument("--artifacts", default=None, help="artifact directory (default: .zig-cache/guided-fuzz/<stamp>)")
    parser.add_argument("--extra-build-arg", action="append", default=[], help="additional zig build argument")
    parser.add_argument("--replay-target", default=None, help="force replay target (codec|bucket|checkpoint|probe)")
    parser.add_argument("--self-test", action="store_true", help="drive the synthetic probe end to end and require fail-closed behavior")
    args = parser.parse_args()

    if not 0 <= args.seed <= 0xFFFFFFFF:
        log("seed must fit in u32")
        return EXIT_MISUSE
    if args.cycles <= 0:
        log("cycles must be positive")
        return EXIT_MISUSE

    expected_error = None
    extra_build_args = list(args.extra_build_arg)
    replay_target = args.replay_target
    if args.self_test:
        args.step = "guided-probe-coverage"
        if args.cycles == 20000:
            args.cycles = 5000
        if args.timeout == 1200:
            args.timeout = 600
        extra_build_args += ["-Dguided-probe=true"]
        replay_target = replay_target or "probe"
        expected_error = "SyntheticProbeFailure"

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    artifacts = Path(args.artifacts) if args.artifacts else REPO / ".zig-cache" / "guided-fuzz" / f"{stamp}-{args.step}-s{args.seed}"
    artifacts.mkdir(parents=True, exist_ok=True)
    cache_dir = artifacts / "zig-cache"
    log_path = artifacts / "build.log"

    build_command = [
        "zig", "build", args.step,
        f"-Doptimize={args.optimize}",
        f"--fuzz={args.cycles}", f"--seed={args.seed}",
        "--summary", "all", "--color", "off",
        "--cache-dir", str(cache_dir),
        *extra_build_args,
    ]
    provenance = {
        "started_utc": stamp,
        "step": args.step,
        "cycles": args.cycles,
        "seed": args.seed,
        "timeout_seconds": args.timeout,
        "optimize": args.optimize,
        "build_command": build_command,
        "zig_version": zig_version(),
        "git": git_state(),
        "self_test": args.self_test,
    }
    (artifacts / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    log(f"artifacts: {artifacts.relative_to(REPO)}")
    log(f"campaign: {' '.join(build_command)}")

    with log_path.open("wb") as log_file:
        process = run_mise(build_command, stdout=log_file, stderr=subprocess.STDOUT)
        code, expired, _ = wait_with_watchdog(process, args.timeout, log_file)
    text = log_path.read_text(errors="replace")
    diagnostics = [pattern.search(text) for pattern in FAILURE_DIAGNOSTICS]
    found_failure = any(match is not None for match in diagnostics)
    error_names = ERROR_NAME.findall(text)
    fuzz_tests = FUZZ_TEST.findall(text)
    report = text[text.index(REPORT_BEGIN):].strip() if REPORT_BEGIN in text else ""
    (artifacts / "report.txt").write_text(report + "\n" if report else "no fuzzing report captured\n")
    log(f"build exit={code} watchdog_expired={expired} failure_diagnostics={found_failure}")
    if fuzz_tests:
        log("fuzz tests: " + ", ".join(f"{name} ({digest})" for name, digest in fuzz_tests))

    # Preserve every mapped input before anything can reuse the fresh cache.
    recovered: list[dict] = []
    crash_entry = None
    fdir = cache_dir / "f"
    if fdir.is_dir():
        preserved = artifacts / "recovered"
        preserved.mkdir(exist_ok=True)
        for entry_path in sorted(fdir.iterdir()):
            if entry_path.name == "crash":
                crash_entry = {"file": "f/crash", "size": entry_path.stat().st_size}
                (preserved / "crash").write_bytes(entry_path.read_bytes())
                continue
            if not entry_path.name.startswith("in"):
                continue
            entry = parse_mapped(entry_path)
            blob = entry_path.read_bytes()
            if entry["valid"]:
                (preserved / f"{entry_path.name}.mapped").write_bytes(blob)
                (preserved / f"{entry_path.name}.smith").write_bytes(
                    blob[MAPPED_HEADER.size:MAPPED_HEADER.size + entry["length"]])
                if fuzz_tests and entry["test_index"] is not None and entry["test_index"] < len(fuzz_tests):
                    name = fuzz_tests[entry["test_index"]][0]
                    entry["test_name"] = name
                    for suffix, target in TARGET_BY_SUFFIX.items():
                        if name.endswith(suffix):
                            entry["target"] = target
            recovered.append(entry)
    (artifacts / "recovered.json").write_text(json.dumps(
        {"crash_file": crash_entry, "inputs": recovered, "expected_error": expected_error}, indent=2) + "\n")
    if crash_entry is not None:
        log(f"crash file size: {crash_entry['size']} bytes (known runner defect: often empty; not trusted)")
    log(f"recovered mapped inputs: {len(recovered)} "
        f"({sum(1 for r in recovered if r['valid'])} valid, {sum(1 for r in recovered if not r['valid'])} invalid)")

    def finish(exit_code: int, summary: str) -> int:
        (artifacts / "verdict.txt").write_text(f"exit={exit_code}\n{summary}\n")
        log(f"exit {exit_code}: {summary}")
        log(f"full log and artifacts: {artifacts.relative_to(REPO)}")
        return exit_code

    if expired and not found_failure:
        return finish(EXIT_WATCHDOG, "watchdog expired without a completed campaign; inconclusive")
    if found_failure:
        valid = [r for r in recovered if r["valid"]]
        if not valid:
            return finish(EXIT_RECOVERY_FAILED,
                          "failure diagnostics present but no valid mapped input was recovered")
        candidates = sorted({name for name in error_names})
        wanted = expected_error or (candidates[0] if candidates else "any")
        reproduced: list[dict] = []
        replay_dir = artifacts / "replay"
        replay_dir.mkdir(exist_ok=True)
        for entry in valid:
            target = replay_target or entry.get("target")
            if target is None:
                # Ambiguous identity: try every library target and require a match.
                for candidate in ("codec", "bucket", "checkpoint"):
                    if replay_reproduces(replay_dir, entry, candidate, wanted, extra_build_args):
                        entry["replayed_as"] = candidate
                        reproduced.append(entry)
                        break
                continue
            if replay_reproduces(replay_dir, entry, target, wanted, extra_build_args):
                entry["replayed_as"] = target
                reproduced.append(entry)
        (artifacts / "recovered.json").write_text(json.dumps(
            {"crash_file": crash_entry, "inputs": recovered, "expected_error": wanted,
             "reproduced": bool(reproduced)}, indent=2) + "\n")
        if not reproduced:
            return finish(EXIT_NOT_REPRODUCED,
                          f"failure (error {wanted}) did not replay exactly; artifacts preserved for diagnosis")
        summary = (f"fuzz failure found, recovered, and reproduced: error={wanted}; "
                   f"tests={sorted({r['test_name'] or '?' for r in reproduced})}; "
                   f"input={reproduced[0]['file']}; replay via "
                   f"zig build fuzz-portable -- --replay-target {reproduced[0].get('replayed_as')} "
                   f"--replay-mapped {artifacts / 'recovered' / (reproduced[0]['file'] + '.mapped')} --expect-error {wanted}")
        if args.self_test:
            log("SELF-TEST PASS: wrapper stayed fail-closed through a synthetic discovered failure")
            # The synthetic failure was expected; the wrapper itself worked, so
            # the self-test exits clean rather than as a real finding.
            return finish(EXIT_CLEAN, "self-test " + summary)
        return finish(EXIT_FOUND_FAILURE, summary)

    if code != 0:
        return finish(EXIT_BUILD_FAILED, f"build exited {code} without fuzz-failure diagnostics")
    if args.self_test:
        log("SELF-TEST FAIL: the armed probe campaign completed without discovering the synthetic failure")
        return finish(EXIT_MISUSE, "self-test expected a discovered failure; check --cycles/--seed")
    return finish(EXIT_CLEAN, "bounded campaign completed with no failure diagnostics")


def replay_reproduces(replay_dir: Path, entry: dict, target: str, wanted_error: str, extra_build_args: list[str]) -> bool:
    mapped = replay_dir.parent / "recovered" / f"{entry['file']}.mapped"
    replay_log = replay_dir / f"{entry['file']}-{target}.log"
    command = [
        "zig", "build", "fuzz-portable", "-Doptimize=ReleaseSafe", "--summary", "all", "--color", "off",
        *extra_build_args, "--",
        "--replay-target", target, "--replay-mapped", str(mapped), "--expect-error", wanted_error,
    ]
    with replay_log.open("wb") as handle:
        process = run_mise(command, stdout=handle, stderr=subprocess.STDOUT)
        code, _, _ = wait_with_watchdog(process, 300, handle)
    ok = code == 0
    log(f"replay {entry['file']} as {target} expecting {wanted_error}: exit={code} {'OK' if ok else 'no match'}")
    return ok


if __name__ == "__main__":
    sys.exit(main())
