# Disk database and bounded native host

Status: **implemented and verified**, Experimental `0.1.0-dev`. M7–M9 preserve
all v1 consensus hashes. The [validation record](validation.md) reports the
platform, resource, failure, and integration gates; [ADR 0001](adr/0001-disk-engine-and-bounded-delivery.md)
records the architectural decision.

## Modules and ownership

`bucketlist-disk` exports `Database(Schema)` and `Host(Schema)`. A developer uses
the same typed table and canonical codec definitions as the portable
`bucketlist` database. The disk engine stores canonical bucket contents in the
native [Store](storage.md), retaining frontier descriptors and hashes in memory.
Its operations can fail with allocation or I/O errors.

The portable database continues to own in-memory buckets. Its
[checkpoint manager](checkpoints.md) persists that database efficiently but
restores its contents into memory. The disk engine uses a dedicated local
manifest containing schema/profile identity, advance, current/snapshot/pending
hashes and bounded opaque recovery metadata. Its catalog names that immutable
manifest and the complete database digest. This format is separate from the
portable checkpoint and checkpoint-manager catalog.
Aggregate database size is not constrained by the portable checkpoint's 1 GiB
cap; local bucket, record, batch, and metadata limits still apply.

Disk read views retain a fixed frontier and pin its referenced files until
released. They do not copy the logical database into memory. Collection must
retain the current frontier, live read views, explicitly retained historical
frontiers, and pending work. The owner must quiesce active cursors and worker
jobs before collection or store shutdown. A bare copied hash does not register
a pin.

## Local disk encoding

The manifest blob is SHA-256 content addressed and uses this exact framing:

| Field | Encoding |
| --- | --- |
| Domain | `bucketlist.disk-frontier.v1` followed by NUL |
| Schema and profile | Two 32-byte hashes |
| Advance | `u64` big endian |
| Each profile level | Current hash, snapshot hash, pending tag (`0` or `1`), then pending hash only for tag `1` |
| Application metadata | `u32` big-endian length followed by exactly that many bytes |

The profile fixes the number of levels; ordinary `Database(Schema)` uses eleven.
The catalog payload is `bucketlist.disk-current.v1` followed by NUL, the 32-byte
manifest hash, and the 32-byte database digest. Store wraps and atomically
publishes that payload using its checksummed manifest format. Trailing bytes,
unknown tags, mismatched schema/profile, and oversized metadata are rejected.
Use a dedicated store directory: this catalog is not interchangeable with
`Checkpoints(Database)` catalogs. `Options.expected` accepts an independently
trusted full reference. Empty buckets use their real canonical hash; a present
empty pending hash differs from absent pending work.

## Exact commitments and parallel work

All v1 canonical bytes and hashes remain unchanged. Disk and portable engines
must produce identical database and continuation commitments for the same
schema and ordered normalized batches, including empty advances and terminal
tombstone removal.

Preparation derives the complete job set from the immutable pre-advance
frontier. It applies the prescribed rotations and promotions to candidate
descriptors and gives independent merges their fixed input hashes. Worker
completion order cannot choose input precedence or change the schedule.
Worker count and queue sizes are local resource policies.

Real worker threads perform the streaming file merges. Every output required
by the candidate's continuation commitment must be known and durable before
the frontier is published, even if that output is not visible until a later
advance. A failed job prevents publication of an incomplete candidate. The
durable atomic manifest replacement publishes the database frontier and its
application metadata together; an error after replacement is ambiguous and
requires reopening before further publication.

The working-memory budget includes bounded batch staging, bounded admitted
work, a record workspace for each active worker, metadata, and descriptors for
retained frontiers. No operation may retain all bucket contents or construct a
complete serialized database merely to read, merge, open, or publish it. Retained
view count and application-owned state must be budgeted too.

## Reads and recovery validation

The first implementation uses authenticated linear point reads. It searches
current/snapshot buckets in the v1 precedence order, fully verifies each bucket
it reads, and distinguishes an absent identity from a tombstone and a live empty
value. Finding a matching record early does not bypass verification of its tail.
This bounds memory but can make reads and unchanged-write detection expensive.

Opening a disk frontier validates its local framing, schema/profile, all unique
referenced bucket files, typed canonical records, schedule shape, terminal
tombstone rules, and recomputed pending outputs before accepting the database
commitment. A streaming cursor's rows and header counts are provisional until
verified EOF. Corruption cannot be converted into a missing record or an empty
database. Local checks establish integrity; checkpoint authenticity and rollback
policy still belong to the application. A missing catalog with non-genesis
canonical blobs fails with `MissingManifest`; it cannot silently reset a
populated store. Initialization may resume when only the known empty bucket
and deterministic genesis manifest remain from an interrupted first open.

`Options.expected` accepts a full trusted `Reference`: both manifest hash and
database digest. Comparing it with the local catalog detects rollback relative
to that external expectation. Without an external expectation, a valid older
catalog can still pass local integrity checks. The manifest hash also binds
opaque metadata, which the database digest alone does not authenticate.

