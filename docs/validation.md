# Implementation and validation

Date: 2026-09-04. Version: Experimental `0.1.0-dev`.

## Delivered

The portable library implements typed tables and bounded canonical codecs,
structural schema identity, normalized atomic batches, immutable refcounted
buckets, factor-four scheduling, eleven-level commitments, read views and
ordered iteration, and exact authenticated checkpoint continuation.

The native module implements verified content-addressed blobs, exclusive store
locking, atomic manifests, explicit reachability collection, and bounded-memory
streaming bucket merges. The typed database is still an in-memory database;
native persistence is an explicit host building block, not a transparent
disk-backed replacement for its engine.

The SLCP consumer demonstrates two tables, allocation-free validation and
combination, owned observations, journal replay, checkpoint publication outside
apply, network catch-up, and participation in quorum after process restart.

## Reproducible checks

Final local runs passed all 38 native tests on macOS ARM64 and Linux ARM64 in
Debug and ReleaseSafe, plus the checks below. Linux runs in a disposable native
ARM container; x86_64 Linux is separately cross-compiled. The first emulated
x86 container could not run this Zig toolchain under Rosetta and is not counted
as runtime validation.

| Check | Evidence |
| --- | --- |
| `just test` | Codec/schema negatives, literal encodings/hashes, map properties, schedule boundaries, OOM atomicity/cleanup, strict restore, native storage, core/file merge parity, and the two-table consumer. |
| `zig build test -Doptimize=ReleaseSafe` | Same semantic gates with runtime safety and optimization. |
| `just vectors-check` | Independent Python model reproduces 274 unique bucket frames, four profiles, and 128 advances per profile. |
| `just wasm-diff` | Native and wasm32-freestanding execute the same typed update/recovery trace and match the independent aggregate `53aee56398b68769c20d6725239f1fdbb3a739561682db9fd08da16e040ece0e`. |
| `just core-oracle` | Eight original pinned Stellar Core function definitions, adapted only through symbolic shims, match 153 geometry cases and 6,579 exact bucket maps. No claim of Stellar hash compatibility. |
| `just slcp-smoke` | Three real processes: checkpoint at 7, journal through 9, confirmed SIGKILL/exit 137, restart/replay, peer catch-up through 11, then restarted voter required for quorum at 12. Exact commands, database digests and application headers match. Also passed in ReleaseSafe. |
| `just package-preflight` | Builds/tests a fresh extracted archive and runs its standalone consumer without any sibling checkout. |
| `zig build check -Dtarget=x86_64-linux` | All native tests and directory example cross-compile. |
| `just linux-check` | Native Linux runtime gate in a disposable container using repo-pinned mise tools. |
| `just preflight` | Formatting, workflow lint, fixtures, ordinary tests, WASM, ReleaseSafe, Linux cross-compile, and clean packaging. |

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

## Review outcomes and limits

Review caught and fixed a mutable backing-buffer escape that could invalidate
cached hashes, a checkpoint size-boundary omission, and a FIFO open that could
block before the regular-file check. Native Linux execution additionally caught
directory `fsync` attempted on an `O_PATH` handle; the store now acquires a
readable directory descriptor for synchronization. Regression tests cover const storage,
canonical decoding, and nonregular-file rejection. Immutable sharing requires
an allocator that supports freeing on the receiving thread.

Process SIGKILL is tested. Native publication fault injection checks all seven
implemented write/sync/replace boundaries, reopens the store, and verifies the
expected old or new frontier and both referenced blobs. Neither emulates physical power loss or
proves a filesystem's flush guarantees. The store excludes hostile concurrent
replacement of its directory entries; see [storage.md](storage.md).

The APIs and format remain Experimental. There is no automatic schema migration,
SQL/query planner, secondary-index maintenance, succinct record proof, background
compaction service, or application-independent journal-retention policy. The
example is bounded demonstration code, not a production service.

The SLCP revision used here is not publicly available as an immutable archive.
The optional integration reads that exact Git object from a local source and
materializes it in this repo's cache. A distributable standalone SLCP consumer
needs an accessible immutable companion release. The main bucketlist package
is independent of this limitation.
