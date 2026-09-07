# Native checkpoint storage

`src/store.zig` provides an independent native store for canonical bucket bytes
and opaque checkpoint manifests. It accepts an explicit `std.Io` and allocator.
The deterministic database and BucketList layers define the bytes and references;
the store neither interprets a schema nor decides which state is authoritative.
For typed checkpoint publication, application metadata, and automatic reference
discovery during collection, use [Checkpoints(DatabaseType)](checkpoints.md).
The implemented [disk engine and bounded host](disk.md) build on the same
primitives for file-backed execution and bounded asynchronous publication.

`Store.open(gpa, io, path)` returns an owned value. Call `deinit` exactly once.
An exclusive advisory `LOCK` file prevents another cooperating store from opening
the same directory. With a thread-safe allocator and `std.Io`, immutable blob
reads, puts, merges, and independent cursors may run concurrently on one Store.
Do not mutate Store fields during use; each cursor has one owner. Serialize
publication and recovery decisions. Collection and deinitialization require
quiescence: no active calls, cursors, or background jobs. Readers receive owned
byte allocations and free them with the allocator supplied to the read.

The directory layout is:

```text
store/
  LOCK
  manifest
  blobs/
    <64 lowercase hex characters>
```

Each blob filename is SHA-256 of the exact contents. For a new hash,
`putBlob(bytes)` creates a temporary file, writes and flushes all bytes, syncs it,
atomically installs it without replacing an existing destination, then syncs the
blob directory. An existing blob is checked for exact length and hash using
8 KiB of streaming scratch, without rewriting it or allocating another whole
blob. The initial absence/link-collision path verifies the winning file too.
Both paths retain file/directory/file synchronization. On macOS the file sync
includes `F_FULLFSYNC`. Corruption is reported and never silently repaired.
Under the default `per_blob` durability, successful `putBlob` means the blob is
durable before its hash is returned; under `pre_publish` it means the write is
recorded for the next publication barrier (see Durability).

`getBlob(gpa, hash, max_bytes)` checks that the file is regular, enforces the
inclusive byte limit before allocation and during reading, and recomputes the
hash before returning. Empty blobs are valid. Missing blobs, oversized files, and
hash mismatches are distinct errors. A truncation cannot pass hash verification.

`lookupBucket(gpa, hash, table, key, limits)` streams and verifies the entire
canonical bucket, including the tail after a matching record. It returns
`BucketLookup.absent`, `.tombstone`, or `.value`; a live zero-length value is
distinct from deletion. A value belongs to `gpa`; `result.deinit(gpa)` releases
it. An error releases any captured value and returns no unverified result.
Initial lookup cost is linear in bucket bytes. Its workspace is one cursor plus
at most one value copy, independent of total bucket size.

`scanBucket(hash, limits)` returns an owned `BucketCursor`. `next()` returns a
`BucketRecord` with table ID and borrowed key/value slices, invalidated by the
next `next`, `finish`, or `deinit` call. These rows are provisional until `next`
returns `null` or `finish()` successfully drains the remainder: only then have
hash, strict order, framing, counts, and EOF all been verified. `byteLength()`
and `recordCount()` expose file/header metadata subject to the same verification
rule. A scan error remains latched. `deinit()` closes the file and workspace but
does not finish verification. The allocator and I/O context must outlive the
cursor.

Scans and lookups use the same `MergeLimits` as native merges. One cursor
allocates `2 * max_key_bytes + max_value_bytes + 8192` scratch bytes. Limits
apply to every parsed record, even one unrelated to the lookup target; a corrupt
or oversized tail cannot be hidden by an early match.

## Compression

`enableCompression()` opts future writes into transparent deflate framing:
each blob file becomes `BKLZRAW1 || u64be(plain_length) || raw-deflate(bytes)`,
while the blob's name keeps hashing the canonical uncompressed bytes. Reads
autodetect the framing, so stores may mix compressed and legacy plain blobs
indefinitely, and commitments are unaffected -- compression is a local
policy, never a consensus input. Streaming scans, verified lookups, v2
block hashing, merges (whose outputs are framed with the exact plain length
patched in before installation), and existing-winner verification all run
through the framing; the read index is not installed for framed blobs
because span offsets lose meaning under decompression, so compressed stores
verify whole blobs per lookup by default. Recorded ledger workload
(2,000 advances, 50k keys, blob-heavy mix): write amplification 11.8x ->
0.5x and blob storage 907 MB -> 38 MB, at a p50 commit cost of 55 ms ->
69 ms from fastest-preset compression CPU.

