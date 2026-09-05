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
repository's pinned compiler (macOS ARM64; the self-hosted AArch64 backend
silently skips `std.testing.fuzz`, so the guided artifacts set `use_llvm`).
Three fuzz tests — codec, bucket, and checkpoint — execute a fixed seed corpus
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
A real finding is minimized by hand into a checked-in corpus entry with the
replay command recorded; no automatic crash minimization exists on this pin.

### Recorded guided campaigns

macOS ARM64, ReleaseSafe, fresh cache per campaign, three seeds
(`1`, `20260904`, `305419896` — build seeds are u32, so the deterministic
campaigns' `11400714819323198485` cannot be reused verbatim), 100,000 mutation
cycles per test per campaign
(23 seconds each; most mutated inputs are rejected by early framing checks):

| Seed | Runs | Unique inputs | Coverage |
| --- | ---: | ---: | --- |
| 1 | 301,526 | 1,308 | 1511/11188 (13.51%) |
| 20260904 | 301,525 | 1,307 | 1510/11188 (13.50%) |
| 305419896 | 301,476 | 1,258 | 1509/11188 (13.49%) |

No campaign reported failure diagnostics, so no input required recovery or
replay. Per-seed artifacts (provenance, report, mapped inputs) are preserved
under `.zig-cache/guided-fuzz/` in the working tree. Coverage counts
instrumented program counters in the whole test binary — shared by all three
tests and dominated by code these entry points cannot reach — and is not
library-statement coverage; the plateau near 13.5% reflects that ceiling, not
an explored limit of the library.

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

Corpus minimization, longer soak campaigns, larger resource limits, Linux
coverage-guided runtime validation, and physical power-loss testing remain
future work. Existing deterministic publication-failure and process-restart
tests cover different failure boundaries and remain separate gates.
