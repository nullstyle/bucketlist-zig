# Build plan for bucketlist-zig

Date: 2026-09-04. Status: the Experimental baseline is implemented; the
authorized M7–M9 disk-engine and native-host phase is **implemented and verified**. M6 release
hardening remains open. See [validation and remaining scope](validation.md) for
delivered evidence and [ADR 0001](adr/0001-disk-engine-and-bounded-delivery.md) for
the architectural extension. The format documents continue to define the
unchanged v1 commitment contract.

## 1. Intended product

Build a small, typed database library whose incremental state commitments are
derived from immutable, sorted buckets and a deterministic BucketList. A Zig
developer defines their own tables, keys, and values. They should not need to
manage bucket levels, canonical byte encodings, or deletion retention to use
the database correctly.

The user's explicit scope is **application-defined databases, with no Stellar
compatibility requirement**. Borrow the BucketList structure and the useful
merge/scheduling invariants, and define an independent, versioned format.
Stellar XDR types and historical protocol compatibility are not dependencies.

The first useful delivery is an in-memory database with two typed tables,
atomic changes across them, deterministic commitments, exact checkpoint
round-trips, and an SLCP consumer example. Disk-resident operation now follows
in M7–M9, including real parallel merge workers and an explicit bounded
publication/delivery lifecycle. SQL, a query planner, automatic secondary
indexes, network replication, Stellar transaction execution, and succinct record proofs are
outside the initial scope.

The user has authorized work across this workspace, including companion
changes if integration requires them. The phase adds an Experimental application durability watermark to `slcp-zig`
while preserving its Stable answering policy, and verifies the consumer against
an immutable companion snapshot. Keep the main package independently consumable.

## 2. Research baseline and implications

