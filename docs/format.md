# Database format, version 1

This is the implemented Experimental format. Changes require new format or
schema identifiers and new vectors. Stellar byte compatibility is not a goal.

## Canonical records and schema

[encoding.md](encoding.md) defines the built-in codec, structural schema
descriptor, bounds, enum tags, and signed integer ordering. Tables are sorted
by explicit numeric ID; keys by their canonical bytes. `Bytes(N)` keys sort
by length first, then unsigned bytes. Names and values receive no Unicode
normalization.

Schema identity describes encoded structure, not business meaning. Changes
that preserve the type layout but change interpretation require an explicit
application schema-version bump; the library cannot infer that intent.

One mutable batch is tied to a database and its exact starting commitment.
Repeated calls for a key take the last value or deletion. Preparing the batch
sorts distinct identities, omits puts equal to the starting visible value,
and omits deletes absent from the starting visible state. Thus create/delete
of a previously absent key and delete/recreate of an unchanged value disappear
from the canonical changes. This reduction happens before any bucket is built.
It depends on the batch's starting state, not on local storage shape.

An empty normalized batch still advances the sequence. An uncommitted batch
or prepared result has no effect on committed state. Preparation may allocate;
publication checks its owner/base/token and then transfers ownership without
allocation. Only one writer is permitted; `Database`, `Batch`, `Prepared`, and
`ReadView` are owned values and must not be copied.

## Buckets and list

[structure.md](structure.md) specifies bucket framing, hashes, factor-four
scheduling, delayed promotion, and deletion retention. The public database
uses eleven levels. Reduced-depth profiles in tests have different hashes.

Genesis has sequence zero and empty current/snapshot buckets at every level,
with no pending merges. Successful advances must be exactly `previous + 1`;
advancing beyond `u64` maximum is rejected. Format-affecting settings are not
per-node tuning options.

## Database commitment

All digests are SHA-256. `||` is byte concatenation; integer suffixes name
their exact widths and byte order. Domain literals include the shown NUL.

```text
digest = SHA256(
    "bucketlist.database.v1\0" ||
    schema_hash:32 || profile_hash:32 || sequence:u64be ||
    bucket_list_root:32 || continuation_hash:32
)
```

`Commitment` exposes `advance`, `bucket_list_root`, `continuation_hash`, and
`digest`. The continuation hash binds the presence and contents of pending
merge outputs. The list root alone excludes them. Empty advances can preserve
the list root but always change the outer commitment's sequence.

The application should bind `digest` into its own network-separated ledger
header together with its preceding header and the agreed value or its hash.
This library does not certify agreement, choose network trust, or make the
agreed application data available.

## Checkpoint

`checkpoint(gpa)` returns owned bytes in this order:

```text
"bucketlist.checkpoint.v1\0"
schema_hash:32
profile_hash:32
sequence:u64be
for level in 0..11:
    current_length:u64be, current_bucket_bytes
    snapshot_length:u64be, snapshot_bucket_bytes
    pending_present:u8                 // exactly 0 or 1
    if present: pending_length:u64be, pending_bucket_bytes
```

There is no trailing data. The current convenience format embeds complete
bucket frames, including empty buckets and repeated immutable contents. It
favors simple independent recovery over checkpoint size; the native blob store
can deduplicate separately managed bucket files.

`restore(gpa, bytes, expected_digest)` validates framing, schema/profile,
canonical typed keys and values, table membership, schedule shape, and exact
pending merge outputs recomputed from their inputs. It then checks the complete
database digest, including continuation state. Unsupported or inconsistent
data is rejected and all allocations are released. Checkpoints are bounded to
1 GiB by this implementation; the caller must bound input before reading it.

`expected_digest` must come from trusted local state or an application-verified
certificate. Reading an expected digest from the same untrusted checkpoint
does not authenticate it. Native store manifests provide local integrity and
durable publication, not consensus certification.

A logical export can seed a new history; it does not recreate an older
history's bucket layout. Restore the exact checkpoint when continuing a
previous history. SLCP applications also retain the exact preceding consensus
value, not merely its digest.

## Ownership and concurrency

Reads return decoded bounded values. `readView()` retains immutable buckets
and remains valid after later commits; its iterator yields visible records in
canonical key order. The view must outlive its iterators. Both the database and
view must be deinitialized, and their allocator must outlive all retained data.

The allocator passed to `prepareAdvance` owns its new buckets and must outlive
their committed state and all retained views; it need not equal the allocator
that first initialized the database.

Bucket reference counts are atomic. Acquire a view on the serialized owning
thread; that fact alone does not make concurrent access to a mutable database
safe. A view may be handed to another thread only when its allocator supports
freeing there. Release observations before destroying the allocator.

## Evidence

Codec and schema literals are checked in their source tests. Bucket/list
literals and independent executable model traces pin the complete format.
Tests additionally compare visible data with a simple map, exercise sequence
boundaries and empty advances, and inject allocation failures. A map oracle
proves logical semantics; it cannot prove the representation hash by itself.
