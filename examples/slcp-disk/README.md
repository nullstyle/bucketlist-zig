# SLCP with a bounded asynchronous disk host

This optional consumer connects the pinned SLCP raw `Node` to
`bucketlist-disk.Host`. Each consensus value carries a bounded command containing
an advance number, the previous command hash, and blind account/name writes.
Validation and deterministic candidate selection inspect only that command chain.
The disk worker prepares and publishes the database after externalization.

The agreed command hash and the asynchronously computed database commitment are
different values. The database commitment is deterministic given the complete
command sequence; this example does not make the quorum certify that commitment
or validate database-dependent conditions such as sufficient account funds.
Applications needing such rules need an additional execution/validation design.

Run from the repository root:

```sh
./tools/slcp-disk-smoke.sh
```

The script uses the repository's mise compiler and materializes the immutable
SLCP commit `e2c48987e4f1237f1b87ee27c148ce51edfe8fda` from `SLCP_SOURCE` (default
`../slcp-zig`) with `git archive`. It neither changes nor builds that checkout.
The companion, Zig package data, and local/global build caches all live inside
this repository's `.zig-cache`. The Cap'n Proto dependency is verified against
the package hash pinned by SLCP. This consumer is optional and ordinary library
tests do not need SLCP.

## Delivery and publication

The raw delivery hook gives this adapter a direct, synchronous handoff after
SLCP's durable externalization-journal append. It avoids the observation queue
of the typed convenience facade. The live hook creates a bounded two-table batch
and calls `Host.trySubmit`; it performs no filesystem I/O and never waits for the
disk worker. Successful submission transfers ownership of the batch and copies
the exact canonical command into the Host's bounded metadata slot.

Capacity two includes active and queued advances until durable publication. A
full queue or transient admission-lock conflict fails delivery with
`DiskBackpressure`. SLCP then becomes inert. The controlling thread closes that
Node, waits for accepted work to drain, and recreates it from the last durable
Host snapshot. The rejected command remains in SLCP's journal. Disk worker or
other consensus failures terminate the process instead of skipping commands.

The startup recovery hook checks that the journal contains a contiguous suffix
starting no later than the published checkpoint's successor. Recovery passes the
exact checkpoint metadata as SLCP's previous consensus value. Journal callbacks
on the creating thread may retry admission and wait for each publication; live
callbacks run on the engine thread and never use that waiting path. This avoids
confusing successful Node creation with the beginning of its engine thread.

## Journal retention

The adapter enables SLCP's experimental `RecoveryOptions.retain_until_durable`
mode. The exact recovered previous command initializes the durability watermark
from the trusted Host checkpoint. Only the controlling thread calls
`Node.acknowledgeDurable`, using the Host's published advance. It never
acknowledges admission to the queue as durable state.

SLCP processes acknowledgments through a bounded, coalesced control path and
clamps journal compaction so that the first command after the durable watermark
remains available. Peer-answering and consensus-engine retention remain separate.
`Node.durableApplicationSlot` reports the acknowledgment actually applied by the
engine, and this example checks it never exceeds Host publication.

A worker can publish before the live callback finishes returning to SLCP, so an
`AheadOfDelivery` rejection is retried by the controlling thread. A closed or
failed Node does not imply acknowledgment; recreation starts again from the
trusted published checkpoint. Disk I/O and acknowledgment waits never run inside
the live callback.

The answering window remains 16 and Host capacity remains two. The fixture
requires `answering_window > capacity + 1` to keep its intentionally missing
network slots inside peers' answering coverage. This is separate from the
explicit watermark that protects local journal replay. Catch-up beyond available
peer history needs an independently trusted checkpoint import.

## Process fixture

`process-test.sh` launches three independent loopback processes with a two-of-three
quorum. It compares database commitments, command hashes, and exact command bytes
at controlled durable barriers. A maintenance pause after advance 7 prevents the
third worker from starting work: advances 8 and 9 fill capacity, and journaled
advance 10 causes failclosed backpressure. The surviving quorum reaches 11.

The script sends actual SIGKILL to the paused process and requires exit status
137. On restart the node restores durable advance 7 and replays 8 through 10 from
its local journal; the surviving peers supply missing advances 11 and 12. It
then runs through 70, inspects a stopped node's compacted journal, and removes a
voter to require the restarted node's participation in quorum at 71. Evidence
files and process logs remain under `.zig-cache/slcp-disk-process.*`.

Pause is an explicit maintenance control, not a sleep inside the consensus
callback. The fixture avoids Host polling while paused, allowing its capacity
assertion to distinguish a full queue from transient admission-lock contention.
It compares roots at the controlled barriers, not every intermediate publication.

Verified on 2026-09-04 with the pinned commit above:

- Consumer build: 8/8 steps; 3/3 focused tests.
- Actual paused pressure: durable 7, accepted 9, capacity 2, rejected journal 10.
- SIGKILL exit 137; exact local replay 8–10, then peer catch-up 11–12.
- Engine-applied durability watermarks reached 7, 70, and 71 at the checked
  barriers; database roots and exact command bytes matched.
- Actual journal inspection after 70: first 49, last 70, 22 retained records.
- The restarted process participated in the surviving quorum at 71.

Evidence remains in `.zig-cache/slcp-disk-process.SbxJuK`. An earlier run against
SLCP `458e25effc3e9676ac02f9a34c104521a5e0757b` is retained separately at
`.zig-cache/slcp-disk-process.fZ0Mc6`; that predecessor relied on the bounded
backlog/window relationship instead of the explicit durability watermark.
