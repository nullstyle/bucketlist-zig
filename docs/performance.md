# Scalability measurements

The batch builder now indexes canonical `(table_id, key_bytes)` identities.
Lookup has expected constant cost with respect to batch cardinality; repeated
puts/deletes retain the final call's effect. The index is never iterated to
produce committed data: normalization and sorting still determine canonical
records. Capacity changes and allocation failures cannot publish partial
changes. The index trades additional staging memory for lower lookup cost.

Native checkpoint save now borrows immutable bucket frames, and restore requests
frames individually. The portable checkpoint bytes, native manifest hashes,
database commitments, and returned database allocations are unchanged.

## Recorded comparison

Measured on macOS ARM64 with the repo-pinned Zig compiler in ReleaseFast, using
the identical benchmark source before and after the changes. The baseline is
commit `55d94cb86d4ca9685c5921930e832c4ca234a995`; the candidate is the implementation
accompanying this report. Each reported duration is the median of three trials.
Raw [before](benchmarks/scalability-before.jsonl) and
[after](benchmarks/scalability-after.jsonl) JSONL results are checked in.

Each batch workload stages all unique keys, replaces all of them in reverse
order, then separately times preparation and publication. Values are 64 bytes.
Input permutation/value generation is outside the timed regions.

| Staged identities | Unique puts before | Unique puts after | Replacements before | Replacements after |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 3.699 ms | 2.815 ms | 3.534 ms | 2.766 ms |
| 4,096 | 17.119 ms | 7.389 ms | 16.015 ms | 6.879 ms |
| 16,384 | 181.856 ms | 20.748 ms | 182.233 ms | 20.572 ms |

At 16,384 identities, staging improved about 8.8 times, while its peak requested
allocation grew from 1,907,568 to 3,293,760 bytes. These measurements include key
and value encoding and the batch's base checks, not only hash-table lookup.
They do not establish a worst-case bound for adversarial hash collisions.

The native fixture has 8,192 live records with 1,024-byte values and 17 advances.
Its exact portable checkpoint occupies 21,937,636 bytes. Each save uses a fresh
store; load reopens that store without evicting the operating system's cache.

| Native checkpoint measurement | Before | After |
| --- | ---: | ---: |
| Save peak requested bytes | 32,905,682 | 1,370 |
| Load peak requested bytes, including returned database | 64,900,131 | 31,994,449 |
| Returned owned allocations | 22,777,191 | 22,777,191 |
| Load peak above returned allocations | 42,122,940 | 9,217,258 |
| Save elapsed | 93.950 ms | 94.050 ms |
| Load elapsed | 26.321 ms | 26.144 ms |

The native improvement is memory use; elapsed times were essentially unchanged
in this workload. Counters record logical bytes requested through the supplied
allocator, including successful resize/remap growth. They exclude stack space,
allocator metadata/internal copies, filesystem caches, and allocations internal
to `std.Io`. These are not process RSS measurements. Fixture construction is
outside the counters and timers, and the retained live source database is not
included in save/load allocation totals. No physical power-loss or cold-storage
performance claim follows from this benchmark.

## Reproduce

Use a fresh path with no symlinked parent components; on macOS prefer a resolved
workspace path over `/tmp` or `/var` aliases. The optional final argument sets
the trial count (1–9, default 3).

```sh
mise exec -- zig build scalability -Doptimize=ReleaseFast -- /absolute/fresh/store/path 3 > results.jsonl
```

The benchmark uses only public interfaces available in the baseline. To compare
another revision, extract `git archive <revision>` into isolated scratch space,
copy the unchanged `tools/scalability.zig` into its `tools` directory, then run
this compiler invocation from that scratch directory using the repo's mise tools:

```sh
mise exec -- zig build-exe -O ReleaseFast --dep bucketlist --dep bucketlist-checkpoints \
  -Mroot=tools/scalability.zig -O ReleaseFast --dep reference_vectors \
  -Mbucketlist=src/lib.zig -O ReleaseFast --dep bucketlist-store \
  -Mbucketlist-checkpoints=src/checkpoints.zig -O ReleaseFast \
  -Mreference_vectors=vectors/reference.zig -O ReleaseFast \
  -Mbucketlist-store=src/store.zig -femit-bin=scalability
./scalability /absolute/fresh/store/path 3 > results.jsonl
```

Recorded benchmark source SHA-256:
`5dc9b29a8bc24c1e9b8b0e51b5e5374a7c966cee45fc9085795e68ba7b25497c`.
The JSONL output records compiler, target, optimization, workload, allocation
counters, and resulting commitments. Compare commitments and manifest hashes
before drawing performance conclusions. Filesystem and hardware differences
can change timings substantially; the fixed-buffer save regression in ordinary
tests separately enforces the absence of a checkpoint-sized save allocation.
