---
status: accepted
---

# Preserve v1 commitments with a disk engine and bounded delivery host

The in-memory database and native checkpoint manager establish exact v1
commitments, but their restored database still retains all bucket contents in
memory. The user has authorized a disk-resident typed engine, real background
merge workers, and a bounded native host/SLCP lifecycle. This decision is
accepted; M7–M9 are implemented with the acceptance evidence recorded in
[validation.md](../validation.md).

Export `Database(Schema)` and `Host(Schema)` from the separate native
`bucketlist-disk` module. The disk database retains a frontier of current,
snapshot, and pending bucket hashes, with canonical record contents in
immutable files. Preserve the exact v1 schema, bucket, profile, level, root,
continuation, and database hashes. The disk manifest is a separate local format
that atomically binds the frontier and bounded application recovery metadata;
it does not embed the memory checkpoint wire format or inherit its aggregate
checkpoint-size cap. The existing portable database and checkpoint manager
remain supported independently.

Derive merge jobs from one immutable pre-advance frontier, applying the v1
rotation/promotion rules to candidate descriptors. Independent jobs may run on
different worker threads, and completion order has no consensus meaning. V1
commits to every pending output hash, including outputs not yet visible to
reads. Publication therefore waits for all required jobs to finish durably.
Publishing unresolved job descriptors and filling in their hashes later would
change the authenticated continuation contract and requires a different format.
This choice permits real parallel work while preserving current hashes; it does
not promise bounded advance latency or unfinished work spanning published
advances.

Working memory scales with bounded batches, worker record buffers, the bounded
delivery backlog, frontier descriptors, and explicitly retained read views,
rather than total bucket-file size. Initially, a point lookup streams and
authenticates a complete bucket before returning a match, tombstone, or absence.
This is linear I/O, and opening a database likewise validates bucket contents
and pending outputs. Read views pin disk frontiers; collection includes current,
retained, and pending references and runs only after active work is quiescent.
Indexes and caches are later optimizations, not a reason to weaken validation.

`Host.trySubmit` is nonblocking: it attempts admission without waiting for
storage, moves the bounded batch only on success, and copies metadata into
bounded queue storage. Capacity includes both queued and active work until
durable publication. Acceptance is distinct from durable acknowledgement.
Execution failures latch and stop later advances; ambiguous publication requires
closing and reopening to discover the authoritative frontier. The host cannot
skip an agreed advance or interpret an I/O failure as an invalid command.

The native SLCP consumer uses raw `Node` and its existing `DeliveryHook`, whose
live callback only performs bounded admission. Backpressure is explicit and
fails the node closed. The callback does not wait for merge jobs or perform
filesystem publication, and the owned in-memory application callback gains no
new I/O contract. An opt-in companion application durability watermark
clamps local journal compaction to preserve every value after the published
frontier. Only the controlling thread acknowledges completed Host publication;
control admission and the engine-applied watermark are distinct. A publication
that wins the callback-return race may temporarily be ahead of successful
delivery, so its acknowledgement must be retried. Peer answering, bounded engine
state, and gap policy keep their existing semantics. The companion change is
Experimental and preserves its Stable surface.

Recovery outside the live callback restores the exact saved previous value,
replays a contiguous journal suffix, and then resumes delivery. The initial
pinned consumer established the same recovery behavior with a conservative
backlog/window bound; the explicit watermark removes that implementation-dependent
retention assumption. The user extended workspace ownership to `slcp-zig` and
provided its handoff before this companion change.

The trade-off is an explicit fail-stop recovery path and potentially expensive
authenticated reads, in exchange for bounded memory, preserved commitments,
and a clear durable publication point. M6 release hardening remains open. The
[disk contract and acceptance gates](../disk.md) and [roadmap](../plan.md) track
the delivered evidence and remaining release-hardening work.