## Host admission and durability

The host owns one serialized advance stream and a bounded delivery backlog.
Its thread-safe allocator and `std.Io` must outlive all worker threads.

| Operation | Contract |
| --- | --- |
| `trySubmit` | Attempts the admission lock without waiting. Contention or full capacity returns `Backpressure`. Only success moves the batch; the caller's batch becomes empty and safe to deinitialize. Metadata is copied into preallocated bounded slots. |
| Sequence admission | Requires the next contiguous advance. Gaps/repeats return `InvalidSequence`; advancing past `u64` returns `SequenceExhausted`. |
| Input bounds | Oversized batches/metadata return `BatchTooLarge`/`TooLarge` before admission and preserve caller ownership. |
| Capacity | Counts queued and active work until durable publication completes, so removing an item from the queue does not free admission capacity early. |
| `wait(advance)` | Waits for a durable acknowledgement. A frontier never admitted returns `NotAccepted`. Already durable advances remain acknowledged even after a later failure. |
| Failure | The original execution error latches and rejects subsequent submissions. A failed publication may already be visible; close/reopen resolves the durable frontier. |
| `snapshot` | Returns a coherent cached durable commitment/reference and owned recovery metadata. Allocation occurs outside the short admission mutex. |
| `pause` / `resumeProcessing` | Control starting the next item; an already active advance continues. |
| Shutdown | Closes admission with `Closed`, resumes/drains accepted work and joins workers; after a latched failure it disposes unpublished queued work. |

Successful submission does not mean durable publication. Rejected submission
leaves ownership with the caller. Accepted work must either reach the durable
frontier or be recovered from the application's durable agreed-value history;
it must never be silently dropped while later advances are published.

## Native SLCP delivery lifecycle

The consumer is `examples/slcp-disk`. It uses raw `Node` with
`DeliveryHook`, leaving `OwnedAppNode` as the existing portable example's
interface. The command model uses bounded canonical blind writes and binds the
exact predecessor command. A future command whose predecessor is unavailable
is deferred by the validation policy. This is command agreement, not a separate
certificate of the database root.

SLCP appends an agreed value to its journal before the delivery hook. The live
hook prepares the bounded typed effects and calls `trySubmit`; it performs no
disk I/O and waits for no host worker. A full or contended host queue is surfaced
as explicit disk backpressure and fails delivery closed. The journal remains the
source for the rejected or accepted-but-unpublished suffix.

The companion's opt-in `RecoveryOptions.retain_until_durable` initializes an
application durability watermark from the trusted checkpoint's exact previous
value. The controlling thread calls `Node.acknowledgeDurable` only after a Host
snapshot confirms publication. `AheadOfDelivery` is retryable: the worker can
publish before the live delivery callback returns. Acknowledgement admission
and the engine-applied `durableApplicationSlot` are distinct.

The engine clamps local journal compaction to retain every value after that
durable frontier. This keeps application recovery independent of queue/window
arithmetic; the peer answering window and engine cache/gap policy retain their
existing semantics. Recovery outside the live callback restores the exact
previous command from durable metadata and replays contiguous values, waiting
for each replayed advance as needed. Reject gaps. Distinguish creating-thread
recovery from live engine delivery without a mutable startup flag.

Stop node delivery before draining/joining the host and closing the store.
After ambiguous publication, reopen the disk database and choose the replay
range from the recovered durable frontier, not from the last failed return
value. The consumer pins the companion's Experimental watermark interface and
verifies its real delivery/recovery behavior. Its Stable answering-window
contract is unchanged.

## Acceptance evidence

- 93 native tests pass on macOS ARM64 and Linux ARM64, Debug and ReleaseSafe;
  x86_64 Linux cross-compiles, and the independent native/WASM trace is unchanged.
- Deterministic frontier planning matches the portable engine at depths 1, 2, 3,
  and 11 with varied job completion order. Native file execution, reopen, empty
  advances, deletion precedence, and reduced terminal profiles are checked.
- A 1,580,957-byte bucket operates under a 131,072-byte allocator cap, with a
  measured 36,041-byte peak. This excludes stacks, Io backend, and OS cache.
- Corruption, forged pending hashes, missing catalogs, allocator failures,
  publication errors, pinned GC, admission contention/full capacity, active
  publication, and draining/failed shutdown have regression coverage.
- Standalone portable, checkpoint, and disk-host consumers pass from a clean
  package without a sibling repository.
- The SLCP consumer pins `e2c48987e4f1237f1b87ee27c148ce51edfe8fda`. Three real
  processes verify durable 7/accepted 9 backlog, journaled rejection at 10,
  SIGKILL exit 137, exact replay and peer catch-up, journal compaction at 64,
  engine-applied publication watermarks, and restarted participation in quorum
  at 71. The companion's full suite, strict Stable API gate, and eight socket
  E2E scenarios also pass.

Authenticated point reads remain linear scans. M6 retains sustained fuzzing,
production-scale performance work, release review, and distribution of an
accessible immutable SLCP dependency. These interfaces remain Experimental.
