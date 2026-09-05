# v0.1 release review

Reviewed 2026-09-05 at the release-review commit on `guided-soak`, covering
the M6 release-review item in [plan.md](plan.md) §8/§11. The scope is the
four importable modules (`bucketlist`, `bucketlist-store`,
`bucketlist-checkpoints`, `bucketlist-disk`), the packaging story, and the
evidence claims in these documents. Promotion to a non-`dev` `0.1.0` tag is
a separate decision with its own conditions listed at the end.

## Gate evidence at the reviewed revision

| Gate | Result |
| --- | --- |
| `just doctor` / `fmt-check` / `ci-lint` | Pass; pinned compiler `0.17.0-dev.1786+75044cb04`, just 1.58.0. |
| `just vectors-check` | Pass: 274 unique buckets, 4 profiles, 128 advances each against the independent model. |
| `just test` (Debug + `-Doptimize=ReleaseSafe`) | Pass: 99 tests, 100 native mutation cases, fixed guided corpus through LLVM, consumers, API snapshot check. |
| `just wasm-diff` | Pass: native and wasm32-freestanding match `53aee563…` over 128 advances. |
| `just guided-self-test` | Pass: armed synthetic failure discovered under a zero build exit, recovered, and exactly replayed. |
| `just package-preflight` | Pass: fresh extracted archive builds and runs portable, persistent, and disk-host standalone consumers without any sibling checkout (M6 exit criterion). |
| `just linux-check` | Pass: native Linux ARM64 container gate with repo-pinned mise tools. |
| `zig build check -Dtarget=x86_64-linux` | Pass: full cross-compile of native tests and examples. |
| Fuzzing evidence | Bounded guided campaigns and 10M-cycle-per-test soaks on macOS and Linux ARM64: 360M+ recorded runs, zero failure diagnostics ([fuzzing.md](fuzzing.md)). |

Skip audit: exactly one `error.SkipZigTest` exists — the FIFO helper on
platforms other than Linux/macOS, which cannot fire on supported targets. No
oracle, differential, or adversarial test is skipped or softened.

Environment observation, recorded for honesty: on this development machine,
parallel suite runs occasionally log a one-shot `failed command` line that the
build runner retries successfully; exact-seed replays and repeated full runs
pass. Pushed CI will provide independent confirmation.

## Surface audit and v0.1 classification

`docs/api.txt` is the frozen interface snapshot; `zig build test` fails on any
drift (update only via `zig build api-snapshot`). The snapshot now enumerates
all four modules — 122 declarations across 27 groups, including the
previously unlisted `Store` surface (14 operations) added by this review.

**Supported in v0.1** (breaking changes require a version decision):

- `bucketlist`: `Database(Schema)`, `Batch`, `Prepared`, `ReadView`,
  `Codec`/`Bytes`, checkpoint encode/restore, commitments. Evidence:
  vectors, deterministic campaigns, guided soaks, wasm differential,
  allocation-failure sweeps, cross-platform tests.
- `bucketlist-store`: `Store` blob/manifest/merge operations,
  `BucketCursor`, `MergeLimits`. Evidence: fault-injection matrix at every
  publication boundary, corruption/truncation/symlink/FIFO rejection,
  concurrency test, fixed-workspace proofs.
- `bucketlist-checkpoints`: `Checkpoints(Database)` save/load/collect with
  typed retained views. Evidence: 17 checkpoint tests including every
  save/restore allocation failure.
- `bucketlist-disk`: `Database`, `Batch`, `Prepared`, `ReadView`, `Options`,
  `Reference`. Evidence: exact portable parity, adversarial topology and
  budget tests, reopen allocation-failure sweep, benchmarks, plus the
  verified read index with its documented trust semantics
  ([storage.md](storage.md)).

**Experimental within v0.1** (shape may move without a version decision):

- `Host(Schema)` and `HostOptions`/`HostStatus`: the bounded asynchronous
  publication surface is the newest concurrency API and has one consumer;
  its observability fields grew during review (backpressure counter).
- `ReadIndexOptions` tuning fields and the scan/verify variants
  (`scanBucketIndexed`, `lookupBucketIndexed`, `mergeBucketsVerify`): new
  this week; semantics are documented and gated, but knob shapes may evolve.
- `CheckpointLayout` internals and replay tooling interfaces
  (`tools/guided-fuzz.py` flags), which follow the pinned compiler's runner
  defects.

**Byte-frozen consensus inputs** (any change is a format decision, not an API
change): v1 codecs, bucket framing, level/list/profile/schema/commitment hash
composition, and the disk manifest/catalog framing — pinned by literal
vectors and recorded campaign digests.

## Carried limitations

No automatic schema migration, secondary indexes, SQL/planner, succinct
record proofs (excluded by plan §4 for v0.1), or application-independent
checkpoint trust policy. Physical power-loss behavior is untested; fault
injection covers software boundaries only. Warm point reads trust one prior
full verification per blob with a size guard
([storage.md](storage.md) documents the residual risk and the
`read_index = null` opt-out). Production workload qualification and
multi-day soaks remain open; the SLCP companion dependency is not yet an
accessible immutable release.

## Promotion conditions for `0.1.0`

1. Pushed CI green on macOS and Linux x86_64 runners (also closes runtime
   validation on x86_64).
2. A multi-day guided soak on the frozen revision with no findings.
3. Release review refresh if `docs/api.txt` moved since this review.
4. The tag drops `-dev` from `0.1.0-dev` only with the classification above
   re-confirmed.
