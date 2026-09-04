# BucketList research for a generic Zig database library

Researched 2026-09-04. This report incorporates the clarified scope: **applications define their own database records and encoding; Stellar compatibility is not a goal**. Stellar Core is an algorithmic reference and a source of adversarial cases, not the required wire format, schema, or runtime.

## Recommendation

Build a deterministic, immutable, leveled database accumulator around application-defined keys and records. Start with `put` and `delete`, ordered immutable buckets, scheduled merges, explicit snapshots, and a documented commitment format. Keep the state machine independent of files, workers, clocks, networking, transaction execution, and `slcp-zig`.

The central semantic decision is that a BucketList root commits to **a particular leveled representation reached through a sequence of commits**. It is not a canonical hash of only the currently visible key/value map. The same final records, introduced at different commits or restored through a different layout, can produce different roots. This follows from hashing separate current/snapshot buckets while scheduling their replacement by ledger number. It is not a weakness if all consensus participants use the same history and profile. It must be explicit in the API, bootstrap procedure, and consensus integration. [Core level structure and root contract](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.h), [archive root calculation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/history/HistoryArchive.cpp#L222)

All recommendations below are project design proposals. Source descriptions are labeled as Core behavior and do not imply a compatibility obligation.

The [build plan](../plan.md) resolves the initial product choices after this
research: one list with typed tables, a deliberately restricted built-in schema
codec before custom codecs, and no public storage abstraction until the file
implementation is needed. Where this report discusses alternatives (including
absent-key deletion policy), the build plan is the current proposed direction.

## Evidence and pins

| Reference | Inspected revision | Use |
| --- | --- | --- |
| `stellar/stellar-core` | `100cc3816c59357df488b17972aa5e2846ead831` — 2026-08-14, “Add new mode to apply load for tx set validation” | Primary behavioral reference; the existing workspace checkout points here. |
| `stellar/stellar-xdr` | `9c9c145953e80990d6ff1ae3a6a973a0ce6d0694` | Schema submodule pinned by that Core revision; inspected only to understand the consensus boundary. |
| CAP-0062 | Official `master` page, consulted 2026-09-04; not an immutable implementation pin | Rationale for the live/hot archive split; marked Final, protocol 23. |

The local Core working tree is sparse, exposing `src/scp`. Missing source files were read with `git show` into a temporary research directory; its sparse checkout configuration and tracked files were not changed. The source revision is a reproducible reference, **not a claim about the protocol currently active on any Stellar network**. The application must pin its own commitment specification independently. [Core commit](https://github.com/stellar/stellar-core/commit/100cc3816c59357df488b17972aa5e2846ead831), [pinned schema tree](https://github.com/stellar/stellar-xdr/tree/9c9c145953e80990d6ff1ae3a6a973a0ce6d0694), [CAP-0062](https://github.com/stellar/stellar-protocol/blob/master/core/cap-0062.md)

## What Core teaches us

### Bucket bytes, identity, and empty state

Core writes each bucket entry as one XDR record: a four-byte big-endian length with its high bit set, followed by the canonical XDR object. SHA-256 receives the framing bytes as well as the payload. The hash is over the uncompressed record stream, not concatenated record hashes or an unordered map. [Exact write and hash implementation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/util/XDRStream.h#L479)

An untouched empty bucket has an all-zero hash and no filename. A metadata-only bucket is different: protocol 11+ output normally emits a metadata record even when there are no data entries, so it has bytes and a nonzero content hash. This means “no visible records,” “zero data records,” and “untouched empty bucket” are not interchangeable. [Empty bucket contract](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketBase.h#L88), [metadata emission and output finalization](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketOutputIterator.cpp)

Entry ordering uses logical identity, not payload contents or entry-state discriminants. Core compares entry types and each type's key fields; metadata sorts first. Fresh buckets require unique identities across the combined mutation vectors. This distinction matters for a generic library: a changed value must retain the same identity, and two encodings of the same logical key must not become separate database rows. [Identity comparator](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/LedgerCmp.h), [fresh bucket conversion](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/LiveBucket.cpp#L380)

**Project implication:** define an independent, unambiguous frame and explicit empty-bucket convention. Prefer canonical key bytes as the identity and ordering substrate. Do not hash Zig memory layouts, native-endian integers, pointer values, allocator padding, unordered map iteration, or debug/JSON rendering. Canonical encoding and schema versioning are application-facing consensus contracts.

### Levels, schedule, and commitment

Core has 11 levels, each with `curr`, `snap`, and a pending next-current merge. Its bucket-list commitment is:

```text
level_hash[i] = SHA256(curr_hash[i] || snap_hash[i])
bucket_list_hash = SHA256(level_hash[0] || ... || level_hash[10])
```

Pending outputs do not enter this root until promoted. Neither a binary Merkle reduction nor hashing the 22 bucket hashes directly is the same formula. [Core hash contract and fixed depth](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.h), [independent archive implementation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/history/HistoryArchive.cpp#L222)

Core's ideal level size is `4^(i+1)` ledger batches; a half level is half that. Levels spill at half-level boundaries, except the oldest level never spills. On each batch it visits large levels before small levels, snapshots each spilling source, promotes the destination's previously prepared result, and prepares its next merge. Level zero then merges and promotes the new batch immediately. Before a destination is itself due to snapshot, its next merge starts with an empty current bucket. [Schedule and state-transition implementation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.cpp)

**Project implication:** the *promotion time* is consensus behavior; whether a worker computed the result early is operational. A synchronous implementation can compute pending buckets immediately and keep them staged until the required commit. Simply cascading all newly merged content into older current buckets immediately implements a different algorithm.

For the first project profile, copying the geometric schedule is reasonable; copying 11 levels is optional. Depth, sequence origin, overflow behavior, and all boundaries must be frozen in the format profile. Every successful application commit should advance exactly one logical sequence, including an empty batch. Skipping empty commits must be an explicitly different profile, because it changes later layout.

### Tombstones and lifecycle optimizations

Core live buckets use `INIT`, `LIVE`, and `DEAD` records. For equal keys, older/newer combinations include:

| Older | Newer | Result |
| --- | --- | --- |
| `DEAD` | `INIT(v)` | `LIVE(v)` |
| `INIT(a)` | `LIVE(b)` | `INIT(b)` |
| `INIT` | `DEAD` | No record |
| `INIT` or `LIVE` | `INIT` | Invalid |
| Neither side is `INIT` | Any valid newer non-`INIT` record | Newer record |

The create/delete cancellation is safe only because `INIT` promises that earlier history is absent or dead. Core's documentation explicitly traces how violating that invariant can resurrect a deleted value. [Live merge cases and lifecycle rationale](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/LiveBucket.cpp#L193)

Hot archive merging is simpler: for equal keys it always takes the newer record. Its restored-to-live marker acts as a tombstone. Both list types discard tombstones at the bottom level, where there is no older level whose value could be exposed. [Hot merge implementation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/HotArchiveBucket.cpp#L88), [output tombstone filtering](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketOutputIterator.cpp)

**Project implication:** begin with upsert/delete, taking the newer record and preserving deletes until the oldest level. This accommodates a developer-defined database without requiring the caller to distinguish creation from update. Deleting an absent key should have one documented meaning; a simple baseline retains that delete as a mutation. Lifecycle cancellation is a later commitment-profile change with separate proofs and fixtures, not a transparent optimization.

### Historical rules are reference material, not scope

| Core boundary | Relevant behavior | Project lesson |
| --- | --- | --- |
| Before protocol 11 | Only live/dead bucket states; no metadata. | An absent metadata record is a format state, not permission to guess a current version. |
| Protocol 11 | Metadata and init records; shadowing preserves lifecycle markers. | An optimization can require nonlocal invariants. |
| Protocol 12 | Shadows removed. Old in-flight merges can still follow older rules based on input versions. | A version change may need to preserve previously scheduled work. |
| Protocol 23 | Hot archive and bucket-list-type metadata extension; combined header commitment. | Multiple collections need an explicit commitment composition. |

Constants are in [LiveBucket.h](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/LiveBucket.h#L74) and [BucketBase.h](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketBase.h#L88). Core derives merge versions from input metadata and eligible older shadow versions, checks a maximum supported version, and propagates metadata extensions. [Merge version and metadata rules](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketBase.cpp)

The generic project does not need protocol numbers 10/11/12/23, Stellar record types, XDR, Soroban expiry, hot/cold archives, network repair data, or historic Stellar replay. In particular, the richer archival proposal CAP-0057 should not be mistaken for what the inspected Core implements. CAP-0062 is its smaller live/hot subset. [CAP-0062 scope](https://github.com/stellar/stellar-protocol/blob/master/core/cap-0062.md)

### Consensus integration boundary

In Core, `StellarValue` contains a transaction-set hash, close time, upgrades, and an extension carrying signature/proposed-value information. It does not contain a direct BucketList-root field. `LedgerHeader` separately contains the consensus value, previous-header hash, transaction-result hash, and bucket-list hash. [Pinned value and header schemas](https://github.com/stellar/stellar-xdr/blob/9c9c145953e80990d6ff1ae3a6a973a0ce6d0694/Stellar-ledger.x#L26)

For protocol 23+, Core writes `SHA256(live_list_root || hot_archive_root)` into the header's bucket-list field; before that it uses the live root. It hashes the canonical XDR header to obtain the ledger hash. Thus bucket state participates in the chain commitment, while consensus on a proposed transaction set and execution of that set remain separate responsibilities. [Header bucket commitment](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketManager.cpp#L1106), [ledger header hashing](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/ledger/LedgerManagerImpl.cpp#L2290)

**Project implication:** `bucketlist-zig` should return a typed commitment and let the application decide whether its `slcp-zig` value commits to commands, the previous state root, an expected next root, or a combination. Do not put consensus, signatures, membership, command execution, or speculative state acceptance into the bucket library. An integration example should show the exact application proposal encoding and demonstrate that a failed/rejected proposal cannot replace committed state.

## Proposed generic contract

These choices are intentionally independent of Stellar's format.

1. **Schema adapter.** A compile-time application schema supplies typed keys/records, record-to-key extraction, and canonical key/value encode/decode. Require explicit stable field encodings. Start with caller-owned codecs instead of pretending arbitrary Zig structs have a stable consensus encoding. A small typed sample database should prove the interface is pleasant.
2. **Canonical identity.** Encoded key bytes determine equality and lexicographic order. Encoding must be injective over supported keys. Include collection/table identity where different record families share one list. Default to rejecting duplicate keys in a batch; a transaction builder can coalesce ordered operations before submission.
3. **Owned normalized batches.** The engine receives final put/delete mutations for one successful sequence, copies or takes documented ownership, sorts canonically, validates bounds, then computes a candidate state. It must not depend on caller buffer lifetime or mutation after submission.
4. **Immutable snapshots.** Reads search newest to oldest, with a tombstone terminating the search. Expose explicit snapshot lifetime. A commit constructs the complete replacement state before publishing it, so allocation, decoding, hashing, or storage failure leaves the previous state usable.
5. **Commitment profile.** Version an exact binary specification: codec/schema identifier, record tags, integer widths and byte order, length framing, empty representation, hash algorithm, level depth, schedule, promotion order, and sequence width/origin. Use separate hash-domain tags for buckets, levels, and roots. Bind the profile and application schema identifiers into the root and bind the commit sequence either there or in a mandatory outer state commitment. The prototype can choose SHA-256 without exposing runtime pluggable hashes.
6. **Bounds and errors.** Specify maximum key/value/batch sizes and sequence exhaustion; reject malformed or noncanonical records, unsupported profile versions, trailing bytes, duplicate keys, and invalid snapshot topology. Use explicit errors rather than assertions for application/network input.
7. **Storage seam.** Model immutable content-addressed bucket blobs behind a narrow read/write contract. Start with an in-memory store and deterministic merge engine. Later add atomic filesystem publication, blob verification, and reachable-blob cleanup without changing committed bytes.

Keep configuration that changes hashes distinct from tuning that merely changes resource use. Index sizes, file caching, worker count, and filesystem layout should not alter roots. Different codecs, sort orders, batch boundaries, deletion normalization, schedule parameters, and empty handling do alter roots and therefore require an application-wide agreement.

## Bootstrap and snapshot consequences

There should be two visibly different operations:

- **Create a new history from a database:** canonically ingest the application's existing records at the defined genesis/bootstrap sequence and publish a new root. Every participant must use the same bootstrap rules. Do not promise equivalence with some older history that happens to have the same records.
- **Resume an existing history:** restore the exact current/snapshot topology, sequence, profile, bucket bytes, and pending merge inputs or output. Verify content hashes and the expected commitment before exposing the state.

Core's archive state stores current and snapshot hashes plus future-merge state; post-shadow-removal merges can also be reconstructed deterministically from current/snapshot buckets and the ledger sequence. This is evidence that a logical record dump alone is not the resume format. [History state representation](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/history/HistoryArchive.h), [restart rules](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.h)

If pending outputs are excluded from the committed root, an importer must not trust arbitrary pending output references merely because current/snapshot hashes verify. It must reconstruct or validate those outputs against the authenticated inputs and schedule before their promotion. Otherwise a valid present root could resume into an invalid future root.

A BucketList root alone also does not automatically provide compact per-record membership/nonmembership proofs: Core hashes complete sequential buckets. Do not advertise a Merkle-map proof API without designing another authenticated indexing layer. [Bucket output hashing](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketOutputIterator.cpp), [Core index overview](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/README.md)

## Validation strategy

Use three distinct authorities rather than conflating them:

| Authority | What it can establish | What it cannot establish |
| --- | --- | --- |
| A plain logical map model | Puts, overwrites, removals, visible reads, snapshots preserve database semantics. | Correct bucket bytes, staged layout, or commitment hashes. |
| A small independent executable specification of this project's format/schedule | Exact byte fixtures, topology, roots, and resumed future behavior. | Correctness solely by reusing production encoder/merge code. |
| Pinned Core test/oracle subset | Shared geometric scheduling, newest-wins semantics, tombstone safety, boundary and restart scenarios. | Hash equality with Core when the project's schema, framing, domain tags, lifecycle, or profile differ. |

Core tests cover overwrite order, tombstone expiration at the bottom, init/dead cancellation, shadow resurrection, repeated archive/restore cycles, boundary arithmetic, deepest-current accumulation, and searchable snapshots. Port the cases relevant to the chosen generic profile, preserving provenance. Do not port historical protocol matrices as requirements. [Bucket tests](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/test/BucketTests.cpp), [BucketList tests](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/test/BucketListTests.cpp)

The project fixture corpus should cover:

- Empty initial state, empty successful commits, one put, update, delete, recreation, and deletion of an absent key under the specified policy.
- Multiple collection types; zero bytes and long common prefixes in keys; integer/endian boundaries; exact value framing; rejected duplicate/noncanonical inputs.
- Every early spill boundary and one commit on either side, simultaneous multi-level spills, the final-level no-spill rule, and sequence overflow. Use small test profiles to exercise deep behavior quickly while checking the production profile separately.
- Different input permutations for an identical unique-key batch; different histories reaching an identical visible map; explicitly demonstrate which roots should match and which may differ.
- Restore at every early commit and compare several subsequent roots with uninterrupted execution; restore with pending work complete/incomplete; injected corrupt bytes, unsupported versions, substituted pending outputs, and truncated manifests.
- Allocation/I/O failure during commit and publication; cross-target Debug and optimized builds; in-memory versus disk stores; later, worker completion permutations.

Fixtures should store the profile/schema version, canonical batch bytes, expected bucket bytes or their content hashes, level current/snapshot hashes, commit sequence, and expected root. Golden digests must come from the independent project specification. A Core adapter can map a constrained key/value universe into Core entries and compare normalized merge output/topology, but cannot provide this project's golden hashes.

## Scope order and unresolved decisions

Recommended order: freeze a small format and schema contract; implement canonical records and hashing; implement a synchronous merge engine and staged scheduler; add typed snapshots and database reads; add snapshot import/export and failure atomicity; demonstrate application-owned integration with `slcp-zig`; only then add disk storage, indexing, and asynchronous merges.

Resolve these before stabilizing the public API:

- Whether the developer supplies a codec directly or the library provides a small explicit schema DSL. Avoid automatic serialization of arbitrary structs as the initial promise.
- Whether one list stores all application tables with namespaced keys or the application composes several independently profiled list roots.
- Whether only committed state is public initially or proposals need a cheap fork/preview API immediately. A preview must not publish speculative state.
- The initial depth and sequence width, exact empty/deletion semantics, limits, and where the profile/schema/sequence are bound cryptographically.
- Whether root equality independent of history is actually required. If it is, an authenticated ordered map or an additional canonical map commitment is a different design requirement and should be evaluated explicitly.

No Stellar runtime dependency is required for this scope. The useful inherited ideas are immutable ordered buckets, efficient streaming merge, geometric update scheduling, and a small state commitment. The project owns its database contract, canonical bytes, and consensus-facing guarantees.