The companion was inspected at
[`slcp-zig` 458e25e](https://github.com/nullstyle/slcp-zig/tree/458e25effc3e9676ac02f9a34c104521a5e0757b).
The structural reference is
[`stellar-core` 100cc38](https://github.com/stellar/stellar-core/tree/100cc3816c59357df488b17972aa5e2846ead831),
dated 2026-08-14, not an assertion about the latest release or public-network
protocol. The local Stellar checkout is sparse: missing files were inspected
from Git objects without expanding or changing that checkout.

The [research report](research/stellar-bucketlist.md) records the detailed
source evidence. The design consequences are:

| Finding | Consequence for this library |
| --- | --- |
| BucketList is a leveled collection of immutable sorted runs, with current and snapshot buckets and scheduled merges. | Implement deterministic scheduling as part of the format, separately from when a worker happens to finish computing a merge. |
| Bucket hashes commit to encoded records; level/root hashes commit to the ordered bucket representation. | Specify exact framing, sorting, tags, and empty behavior before writing the optimized implementation. |
| Different histories can produce the same live records but different bucket representations. | Name the result `bucket_list_root`; do not promise a canonical hash of the logical map. |
| Empty ledger advances can rotate buckets. | An empty batch still advances the schedule; never skip it as a no-op. |
| Tombstones prevent older records from resurfacing. | Retain deletions until a specified merge proves there is no older value left to hide. |
| Stellar has additional INIT entries, shadows, protocol transitions, and a hot archive. | Start with put/delete semantics; do not import those domain-specific or historical mechanisms. |
| Stellar's ledger-header commitment and its SCP value are different concepts. | Keep database commitments distinct from consensus values and validator attestations. |

The existing registry currently computes `SHA256(canonical full-state bytes)`
after apply and includes that root in its header. Replacing it with a
BucketList root changes observable hashes and restart verification; it is an
application format/network epoch, not a transparent optimization. Demonstrate
the new library in its own example first.
Sources: [registry state root and header](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/examples/registry/src/registry.zig#L614),
[registry apply](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/examples/registry/src/registry.zig#L794).

## 3. Developer-facing interface

### Typed schema

Make `Database(Schema)` the main interface, exported from module `bucketlist`.
The following illustrates the intended shape; it is **design notation, not
implemented or compile-checked Zig**:

```zig
const Schema = struct {
    pub const namespace = "example.directory";
    pub const version = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, AccountId, Account),
        .names = bucketlist.Table(2, Name, NameRecord),
    };
};
const Directory = bucketlist.Database(Schema);

// Allocation-free point reads; typed keys and values.
const owner = db.get(.accounts, account_id);

// Sketch: stage the final effects of one application ledger.
var batch = try db.batch(gpa);
defer batch.deinit();
try batch.put(.accounts, account_id, account);
try batch.delete(.names, name);

// Prepare owns all fallible work. Publication does not allocate.
var advance = try db.prepareAdvance(gpa, next_slot, &batch);
defer advance.deinit();
try db.commit(&advance); // rejects a stale base before any mutation
const commitment = db.commitment();
```

Resolve the exact spelling by implementing a two-table consumer in M1, then
keep the public surface small: create/deinit, typed get, ordered read view,
batch put/delete, prepare/commit, commitment, checkpoint/restore.

Schema rules:

- Each table has an explicit stable numeric ID, key type, and value type.
  Table declaration order, Zig type names, addresses, and compiler reflection
  strings must not define on-disk identity.
- The built-in codec covers fixed-width integers, booleans, fixed byte arrays,
  structs, explicit enum tags, and library bounded byte strings. These cover
  account-like and directory-like data without pointers in encoded records.
  Unsupported types produce useful compile errors. Add optional values or
  tagged unions only with specified tags and malformed-input vectors.
- A versioned canonical schema descriptor binds the application's namespace
  and schema version, table IDs, key/value layouts, field order, bounds, and
  enum tags. The application version is separate from the library descriptor
  and format versions. Hash that descriptor, not `@typeName`.
  A changed descriptor requires an explicit database epoch; automated migration
  is outside v0.1.
- A custom canonical codec is an advanced extension after the built-in schema
  works. It needs a stable codec ID/version, bounded decoding, and conformance
  vectors. Arbitrary user comparators must not enter the first format.
- Keys are ordered by `(table_id, canonical_key_bytes)` using unsigned byte
  order. Integer key encoding preserves numeric order. Specify bounded-string
  key ordering separately from value length framing; do not accidentally
  promise lexical string ranges if a length prefix changes their order.
  Bound encoded key sizes so reads use fixed scratch without allocation.
  Byte strings are raw bytes; there is no implicit Unicode normalization.
- Secondary indexes, when needed, are ordinary application-maintained tables
  updated in the same atomic batch. Database integrity is distinct from
  application constraints such as account ownership or uniqueness across tables.

### Batch and ownership rules

Applications execute their transactions deterministically, then supply the
batch's final effects. The batch builder may coalesce repeated changes to one
key in explicit call order; the canonical committed batch has at most one
effect per key and is strictly sorted. Encoded duplicate keys are rejected.
Putting a value replaces the record; deleting an absent record is a specified
no-op. M1 pins whether unchanged puts are omitted, including delete/recreate
cases, so implementations cannot disagree on bucket bytes.

Use an explicit allocator and owned immutable bucket data. Preparation builds
all replacement buckets and metadata before publishing anything. An OOM or
invalid batch leaves the database root, frontier, and readable records intact.
`commit` checks the prepared base/profile/advance, then publishes without
allocation or other fallible work. A stale prepared result fails without
mutation. Dropping an uncommitted result releases its memory.

Read lifetime must be explicit: point results are values for bounded types;
read views pin immutable storage and have `deinit`. No reader borrows mutable
storage across a commit. Stage resource use must be bounded and measured; an
implementation that clones the entire database for every batch defeats the
reason for using buckets.

Initially allow one mutable batch at a time. It is tied to its starting
frontier, cannot outlive the database, and is consumed on publication. Shared
read snapshots across SLCP's engine/user threads need explicit release rules
and a thread-safe allocator/refcount policy; start with independently owned
observations before optimizing shared storage.

## 4. Commitment and scheduling contract

Write `docs/format.md` in M1 as the normative byte contract, backed by literal
vectors. This plan recommends the following design, but does not freeze tags
or byte layouts before that work:

- SHA-256 via `std.crypto`, with distinct fixed domain tags for bucket, level,
  list, schema/profile, and database commitment. Use `[32]u8` digest payloads
  with named semantic wrappers where they prevent mixups. Do not reuse SLCP
  statement, quorum-set, or nomination preimages.
- Explicit fixed-width endian rules and bounded, unambiguous record framing.
  Hash canonical serialized bytes, never struct memory, padding, filenames,
  compression artifacts, or native-endian integers.
- The bucket preimage binds its format and ordered put/tombstone entries.
  A level binds its index and current/snapshot hashes. The list binds the
  ordered levels and profile. Specify one empty bucket representation and the
  exact empty list root; Stellar's zero-hash sentinel need not be copied.
- A `DatabaseCommitment` binds the schema/profile, logical advance number,
  and BucketList root. The application's ledger header separately binds its
  network identity, previous header, exact agreed value or its digest, and
  this commitment. A bare root provides neither an explicit complete history
  chain nor evidence of quorum agreement.
- One initial profile uses the reference's factor-four level schedule and
  eleven levels, including a precisely specified terminal level. Advance
  numbers are checked `u64` values; overflow and unsupported transitions are
  errors. Genesis, the first advance, all spill boundaries, and the terminal
  retention rule must be stated explicitly, not inferred from diagrams.
- The first profile uses upserts and tombstones, newest visible version wins,
  with tombstones removed only at the terminal merge that covers all older
  records. No shadow buckets, INIT optimization, or hot-archive list.
- Merges may be computed synchronously at first. An output computed early
  stays pending until its specified promotion advance. No wall clock,
  background-worker completion order, heap pressure, local batch-size
  threshold, or filesystem enumeration order may affect committed bytes.
- Format, codec, schema, level geometry, duplicate/no-op handling, tombstone
  rules, and hash composition are consensus inputs. They are not per-node
  tuning knobs. Local indexes, cache sizes, compression, and worker counts
  may vary only if they leave those inputs and resulting commitments unchanged.

The BucketList is not a general Merkle search tree with logarithmic record
proofs. Keep membership/non-membership proofs out of the advertised v0.1
contract. A slow sorted-map digest may be useful as a test oracle, but it is
not the fast BucketList root. That exclusion holds for v1 profiles;
[ADR 0002](adr/0002-block-hashed-v2-buckets-and-record-proofs.md) records the
accepted opt-in v2 profile decision that adds block-hashed buckets and record
proofs without touching any v1 history.

## 5. Implementation shape

Start with one pure Zig module, `bucketlist`, independent of SLCP, Cap'n Proto,
and platform I/O. It contains the typed database, codec, batch normalization,
bucket creation/merge, level scheduling, and checkpoint manifest model. It
must be usable on native targets and `wasm32-freestanding`.

Keep key encoding, merge cursors, and level scheduling behind the database
interface. Test them directly where byte-level vectors need it, but do not
make developers orchestrate those internals. Delay a public storage abstraction
until the memory and file implementations establish what actually varies.

Add a separate native module, `bucketlist-store`, in M5. It takes
`std.Io` explicitly and owns immutable bucket files, manifests, garbage
collection, and recovery. This keeps the common import name `bucketlist`
stable and lets the deterministic database remain usable without a filesystem.
Separate optional consumer packages import SLCP; the main manifest never
requires a sibling checkout.

M7–M9 add `bucketlist-disk`, exporting `Database(Schema)` and `Host(Schema)`.
The disk database retains hashes and frontier descriptors in memory, with
canonical bucket contents on disk. The host owns bounded admission and durable
execution. The existing portable `bucketlist` database and
`bucketlist-checkpoints` manager remain distinct choices. Native disk manifests
have a separate local format and do not inherit the portable checkpoint's
aggregate byte cap. See the [disk and host contract](disk.md).

## 6. SLCP integration

Use `slcp.OwnedAppNode(App)` in a new consumer example under this repository.
The current registry already uses it for heap-backed state. Do not put a
database with owned allocations into the by-value `AppNode` interface.
Source: [owned application contract](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/src/node/owned_app_node.zig#L42).

For the first example, one externalized slot corresponds to one database
advance. Agree on a bounded application ledger value that contains enough data
to execute the update and binds its predecessor. Compute the resulting
database commitment during deterministic apply, then include it in the
application header/observation. Do not propose only a post-state root with no
data-availability or independent validation protocol. Respect SLCP's configured
value size (4096 bytes by default, at most 65536 at the inspected revision).
Sources: [driver](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/src/driver.zig),
[limits](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/src/engine/limits.zig#L8).

The adapter must account for these real constraints:

1. `validate` and `combine` have no allocator or I/O. Use allocation-free
   reads and bounded command scratch storage. Check structural bounds, base
   commitment, expected advance, and application preconditions before a value
   becomes eligible. Allocation failure must never change a validity verdict.
   Distinguish malformed values from values whose predecessor the local node
   has not reached: future state can be `.maybe_valid`, not automatically
   `.invalid`. Fully check the immediate successor against its known base.
   `combine` must be total for every admitted nonempty candidate set and its
   result must pass its own validator as valid or maybe-valid.
2. `apply(*State, Command, gpa)` can return only `Allocator.Error!void` and has
   no slot-context argument. Carry a validated advance in the command or
   derive it from the persisted predecessor; do not read a clock or process
   counter. All non-OOM database failures must have been excluded by the
   deterministic precheck and serialization contract. An internal violation
   is fatal, never a silently skipped agreed value.
3. Preparation and commit run on the engine thread for the small in-memory
   MVP. OOM fails the node closed; library failure atomicity also keeps state
   intact. Do not wait for workers or perform file I/O inside these hooks.
   Measure worst-case spill latency, not only average update throughput.
4. `observe` returns an owned checkpoint/read snapshot or an independently
   owned observation. Preserve exact ownership and `release`/`deinitObs`
   semantics when crossing to the user thread.
5. Restart restores the database frontier **and the exact previous consensus
   value** via `initialSlot`/`initialCommand`. The root cannot replace that
   value because nomination hashes its bytes.

Sources: [owned-state ADR](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/docs/adr/0003-owned-application-state.md),
[registry adapter](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/examples/registry/src/app.zig#L32),
[driver hot path](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/docs/determinism.md#3-the-hot-path).

The owned-state interface is Experimental and newer than the companion's
v0.1.0 tag. Record an exact compatible revision for consumer validation. A
separate local integration package can use a sibling path; release validation
must also use immutable dependency URLs and hashes. When importing the native
`slcp` module, access its core through `slcp.core` to avoid a second instance of
the same dependency graph.
Source: [SLCP build modules](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/build.zig#L62).

## 7. Checkpoints and persistence

A logical export is not a resumable BucketList checkpoint. Restore must retain
the schema/profile, advance, current/snapshot bucket hashes and bytes, and any
pending merge inputs or descriptors necessary to resume the same future
schedule. Cached outputs may be discarded only when exact recomputation is
proved. Reject missing buckets, unsorted or duplicate entries, noncanonical
records, hash mismatches, wrong profiles, and impossible schedule states.

Root verification authenticates only what its specified preimage covers.
Pending-work metadata must be derivable and checked against the authenticated
frontier, or separately bound into the checkpoint commitment/certificate;
accepting arbitrary unhashed pending inputs would permit a future fork. M3
must settle that rule with adversarial continuation tests.

M5 stores immutable content-addressed buckets, makes bucket data durable
before publishing the manifest, then atomically installs a durable frontier.
Old checkpoints and readers pin referenced files. Garbage collection only
deletes unreachable files after publication; pending-merge inputs count as
reachable. Crash testing covers each write/flush/rename/publication boundary.

Application recovery binds the saved frontier to its journal replay range,
header ancestry, exact previous value, and trust policy. The SLCP journal's
retention floor must never advance past the only recoverable application
checkpoint. Local integrity checks alone do not turn peer-supplied snapshots
into authenticated checkpoints.

The authorized native-host design uses the raw SLCP node's existing
`DeliveryHook` for bounded admission. Its callback hands off ownership without
waiting for filesystem work. An admission failure is explicit backpressure and
stops delivery; recovery outside the callback replays contiguous agreed values
from the durable frontier. `OwnedAppNode.apply` remains the in-memory example's
interface and is not extended with filesystem errors. M9 implements and verifies
this contract against the pinned companion, with any necessary companion
changes verified through the same integration gates.

## 8. Milestones and exit criteria

| Milestone | Deliverables | Exit evidence |
| --- | --- | --- |
| M0 — research and tooling | This plan, source report, glossary, independent Git repo, aligned `mise.toml`, `just doctor`. | `mise install` succeeds and `doctor` reports the expected Zig and just versions. **Done.** |
| M1 — schema and byte contract | **Done (Experimental).** Minimal `build.zig`/manifest/module, typed two-table consumer, normative format, built-in codec, sorted-map semantic oracle, initial literal vectors, test/fmt commands and Linux/macOS CI. | Exact bytes/hashes for empty, single-record, two-table, signed-key and bounded-byte cases; namespace/schema-version changes alter commitments; malformed encodings rejected; declaration-independent table identity; compiled consumer; allocator cleanup checks. |
| M2 — bucket and merge engine | **Done (Experimental).** Immutable bucket builder/reader, canonical batch reduction, upsert/tombstone streaming merge, terminal deletion rule. | Golden merge cases; randomized equivalence to the independent sorted map; no duplicate visible keys or resurrected deletions; failure-atomic preparation under injected allocation failures. |
| M3 — complete in-memory database | **Done (Experimental).** Fixed schedule, eleven-level profile, deterministic pending/promotion state, typed reads/views, atomic multi-table prepare/commit, commitment, exact checkpoint/restore. | Boundary traces including empty advances, stale prepared results, bottom-level deletion, and checkpoint continuation; same trace gives identical bytes/roots across ordering of independent batch inputs, targets, optimization modes, and artificial worker schedules. |
| M4 — SLCP consumer MVP | **Done (Experimental).** New two-table application importing both packages; bounded canonical values, owned state, root-bearing headers, restart snapshots. | Three loopback nodes agree on every root; kill/restart one node around spill/checkpoint boundaries; a lagging node catches up without rejecting valid future values; replay reaches the same root and exact previous value; no changes required in the sibling engine. |
| M5 — native persistence | **Done (Experimental).** Explicit-I/O bucket store, streaming file merges, durable manifest publication, recovery and reachability GC; separate proposal for SLCP host integration if needed. | Fault injection at publication boundaries; restart yields the last recoverable frontier plus replay; corrupt/missing input rejection; reader/pending-work pinning; bounded-memory merge benchmarks. |
| M6 — release hardening | **Open.** Stable/Experimental surface policy, API snapshot, fuzzing, native/WASM differential runner, package/preflight checks, realistic performance report and usage docs. | Fresh package consumer works without sibling checkouts; Linux/macOS gates pass; no skipped oracle/differential tests masquerade as success; published vectors include provenance and negative cases. |
| M7 — disk-resident typed engine | **Done (Experimental).** `bucketlist-disk.Database(Schema)`, hash-only frontier, bounded typed batch staging, verified disk point reads, pinned disk read views, atomic frontier/recovery-metadata publication, strict reopen and reachability GC. | Exact portable/disk v1 commitments and continuation across spill/terminal boundaries; datasets exceeding the configured working-memory budget; no whole-bucket or whole-checkpoint load; missing/corrupt/noncanonical inputs rejected; retained views survive publication and GC. |
| M8 — real background merges | **Done (Experimental).** Bounded worker threads execute independent merge jobs derived from the immutable pre-advance frontier; each advance waits for every required pending hash before publication. | Real overlapping workers; varied completion orders yield identical bytes and commitments; batch plus per-worker record-buffer memory remains bounded; job failures publish no incomplete frontier; shutdown and GC quiesce workers. |
| M9 — bounded native host and SLCP delivery | **Done (Experimental).** `bucketlist-disk.Host(Schema)`, ownership-moving nonblocking `trySubmit`, capacity including active work, durable acknowledgements, latched failures, raw-node `DeliveryHook` consumer and journal replay outside callbacks. | Full/contended admission returns explicit backpressure without consuming the caller's batch; delivery fails closed without losing agreed values; explicit application-durability acknowledgements constrain journal compaction; restart replays a contiguous suffix from the durable snapshot; ambiguous publication is resolved by reopen; pinned companion integration passes. |

M1 → M2 → M3 is the correctness path. Start M4's adapter sketch during M1 to
check ergonomics, but its cluster gate depends on M3. Define M5's checkpoint
requirements during M3; defer its filesystem implementation. Release the
in-memory MVP as Experimental after M4 if useful; claim durable database
support only after M5. Freeze a supported v0.1 surface after M6.

M1's schema consumer and vectors are implemented, along with the in-memory
database, SLCP restart example, native storage primitives, and release checks.
Follow [validation.md](validation.md) for current evidence rather than treating
the original M1–M5 sequencing as a queue of unstarted tasks. M7 → M8 → M9 extends
that baseline; the new phase does not close M6 or claim production readiness.

## 9. Verification strategy

Use three independent kinds of evidence:

- **Semantic model:** a deliberately simple sorted map folds advances and
  checks visible records. It can verify last-writer/delete behavior but cannot
  validate a history-sensitive BucketList root by itself.
- **Representation model and golden bytes:** a slow deterministic scheduler
  produces expected level contents and transitions. Derive hash literals with
  an independent SHA-256 implementation from documented preimages, not by
  asking the implementation under test to regenerate its own expectations.
- **Stellar reference traces:** use the pinned C++ implementation or an
  explicitly adapted harness to compare the shared schedule/merge subset.
  Record adaptations for generic keys, omitted INIT/shadows, and independent
  framing. Never assert Stellar byte/hash equality. Normal tests consume
  checked-in traces; regeneration is an explicit oracle task in isolated
  scratch storage, not a build of a sibling working tree.

Essential scenarios include create/update/delete/recreate across spill
boundaries; a key hidden by multiple newer tombstones; empty batches;
same logical map reached by different histories; same-key duplicates;
table-ID collisions; profile mismatch; malformed length/enum encodings;
maximum sizes and checked arithmetic; reads pinned across commits; stale
preparation; OOM at each staging allocation; checkpoint tampering including
pending inputs; and repeated restart just before and after promotion.

Use a separate, explicitly identified reduced-depth test profile to force
terminal-level cases cheaply, plus production-profile boundary vectors.
Production profile parameters remain fixed. Randomized tests must record the
seed and failing advance; reduced cases become permanent regression vectors.

Measure bytes hashed/read/written per advance, peak retained memory, lookup
cost, checkpoint cost, and median/tail/max apply latency against the
full-state-hash baseline. Do not promise logarithmic worst-case apply time:
large scheduled merges can dominate. If the in-memory example stalls SLCP
unacceptably, the host scheduling interface becomes required before expanding
the production scope.

## 10. Development experience and packaging

`mise.toml` is the single exact compiler pin, initially
`0.17.0-dev.1786+75044cb04`, matching the inspected SLCP checkout. Pin `just`
to the installed `1.58.0`; the companion currently uses a floating `latest`.
The Zig manifest will carry only the compiler floor, and CI will assert that
PATH agrees with mise rather than repeating an independent compiler version.
Sources: [companion tools](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/mise.toml),
[CI setup](https://github.com/nullstyle/slcp-zig/blob/458e25effc3e9676ac02f9a34c104521a5e0757b/.github/actions/setup-zig/action.yml),
[mise configuration](https://mise.jdx.dev/configuration.html).

Add tools through repo-local mise configuration as the milestones need them:
Node for executing the WASM differential harness, actionlint for workflow
linting, and any supported oracle tooling only when the isolated harness is
chosen. Do not install Cap'n Proto or a C++ build stack for ordinary consumers.
Zig and just are sufficient for the present planning repo.

Match familiar commands as they become real: `zig build test`, `just test`,
`just fmt`, `just fmt-check`, `zig build vectors`, `zig build check-api`,
`zig build example-smoke`, and eventually `just preflight`. Keep expensive
oracle regeneration and cluster tests explicit. Never provide a green test
target that merely skips unavailable inputs.

Do not cache partially built compiler output across CI runs. Include every
file the build script imports/embeds in the package manifest's `.paths` and
exercise a clean extracted-package consumer. Pin published dependencies by
immutable URL and content hash. Keep compiler upgrades coordinated across the
two libraries without automatically editing the companion repo.

## 11. Remaining design choices

M1/M3's encoding and continuation choices are frozen by the v1 format documents.
M4's in-memory consumer and M5's [native checkpoint manager](checkpoints.md)
remain the validated baseline. M7–M9 implement the accepted disk/host decisions
in [ADR 0001](adr/0001-disk-engine-and-bounded-delivery.md), with completed
resource, failure/recovery, platform, and real-process integration evidence in
[validation.md](validation.md).

M6 now includes deterministic portable/native malformed-input campaigns, fast
seeded CI cases, larger disk workload measurements, sorted streaming batch
normalization, and LLVM coverage-guided campaigns on macOS and native Linux
ARM64 — bounded campaigns plus extended 10M-cycle-per-test soaks — through a
fail-closed wrapper with exact input replay (see
[fuzzing.md](fuzzing.md)). The v0.1 release review — gate evidence, surface
classification, skip audit, and promotion conditions — is recorded in
[release-review.md](release-review.md). The SLCP companion objects are now
fetched from the public `slcp-zig` remote when no local source holds them.
It still needs multi-day soak testing and production workload qualification
before a standalone integration release. Local gates and API
snapshots are necessary evidence, not a stability promise. Disk point reads
are served from a verified per-bucket span index that preserves exact v1
bytes and hashes; scans still govern merges, reopen validation, and
retained-checkpoint verification.
Application-specific journal retention and checkpoint trust remain host policy.
