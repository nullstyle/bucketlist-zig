@0xd4a1b2c3e5f60718;

# Wire framing for the v2 proof structures (docs/format-v2.md). The hashed
# bucket bytes never use this format; capnp frames proof messages only.
struct Hash {
  bytes @0 :Data;  # exactly 32
}

struct Step {
  hash @0 :Hash;
  right @1 :Bool;
}

struct BucketProof {
  block @0 :Data;
  blockIndex @1 :UInt64;
  blockCount @2 :UInt64;
  recordCount @3 :UInt64;
  path @4 :List(Step);
}

struct ChainLevel {
  curr @0 :Hash;
  snap @1 :Hash;
  next @2 :Hash;  # null when no pending output
}

struct SlotPlacement {
  slotLevel @0 :UInt32;
  slotSnapshot @1 :Bool;
  bucket @2 :BucketProof;
}

struct VisibleProof {
  table @0 :UInt32;
  key @1 :Data;
  value @2 :Data;  # null: tombstone or absent
  absent @3 :Bool;
  younger @4 :List(SlotPlacement);
  deciding @5 :SlotPlacement;
  schemaHash @6 :Hash;
  profileHash @7 :Hash;
  advance @8 :UInt64;
  levels @9 :List(ChainLevel);
}
