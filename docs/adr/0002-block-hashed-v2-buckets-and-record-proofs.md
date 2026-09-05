---
status: accepted
---

# Add opt-in block-hashed v2 buckets with succinct record proofs

Plan §4 kept membership and non-membership proofs out of the v0.1 contract
because the v1 bucket hash is a flat SHA-256 over the whole canonical bucket:
it authenticates all-or-nothing, and logarithmic proofs would require changing
committed bytes. The user has now explicitly reopened that direction and
additionally required that new message serialization use capnp-zig
(`capnpc-zig`), pinned once across new bucketlist surfaces. This decision
records the shape agreed for that work; implementation evidence will land in
[validation.md](../validation.md) as it completes.

## Decision

Introduce a **v2 bucket format as an opt-in profile-level choice**, leaving
every v1 history byte-identical. A database chooses v2 at creation; the choice
is recorded in the profile hash and therefore in every commitment digest, so
mixed-version histories are structurally impossible and all recorded v1
evidence stays valid.

**v2 bucket bytes stay bespoke-canonical** — the same auditable
length-prefixed style as v1 — but blocks (ordered record spans bounded by a
target block size) carry per-block SHA-256 domain-separated hashes, and the
bucket hash covers an interior binary Merkle tree over those block hashes with
a specified padding rule for non-power-of-two leaf counts. Block hashing fits
the existing two-pass streaming merge: blocks fall out of the record stream
without buffering a bucket. The read index's span sampling aligns with block
boundaries in v2 buckets.

**Proofs verify against the existing commitment digest.** A proof carries the
record's block bytes, the sibling-hash path to the block tree root, the level
chain (level index, curr/snap placement) to the list root, and the
schema/profile/advance binding to the database digest. Absence semantics are
explicit and distinct: a tombstone record (provable membership of a deletion
marker), an absence-between-adjacent-records proof inside a block, and
terminal-drop absence (the terminal level carries no tombstones, so terminal
absence proves via neighbors and the terminal invariant). Each gets its own
tested meaning before any API ships.

**capnp-zig serializes proof messages, not hashed bytes.** A new
`bucketlist-proofs` module (mirroring `bucketlist-checkpoints`) owns a
`schema/proof.capnp` and commits its generated code, following the slcp-zig
precedent so consumers need neither the capnp compiler nor codegen at build
time. It pins one current capnp-zig release (0.18.0) via the manifest. The
core `bucketlist` and `bucketlist-store` modules remain dependency-free and
expose proof data as plain Zig structs; the module layer only frames them for
transport. The same pin and pattern extend to the other new message surfaces
(host observability events, checkpoint export), which is the agreed
workspace-unification scope: the 0.13/0.16 versions used by frozen SLCP
companion pins are dictated by those pins and are not rewritten here.

## Consequences

- Verification of a proof needs only the 32-byte digest, the proof message,
  and schema knowledge; no database, no disk, and no trusted server. The
  verifier is pure computation over plain data structs (wasm-friendly,
  subject to the wasm gate once the capnp layer lands).
- Proof size is O(log blocks + level chain + one block), not O(bucket); a
  block target near the read-index span size (~64 KiB) keeps proofs small
  and the fast paths aligned.
- Merges, GC, manifests, and the disk engine are format-agnostic in shape:
  they stream records and rehash per profile. Fixed workspace limits
  (`MergeLimits`) gain a block-size knob that is local policy for v2, never
  consensus-visible.
- New evidence obligations: v2 format vectors with an independent verifier,
  proof fixtures across spill boundaries and retained checkpoints, a fuzz
  oracle that mutates every proof component and requires rejection, and
  absence-semantics tests per class.
- The release-review surface classification gains a new experimental module;
  promotion of v2 profiles or proofs out of experimental requires the same
  review refresh as any other surface move.
