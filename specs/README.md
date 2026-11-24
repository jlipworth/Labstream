# specs/

TLA+ models of Labstream subsystems, checked with TLC. This page covers the layout and how to
run the checks. What each model covers, what it found and how it is kept equal to the Swift are
in [docs/DOWNLOADS-OFFLINE.md, "Formal model (TLA+)"](../docs/DOWNLOADS-OFFLINE.md#formal-model-tla)
and the plan, [docs/plans/2026-11-24-downloads-tla-model.md](../docs/plans/2026-11-24-downloads-tla-model.md).

## Layout

```text
specs/
  downloads/                  one area: the downloads manager
    base/                     modules every other folder imports
      DownloadsBase.tla         shared vocabulary, and the contract for writing a module
      DownloadsReducer.tla      DownloadLifecycleReducer.reduce as pure operators
      DownloadsReducerTable.tla generated from the Swift reducer; do not edit by hand
      DownloadsReducerConformance.tla, Reducer-Conformance.cfg
    session/                  DownloadsSessionCore.tla: transfer, finalize and sweep
    admission/  server-prep/  cleanup/  wake/  side-assets/
    storage/  range-train/  status/
```

A module folder holds `Downloads<Name>.tla`, any helper module (`wake/` has
`DownloadsWakeLaunchGate.tla`), its configs and a `README.md` with the model-to-Swift table,
bounds, properties, per-config results and finding traces. `session/` has no README; its notes
are the plan document.

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

## Configs

A config is `<Kind>-<What>.cfg` in its module's folder. The first lines are headers:

```text
\* SPEC: DownloadsAdmission              module to check: this folder's, or one in base/
\* EXPECT: pass                          or: violation <Property>, violation TEMPORAL
\* TIER: deep                            only on deep configs
```

| Kind | Meaning | Must |
| --- | --- | --- |
| `Current` | The code as it stands. | pass |
| `Liveness` | A fairness run of the code as it stands. Never uses `SYMMETRY`. | pass |
| `Faithful` | One shipped fix turned off. Shows the model can see that bug. | be violated |
| `Mutant` | A deliberately injected bug, for a subsystem with no historical one. | be violated |
| `Finding` | An open defect the model found on the current design. | be violated until fixed |
| `Proposed` | Proposed fixes turned on. | pass |
| `Projection` | Proves the reducer fields a module leaves out never affect the ones it keeps. Runs `DownloadsReducerConformance` from `base/`. | pass |
| `Deep` | Larger bounds, `TIER: deep`. Skipped unless `--deep`, `--deep-only` or `TLC_TIER` asks, or the file is named. | pass |

A config for a helper module keeps that module's name in front
(`wake/WakeLaunchGate-Current-Gate.cfg`). An `EXPECT: violation` config fails when TLC passes or
reports a different property. TLC reports a failed liveness property only as "Temporal properties
were violated", so those configs expect `TEMPORAL`; the summary adds the property name from the
config's `PROPERTY` list.

## Keeping specs and code together

Each module lists the Swift files it models on `\* MODELS: <path>` lines under its `MODULE`
line. `scripts/check-tla-drift.py` (default range `origin/main...HEAD`) fails when a listed file
changed and nothing in that module's folder did. In `base/` only the module itself or one of its
configs counts. A change that leaves the model untouched says so in the commit that makes it:

```text
Spec-Unaffected: comment-only change to the session
```

`scripts/check-tla-drift.py --list` prints the map. The reducer table and its conformance check
are described in the docs linked above.
