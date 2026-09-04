# BucketList directory over SLCP

This optional consumer imports both `bucketlist` and the Experimental
`slcp.OwnedAppNode` API. The core library has no SLCP dependency, and normal
`zig build test` does not build this package.

Run from the repository root:

```sh
./tools/slcp-smoke.sh
```

The script uses the root `mise.toml` compiler pin, prepares SLCP revision
`458e25effc3e9676ac02f9a34c104521a5e0757b`, verifies its Cap'n Proto Zig package
by the pinned content hash, and runs the adapter, loopback, and process-crash tests. The SLCP
revision is not available from its public GitHub archive URL, so the script
reads that commit with `git archive` from `../slcp-zig`; set `SLCP_SOURCE` to
another checkout containing the same object if needed. Uncommitted work and
newer commits in that checkout do not enter the build. Extraction, package
resolution, compiler caches, and test state are all inside `bucketlist-zig`.
The script never builds or writes in the source checkout. A releasable
standalone consumer still needs an accessible immutable SLCP source URL.

The small application has two tables: 26 account balances and 26 names that
map to their account IDs. This finite domain bounds state and observation
costs; balances demonstrate final record values and do not implement payment
authorization. A bounded canonical command contains its next advance, prior
database commitment, prior application header, and the final account/name
changes. The name mapping is periodically deleted and recreated by the test.
The maximum encoded consensus value is 125 bytes, below SLCP's 4096-byte
default. The database root is calculated after deterministic apply.

Validation and combination allocate no memory. Structural validation runs
for every command; a successor whose predecessor is ahead of local state is
`maybe_valid`. An immediate successor must match the current commitment and
header. Combination selects the smallest canonical encoding among admitted
candidates, retaining one candidate's valid/maybe-valid verdict. Apply
prechecks the immediate successor, prepares all allocations, then publishes
both tables atomically. OOM propagates through SLCP's fail-stop contract;
other database errors after that precheck are fatal invariant violations.

Application headers bind the network name, previous application header,
exact canonical consensus command, and resulting database commitment. This
is a local deterministic commitment, not a quorum certificate. Observations
own complete independent checkpoints, avoiding shared storage ownership across
engine and user threads. Every observation is
released through the node; startup borrows a trusted local snapshot only
while constructing independently owned state.

The automated checks exercise:

- Strict command round-tripping, future-state validation, deterministic
  combination, two-table application, and checkpoint continuation.
- Three real TCP loopback nodes with a 2-of-3 quorum comparing every database
  commitment and application header through advance 12.
- An advance-7 checkpoint followed by journal advances 8 and 9, shutdown and
  recreation of one node, exact replay of 8 and 9, then live convergence
  through advance 12. `initialSlot` and `initialCommand` come from the restored
  snapshot so nomination retains the exact predecessor value.
- Three independent host processes: retain node 2's application checkpoint at
  advance 7, advance its journal to 9, send SIGKILL and require exit status 137,
  then advance the two survivors to 11. The restarted process restores 7,
  replays its local journal at 8 and 9, and obtains missing advances 10 and 11
  from peers. Stop another voter and require the restarted node to form quorum
  for advance 12. Compare the exact canonical command, database commitment,
  and application header at every overlapping advance.

The subprocess host uses `bucketlist-store` to make checkpoint blobs durable
before atomically publishing its application manifest. This occurs on the
observation-consumer thread, outside `OwnedAppNode.apply`; errors stop the
host and leave restart to recover from the published checkpoint and journal.
The fixture deliberately freezes one checkpoint to prove replay and network
catch-up; it does not truncate the SLCP journal or perform blob garbage
collection. A general production host still needs explicit error handling,
backpressure, checkpoint cadence, and journal-retention policy.

The process fixture retains per-slot values and child logs under the printed
`.zig-cache/slcp-process.*` directory. Its staged targets are 7, 9, 11, and 12,
covering BucketList spill boundaries and a two-slot outage within SLCP's
answering window. SIGKILL tests process failure; it does not emulate sudden
power loss or exhaust every possible storage-publication crash boundary.
