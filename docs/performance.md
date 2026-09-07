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

## Disk engine working-memory bound

The disk adversarial fixture persists **384 records of 4,096 value bytes** in a
1,580,957-byte canonical bucket. A separate allocator enforces a **131,072-byte
live allocation cap** while the disk engine reopens the trusted reference,
performs hit/miss reads, pins a view, normalizes a typed update, merges and
publishes advance 2, collects with the view retained, and reopens the resulting
continuation. Its commitment must match an independently executed portable
history.

The measured peak is **36,041 requested bytes**, with zero denied allocations
and zero live tracked bytes after close, in Debug and ReleaseSafe on macOS ARM64
and Linux ARM64. The test configures one merge worker so the measuring allocator
can remain serial. Separate Store and Host tests exercise actual concurrent
workers and active queue capacity.

This measures allocations requested through the disk engine's allocator. It
excludes fixture construction, the portable reference computation, stack space,
filesystem cache, and the `std.Io` backend. It establishes bounded execution of a
database larger than the allocator budget; it is not an RSS measurement or a
production throughput benchmark. Linear authenticated point reads and sorted
batch normalization still scale with the bytes scanned. See
`src/disk_adversarial_test.zig` for the repeatable gate.

## Disk batch normalization

Commit `09fcc4f` replaces one authenticated point lookup per staged identity
with a sorted merge-join against each visible bucket. The first occurrence of
an identity decides its current value, including tombstones hiding older
records. Preparation omits unchanged puts and absent deletes, then encodes the
same canonical fresh bucket as before. It fully authenticates each touched
file before returning a prepared result.

For a batch with many keys, normalization reads each relevant frontier bucket
once rather than rereading it for every key. Sorting and decision storage scale
with the batch; record buffers remain bounded by the schema. Later scheduled
merges, deduplication, and manifest publication have their own costs. Point reads
and recovery validation retain their existing scan behavior.

The regression gate stages 128 existing 128-byte values unchanged, then prepares
the next advance with a measured file-read allowance. It fails on `a7741e5` and
passes after the change. Separate tests require dense multi-table histories to
match the portable engine, reject a corrupt tail even when all requested keys
match earlier, and allow retry on the same database and batch after every
preparation allocation failure.

## Recorded disk workload

The comparison uses immutable source archives of `a7741e5` and `09fcc4f`, the
same benchmark source, and the pinned compiler with **ReleaseFast for every
module**. The host is an Apple M5 Max running macOS 26.6.2 with 128 GiB RAM.
Final measurements run sequentially after the mutation campaigns and other
heavy checks finish. Operating-system caches are not evicted.

The 16 MiB workload has 1,024 records with 16 KiB values. Each batch contains
at most 64 records (1 MiB of values). It loads all records, updates a quarter,
repeats those updates unchanged, deletes another quarter, and inserts new
identities to replace the deleted quarter. It then verifies sampled reads,
closes/reopens against the trusted reference, verifies reads again, collects
unreachable files, and verifies reads once more. Each read phase samples 32
requests across updated, unchanged, deleted, newly inserted, and absent keys.
Record counts follow that deterministic model; these are sampled checks, not a
full independently materialized database oracle.

Each worker configuration executes 32 advances per trial, with three trials.
All **192 compared advances have identical database digests and native manifest
references before and after**. One- and two-worker executions also compare
every reference inside the benchmark. Raw
[baseline](benchmarks/disk-baseline-16m.jsonl) and
[candidate](benchmarks/disk-candidate-16m.jsonl) JSONL include provenance and
per-phase counters. Durations below are medians; allocation peaks are maxima
across trials.

| Measurement | Before | After |
| --- | ---: | ---: |
| All measured phases, 1 worker | 11.484 s | 2.391 s |
| All measured phases, 2 workers | 11.506 s | 2.389 s |
| Preparation phases, 1 worker | 10.466 s | 1.361 s |
| Preparation phases, 2 workers | 10.467 s | 1.354 s |
| Returned positional read bytes, either configuration | 24,883,775,015 | 2,327,788,837 |
| Peak requested allocation, 1 worker | 2,161,253 bytes | 2,161,253 bytes |
| Peak requested allocation, 2 workers | 2,210,437 bytes | 2,210,437 bytes |

