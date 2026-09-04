# Native checkpoint management

`bucketlist-checkpoints` exports `Checkpoints(DatabaseType)`, `Reference`, and
`Limits`. It owns a dedicated `bucketlist-store` directory and provides the
checkpoint publication and retention work that would otherwise be repeated in
application hosts. Its interface and local format are Experimental.

```zig
const Checkpoints = @import("bucketlist-checkpoints").Checkpoints(Directory);
var checkpoints = try Checkpoints.open(gpa, io, path, .{});
defer checkpoints.deinit();

var view = db.readView();
defer view.deinit();
const reference = try checkpoints.save(&view, exact_recovery_metadata);

var recovered = try checkpoints.load(gpa, reference);
defer recovered.deinit();
// recovered.database owns the restored typed database.
// recovered.metadata owns the exact application bytes passed to save.
```

The [standalone consumer](../examples/persistent-directory/main.zig) is compiled
and run in the ordinary test gate. To leave its files available for inspection,
choose a new storage directory and run:

```sh
mise exec -- zig build run --build-file examples/persistent-directory/build.zig -- /absolute/path/to/new-store
```

## Publication and ownership

`open(gpa, io, path, limits)` acquires the native store's exclusive lock and
checks any existing catalog framing. `current()` returns `null` for a new
directory or its published `Reference`. Opening and reading the catalog do not
perform full checkpoint restoration; `load` verifies the referenced contents.
Malformed storage is an error rather than an empty database.

`save(view, metadata)` takes a borrowed immutable database read view and opaque
application recovery bytes. It obtains an allocation-free layout of borrowed
canonical frames and checks the aggregate encoded size before staging files.
It stores each canonical bucket under its SHA-256
hash, including pending merge outputs, then stores an immutable manifest with
the checkpoint structure and metadata. Only after those writes are durable does
it atomically replace the catalog with the new reference. Identical bucket
contents share a file across levels and checkpoints. Existing files are verified
with bounded streaming reads instead of being rewritten.

The caller chooses the frontier: saving an older pinned view deliberately
publishes that older frontier. Save does not advance or modify the database,
prevent rollback, or validate application metadata. The host must enforce its
own advance/replay policy and ensure the metadata describes that exact view.

`Reference` contains `manifest_hash` and `database_digest`, both 32-byte SHA-256
values. The manifest reference covers application metadata as well as bucket
references. Equal database states saved with different metadata have different
manifest hashes. Keep the full reference when identifying a recovery point.

The manager, database views, and restored results are owned values and must not
be copied. Calls on a manager must be serialized. The allocator passed to `open`
must outlive the manager; the allocator passed to `load` must outlive its
`Restored` result and any database views taken from it. `Restored.deinit` releases
both the database and metadata. Loaded databases own their in-memory bucket
contents and remain usable after closing or collecting the on-disk store.

## Recovery and trust

`load(gpa, reference)` verifies the immutable manifest's hash and declared
database digest, parses all references and validates their aggregate lengths
before reading any bucket, then supplies hash-verified frames one at a time to
the typed database's `restoreFrom`. That validates
schema/profile identity, canonical records, level topology, pending outputs,
and the complete database commitment. Trailing or truncated input is rejected.

The full reference must come from trusted local storage or an independently
authenticated source. A database commitment alone does not authenticate the
opaque application metadata. For an untrusted checkpoint, certify the manifest
hash too, or independently authenticate and validate the metadata. The catalog
checksum detects corruption; it is not a validator certificate or rollback
protection. `current()` reads the local frontier and does not create trust in it.

For SLCP, recovery metadata can carry the exact previous agreed command and
application header. Encoding and validating that information remains the host's
responsibility. Perform filesystem publication outside `OwnedAppNode.apply`.

If writing an immutable bucket or manifest fails, the old catalog remains the
published frontier, and unused staging blobs may remain. If catalog publication
returns an error, the new frontier may already be visible. The manager becomes
poisoned and rejects further operations until it is closed and reopened. Read
the recovered frontier and apply the host's recovery policy; do not assume that
an error implies rollback.

## Retention and collection

`collect(retained_references)` automatically retains the current checkpoint and
all caller-selected historical checkpoints, including every pending bucket.
It fully loads and verifies every retained reference before deleting any file.
A missing, corrupt, incompatible, or oversized retained checkpoint aborts the
operation before deletion. Once verification succeeds, collection may still
fail after partial deletion due to an I/O error; every deleted blob was already
proved unreachable from the supplied set.

Retaining a `Reference` variable does not implicitly pin files. Include every
reference that must remain loadable in each collection call. Existing loaded
databases and read views need no disk pin because they own their contents in
memory. The directory must be dedicated to this manager: unrelated raw store
blobs are not recognized as live and may be collected. Unknown filenames and
nonregular files retain the low-level store's conservative handling.

## Resource and durability limits

`Limits.max_checkpoint_bytes` defaults to 1 GiB and cannot exceed the portable
database's limit. `max_metadata_bytes` defaults to 64 KiB; zero permits only
empty metadata. Limits are inclusive and local resource policies. They do not
change the database encoding or commitments.

Save borrows immutable bucket bytes directly. Its temporary heap allocations
scale with metadata and level descriptors, not total checkpoint size. A test
saves a database larger than 4 MiB using a 32 KiB manager allocator.

Load creates the owned in-memory database and keeps at most one input bucket
buffer at a time. It does not assemble an additional complete serialized
checkpoint. Bucket decoding and pending-merge validation still require temporary
allocations; the final input buffer can remain alive during that validation.
Collection restores retained checkpoints one at a time before deletion. This
manager is not an engine for databases larger than memory. Limits on encoded
input bytes are not exact bounds on total process memory. See the measured
[scalability comparison](performance.md).

The low-level store's Linux/macOS filesystem, synchronization, advisory-lock,
and trusted-directory requirements apply. See [storage.md](storage.md). The
manager adds reference validation and publication orchestration; it does not
provide journal replication, background compaction, physical power-loss
simulation, schema migration, or application-specific journal retention.

## Local format, version one

This format does not change any portable database encoding or commitment.
All integers below are unsigned and big-endian. Domain strings end in exactly
one NUL byte; no padding or trailing bytes is permitted.

The catalog is the payload inside the low-level store's checksummed atomic
`manifest` envelope:

```text
"bucketlist.checkpoint-frontier.v1\0"
manifest_hash[32]
database_digest[32]
```

The immutable manifest is a blob whose complete bytes hash to `manifest_hash`:

```text
"bucketlist.native-checkpoint.v1\0"
database_digest[32]
metadata_length:u64
metadata[metadata_length]
portable_checkpoint_header
level_count:u8
for each level, youngest first:
    current_length:u64, current_hash[32]
    snapshot_length:u64, snapshot_hash[32]
    pending_present:u8
    if pending_present == 1:
        pending_length:u64, pending_hash[32]
```

The portable header is exactly `"bucketlist.checkpoint.v1\0"`, schema hash
(32 bytes), profile hash (32 bytes), and advance (`u64`). The local parser bounds
level count to 1–31; the supplied database's strict restore additionally requires
its exact profile and level count. Pending presence accepts only 0 or 1.
Each bucket hash addresses the complete canonical portable bucket frame, whose
length must equal its manifest length. Empty buckets use the ordinary canonical
empty frame and share its real content hash; they are never absent sentinels.
