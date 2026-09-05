# Implementation and validation

Date: 2026-09-04, evidence extended through 2026-09-05. Version: Experimental `0.1.0-dev`.

## Delivered

The portable library implements typed tables and bounded canonical codecs,
structural schema identity, normalized atomic batches, immutable refcounted
buckets, factor-four scheduling, eleven-level commitments, read views and
ordered iteration, and exact authenticated checkpoint continuation.

The native module implements verified content-addressed blobs, exclusive store
locking, atomic manifests, explicit reachability collection, and bounded-memory
streaming bucket merges. The native checkpoint manager publishes pinned typed
views with application metadata, shares bucket files, verifies exact restoration,
and calculates reachability for current and retained historical checkpoints.
The portable database and its checkpoint manager retain database contents in
memory. The separate `bucketlist-disk` engine retains bucket hashes and executes
against immutable files; `Host` provides bounded asynchronous publication.

The original in-memory SLCP consumer demonstrates two tables, allocation-free validation and
combination, owned observations, journal replay, checkpoint publication outside
apply, network catch-up, and participation in quorum after process restart.

## Disk engine and bounded host evidence

M7–M9 are implemented and verified. The native engine preserves exact v1
commitments, performs parallel streaming merges, authenticates typed disk reads
and recovery, and pins read-view files against collection. Host admission is
nonblocking and ownership-moving; capacity includes active publication. Worker
errors latch without publishing later advances. [ADR 0001](adr/0001-disk-engine-and-bounded-delivery.md)
and the [disk contract](disk.md) describe those boundaries.

The current suite has **99 tests**: 30 portable, 20 Store, two core/file parity,
17 checkpoint, 23 disk/host, five hash-frontier, and two portable campaign tests.
An additional 100 native mutation cases run as an executable smoke gate.
Debug and ReleaseSafe
pass on macOS ARM64 and native Linux ARM64. The disk/host tests cover exact
portable parity, reduced terminal profiles, real active-publication backpressure,
rejected-batch ownership, durable snapshots, shutdown, publication failures,
corrupt tails, forged pending hashes, rollback/schema rejection, allocator failure
cleanup, pinned GC, missing catalogs, and interrupted genesis initialization.

A **1,580,957-byte** bucket supports reopen, reads, update/publication, pinned
collection, and another reopen under a **131,072-byte allocator cap**. Peak live
requested allocation is **36,041 bytes**, with no denials or leaks. This excludes
setup/reference computation, stacks, filesystem cache, and the Io backend;
[performance.md](performance.md) records the measurement's scope.

The final disk SLCP consumer pins
`e2c48987e4f1237f1b87ee27c148ce51edfe8fda`: build **8/8 steps**, **3/3 focused
tests**, and the real-process fixture pass. The paused node is durable at 7 with
accepted 9 and two outstanding advances; journaled advance 10 fails admission.
Actual SIGKILL exits 137. Restart restores 7, replays 8–10, catches up through
11–12, and joins quorum at 71. Commands and database roots agree at the controlled
barriers; compaction retains 49–70 (22 records), and applied publication
watermarks finish at 71/70/71. Evidence lives in
`.zig-cache/slcp-disk-process.oNA2jh`; the ReleaseSafe fixture was rerun after
the disk normalization change with the same outcomes. The sibling SLCP working
tree is unchanged by this hardening slice.

The companion change passes **113/113 build steps, 437 tests with one platform
skip**, **8/8 real-socket E2E tests**, **436 docs checks / zero failures**, and the
strict API gate with **292 Stable declarations unchanged**. The existing skipped
negative test expects privileged ports; this macOS host permits an unprivileged
bind to port 1. No oracle or differential check is skipped. The journal watermark
is Experimental and does not change the peer answering-window policy.

M6 adds deterministic malformed-input campaigns and larger disk workload
measurements. The v0.1 release review — full gate evidence, the supported
versus experimental surface classification, the skip audit, and promotion
conditions — is recorded in [release-review.md](release-review.md).
Multi-day soak testing, production workload qualification, and an accessible
immutable companion artifact for a distributable standalone SLCP consumer
remain open.

The recorded ReleaseSafe campaigns execute **300,000 portable** and **30,000
native** mutation/property cases across three seeds, without mismatches or
leaks. Portable runs include 17,113 accepted checkpoint continuations and 6,885
intentional allocation failures; native runs include hash-valid malformed
buckets/manifests and preservation after rejected recovery/collection. Exact
source/compiler provenance, counters, and replay commands are in
[fuzzing.md](fuzzing.md). Deterministic mutation testing does not claim
exhaustive input coverage; the coverage-guided campaigns below add LLVM-guided
exploration on top of it.