The measured workload improves about **4.8 times** and returned read bytes fall
about **10.7 times**. Preparation accounts for the improvement; sampled point
reads, publication, and recovery costs are essentially unchanged. A second
worker provides no meaningful total-time improvement on this workload.

The candidate also completes larger workloads with the same batch size, value
size, mutation pattern, and 32 reads per verification phase. These are **one
trial per worker configuration**, not medians across repeated trials. Raw
[64 MiB](benchmarks/disk-candidate-64m.jsonl) and
[256 MiB](benchmarks/disk-candidate-256m.jsonl) results include every advance.

| Live value bytes | Advances | Measured time, 1 worker | Measured time, 2 workers | Returned read bytes, each configuration |
| --- | ---: | ---: | ---: | ---: |
| 64 MiB | 128 | 11.531 s | 11.412 s | 14,378,028,315 |
| 256 MiB | 512 | 75.460 s | 74.237 s | 130,519,419,904 |

Every advance matches across worker configurations. Peak requested allocation
remains **2,161,253 bytes with one worker** and **2,210,437 bytes with two** at
both sizes, with zero live tracked allocations after close. The 256 MiB dataset
exceeds the measured engine heap by over 120 times; it remains well below this
host's 128 GiB RAM. This demonstrates allocation behavior, not execution beyond
physical memory capacity.

For the 256 MiB run, preparation latency is 109.5 ms median / 318.5 ms p99 /
836.5 ms maximum with one worker, and 106.2 / 275.1 / 658.1 ms with two. The p99
uses the nearest-rank value among 512 advances. Preparation includes scheduled
merges and durable immutable-file writes. The roughly **121.6 GiB** returned
read traffic per configuration shows that full-bucket scanning remains
expensive as datasets grow. Bounded memory and nonblocking host admission do
not guarantee a short publication latency.

The measured total sums staging, preparation, publication, batch cleanup,
reads, open/close, recovery, and collection. It excludes bounded fixture
generation and JSON reporting. Requested-allocation peaks include staged batch
data and active merge workspaces, but exclude fixture buffers (1,049,088 bytes),
the 96-byte comparison record retained per advance per worker, stacks, allocator
internals, and `std.Io` allocations. All tracked allocations are freed at close.
These are not RSS measurements. Positional I/O counters count returned bytes
through public callbacks, not physical disk traffic. `file_sync_ops` counts
`Io.fileSync` callbacks, including directory syncs routed through them; the
additional macOS `F_FULLFSYNC` operation is included in elapsed time but not in
that callback count.

### Reproduce and compare

For a single current-source run, choose an empty root with resolved parent
paths. Existing contents are rejected before any benchmark work.

```sh
mise exec -- just disk-bench /absolute/fresh/store/path 64
```

To capture provenance alongside every result, use the wrapper. For the baseline,
first extract `git archive a7741e5` into an isolated source directory and write
the full revision returned by `git rev-parse a7741e5` to that directory's
`.baseline-revision` file. The wrapper compiles the current benchmark against
that archive using the current repository's mise tools.

```sh
DISK_BENCH_SOURCE_DIR=/absolute/baseline/source \
  mise exec -- bash tools/disk-bench.sh /absolute/fresh/before 16 64 32 3 > before.jsonl
mise exec -- bash tools/disk-bench.sh /absolute/fresh/after 16 64 32 3 > after.jsonl
mise exec -- python3 tools/compare-disk-bench.py before.jsonl after.jsonl
```

The comparison command requires matching benchmark source and workload settings,
complete phase histories, consistent read/time totals and allocation peaks, and every committed digest
and manifest reference before it reports median costs. Its checks also reject
altered commitments, workload settings, phase records, missing cleanup, and
inconsistent allocation summaries.

Recorded benchmark SHA-256:
`27a4ec874a139a48fe00e11a0033d7323b65fc8fec1edf202e478537385401af`.
Results remain specific to this synthetic workload and machine; production
workload qualification and cold-storage measurements remain open.

## Point-read latency and the verified read index

`tools/read-bench.zig` measures one public `get` at a time against a
deterministic 16 KiB-value workload (`deep` = oldest eighth of the key space,
`shallow` = newest eighth, `miss` = beyond the range), reporting per-read
latency and logical positional read traffic. The OS page cache stays warm —
`open` authenticates every bucket — so costs isolate parse/hash work and
logical I/O, not physical media. Recorded on the same machine as the workload
above, ReleaseFast, 128 samples per class:

