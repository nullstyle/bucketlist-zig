# Stability

All public interfaces and formats are **Experimental** during `0.1.0-dev`.
The checked-in API snapshot detects accidental drift; it is not a promise that
this initial development version is stable or production-reviewed.

`docs/format.md`, `docs/encoding.md`, and `docs/structure.md` are normative for
the implemented v1 profile. Never change committed bytes under the same profile
or schema identity. Changing table IDs, type layouts, enum tag sets, bounds,
schema namespace/version, level geometry, normalization, or hash rules requires
an explicit epoch and new fixtures. Renaming a Zig type or table field does
not change its structural schema identity.

The descriptor captures structure, not application meaning. Swapping two
same-typed record fields, changing units, or reinterpreting an enum tag can
leave the descriptor unchanged. Such changes still require an explicit
`Schema.version` bump and an application migration decision.

The library has no runtime dependency on SLCP or Stellar Core. The SLCP example
uses a pinned companion revision and its Experimental owned-state interface.
Native storage supports Linux and macOS and is a separate import from the
portable database. Its I/O errors cannot be returned from the current SLCP
`OwnedAppNode.apply` callback; persistence belongs to the host/observation path.
The implemented `bucketlist-disk` database, worker, and host phase
uses raw-node delivery admission with explicit backpressure and recovery
outside the live callback. See [ADR 0001](adr/0001-disk-engine-and-bounded-delivery.md).
These additional interfaces remain Experimental and do not change v1 hashes.

The library supplies commitments, not record membership proofs, validator
certificates, a network transport, or automatic schema migration.
