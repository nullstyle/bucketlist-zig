# Native checkpoint storage

`src/store.zig` provides an independent native store for canonical bucket bytes
and opaque checkpoint manifests. It accepts an explicit `std.Io` and allocator.
The deterministic database and BucketList layers define the bytes and references;
the store neither interprets a schema nor decides which state is authoritative.

`Store.open(gpa, io, path)` returns an owned value. Call `deinit` exactly once.
An exclusive advisory `LOCK` file prevents another cooperating store from opening
the same directory. Calls on one Store must be serialized; there is no internal
thread synchronization. Readers receive owned byte allocations and free them with
the allocator supplied to the read.

The directory layout is:

```text
store/
  LOCK
  manifest
  blobs/
    <64 lowercase hex characters>
```

Each blob filename is SHA-256 of the exact contents. `putBlob(bytes)` creates a
temporary file, writes and flushes all bytes, syncs it, atomically installs it
without replacing an existing destination, then syncs the blob directory. On
macOS the file sync includes `F_FULLFSYNC`. An existing blob must have the same
contents and valid hash; corruption is reported and never silently repaired.
Successful `putBlob` means the blob is durable before its hash is returned.

`getBlob(gpa, hash, max_bytes)` checks that the file is regular, enforces the
inclusive byte limit before allocation and during reading, and recomputes the
hash before returning. Empty blobs are valid. Missing blobs, oversized files, and
hash mismatches are distinct errors. A truncation cannot pass hash verification.

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
size; lower per-record limits reduce the workspace. The two passes reuse it.

`publish(manifest_bytes)` first syncs the blob directory, writes a new manifest
to a temporary file, flushes and syncs it, atomically replaces `manifest`, and
syncs the store directory. Every referenced blob must already have been written
successfully through `putBlob`. The payload is opaque, so this precondition is
the caller's responsibility: the store cannot prove that references exist.

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
pinning in this low-level module.

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

The publication test matrix injects `IoFailed` after the header write call,
after the payload write call, after temporary-file sync, immediately before
replacement, after replacement, after directory sync, and after final-file
sync. It then closes and reopens the store through its ordinary API. Every
pre-replacement error preserves the old frontier; every post-replacement error
exposes the new frontier, and both referenced blobs still verify. The write
calls may still be buffered before the flush phase. These are injected-error
and crash-boundary recovery-ordering tests, not physical power-loss tests or a
proof of the filesystem/device's `fsync` fidelity. They do not emulate abruptly
killing the process while bypassing error cleanup.

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