| Dataset | Class | Before: median / bytes per read | After: median / bytes per read |
| --- | --- | --- | --- |
| 16 MiB / 1,024 records | deep, first touch | 6.50 ms / 16.8 MB | 0.078 ms / 172 KB |
| 16 MiB | deep, warm | 6.52 ms / 16.8 MB | 0.068 ms / 41 KB |
| 16 MiB | shallow, warm | 0.52 ms / 1.8 MB | 0.036 ms / 41 KB |
| 16 MiB | miss, warm | 6.66 ms / 16.8 MB | 0.244 ms / 460 KB |
| 64 MiB / 4,096 records | deep, first touch | 26.6 ms / 67.2 MB | 0.087 ms / 566 KB |
| 64 MiB | deep, warm | 27.6 ms / 67.2 MB | 0.086 ms / 41 KB |
| 64 MiB | shallow, warm | 2.26 ms / 7.2 MB | 0.054 ms / 41 KB |
| 64 MiB | miss, warm | 28.5 ms / 67.2 MB | 0.258 ms / 591 KB |

Before the change, every point read re-streamed and re-hashed each candidate
bucket to verified EOF — a deep hit or miss hashed essentially the whole
dataset, and warm repeats were byte-identical to first touches. The verified
read index ([storage.md](storage.md)) pays that full verification once per
blob, then reads one 64 KiB span per bucket: warm deep reads improve about
**96x** at 16 MiB and **320x** at 64 MiB, with per-read traffic falling from
67.2 MB to 41 KB at 64 MiB. First-touch medians include the amortized single
verifying pass. A miss still probes every level, so it pays one span per
bucket (~110x here); misses remain O(levels) rather than O(1). Reopen
rebuilds indexes on first touch; earlier recorded workload numbers above
predate the index and measured per-read full verification.

Reopen after these changes costs 38.8 ms on the 16 MiB workload versus
71.0 ms before (write-free pending-merge verification replaces the temporary
rewrite and syncs during validation), and because validation seeds the read
index, the first reads after reopen are already warm (41 KB per lookup) with
no cold per-bucket pass.

```sh
mise exec -- zig build read-bench -Doptimize=ReleaseFast -- /absolute/fresh/store 64 16 128
```

## Workload qualification harness

`tools/workload-bench.zig` runs three pre-registered production shapes
(`zig build workload-bench -- <mode> /absolute/fresh/path [params]`),
each reporting medians and tails with the same logical-traffic counters as
the recorded workloads above:

- **ledger** — consensus-node writing: 50-200 change batches, 85/15
  put/delete over a bounded key space, 93% values 32-64 B, 6% 256 B-1 KiB,
  1% blobs 1-64 KiB. Metrics: commit latency distribution, advances/sec,
  write amplification (positional write bytes per logical payload byte),
  blob growth.
- **zipf** — read serving: builds the key space, then a 95/5 read/write
  mix over a Zipf-Mandelbrot distribution (skew sweeps via the `skew_x10`
  parameter). Metrics: read and write latency distributions, sustained
  ops/sec, logical read traffic.
- **catchup** — rejoin after downtime: reopen-with-validation wall time
  and validated GiB/sec at scale, fastest-possible suffix replay
  throughput, and the post-replay reopen delta.

Smoke-scale first measurements (ReleaseFast, this machine, blob-heavy
default value mix): ledger 2,000 advances over 50k keys commits at
p50 55 ms / p99 94 ms with write amplification 11.8x (0.5x and 38 MB of
blobs instead of 907 MB with the compression option enabled; p50 69 ms); zipf (skew 1.0,
50k keys) reads at p50 361 us / p99 1.4 ms with writes p99 80 ms;
catchup over ~1 GB of blobs reopens in 102 ms — **9.14 GiB/s validated**,
so reopen cost scales linearly at roughly a tenth of a second per GiB and
restart floors stay sub-second into multi-GiB stores. These are
first-contact numbers at toy scale, recorded to anchor the parameter
space; qualification runs at target scale with pre-registered thresholds
remain open work.