Coverage-guided campaigns on the same pinned compiler (macOS ARM64 and native
Linux ARM64, LLVM, ReleaseSafe, fresh cache per campaign) ran three seeds at
100,000 mutation cycles per test through the fail-closed `guided-fuzz.py`
wrapper. The wrapper exists because the pinned build runner can exit zero
after a discovered fuzz failure and write an empty crash file; the Linux run
observed this exit-zero defect directly. `just guided-self-test` (part of
`just preflight`) replays an armed synthetic failure end to end to prove the
wrapper recovers the mapped input and reproduces the failure exactly; on
Linux the probe failed after 68 runs and replayed `SyntheticProbeFailure`
exactly. The library campaigns completed with no failure diagnostics on
either platform; program-counter coverage is not library-statement coverage.
The Linux campaigns ran in a disposable native-architecture container
(OrbStack, Debian 13 trixie) with per-invocation watchdogs and unchanged
source hashes; runner counters and provenance are in [fuzzing.md](fuzzing.md)
and [guided-linux.jsonl](fuzz/guided-linux.jsonl).

Both platforms then ran extended soaks at one hundred times that budget
(10,000,000 mutation cycles per test, three further seeds each, 7,200-second
watchdogs): 90,037,770 runs on macOS and 90,033,304 on Linux — 180,071,074
total — again with no failure diagnostics and unchanged sources. Counters
and provenance are in [fuzzing.md](fuzzing.md) and the
`guided-soak-*.jsonl` evidence files.

The disk workload comparison against `a7741e5` validates 192 identical committed
digests and manifest references. At 16 MiB, median measured time improves about
4.8 times and returned read bytes fall 10.7 times. Additional 64/256 MiB traces
match across one/two workers with peak requested engine allocation at most
2,210,437 bytes. These are synthetic warm-cache measurements; physical memory,
fixture buffers, per-advance comparison records, and other excluded costs are
documented in [performance.md](performance.md).

Point reads no longer rehash whole buckets: a verified local read index pays
full bucket verification once per blob and then reads a single sampled span
per lookup ([storage.md](storage.md) documents the trust semantics, size
guard, fail-closed framing checks, observable allocation failures, and the
`read_index = null` opt-out restoring per-read verification). Recorded
per-read measurements show warm deep-level reads improving about 96x at
16 MiB and 320x at 64 MiB, with logical read traffic per lookup falling from
67.2 MB to 41 KB at 64 MiB; misses improve about 110x. The index changes no
committed byte, and indexed and non-indexed opens agree across the test
suite. Full-bucket scanning still governs merges, reopen validation, and
retained-checkpoint verification by design. Reopen validation now also seeds
the read index during those required scans (first reads after open are warm)
and re-derives pending merge outputs with a write-free hash verification
instead of rewriting durable blobs; recorded reopen time fell from 71 ms to
39 ms on the 16 MiB workload with the same rejection guarantees.

## Reproducible checks

Local gates passed all 104 tests on macOS ARM64 and Linux ARM64 in Debug and
ReleaseSafe (including the fixed guided corpus through LLVM), plus the checks
below. Linux runs in a disposable native ARM container; x86_64 Linux is
separately cross-compiled. The first emulated x86 container could not run this
Zig toolchain under Rosetta and is not counted as runtime validation.

| Check | Evidence |
| --- | --- |
| `just test` | All 104 tests described above, 100 native mutation cases, API/schema diagnostics, and portable, checkpoint, and disk-host consumers. |
| `just fuzz-smoke` | A 1,000-case portable parser campaign, exhaustive checkpoint continuation allocation failures, the fixed guided corpus through LLVM, and 100 native cases; included in ordinary tests. See [fuzzing.md](fuzzing.md) for coverage and replay. |
| `just guided-self-test` | An armed synthetic fuzz failure is discovered by a bounded campaign, reported with a zero build exit and an empty crash file, and the wrapper still fails closed: it recovers the mapped input, resolves the test identity, and replays the exact `SyntheticProbeFailure`; part of `just preflight`. |
| Native checkpoint tests | Seventeen checks cover spill-boundary continuation, metadata authentication, retained/current reachability, hash-valid malformed manifests, inclusive limits, all save/restore allocation failures, and both pre-replacement and ambiguous publication errors. They also require full manifest checks before bucket reads and save a database over 4 MiB with a 32 KiB manager allocator. Imported-module tests are explicitly included through the dedicated test root. |
| Portable checkpoint and staging tests | Borrowed-frame restoration survives reused input buffers, source failures, and all allocator failures; malformed headers fail before callbacks. Large repeated batches match final-only canonical effects, and every staging allocation failure permits a correct retry on the same batch. |
| `just disk-example-smoke` | Bounded queue admission, explicit backpressure, durable background publication, authenticated disk reopen, and typed two-table reads. |
| `just slcp-disk-smoke` | The pinned three-process watermark/recovery fixture described above; local Git source required only for this optional gate. |
| `just persistent-example-smoke` | A pinned advance-1 snapshot survives close/reopen, replays identically through advance 3, and remains loadable alongside current advance 3 after obsolete blobs are collected. |
| `zig build test -Doptimize=ReleaseSafe` | Same semantic gates with runtime safety and optimization. |
| `just vectors-check` | Independent Python model reproduces 274 unique bucket frames, four profiles, and 128 advances per profile. |
| `just wasm-diff` | Native and wasm32-freestanding execute the same typed update/recovery trace and match the independent aggregate `53aee56398b68769c20d6725239f1fdbb3a739561682db9fd08da16e040ece0e`. |
| `just core-oracle` (prior baseline evidence) | Eight original pinned Stellar Core function definitions, adapted only through symbolic shims, match 153 geometry cases and 6,579 exact bucket maps. No claim of Stellar hash compatibility. |
| `just slcp-smoke` (prior baseline evidence) | Three real processes: checkpoint at 7, journal through 9, confirmed SIGKILL/exit 137, restart/replay, peer catch-up through 11, then restarted voter required for quorum at 12. Exact commands, database digests and application headers match. Also passed in ReleaseSafe. |
| `just package-preflight` | Builds/tests a fresh extracted archive and runs portable, persistent, and disk-host standalone consumers without any sibling checkout. Temporary paths are resolved so macOS's `/var` symlink does not violate native store path requirements. |
| `zig build check -Dtarget=x86_64-linux` | All native tests and directory example cross-compile. |
| `just linux-check` | Native Linux runtime gate in a disposable container using repo-pinned mise tools. |
| Preflight component gates | Formatting, workflow lint, fixtures, ordinary tests, WASM, ReleaseSafe, Linux cross-compile, and clean packaging. |