## Durability

`setDurability(mode)` selects a local durability policy (never a consensus
input; commitments and blob bytes are identical under both modes):

- `per_blob` (default) — every `putBlob`/`putBucketV2`/`mergeBuckets` is
  individually durable before returning: file sync, blob-directory sync, then
  a post-rename file sync. A successful write means the bytes survive a crash.
- `pre_publish` — blob writes skip all per-file syncs and record their names
  in a pending set instead. `publish` then performs one batched barrier
  before the atomic manifest replace: it opens and full-syncs every pending
  blob (each name leaves the set only after its sync succeeds), then syncs
  the blob directory, and only then writes, syncs, and replaces the
  manifest. Blob data is durable before the directory entry that names it,
  and both precede any manifest that could reference them, so a published
  manifest never names non-durable bytes. A crash or close before
  publication leaves the previous frontier recoverable and abandons the
  unsynced writes as unreachable debris.

Operational notes: the barrier syncs each distinct pending blob exactly once
per publication (re-putting an existing blob re-arms one name), a failed
barrier retries the unsynced remainder on the next publication (already
synced files may sync again, which is redundant but sound), and blobs
deleted by `collect` are skipped. A crash under `pre_publish` can leave
truncated debris at canonical blob names — unlike `per_blob`, where a blob
is complete before its name exists — so a later put of the same content
fails closed with `CorruptBlob` until `collect` removes the unreachable
debris. The pending set is mutex-guarded, so concurrent puts and merges on
one thread-safe Store remain safe; call `setDurability` once after open,
before concurrent use. Switching back to `per_blob` does not discard the
pending set: the next `publish` still drains it before replacing the
manifest. The disk engine exposes this as `DiskOptions.durability`, where
each `prepare`/`commit` pair publishes exactly once, so the barrier batches
every blob a commit wrote (fresh bucket, merges, manifest) into one sync
point.

## Read index

`enableReadIndex(options)` opts a Store into `lookupBucketIndexed`, the same
verified lookup with a local index: the first lookup of a blob fully verifies it
exactly as `lookupBucket` does and, along that single verified pass, records a
sampled key/offset spine (a new sample at least `min_span_bytes` apart, bounded
by `max_samples`, at most `max_buckets` blobs retained least-recently-used).
Later lookups of an unchanged blob binary-search the spine and read only the one
span that can contain the key, instead of rehashing the whole blob. The disk
database enables this by default; `DiskOptions.read_index = null` restores
per-read whole-bucket verification. The index is local policy: it stores keys,
offsets, and the verified size only, and never changes any committed byte.

Trust semantics: content-addressed immutable names make a verified entry sound
across garbage collection and recreation — a recreated file with the same hash
holds the same verified bytes. Each warm lookup reopens the blob as a regular
non-symlink file and rechecks its size; any size change discards the entry and
repeats the full verification. Framing or order anomalies inside a read span
fail closed. The residual risk is explicit: same-size in-place corruption of a
blob after its one verifying pass is not detected by warm point reads — scans,
merges, `open` validation, and collection still detect it, and `read_index =
null` restores detection on every read. Index bookkeeping allocation failures
are caller-visible `OutOfMemory` errors, never silent degradation; entries are
reference-counted so concurrent merges and lookups on one thread-safe Store
remain safe. Warm spans allocate the same bounded key/value scratch as a scan.

`mergeBucketsVerify(older, newer, drop_tombstones, limits, expected)` proves
that a merge would produce exactly `expected` without writing anything: the
same two bounded passes hash the would-be output stream, header included.
Reopen validation uses it to re-derive pending outputs that are already
durable blobs, instead of rewriting and re-syncing them; a forged pending
hash fails with `MergeMismatch`.

