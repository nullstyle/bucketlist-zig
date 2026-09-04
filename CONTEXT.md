# BucketList databases

A developer-defined database whose ordered updates produce a reproducible
cryptographic commitment. Applications use that commitment in their own
consensus and history rules.

## Database

**Database**:
The named collections of records an application maintains together as one
committed state.
_Avoid_: Stellar ledger

**Schema**:
The definition of a database's tables, record identities, and permitted values.

**Table**:
A named collection whose records share a key and value definition.

**Record**:
A value identified by a table and a key within that table.
_Avoid_: Ledger entry

**Logical state**:
The currently visible records, independent of the update history that produced
them.

**Batch**:
The complete set of record changes associated with one database advance.
_Avoid_: Consensus value, transaction set

**Advance**:
One position in the database's ordered update history, including positions
whose batch contains no record changes.
_Avoid_: Merge completion

## Buckets and commitments

**Bucket**:
An immutable, ordered collection of record versions and deletion markers.

**Tombstone**:
A record's deletion marker that prevents an older value from becoming visible.
_Avoid_: Missing record

**Level**:
A band of database history represented by a current bucket and a snapshot
bucket.

**Bucket snapshot**:
The older, fixed part of one level awaiting movement into deeper history.
_Avoid_: Database checkpoint

**BucketList**:
The ordered levels that retain recent and older database changes together.

**BucketList root**:
A cryptographic commitment to the BucketList's committed representation. Equal
logical states can have different roots when their retained histories differ.
_Avoid_: Hash of the logical state, consensus certificate

**Database commitment**:
A BucketList root and its scheduled continuation bound to the database's
format and position in its ordered history.
_Avoid_: Consensus value, previous value

**Continuation commitment**:
A commitment to the pending merge results that will enter the database's
committed representation at future advances.
_Avoid_: Current BucketList root

**Format profile**:
The shared rules that determine which database histories have identical
commitments.

**Database checkpoint**:
A saved database frontier sufficient to resume its committed history exactly.
_Avoid_: Logical export, bucket snapshot

**Logical export**:
A listing of the currently visible records without a promise to preserve the
BucketList's historical representation.
_Avoid_: Database checkpoint

## Application consensus

**Slot**:
One indexed instance of application consensus. An integration defines how a
slot corresponds to a database advance.

**Previous value**:
The exact bytes agreed in the preceding consensus slot. A database commitment
does not replace those bytes.

**Authenticated checkpoint**:
A database checkpoint whose commitment has been accepted under the
application's trust rules.
_Avoid_: Hash-verified checkpoint
