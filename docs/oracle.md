# Adapted Core schedule oracle

Run this optional source gate from the repository:

```sh
mise exec -- python tools/check-core-oracle.py
```

Pass `--core /path/to/stellar-core` when the reference Git repository is not
at `../stellar-core`. The repository must contain commit
`100cc3816c59357df488b17972aa5e2846ead831`. Its working tree is neither expanded
nor changed. Ordinary tests do not require a Core checkout or C++ compilation.
The gate invokes this repository's pinned `mise` Zig C++ compiler and writes
only temporary build files outside the reference checkout.

This is an adapted symbolic harness, not a full Core build or an XDR/hash
compatibility test. It provides a separate check on the inherited scheduling
algorithm by compiling the following **verbatim** function definitions from
the pinned `src/bucket/BucketListBase.cpp` Git object at run time:

- `BucketListBase::levelSize`, `levelHalf`, and `levelShouldSpill`.
- `BucketListBase::shouldMergeWithEmptyCurr` and `keepTombstoneEntries`.
- `BucketLevel::snap` and `prepare`.
- `BucketListBase::addBatchInternal`.

The extraction script selects complete function definitions and preserves
their source text without substitution. The standalone C++ wrapper supplies
application/configuration stubs, symbolic ordered maps, synchronous future
results, and the promotion operation. Those adapter components are project
code. In particular, its generic newest-wins merge is not Stellar's live
bucket merge: it has no XDR, INIT records, ledger schema, hashing, filesystem
I/O, worker scheduling, or historical shadow handling. The adapter selects a
post-shadow-removal protocol value and checks that merge shadow lists are empty.

The harness executes Core's actual reverse visitation order, snapshot call,
delayed promotion call, and next-merge preparation. It compares every current,
snapshot, and pending bucket's complete symbolic key/value map, including
tombstones and pending absence, with the independent Python corpus. Profiles
of depths 1, 2, 3 and production 11 each execute 128 advances. These include
simultaneous spills and terminal tombstone removal in the smaller profiles.
Additional geometry cases exercise either side of half/full boundaries and
lookahead boundaries for every level, including the deepest production levels.

The resulting independent signals are deliberately limited:

| Check | Evidence |
| --- | --- |
| Core extracted functions versus Python corpus | Shared schedule order, geometry, pending presence, and symbolic merge inputs agree. |
| Python corpus versus Zig tests | This project's byte encodings, roots, continuation hashes, database commitments and restoration agree. |
| Native versus WebAssembly execution | The same typed application trace and restart points produce the independent expected aggregate on both targets. |

Core uses 32-bit ledger numbers at this revision. The oracle does not validate
this library's `u64` extension near exhaustion; dedicated Zig boundary tests
cover that arithmetic. The synchronous adapter also cannot establish Core
worker/I/O correctness or measure a full Core node's behavior.

The source file carries the notice “Copyright 2024 Stellar Development
Foundation and contributors” and is licensed under Apache License 2.0. The
script preserves its original notice on the temporary extracted header and
places the full pinned `LICENSE-APACHE.txt` beside it. No extracted Core source
is checked into this repository. See the pinned
[source](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/src/bucket/BucketListBase.cpp),
[COPYING](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/COPYING),
and [license](https://github.com/stellar/stellar-core/blob/100cc3816c59357df488b17972aa5e2846ead831/LICENSE-APACHE.txt).