`scanBucketIndexed(hash, limits)` returns an `IndexedCursor`: a verified scan
like `scanBucket` that additionally records read-index samples and installs
them exactly when verification reaches EOF (see the read index section).
Open validation uses it, so the required full-bucket scans at reopen also
seed the index and every post-open lookup is warm immediately.

`mergeBuckets(older, newer, drop_tombstones, limits)` merges two stored canonical
buckets without loading either whole bucket into memory. Records are ordered by
numeric table ID then lexicographic encoded key. The newer input wins duplicate
identities, including replacing a value with a deletion marker. Set
`drop_tombstones` only when no still-older record can be resurrected; otherwise
deletion markers must survive. The method returns a durable output hash and does
not publish a manifest or change the in-memory database's topology.

The native parser consumes the core's exact version-one bytes: the ASCII domain
`bucketlist.bucket.v1`, one NUL byte, then `record_count:u64be`, followed by records encoded as
`table:u32be || key_length:u32be || key || tag:u8`. Tag zero is a deletion marker.
Tag one is followed by `value_length:u32be || value`; a zero-length live value is
distinct from deletion. Both inputs must have the correct content hash, strictly
increasing unique identities, valid tags/counts/lengths, and no trailing bytes.
The native source intentionally has no import of the core source, so both Zig
module graphs can coexist. Literal frame bytes and independently known hashes
pin their encoding agreement in the tests.

Merging makes two sequential passes. The first fully validates both inputs and
counts selected output records; the second reopens and revalidates both inputs,
writes the known count and selected records to a temporary file, and incrementally
hashes the output. Only after full input validation and output sync is the final
hash filename installed. A preexisting output is verified by streaming, too.
An invalid input cannot cause publication of an output bucket. All operations
remain synchronous; callers schedule merge jobs outside the consensus callback.

`MergeLimits` sets inclusive `max_key_bytes` (default 64 KiB), `max_value_bytes`
(1 MiB), `max_records` (2^32), and `max_bucket_bytes` (1 TiB). Record counts and
total-byte limits apply to each input and the output. The parser checks declared
key/value lengths before reading into its fixed workspace and bounds counts
against the actual file size before looping. These limits describe local
resource policies and do not affect canonical hashes. Two readers allocate
exactly `2 * (2 * max_key_bytes + max_value_bytes + 8192)` scratch bytes total,
plus constant stack and I/O backend state. Memory does not grow with bucket
size; lower per-record limits reduce the workspace. Each pass allocates and
releases its readers, so the peak bound covers only one pass at a time.

`publish(manifest_bytes)` first performs the durability barrier (`per_blob`
has nothing pending; `pre_publish` syncs every blob written since the last
successful publication), syncs the blob directory, writes a new manifest
to a temporary file, flushes and syncs it, atomically replaces `manifest`, and
syncs the store directory. Every referenced blob must already have been written
successfully through `putBlob`. The payload is opaque, so this precondition is
the caller's responsibility: the store cannot prove that references exist.
An owner may publish alongside independent blob jobs, provided every referenced
output has already completed (durably under `per_blob`; at least installed and
pending under `pre_publish`). Completion of an unrelated background
job does not choose which manifest is authoritative.

The local storage envelope is `"BKLSTOR1" || payload_length:u64be ||
SHA256(payload) || payload`. This wrapper is not a consensus encoding. The
application payload must carry its own schema/format epoch, ledger frontier,
BucketList structure, and required blob references. `readManifest(gpa, max_bytes)`
returns the original payload after checking the version marker, exact length,
and checksum. Its inclusive limit applies to payload bytes. It returns `null`
only when no manifest file exists; corruption is an error.

Failures before atomic replacement leave the previous manifest authoritative.
A failure after replacement can leave the new manifest visible even though the
call reported an error: callers must halt publication and reopen/read to recover,
not assume the old frontier remains. A crash before publication can leave
unreferenced complete blobs or temporary files. No startup routine deletes them.
The store does not independently certify a checkpoint, supply SLCP's exact
previous consensus value, or replace an application's recovery policy.

Directory sync obtains its own readable/iterable directory handle. On Linux,
the ordinary path-access directory handle may use `O_PATH`, which cannot be
passed to `fsync`; requesting a readable handle is part of the durability path.

