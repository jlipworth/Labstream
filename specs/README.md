# specs/

TLA+ models of Labstream subsystems, checked with TLC. This page covers the layout and how to
run the checks. What each model covers, what it found and how it is kept equal to the Swift are
in each area's canonical doc and plan:

- downloads: [docs/DOWNLOADS-OFFLINE.md, "Formal model (TLA+)"](../docs/DOWNLOADS-OFFLINE.md#formal-model-tla)
  and [docs/plans/2026-11-24-downloads-tla-model.md](../docs/plans/2026-11-24-downloads-tla-model.md);
- playback restart and cleanup: [docs/PLAYBACK-ARCHITECTURE.md, "Formal model (TLA+)"](../docs/PLAYBACK-ARCHITECTURE.md#formal-model-tla)
  and [docs/plans/2026-11-25-playback-tla-model.md](../docs/plans/2026-11-25-playback-tla-model.md).

## Layout

```text
specs/
  downloads/                  one area: the downloads manager
    base/                     modules every other folder imports
      DownloadsBase.tla         shared vocabulary, and the contract for writing a module
      DownloadsReducer.tla      DownloadLifecycleReducer.reduce as pure operators
      DownloadsReducerTable.tla generated from the Swift reducer; do not edit by hand
      DownloadsReducerConformance.tla, Reducer-Conformance.cfg
    session/                  DownloadsSessionCore.tla: transfer, finalize and sweep;
                              DownloadsSessionRowMap.tla (how the session stores a reducer
                              state) and DownloadsSessionRowMapCheck.tla
    admission/  server-prep/  cleanup/  wake/  side-assets/
    storage/  range-train/  status/
  playback/                   one area: playback restart, reopen, Retry and cleanup
    base/                     PlaybackBase.tla (abstract server: jobs per session id and
                              incarnation, stops, acks, recreated jobs) and
                              PlaybackControllerOps.tla (controller state and steps); the
                              contract for writing a module
    restart/                  PlaybackRestart.tla: the backend-agnostic controller core
    plex/  emby/  jellyfin/   each backend's replacement order over base/
    proxy/                    PlaybackProxy.tla: the PMSKit loopback proxy's listener,
                              request handlers and upstream session
```

A module folder holds `Downloads<Name>.tla` (`Playback<Name>.tla` in `playback/`), any helper module (`wake/` has
`DownloadsWakeLaunchGate.tla`, `status/` has `DownloadsStatusPhase.tla`, whose table the Swift
tests read), its configs and a `README.md` with the model-to-Swift table, bounds, properties,
per-config results and finding traces. `session/README.md` holds the second-round changes,
results and the F4 trace; the pilot's design and F1 to F3 are in the plan document.
`base/README.md` describes the reducer table and its coverage.

## Running

```sh
scripts/check-tla-specs.sh                                          # everything, default tier
scripts/check-tla-specs.sh specs/downloads/admission                # one module folder
scripts/check-tla-specs.sh specs/downloads/session/Current-Static.cfg   # one config
scripts/check-tla-specs.sh specs/downloads/base/DownloadsReducer.tla    # parse one module, run its configs
scripts/check-tla-specs.sh --deep                                   # also the deep configs
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/status
```

The script needs a JDK (Homebrew `openjdk`, or `JAVA=`) and downloads a pinned `tla2tools.jar`
into the gitignored `build/tla/`. It runs SANY and TLC inside each folder with
`-DTLA-Library=<area>/base`, so `EXTENDS DownloadsReducer` resolves from any module folder. To
run TLC by hand, do the same. `TLC_WORKERS` defaults to `auto` and `TLC_HEAP` to `4g`. Each
config's log is kept at `build/tla/<area>/<module>/<config>/tlc.log`.

Run one `scripts/check-tla-specs.sh` at a time in a worktree. Two runs over the same folder share
`build/tla/<area>/<module>/<config>/` and report wrong results.

## Configs

A config is `<Kind>-<What>.cfg` in its module's folder. The first lines are headers:

```text
\* SPEC: DownloadsAdmission              module to check: this folder's, or one in base/
\* EXPECT: pass                          or: violation <InvariantOrActionProperty>,
                                         violation DEADLOCK, violation TEMPORAL,
                                         violation TEMPORAL <Property>
\* TIER: deep                            only on deep configs
```

| Kind | Meaning | Must |
| --- | --- | --- |
| `Current` | The code as it stands. | pass |
| `Liveness` | A fairness run of the code as it stands. Never uses `SYMMETRY`. | pass |
| `Faithful` | One shipped fix turned off. Shows the model can see that bug. | be violated |
| `Mutant` | A deliberately injected bug, for a subsystem with no historical one, or the mutation that once slipped past a check, kept so the check's strength stays tested. | be violated |
| `Finding` | An open defect the model found on the current design. A finding that holds only if a server behaves a particular way says so in its header ("conditional on …"), and a config that passes only under such an assumption is reported as "pass (given …)". | be violated until fixed |
| `Proposed` | Proposed fixes turned on. | pass |
| `Projection` | Proves the reducer fields a module leaves out never affect the ones it keeps. Runs `DownloadsReducerConformance` from `base/`. | pass |
| `Deep` | Larger bounds, `TIER: deep`. Skipped unless `--deep`, `--deep-only` or `TLC_TIER` asks, or the file is named. | pass |

A config for a helper module keeps that module's name in front
(`wake/WakeLaunchGate-Current-Gate.cfg`, `session/SessionRowMapCheck-Current-RowMap.cfg`). A
module that tracks only some reducer fields puts its mapping operators in a helper module and
checks them against the reducer table (`session/SessionRowMapCheck-*.cfg`). That check runs the
operators the model runs; `Projection` only checks field names.

### What counts as a result

The runner accepts a run only when TLC's exit status, its banner and a clean finish agree:
status 0 with "No error has been found" for a pass; 12 for an invariant; 13 for a liveness
property or an action property; 11 for a deadlock. In every case there must be exactly one
violation banner, no other `Error:` line, and TLC's closing "Finished in" line. A crash, an
out-of-memory error, a killed JVM, an evaluation or configuration error, or a truncated log
fails the config whatever was printed first. This holds for `EXPECT: violation` configs too, so
a `Faithful`, `Mutant` or `Finding` config cannot pass because TLC died after printing the
expected banner.

### Liveness expectations

TLC reports a failed liveness property only as "Temporal properties were violated", without its
name. A config that checks one property writes `EXPECT: violation TEMPORAL`. A config that lists
several properties must name the one that fails: `EXPECT: violation TEMPORAL WaitingRowIsServed`.
The runner then runs TLC twice from copies of the config: once with only the named property,
which must be violated, and once with the others, which must hold. An unnamed `TEMPORAL`
expectation over several properties fails without running, and a name that is not in the
config's `PROPERTY` list is an error (exit 2). The copies and the second log
(`only-<Property>.cfg`, `without-<Property>.cfg`, `tlc.others.log`) are kept beside `tlc.log`.

## Keeping specs and code together

Each module lists the Swift files it models on `\* MODELS: <path>` lines under its `MODULE`
line. `scripts/check-tla-drift.py` (default range `origin/main...HEAD`) fails when a listed file
changed and nothing in that module's folder did. In `base/` only the module itself or one of its
configs counts. Helper modules that hold no model of Swift of their own carry no `MODELS:` line
(the generated reducer table, the two table checks and the session row map). A change that
leaves the model untouched says so in the commit that makes it:

```text
Spec-Unaffected: comment-only change to the session
```

The guard reads everything from Git objects: the `MODELS:` lines, config ownership and the
modelled files come from the range's head commit, so uncommitted edits never change the answer
(`--list` reads `HEAD`). Commit before relying on it. Two cases are easy to miss:

- A merge commit touches a file when its recorded result differs from Git's own merge of its
  parents: a conflict resolution, or an edit made while merging. That merge needs its own
  trailer or a spec change in the range. A clean merge needs none, and merging the target branch
  in brings no drift. This needs git 2.36 or later.
- A config that the range deleted, moved or re-pointed counts as a change to the module it ran
  at the start of the range, so retiring a shared module's config alongside a code change is
  covered. Deleting a different module's config in `base/` is not.

A `MODELS:` line that names a file missing from the head commit is a failure, so renaming a
modelled file requires the declaration to follow in the same range.

`scripts/check-tla-drift.py --list` prints the map. The reducer table and its conformance check
are described in the docs linked above.
