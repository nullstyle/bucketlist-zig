# Bucket and schedule format, version 1

This is the normative contract for `src/bucket.zig` and `src/list.zig`.
The application schema/codec and outer database commitment are specified in
the other format documents. None of these bytes are Stellar XDR or Stellar
BucketList hashes.

All integers below are unsigned, fixed-width, big-endian. All tags are their
literal ASCII bytes followed by one `00` byte. Hashes are raw 32-byte SHA-256
digests, never hexadecimal text. `||` means byte concatenation.

## Immutable bucket bytes

```text
bucket_bytes = "bucketlist.bucket.v1\0" || u64(record_count) || record*
record       = u32(table_id) || u32(key_length) || key || effect
effect       = 00                                      # deletion
             | 01 || u32(value_length) || value        # upsert
bucket_hash  = SHA256(bucket_bytes)
```

Records must be strictly increasing by `(table_id, key_bytes)`. Table IDs
compare numerically; key bytes compare unsigned lexicographically, with a
shorter prefix sorting first. Keys and values are the schema codec's canonical
bytes. In particular, the built-in bounded-byte codec includes its length
prefix, so those keys order by length before contents. A null value is a
tombstone; a non-null zero-length value is a live value. Empty keys are legal
at this internal layer. The schema decides whether they encode a valid key.

The empty bucket has the same tag and an eight-byte zero record count. There
is exactly one representation for an empty bucket, including merge outputs
and untouched levels. Its SHA-256 digest is:

```text
7076a8bba14bcc34e17a8a22d54a16d13b09247075da48782dac74352f01ac12
```

A bucket containing table `7`, raw key `6b` and raw value `76` has bytes:

```text
6275636b65746c6973742e6275636b65742e763100
0000000000000001
00000007 00000001 6b 01 00000001 76
```

Its digest is
`f0c97d1ffee7489cfcb47d1eba0918147cd67b220cbb5db08b045de3118ab940`.

The parser rejects an unknown tag/version, invalid effect tag, truncated
record, duplicate identity, out-of-order identity, incorrect count, or trailing
data. Key/value lengths must fit `u32`; record count fits `u64`; allocation and
total-length arithmetic must fit the target's `usize`. The count is checked
against the input's minimum possible record size before index allocation.
Typed canonicality is additionally checked by the database restore layer.

A merge walks both ordered inputs and chooses the newer record at an equal
identity. It retains all tombstones unless this merge produces the terminal
level's current or pending bucket. Removing a tombstone earlier would expose an
older value. Raw bucket construction and merging do not normalize unchanged
puts or absent deletes; database batch normalization precedes this layer.

## Geometry and schedule

The production profile has depth `11`, levels `0...10`, and factor `4`.
Reduced depths used in tests have distinct profile hashes. The implementation
accepts compile-time depths `1...31`, keeping all schedule arithmetic within
`u64`; applications must agree on a profile rather than choosing it locally.

```text
half(i) = 2 * 4^i
spill(sequence, i) = (i < depth-1) and (sequence mod half(i) == 0)
```

Genesis has sequence zero, empty current/snapshot buckets, and no pending
outputs. An advance is valid only at `previous_sequence + 1`, beginning at
one. Empty advances execute the schedule. At maximum `u64`, another advance
fails with `SequenceExhausted` without changing state. Gaps, repeats, and
reverse advances fail with `InvalidSequence`.

For advance `n`, visit destination levels `i = depth-1` down through `1`.
Whenever level `i-1` spills:

1. Replace source `snap` with source `curr` and clear source `curr`.
2. If the destination has a pending `next`, promote it to destination `curr`
   and clear `next`.
3. Prepare the new destination `next` by merging its current bucket with the
   new source snapshot. Use an empty older input instead if the destination
   will itself spill at `n + half(i-1)`. The terminal level never spills and
   always merges with its complete current bucket.

Then merge the new batch into level zero's current bucket immediately. With
depth one this is the terminal merge, so tombstones are removed there.

The destination's next output is computed synchronously but remains pending
until the *next* incoming spill. Pending output presence is meaningful even
when that output is empty. Reads do not search pending outputs. Reads search
level zero's current and snapshot, followed by level one's current and
snapshot, continuing to the terminal level. The first identity found wins;
a tombstone terminates the search as absent.