`collect(reachable_hashes)` is explicit reachability collection. The caller must
include all blobs needed by the current manifest, retained checkpoints, active
readers, and pending publications. It removes only regular files named by a
canonical lowercase 64-character hash, then syncs the blob directory, and returns
the deletion count. Other names, directories, symlinks, and temporary debris are
preserved. A collection error can follow partial deletion; callers must never
offer an incomplete reachability set. There is no automatic collection or reader
pinning in this low-level module. Quiesce all active jobs and cursors before
collection; the owning disk database is responsible for tracking its read-view
and pending-work references.

Durability is currently supported on local Linux and macOS filesystems providing
working file/directory sync and atomic same-directory replacement. Other targets
return `UnsupportedPlatform`. The filesystem and storage device must honor those
operations. Directory resolution walks components with symlink following
disabled; `..` paths are rejected. Blob and manifest reads also disable symlink
following and request beneath-directory resolution where supported. The store
checks file kind before opening to reject static FIFOs/devices without blocking,
and checks the opened handle again. It uses opened directory handles for
subsequent operations. Its parent directories
must remain trusted: these checks are not a defense against an attacker who can
rewrite arbitrary entries concurrently or a noncooperating process ignoring the
advisory lock.

The pre-open kind check and open are separate operations: callers must exclude
hostile concurrent entry replacement. The store lock serializes cooperating
users, but it cannot stop a process that ignores that lock from replacing a
checked regular file with a FIFO before the open.

The publication test matrix injects `IoFailed` before the durability barrier,
after the header write call, after the payload write call, after
temporary-file sync, immediately before replacement, after replacement, after
directory sync, and after final-file sync. It runs every point under both
durability modes and then closes and reopens the store through its ordinary
API. Every pre-replacement error preserves the old frontier; every
post-replacement error exposes the new frontier, and both referenced blobs
still verify. Barrier-specific tests additionally pin the sync economics
(relaxed writes perform no syncs; one publication syncs each distinct
pending blob exactly once plus the manifest barriers), that a failed barrier
keeps the unsynced remainder pending for the next publication, that
collected blobs are skipped, and that a disk-level commit sequence syncs
strictly less than half the per-blob policy over identical work. The write
calls may still be buffered before the flush phase. These are injected-error
and crash-boundary recovery-ordering tests, not physical power-loss tests or a
proof of the filesystem/device's `fsync` fidelity. They do not emulate
abruptly killing the process while bypassing error cleanup.

Tests cover exact and zero-byte limits, idempotent immutable writes, missing and
corrupt/truncated blobs, manifest replacement and reopening, an injected failure
after the temporary manifest is synced but before replacement, invalid manifest
bytes, reachability retention, symlink rejection, and exclusive locking. Run with
`mise exec -- zig test src/store.zig`.

Streaming tests compare literal output bytes and hashes for newer-value wins,
deletions, terminal deletion removal, empty live values, and different tables.
They reject corrupt hashes, duplicate/unordered keys, invalid tags, trailing and
truncated frames, oversized counts, and huge declared key/value lengths. A
20,000-record merge producing over 420 KiB succeeds with a 17,000-byte fixed
allocator, including a second merge that verifies the preexisting output. This
proves the native primitive's allocation bound; the core Database still owns
in-memory bucket bytes/indexes and does not automatically use this store method.
Allocation-failure tests cover all four reader allocations across the two
passes, require complete workspace cleanup, and verify that no partial output
hash is installed.
A FIFO regression test first uses an I/O guard that fails any attempted open,
then checks real FIFO manifest/blob rejection. Removing the precheck makes the
guard assertion fail immediately, so even a regressed test run cannot hang on
the FIFO.

The public read tests scan 100,000 records (about 2.1 MiB) and perform verified
first-key and absent-key lookups with an 8,300-byte cursor allocator. They cover
owned results, empty values, tombstones, full-tail corruption, sticky scan
failure, strict framing and resource bounds, and allocation-failure cleanup.
A four-thread test concurrently puts/merges the same immutable output and reads
it through independent lookups and cursors on one Store. These primitive tests
support the new concurrency contract; they are not the complete disk-host
acceptance suite.
