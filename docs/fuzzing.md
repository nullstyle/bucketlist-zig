# Deterministic parser campaigns

The ordinary `zig build test` gate includes a 1,000-case portable campaign,
exhaustive allocation failures through one checkpoint continuation, the fixed
guided corpus described below, and 100 native cases. Longer seeded runs are
explicit. The bounded mutation tests are not exhaustive input search; the
guided campaigns are coverage-guided exploration. The formats and interfaces
remain Experimental.

## Coverage

The portable harness exercises canonical codecs, buckets, and typed checkpoint
restoration. Its corpus contains 39 checkpoints from depths 1, 3, and 11 at
13 sequence boundaries through advance 128, including empty advances, repeated
changes, deletions, and pending merges. Mutations cover framing, counts,
lengths, ordering, duplicate keys, tags, table identity, typed bool/enum/Bytes
encodings, schema/profile headers, and continuation shape.

Canonical inputs must be accepted unless allocation failure is deliberately
injected. Known-invalid cases must be rejected. Accepted buckets are checked
against a separate framing scanner and SHA-256 computation, then reencoded
exactly. The harness independently calculates candidate checkpoint hashes from
raw inner frames so mutations reach typed and topology validation. This is a
test technique; deriving an expected hash from the input does not establish
application trust.

Accepted checkpoints reencode exactly and execute another advance. Unchanged
ones are compared with retained states built before serialization; valid mutated
ones are compared with a second restoration. Per-case allocation accounting
enforces a 1 MiB live budget, sometimes reduced to 256 bytes, injects failures,
and requires all temporary allocations to be freed. Corpus construction and
retained reference states are outside that per-case budget.

The native harness cycles through 25 categories using private synthetic stores.
An independent fixed-size model checks bucket scans, point reads, reencoding,
and merges. Disk cases cover valid historical references and changed metadata,
malformed manifest framing, schema/profile mismatch, missing buckets, invalid
typed values, unknown tables, and incorrect pending outputs. Mutated blobs have
their correct SHA-256 filenames, and outer commitments are recomputed where
framing permits. Rejected retained roots must leave the current catalog and a
sentinel blob intact; reopen must neither repair nor publish a rejected catalog.
The committed baseline is restored and verified after each case.

Native sample buffers are at most 1,024 bytes per bucket and 2,048 bytes per
manifest, with at most 16 records and 8-byte keys/values. A debug allocator checks
for leaks. Each run exclusively creates its temporary root and removes only
that root. An existing supplied path is rejected unchanged. No network service,
external database, or caller's existing store is exercised.

## Recorded campaigns

On macOS ARM64 with the mise-pinned compiler, ReleaseSafe campaigns use seeds
`1`, `11400714819323198485`, and `20260904`. Raw counters and exact source/compiler
provenance are in [portable.jsonl](fuzz/portable.jsonl) and
[native.jsonl](fuzz/native.jsonl). Counts describe executed cases, not unique
inputs or measured source coverage. Unexpected errors fail the run; intentional
allocation failures are counted separately from malformed-input rejection.

The portable campaign executes **300,000 cases total** across the three seeds:

| Parser | Accepted | Rejected | Injected OOM |
| --- | ---: | ---: | ---: |
| Codec | 34,787 | 65,215 | 0 |
| Bucket | 37,284 | 59,748 | 2,967 |
| Checkpoint | 17,113 | 78,968 | 3,918 |

All 17,113 accepted checkpoints continue successfully; 11,793 are compared
with retained live states, and 5,320 are accepted mutated checkpoints. The
largest per-case allocation peak is **41,081 bytes**, excluding the corpus and
retained references described above. All 6,885 intentional allocation failures
clean up correctly.

The native campaign executes **30,000 cases total**, with **5,094 accepted** and
**24,906 rejected** as expected. Each of the 25 categories runs 400 times per
seed. There are no mismatches or allocation leaks, source hashes remain
unchanged after execution, and all three private store roots are removed.
The three processes ran concurrently and took about 18.5 minutes each, with
other verification work overlapping. Those durations measure a durability-heavy
correctness campaign, not storage throughput.

## Coverage-guided campaigns

