# Version-two bucket format: block hashes and record proofs

Normative companion to [format.md](format.md) for the opt-in v2 profile
accepted in [ADR 0002](adr/0002-block-hashed-v2-buckets-and-record-proofs.md).
A database chooses v1 or v2 at creation; the choice is committed through the
profile hash, so histories never mix formats and every v1 byte, hash, and
recorded evidence file remains valid. All integers are unsigned big-endian.
`SHA-256(x)` is SHA-256 over the exact concatenated bytes.

## Record framing

Identical to v1: `table:u32 || key_length:u32 || key || tag:u8`, where tag `0`
is a deletion marker and tag `1` is followed by `value_length:u32 || value`.
Record order is table ID then lexicographic key; duplicates are invalid.

## Blocks

A bucket's records are grouped left-to-right into non-empty blocks by a
greedy byte rule. The first record opens block 0. A block closes as soon as
its accumulated framing length is greater than or equal to
`target_block_bytes`; the next record opens the next block. A single record
whose framing alone reaches the target forms exactly its own block; the final
block may be shorter. The rule is a pure function of the record sequence and
`target_block_bytes`.

`target_block_bytes` is a **profile parameter**: it changes block boundaries
and therefore every block hash, so it is committed through the profile hash
below and is never a local tuning knob. The default v2 profile uses 65536.

Block hash, binding position and content:

```
block_hash(i) = SHA-256("bucketlist.block.v2\x00" || u64(i) || block_bytes)
```

## Block tree

The ordered leaf list `block_hash(0) .. block_hash(n-1)` reduces to one root
by the canonical peak structure. Each leaf is appended as a rightmost peak of
span one; while the two rightmost peaks have equal span they are replaced by

```
node = SHA-256("bucketlist.blocknode.v2\x00" || left || right)
```

with doubled span. After all leaves, the remaining peaks (spans strictly
decreasing, the binary decomposition of `n`) fold left-to-right with the same
node hash into the block root. At powers of two this is the classic balanced
binary Merkle tree; `O(log n)` state computes it streaming. With `n == 0`
blocks the root is the constant `SHA-256("bucketlist.block.v2.empty\x00")`.
The reduction is deterministic and independent of any padding or salt.

A leaf's proof path covers the balanced span inside its own peak, then — if
earlier peaks exist — one left sibling equal to their whole fold, then every
later peak as a right sibling. The leaf count fixes the shape, so a verifier
predicts every side and the exact step count.

## Bucket, profile, and chain hashes

```
bucket_hash = SHA-256("bucketlist.bucket.v2\x00" ||
                      u64(record_count) || u64(block_count) || block_root)
profile_hash = SHA-256("bucketlist.profile.v2\x00" ||
                       u32(depth) || u32(4) || u32(target_block_bytes))
```

Level, list, continuation, and database commitment hashes keep their v1
structure and domains, consuming v2 bucket hashes. The v2 empty-bucket hash
(derived from zero records and zero blocks) is the v2 profile's empty
sentinel and differs from the v1 sentinel.

## Merges

A merge output's blocks are derived by applying the greedy block rule to the
**merged record stream** — never by concatenating or reusing input blocks.
The output hash is therefore a pure function of the merged record sequence
and the profile, computable in the existing two-pass bounded-memory merge.

## Proofs (Stage 2 preview)

## Proof semantics (final)

A **membership proof** carries the record's block bytes, block index, the
bucket's counts, the sibling path through the peak structure, the slot
placement, the full frontier levels, and the schema/profile/advance
binding; the verifier re-derives block hash, path fold, bucket hash, slot,
and commitment digest, predicting every path side from the leaf count.

**Absence classes**, each exactly defined and tested:

1. **Tombstone membership.** A deletion marker is an ordinary record: a
   membership proof with a null value claim. Provable like any value.
2. **Absence between neighbors.** Inside the bracketing block, the key
   sorts strictly between two adjacent records — or before the first
   record of block zero, or after the last record of the final block.
   Any other placement could hide the key in a sibling block.
3. **Terminal-drop absence.** At the terminal level the engine enforces
   the v1 invariant that no tombstones survive (reopen validation
   rejects violations), so an absence proof over the terminal bucket is
   complete: nothing can hide there. A key deleted and dropped at
   terminal depth is therefore *deliberately indistinguishable* from a
   key that never existed — deleted history is not committed state, and
   no proof can or should recover it.

**Youngest-wins composition.** A visible-state proof lists younger slots
youngest-first (level ascending, current before snapshot, the engine's
own lookup order), each proving class-2/3 absence, and requires every
strictly younger slot to be covered or hold the computable empty-bucket
hash; the deciding slot carries the class-1 or class-2 result. This is
what `Database.prove` generates and `verifyVisible` checks.

**Range proofs.** For one table and encoded key interval `[start, end)`
with `start < end`, a **range proof** carries, for every frontier slot
whose committed hash differs from the computable empty-bucket hash, a
**covering run**: a consecutive, ascending list of authenticated blocks
(`RangeRun`). Record order is global across blocks (blocks are prefix
segments of the sorted stream), so completeness reduces to two brackets:
the run's first block is block zero, or its last record sorts strictly
before `(table, start)`; the run's last block is final, or its first
record sorts at/after `(table, end)`. Under those rules no in-range
record can exist outside the run, a run from a bucket with no in-range
records degenerates to its boundary witnesses (a block ending before
`start` through one starting at/after `end` — a block mixing records
below `start` with records at/after `end` forces one more), and the
verifier recomputes each run's block hashes, path folds (all blocks in a
run must derive the same root), bucket hash, slot binding, and the chain
digest exactly as the single-key proofs do. Runs are ordered
youngest-first; the claimed entries must be exactly the youngest-wins
live records inside the interval — keys strictly ascending, tombstones
decided by a younger slot omitted — which `verifyRange` recomputes from
the authenticated blocks. Verification keeps its cursors on the stack,
so proofs with more than `max_range_runs` (64) slot runs are rejected;
the checkpoint format caps depth at 31.

**Wire and artifact encodings.** capnp (`schema/proof.capnp`) frames
proof messages across process boundaries; range proofs use the
`RangeProof`/`RangeRun`/`RangeBlock`/`RangeEntry` structs with the
committed-codegen pattern. The standalone wasm verifier instead consumes
the flat framing (`src/proof_flat.zig`): one linear buffer per proof —
magic (`BKLFVIS1`/`BKLFRNG1`), then big-endian `u32`/`u64` counts,
`u32`-length-prefixed byte fields, 32-byte hashes, and single-byte tags,
with paths as `(right:u8 || hash:32)*`. Decoding bounds-charges every
declared count against the remaining input before allocating, rejects
truncated and trailing bytes, and allocates only from a caller-supplied
allocator, so the freestanding artifact decodes into a fixed buffer over
static memory.
