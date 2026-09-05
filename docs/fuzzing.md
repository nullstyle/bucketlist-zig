# Deterministic parser campaigns

The ordinary `zig build test` gate includes a 1,000-case portable campaign,
exhaustive allocation failures through one checkpoint continuation, and 100
native cases. Longer seeded runs are explicit. These are bounded mutation and
property tests, not a coverage-guided fuzzing engine or exhaustive input search.
The formats and interfaces remain Experimental.

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

Coverage-guided execution, corpus minimization, longer soak campaigns, larger
resource limits, and physical power-loss testing remain future work. Existing
deterministic publication-failure and process-restart tests cover different
failure boundaries and remain separate gates.