The same `Guided` oracle runs under Zig's integrated LLVM fuzzer on this
repository's pinned compiler on macOS and native Linux ARM64 (the self-hosted
AArch64 backend silently skips `std.testing.fuzz`, so the guided artifacts set
`use_llvm`).
Four fuzz tests — codec, bucket, checkpoint, and proof — execute a fixed seed corpus
derived from the deterministic corpus above: codec boundary values, empty and
framed buckets, all 39 checkpoint fixtures with a depth selector byte, and two
deliberate >128-record seeds. The ordinary `guided-coverage` step (included in
`test` through `fuzz-smoke`) runs that corpus and fails if a backend skips it.

Sustained campaigns go through `tools/guided-fuzz.py`, a fail-closed wrapper
that exists because the pinned build runner can exit **zero** after a
discovered fuzz failure and its `f/crash` file can be **empty**. The wrapper:

- runs `zig build guided-coverage --fuzz=N --seed=S` in a **fresh dedicated
  cache** under a wall-clock process-group watchdog (`--fuzz=N` bounds mutation
  cycles per test, not wall time);
- scans the captured log for failure diagnostics regardless of process status;
- preserves the campaign's mapped inputs (`f/in*`: 20-byte little-endian
  `<QIII>` header, then the Smith-framed input; trailing bytes are padding)
  before anything reuses the cache, validating `20 + length <= file size`;
- maps each recovered input to its test via the header test index and the
  report's fuzz-test list;
- replays every recovered input **exactly** through `zig build fuzz-portable --
  --replay-target T --replay-mapped F --expect-error E` and exits nonzero
  unless the reported failure reproduces.

Exit codes distinguish clean completion (0), recovery failure (2), watchdog
expiry (3), non-fuzz build failure (4), non-reproducing findings (5), and a
reproduced finding (7). `just guided-self-test` arms a synthetic
`-Dguided-probe=true` target that fails when its first input byte is 42 and
requires the wrapper to catch the zero-exit failure, recover the input, and
replay it exactly; it is part of `just preflight`.

```sh
mise exec -- just guided-smoke      # fixed corpus through LLVM
mise exec -- just guided-fuzz 100000 1
mise exec -- just guided-self-test
```

Replay tooling is shared, not duplicated: raw inputs take `--replay-raw`,
Smith-framed inputs `--replay-smith`, and fuzzer cache files `--replay-mapped`;
`--expect accepted|rejected|oom` or `--expect-error NAME` assert the outcome.
The proof target shapes a deterministic v2 fixture from the input bytes,
requires the honestly built membership proof to verify against its digest,
and requires one of nine selector-picked forgeries to be rejected.
A real finding is minimized by hand into a checked-in corpus entry with the
replay command recorded; no automatic crash minimization exists on this pin.

### Recorded guided campaigns

Build seeds are u32, so the deterministic campaigns'
`11400714819323198485` cannot be reused verbatim; the guided seeds are `1`,
`20260904`, and `305419896` at 100,000 mutation cycles per test per campaign,
ReleaseSafe, with a fresh cache per campaign. The pinned build runner
consolidates every fuzz test in a step into a single report block naming the
first test, with counters accumulated across tests, so `Runs` totals all three
tests ([research detail](research/zig-fuzzing.md)).

**macOS ARM64** — 23 seconds per campaign; most mutated inputs are rejected by
early framing checks:

| Seed | Runs | Unique inputs | Coverage |
| --- | ---: | ---: | --- |
| 1 | 301,526 | 1,308 | 1511/11188 (13.51%) |
| 20260904 | 301,525 | 1,307 | 1510/11188 (13.50%) |
| 305419896 | 301,476 | 1,258 | 1509/11188 (13.49%) |

No campaign reported failure diagnostics, so no input required recovery or
replay. Per-seed macOS artifacts (provenance, report, mapped inputs) are
preserved under `.zig-cache/guided-fuzz/` in the working tree.

**Linux ARM64** — native-architecture Docker container (OrbStack,
`ghcr.io/jdx/mise:2026.8.10`, Debian 13 trixie), same pinned compiler,
1,200-second watchdog per invocation; campaigns finished in 50–55 seconds
each:

| Seed | Runs | Unique inputs | Coverage |
| --- | ---: | ---: | --- |
| 1 | 301,513 | 1,295 | 1525/12384 (12.31%) |
| 20260904 | 301,450 | 1,231 | 1525/12384 (12.31%) |
| 305419896 | 301,499 | 1,280 | 1534/12384 (12.39%) |