The lookahead condition is implemented without overflowing `u64`:
for a nonterminal destination above zero, use an empty older input exactly
when `(floor(n / half(i-1)) mod 4) == 3`. For restore this formula also works
between spill advances because it rounds down to the last merge start.

With one distinct inserted raw identity per advance, the first levels contain
these record counts (`-` means no pending output):

| Advance | Level 0 curr/snap/next | Level 1 curr/snap/next | Level 2 curr/snap/next |
| --- | --- | --- | --- |
| 1 | 1 / 0 / - | 0 / 0 / - | 0 / 0 / - |
| 2 | 1 / 1 / - | 0 / 0 / 1 | 0 / 0 / - |
| 4 | 1 / 2 / - | 1 / 0 / 3 | 0 / 0 / - |
| 6 | 1 / 2 / - | 3 / 0 / 2 | 0 / 0 / - |
| 8 | 1 / 2 / - | 2 / 3 / 4 | 0 / 0 / 3 |

This transition order follows the geometric algorithm in pinned
[Core `BucketListBase.cpp`](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.cpp),
specifically `addBatchInternal`, `shouldMergeWithEmptyCurr`, and
`levelShouldSpill`. INIT/shadow/protocol migration rules are outside this
format. The terminal tombstone rule follows the same oldest-level safety
condition, applied to generic upsert/delete records.

## Hash composition

```text
profile = SHA256("bucketlist.profile.v1\0" || u32(depth) || u32(4))
level[i] = SHA256("bucketlist.level.v1\0" || u32(i)
                  || hash(curr[i]) || hash(snap[i]))
root = SHA256("bucketlist.list.v1\0" || profile || level[0] || ...)

pending[i] = u32(i) || 00                              # no merge scheduled
           | u32(i) || 01 || hash(next[i])             # merge scheduled
continuation = SHA256("bucketlist.continuation.v1\0" || profile
                      || pending[0] || pending[1] || ...)
```

The production profile hash is
`734e3f46c604ea4273d1cad1d0e9a2fdea98454b0318fc9b51a25e65a5040961`.
Its empty root is
`0f7cb01455040129fac75fe61b3684b8aa49c176d9fbebb24d838f2f9e5ee73e`,
and its genesis continuation hash is
`d7a4d7eb08e7c2d334d5ab6b9935fffd84b939a5cf4755c8eb396b2a2344dbef`.

The outer database commitment must bind the schema, profile, sequence, root,
and continuation hash. A bare root is insufficient to authenticate a
checkpoint. An attacker could otherwise substitute a pending output while
preserving its present root. Checkpoint validation also recomputes pending
outputs from their current/snapshot inputs and schedule and checks their
hashes, along with pending presence, untouched levels, terminal emptiness,
and terminal tombstone absence. Validation cannot establish authentic history
without a trusted expected outer commitment.

Different histories can have equal live records and sequence but different
roots. For example, put one record at advance one and advance an empty batch
at two; compare with an empty batch at one and that same put at two. One
record lies in a snapshot while the other lies in level zero's current
bucket. Empty batches may also preserve the bare root while changing sequence
or pending presence. Use the full database commitment in applications.

## Ownership, errors, and reproducibility

Bucket handles pin immutable encoded bytes and their ordered index. `retain`
and `release` use atomic reference counts. Cross-thread sharing requires an
allocator that allows the last holder's thread to free its storage, plus
synchronization while acquiring a handle from a mutating database. A list
clone costs `O(depth)`, allocates nothing, and retains these handles. Borrowed
record slices remain valid while a corresponding bucket handle is retained.

Advance builds a retained candidate and publishes only after every allocation
and merge succeeds. An OOM leaves sequence, values, current/snapshot roots,
pending outputs, and existing read snapshots unchanged. Dropping the candidate
releases all tentative allocations. No full logical database clone is needed.
Merges are synchronous, so a large spill still has linear foreground cost.

The independent Python model in `tools/reference.py` uses dictionaries and
explicit lookahead arithmetic, not production Zig encoders or merge code.
It generates checked-in byte/hash fixtures under `vectors/`. Unit tests check
literal frames, production roots at early/simultaneous spill boundaries,
schema and database commitments, and semantic maps through terminal deletion.
The cross-target runner consumes the same typed operations on native and
WebAssembly builds. These tests establish this project's format and shared
schedule behavior; they do not claim hash compatibility with Core.
