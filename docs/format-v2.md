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
by rounds: each round pairs consecutive nodes left-to-right, hashing

```
node = SHA-256("bucketlist.blocknode.v2\x00" || left || right)
```

and an unpaired trailing node passes to the next round unchanged. The last
remaining node is the block root. With `n == 0` blocks the root is the
constant `SHA-256("bucketlist.block.v2.empty\x00")`. The reduction is
deterministic and independent of any padding or salt.

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

A membership proof carries the record's block bytes, that block's index and
leaf count context, the sibling-hash path through the block tree (sibling
per paired round; pass-through rounds contribute no sibling), the level
placement leading to the list root, and the schema/profile/advance binding
to the database digest. Absence classes — tombstone membership,
absence-between-neighbors inside a block, and terminal-drop absence — each
receive an exact tested definition before any proof API is advertised.