The GitHub workflow runs macOS/Linux tests after the repository is pushed.
No remote repository or release has been published by this task.

## Measurements

One local Apple Silicon ReleaseFast sample performed 4,096 advances over 1,024
keys with 64-byte values. Every advance changed its record, including repeated
visits to a key. Timed update work included batch encoding, preparation,
publication, and commitment calculation:

| Metric | Observed |
| --- | ---: |
| Update median | 9.0 microseconds |
| Update p99 | 19.7 microseconds |
| Maximum scheduled update | 178.9 microseconds |
| Full fixed-map SHA-256 baseline, mean | 30.3 microseconds |
| Checkpoint size | 465,244 bytes |
| Checkpoint encoding | 64.8 microseconds |

These are one-machine, small-workload measurements, not throughput guarantees.
The baseline hashes the fixed key-space's values; it is a cost comparison, not
the same commitment. Larger histories can create much larger scheduled merges.
Run `zig build bench -Doptimize=ReleaseFast` to reproduce the workload.

The file merger separately passes a 20,000-record / roughly 420 KB output test
using a 17,000-byte fixed allocator, including deduplication of an existing
output. Its workspace depends on per-record limits, not total bucket size.

The [scalability comparison](performance.md) uses identical benchmark source
against commits `55d94cb` and `f37871c`. At 16,384 staged keys,
unique and replacement puts improved about 8.8 times, with more memory used by
the staging index. For a 21,937,636-byte checkpoint, peak requested save
allocations fell from 32,905,682 to 1,370 bytes; load peak fell from 64,900,131 to
31,994,449 bytes. Native elapsed times were essentially unchanged. Raw results,
allocator accounting limits, and reproduction commands are in that report.
All measured database digests, native manifest hashes, checkpoint sizes, and
returned owned allocations were identical before and after.

## Review outcomes and limits

Review caught and fixed a mutable backing-buffer escape that could invalidate
cached hashes, a checkpoint size-boundary omission, and a FIFO open that could
block before the regular-file check. Native Linux execution additionally caught
directory `fsync` attempted on an `O_PATH` handle; the store now acquires a
readable directory descriptor for synchronization. Regression tests cover const storage,
canonical decoding, and nonregular-file rejection. Immutable sharing requires
an allocator that supports freeing on the receiving thread.

Review also rejected a missing catalog with non-genesis blobs instead of
silently creating an empty database; an interrupted genesis remains retryable.

Process SIGKILL is tested. Native publication fault injection checks all seven
implemented write/sync/replace boundaries, reopens the store, and verifies the
expected old or new frontier and both referenced blobs. Neither emulates physical power loss or
proves a filesystem's flush guarantees. The store excludes hostile concurrent
replacement of its directory entries; see [storage.md](storage.md).

The APIs and format remain Experimental. There is no automatic schema migration,
SQL/query planner, secondary-index maintenance, succinct record proof, or
application-independent checkpoint trust policy. Disk reads currently scan
complete buckets, and recovery recomputes pending merges. The examples are bounded
demonstrations, not production services. Multi-day coverage-guided soaks
beyond the recorded bounded and extended campaigns, production workload
qualification, and release review remain necessary before promotion to
Stable.

The SLCP revision used here is not publicly available as an immutable archive.
The optional integration reads that exact Git object from a local source and
materializes it in this repo's cache. A distributable standalone SLCP consumer
needs an accessible immutable companion release. The main bucketlist package
is independent of this limitation.
