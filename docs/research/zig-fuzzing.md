# Coverage-guided fuzzing on the pinned Zig toolchain

Researched 2026-09-04 against `0.17.0-dev.1786+75044cb04`, commit
`75044cb04cc67454db98ed7c054081806c3830c6`. Nine inspected installed library
and runner files matched that commit byte for byte. The compiler checkout's
current HEAD differs, so findings below use the installed files and pinned
commit, not that checkout's current implementation.

**Recommendation:** use Zig's integrated fuzzer through a dedicated test build
step with LLVM. Native macOS ARM64 works on this pin. Before using it as a gate,
wrap its output and preserve its mapped input files: an isolated probe found
that a discovered failure can still exit successfully and that the advertised
crash file can be empty. No compiler or library changes were made during this
research.

## Test and build interfaces

The callback receives `*std.testing.Smith`, not a raw byte slice. A bounded byte
target can use this pattern:

```zig
fn one(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    try checkInput(input);
}

test "bounded parser" {
    try std.testing.fuzz({}, one, .{
        .corpus = &.{"\x03\x00\x00\x00abc"},
    });
}
```

`Smith.slice` consumes a little-endian `u32` length followed by bytes during
replay. Consequently, raw protocol fixtures need that length prefix; a saved
Smith replay input already contains it. Multiple Smith calls consume a sequence
of encoded values. Ordinary non-fuzz tests execute the supplied corpus and an
empty input. Fuzz mode resets the testing allocator per input and treats leaks,
unexpected errors, and error logs as failures. [Testing API](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/std/testing.zig#L1222),
[Smith slice replay](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/std/testing/Smith.zig#L623),
[runner implementation](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/test_runner.zig#L534).

Create an ordinary `b.addTest`, set `.use_llvm = true`, then connect
`b.addRunArtifact(t)` to a dedicated step. Do not set the test root permanently
to `.fuzz = true`: the build runner first discovers fuzz tests in an ordinary
run, then rebuilds them with instrumentation. Explicit `.fuzz = false` on an
imported module prevents instrumentation there; otherwise module fuzz settings
inherit from the parent. [Rebuild orchestration](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Fuzz.zig#L91),
[instrumented compiler arguments](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Step/Compile.zig#L185),
[module inheritance](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/src/Module.zig#L238).

```sh
mise exec -- zig build coverage-test -Doptimize=ReleaseSafe \
  --fuzz=10000 --seed=1 --summary all --color off
```

Here `coverage-test` is a proposed project step name. `--fuzz=N` limits mutation
cycles per fuzz test, accepts decimal `K`, `M`, and `G` suffixes, and does not
mean seconds. Initial/corpus executions can make reported runs exceed `N`.
The build seed is a `u32`; the large `u64` seed used by the separate randomized
native executable cannot be reused verbatim. Bare `--fuzz` runs indefinitely
and enables the Web UI. Limited mode rejects `--webui` and uses one fuzzer
process per run artifact; unlimited mode uses `-j` for process count.
[Argument parser](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker.zig#L481),
[seed parser](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker.zig#L3808),
[per-test limit](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/fuzzer.zig#L839),
[process count](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Step/Run.zig#L629).

Use an external process-group watchdog for a wall-clock deadline. The ordinary
`--test-timeout` path is bypassed when the runner enters fuzz mode. Killing only
the outer build process may leave its children running. Direct execution of a
`zig test -ffuzz` binary is also unsuitable: the terminal runner panics because
fuzz mode requires the build-runner server protocol. [Runner dispatch](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Step/Run.zig#L1129),
[terminal restriction](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/test_runner.zig#L260).

## Platform and observed coverage

The self-hosted ARM64 test runner uses `need_simple`, which skips
`std.testing.fuzz`; the fuzz rebuild preserves backend selection. LLVM is
therefore required for this project's ARM64 targets. The runtime supports
ELF and Mach-O; the build runner explicitly rejects Windows and 32-bit hosts.
Linux ARM64 is supported by these code paths but was **not runtime-tested in
this research sprint** (validated on 2026-09-05; see the last section).
[Simple-runner backend selection](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/test_runner.zig#L27),
[object formats](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/fuzzer.zig#L182),
[host restrictions](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker.zig#L2418).

A separate temporary project on `aarch64-macos.26.6.2...26.6.2-none`, using
ReleaseSafe and `.use_llvm = true`, passed `zig build test --fuzz=32 --seed=1
--summary all`:

```text
Runs: 0 -> 35
Unique runs: 0 -> 2
Coverage: 0/8065 -> 16/8065 (0.20%)
Build Summary: 3/3 steps succeeded; 1/1 tests passed
```

This proves the pinned integration works on native macOS ARM64; the tiny probe
does not measure BucketList coverage. The report counts instrumented program
counters and accumulates across preserved caches. Capture the complete report,
before/after counters, compiler/source hashes, seed, and cache policy. Use a
fresh local cache for independent campaigns. Corpus state lives under cache
`f/<test-name-hash>/`; coverage is shared through mapped cache files.
[Report generation](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Fuzz.zig#L598),
[corpus ownership](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/fuzzer.zig#L791).

## Confirmed runner defects and replay workaround

A synthetic target returned `error.ProbeFailure` when the first generated byte
equaled `42`; its ordinary seed contained `41`. With `--fuzz=5000 --seed=1`, the
fuzzer discovered the failure after 147 reported runs. Observed results:

1. The runner printed `run test failure` and `input saved`, but the outer build
   exited **0** and its final summary still reported success. The build tallies
   step failures before the later fuzz phase; the fuzz worker prints its failure
   and returns. A gate must inspect failure diagnostics as well as exit status.
   [Build tally ordering](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker.zig#L2378),
   [fuzz worker failure handling](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Fuzz.zig#L248).
2. The advertised `f/crash` was **zero bytes**. The source creates a buffered
   writer and returns after copying without flushing it. The mapped `f/in0`
   still contained the full 116-byte serialized input. [Crash copy](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/compiler/Maker/Step/Run.zig#L1010).

The mapped input header is exactly 20 bytes: little-endian `<QIII>` containing
coverage digest, instance ID, test index, and input length. Preserve the entire
file, validate that length against the file size and a local cap, then extract
`file[20:20+length]`. Preserve its identifiers so multiple fuzz tests/artifacts
can be distinguished. Do this before another run reuses the cache.
[Pinned input ABI](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/std/Build/abi.zig#L364).

**Correction from integration (2026-09-05):** `f/in*` is a fixed-size mapped
buffer (16,384 bytes observed on this pin), not a length-exact file. The
correct validation is `20 + length <= file size`; the input is
`file[20:20+length]` and trailing bytes are padding to be ignored. A strict
equality check rejects valid crash inputs. The buffer is allocated in
`lib/fuzzer.zig`'s `serveRun`/input-mapping path alongside
`MmapInputHeader`.

Limited mode also gives **each fuzz test in a run artifact its own N-cycle
budget**; tests in one binary share a single coverage map and one report block
that the runner labels with the first test's name
(`run.fuzz_tests.items[0]` in `waitAndPrintReport`). A 300-cycle run over three
tests therefore reports one block whose `Runs` total covers all of them, and
the mapped-header test index (declaration order within the binary) is what
distinguishes which test a recovered input belongs to.

For the probe, the header was coverage `c481ee4dc742aa8a`, instance `0`, test
`0`, length `116`. The payload begins with little-endian length `112` and byte
`42`. Embedding that extracted payload through `.corpus` made ordinary
non-fuzz `zig build test` exit **1** and fail the same test. That runner printed
`failed without output`, so replay proves test failure without preserving the
original error-name diagnostic.

Copy replay inputs into a stable regression corpus and rerun without `--fuzz`.
No dedicated crash-minimization CLI was found on this pin. The engine discards
unhelpful generated corpus inputs, but this is not automatic minimization of a
crashing input. Use a separate deterministic reducer if needed, preserving
Smith framing and requiring the same failure on replay. Official release notes
also recommend embedded corpus entries for crash reproduction.
[Corpus pruning](https://github.com/nullstyle/zig/blob/75044cb04cc67454db98ed7c054081806c3830c6/lib/fuzzer.zig#L1085),
[official Smith and replay overview](https://ziglang.org/download/0.16.0/release-notes.html#Fuzzer).

Local scratch evidence remains under `.zig-cache/zig-fuzz-probe-szdtvozh`.
Logs are `.zig-cache/zig-fuzz-probe.log`, `zig-fuzz-crash-probe.log`,
`zig-fuzz-replay-probe.log`, and `zig-fuzz-recovered-probe.log`. They are
untracked research artifacts. No research processes remain running. Follow-up
status as of 2026-09-05: Linux ARM64 runtime validation and the wrapper
self-test for the false-success defect are done — see the section below and
[fuzzing.md](../fuzzing.md). Compiler fixes for the runner defects remain
out of scope for this repository.

## Linux ARM64 runtime validation (2026-09-05)

The pinned integration was runtime-validated on native Linux ARM64 in a
disposable Docker container (OrbStack, `ghcr.io/jdx/mise:2026.8.10`, Debian
13 trixie, same pinned compiler `0.17.0-dev.1786+75044cb04`). A scratch
driver ran the fail-closed wrapper's self-test and three library campaigns —
seeds `1`, `20260904`, `305419896`, 100,000 mutation cycles per test, fresh
dedicated cache per campaign, 1,200-second watchdog per invocation:

- **Self-test:** the armed probe failed after 68 runs with the usual zero
  build exit; the wrapper recovered the 45-byte Smith-framed input (`f/crash`
  happened to hold the same 45 bytes this time but remains untrusted) and the
  exact replay reproduced `SyntheticProbeFailure`.
- **Campaigns:** 301,513 / 301,450 / 301,499 runs with 1,295 / 1,231 / 1,280
  unique inputs; every build passed 3/3 tests with no failure diagnostics and
  no watchdog expiry (50–55 seconds per campaign).
- Linux instruments 12,384 program counters versus 11,188 on macOS;
  cross-platform percentages are not comparable.
- The consolidated single-report behavior documented above appeared
  identically on Linux — one report block naming `codec`, counters summed
  across tests. A scratch-driver assertion that wrongly demanded three
  per-test report names aborted the first driver attempt after the seed-1
  campaign; the preserved runtime evidence was re-verified in place and the
  remaining campaigns completed. This was a driver-expectation bug, not a
  runner difference.

Tracked counters and provenance are in [guided-linux.jsonl](../fuzz/guided-linux.jsonl);
full untracked artifacts (build/replay logs, reports, recovered mapped
inputs, driver results and both campaign logs) are under
`.zig-cache/linux-guided-20260905T021131Z/results/`.
