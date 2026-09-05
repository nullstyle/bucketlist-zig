# Implementation and validation

Date: 2026-09-04. Version: Experimental `0.1.0-dev`.

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

The current suite has **93 tests**: 30 portable, 20 Store, two core/file parity,
17 checkpoint, 19 disk/host, and five hash-frontier tests. Debug and ReleaseSafe
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
`.zig-cache/slcp-disk-process.SbxJuK`.

The companion change passes **113/113 build steps, 437 tests with one platform
skip**, **8/8 real-socket E2E tests**, **436 docs checks / zero failures**, and the
strict API gate with **292 Stable declarations unchanged**. The existing skipped
negative test expects privileged ports; this macOS host permits an unprivileged
bind to port 1. No oracle or differential check is skipped. The journal watermark
is Experimental and does not change the peer answering-window policy.

M6 release hardening remains open: sustained malformed-input/fuzz coverage,
release review, production-scale throughput measurements, and an accessible
immutable companion artifact for a distributable standalone SLCP consumer.

## Reproducible checks

Final local runs passed all 93 native tests on macOS ARM64 and Linux ARM64 in
Debug and ReleaseSafe, plus the checks below. Linux runs in a disposable native
ARM container; x86_64 Linux is separately cross-compiled. The first emulated
x86 container could not run this Zig toolchain under Rosetta and is not counted
as runtime validation.

| Check | Evidence |
| --- | --- |
| `just test` | All 93 tests described above, API/schema diagnostics, and portable, checkpoint, and disk-host consumers. |
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
demonstrations, not production services. Sustained fuzzing, realistic throughput
workloads, and release review remain necessary before promotion to Stable.

The SLCP revision used here is not publicly available as an immutable archive.
The optional integration reads that exact Git object from a local source and
materializes it in this repo's cache. A distributable standalone SLCP consumer
needs an accessible immutable companion release. The main bucketlist package
is independent of this limitation.