The wrapper self-test ran first on Linux: the armed synthetic probe failed
after 68 runs with the usual zero build exit, the wrapper recovered the
45-byte Smith-framed input, and the exact replay reproduced
`SyntheticProbeFailure`. Every library campaign passed 3/3 tests with no
failure diagnostics and no watchdog expiry. Exact provenance and counters are
tracked in [guided-linux.jsonl](fuzz/guided-linux.jsonl); full artifacts
(build and replay logs, reports, recovered mapped inputs, driver results) are
preserved under `.zig-cache/linux-guided-20260905T021131Z/results/` in the
working tree. Reproduce on any native Linux ARM64 host with the repo-pinned
mise tools via `mise exec -- just guided-self-test` and
`mise exec -- just guided-fuzz 100000 1`, or inside a container such as:

```sh
docker run --rm -v "$PWD:/work" -w /work ghcr.io/jdx/mise:2026.8.10 \
  sh -c 'git config --global --add safe.directory /work &&
         mise exec -- just guided-self-test && mise exec -- just guided-fuzz 100000 1'
```

Coverage counts instrumented program counters in the whole test binary —
shared by all three tests and dominated by code these entry points cannot
reach — and is not library-statement coverage. Linux instruments 12,384
counters versus 11,188 on macOS, so percentages are not comparable across
platforms; each platform's plateau reflects that shared-binary ceiling, not
an explored limit of the library.

### Extended soak campaigns

Both platforms then ran the same harness at one hundred times that budget —
10,000,000 cycles per test, three fresh seeds (`20260905`, `8675309`,
`424242`), fresh cache per campaign, 7,200-second watchdogs, at the same
pinned commit:

| Platform | Seed | Runs | Unique inputs | Coverage | Active time |
| --- | --- | ---: | ---: | --- | ---: |
| macOS | 20260905 | 30,011,429 | 11,211 | 1542/11188 (13.78%) | 18.5 min |
| macOS | 8675309 | 30,014,853 | 14,635 | 1541/11188 (13.77%) | 18.0 min |
| macOS | 424242 | 30,011,488 | 11,270 | 1538/11188 (13.75%) | 21.0 min |
| Linux | 20260905 | 30,010,471 | 10,222 | 1554/12384 (12.55%) | 46.7 min |
| Linux | 8675309 | 30,010,513 | 10,258 | 1557/12384 (12.57%) | 46.7 min |
| Linux | 424242 | 30,012,320 | 12,071 | 1556/12384 (12.56%) | 46.8 min |

Across both platforms that is **180,071,074 runs** with no failure
diagnostics, no watchdog expiry, and 3/3 tests passing in every build. The
soak-opening self-tests again recovered and exactly replayed the synthetic
probe (135 runs on macOS with the usual empty crash file; 68 runs on Linux,
repeating the bounded campaign's probe byte for byte). Counters and
provenance are tracked in [guided-soak-macos.jsonl](fuzz/guided-soak-macos.jsonl)
and [guided-soak-linux.jsonl](fuzz/guided-soak-linux.jsonl); artifacts are
under `.zig-cache/guided-soak-{macos,linux}-20260905T050212Z/`. The Linux
soak survived two recorded environment incidents — a host sleep that wedged
the container engine, and an untracked evidence file that briefly broke the
driver's clean-tree invariant; affected partial runs are preserved in the
artifact directory and every counted row ran against the clean pinned tree.
Elapsed times are monotonic active time and exclude the sleep.

## Run and replay

```sh
mise exec -- just fuzz-smoke
mise exec -- just fuzz-portable 100000 1
mise exec -- just fuzz-native 10000 1
```

The equivalent build targets accept these arguments:

```sh
mise exec -- zig build fuzz-portable -Doptimize=ReleaseSafe -- --iterations 100000 --seed 1
mise exec -- zig build fuzz-native -Doptimize=ReleaseSafe -- 10000 1
```

A failing run prints its seed and zero-based case index, plus the target or
category. Reuse that seed and set iterations to `case_index + 1` to reproduce
the prefix. Portable results are deterministic; the recorded seed-1 1,000-case
run was repeated with byte-identical output. Native roots use random names but
their samples and outcomes depend on the seed. The optional native final
argument supplies a fresh root; use resolved paths without symlinked parents.

Corpus minimization, multi-day soak campaigns, larger resource limits, and
physical power-loss testing remain future work. Existing deterministic
publication-failure and process-restart tests cover different failure
boundaries and remain separate gates.
