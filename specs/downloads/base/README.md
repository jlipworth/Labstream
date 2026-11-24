# base: the reducer and its conformance check

`DownloadsReducer.tla` is `DownloadLifecycleReducer.reduce` as pure operators. It is kept equal to
the Swift by a generated table, not by review.

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/base
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelReducerTests
LABSTREAM_WRITE_REDUCER_TABLE=1 swift test --package-path PMSKit --no-parallel \
    --filter DownloadsFormalModelReducerTests        # regenerate after a reducer change
```

## What the table holds

`DownloadsReducerTable.tla` is written by `DownloadsFormalModelReducerTests` from the real reducer
(about 1.4 MB, 8,300 lines).

| Part | Size | Inputs |
| --- | --- | --- |
| States | 1,728 | Each of the 9 lifecycles with 192 histories: the empty one, every value of every history field alone (28), every pair of values of two different fields (162; `lastFailure` pairs with three of its eleven values) and one history with every field set. |
| Events | 126 | Every event case with every payload the reducer distinguishes, except `relaunchObserved`. |
| Facts | 1,280 | The whole space of `DownloadRowFacts` under the table's abstraction: 5 routes (Emby Convert with and without a job), 4 checkpoints, 4 bodies and the four flags `pendingArtifactHead`, `deletionPending`, `liveTask`, `snapshotEligible`. |
| Event grid | 1,728 x 126 = 217,728 results | Every state with every event, on the default facts. |
| Relaunch grid | 63 x 1,280 = 80,640 results | `relaunchObserved` for every lifecycle with every `pauseCause` (the rest of the history empty), on every fact record. |

Two lemmas make those two grids the whole reducer. Both are checked on each side:

- **Relaunch is local.** `relaunchObserved` reads only `lifecycle` and `pauseCause` of a state and
  writes only those and `lastFailure`. So its result for any of the 1,728 states is the relaunch
  grid's result with the other fields carried over. Swift: `relaunchIsLocal`, all 1,728 states on
  all 1,280 facts. TLA+: `RelaunchLocal`, the same 2.2 million cases.
- **No other event reads the facts.** Swift: `onlyRelaunchReadsFacts`, the 261 states with at
  most one history field set on all 1,280 facts (42 million reductions), and every state on a
  36-record spread in which every value of every fact field occurs. TLA+: `EventsIgnoreFacts`,
  every state and event on the same spread.

`TableCovers` checks that the table's facts are exactly `AllFacts`, the set written out in TLA+,
and that the states cover every value of every field.

## Configs and results

2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Reducer-Conformance` | pass | pass | one evaluation | 24 s |
| `Mutant-DeletionGuardStaticOnly` | `TableMatches` violated | violated | stops at first error | 2 s |
| `Mutant-IneligibleSnapshotFailsFinalizing` | `TableMatches` violated | violated | stops at first error | 2 s |
| `Mutant-PendingHeadIgnoredWithLiveTask` | `TableMatches` violated | violated | stops at first error | 2 s |

The three mutants are wrong readings of the three relaunch guards. Each agrees with the Swift on
the default facts of every route, checkpoint and body, so the first table, which tried each guard
once on default static facts, passed them. `Mutant-DeletionGuardStaticOnly` is the one the review
found.

A module that tracks only some fields of a reducer state checks its mapping against this table:
see `session/DownloadsSessionRowMap.tla` and `session/DownloadsSessionRowMapCheck.tla`. A
`Projection-<Name>.cfg` (`ProjectionSound`) is the weaker check that the dropped fields never
influence the kept ones. Neither is a conformance check: both compare the reducer with itself.
